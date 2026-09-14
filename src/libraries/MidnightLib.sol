// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import { IALMProxy }                from "../interfaces/IALMProxy.sol";
import { IRateLimits }              from "../interfaces/IRateLimits.sol";
import { IMidnight, Market, Offer } from "../interfaces/MidnightInterfaces.sol";

import { ERC20Lib }        from "./common/ERC20Lib.sol";
import { MidnightIdLib }   from "./midnight/MidnightIdLib.sol";
import { MidnightTickLib, MAX_TICK } from "./midnight/MidnightTickLib.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";

library MidnightLib {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    // Midnight's own ceiling on the continuous fee, 1% per year expressed per second in WAD.
    uint32 public constant MAX_CONTINUOUS_FEE = uint32(uint256(0.01e18) / uint256(365 days));

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/

    // One slot. maxBuyTick == 0 disables entry, and the fee and loss guards only apply to entry;
    // minSellTick is an exit price floor, so it has to stay reachable (below par net of the fee).
    // maxLossFactor is a fraction of type(uint128).max.
    struct MarketConfig {
        uint16  maxBuyTick;
        uint16  minSellTick;
        uint32  maxContinuousFee;
        uint128 maxLossFactor;
    }

    struct TakeParams {
        IALMProxy    proxy;
        IRateLimits  rateLimits;
        address      midnight;  // Venue entries are pinned to; sells take the venue from the offer.
        bytes32      buyRateLimitId;
        bytes32      sellRateLimitId;
        bytes32      marketId;
        MarketConfig config;
        Offer[]      offers;
        bytes[]      ratifierData;
        uint256[]    units;
        uint256      assetsBound;  // maxAssetsIn when buying, minAssetsOut when selling
    }

    struct RedeemParams {
        IALMProxy    proxy;
        IRateLimits  rateLimits;
        address      midnight;
        bytes32      buyRateLimitId;
        bytes32      redeemRateLimitId;
        bytes32      marketId;
        MarketConfig config;
        uint256      units;
        uint256      minAssetsOut;
    }

    /**********************************************************************************************/
    /*** Config functions                                                                       ***/
    /**********************************************************************************************/

    function validateMarketConfig(MarketConfig memory config) external pure {
        // A zero maxBuyTick is the kill switch: it blocks new entries, including into resting offers.
        require(config.maxBuyTick <= MAX_TICK, "MidnightLib/max-buy-tick-oob");

        // A non-zero minSellTick marks the market as onboarded; it is an exit price floor, so it has
        // to be set low enough that selling below par net of the settlement fee stays possible.
        require(
            config.minSellTick != 0 && config.minSellTick <= MAX_TICK,
            "MidnightLib/min-sell-tick-oob"
        );

        require(config.maxContinuousFee <= MAX_CONTINUOUS_FEE, "MidnightLib/max-continuous-fee-oob");
    }

    /**********************************************************************************************/
    /*** Taker functions                                                                        ***/
    /**********************************************************************************************/

    function buy(TakeParams memory params) external returns (uint256 assetsSpent) {
        require(params.config.maxBuyTick != 0, "MidnightLib/buy-not-enabled");
        require(params.assetsBound != 0,       "MidnightLib/max-assets-in-not-set");

        _validateBatch(params);

        Market memory market = params.offers[0].market;

        // Entries are pinned to the configured venue. Sells are not (the venue comes from the offer,
        // authenticated by the market id), so a repoint leaves unmatured positions sellable.
        require(market.midnight == params.midnight, "MidnightLib/invalid-midnight");

        // Entering crystallizes the continuous fee over the remaining term, so it is checked up front.
        require(
            IMidnight(market.midnight).continuousFee(params.marketId) <= params.config.maxContinuousFee,
            "MidnightLib/continuous-fee-too-high"
        );

        // A non-zero loss factor means this market's lenders have already been slashed by bad debt.
        require(
            IMidnight(market.midnight).lossFactor(params.marketId) <= params.config.maxLossFactor,
            "MidnightLib/loss-factor-too-high"
        );

        // The bound is on the all-in price, so the settlement fee is reserved out of it up front.
        uint256 maxTickPrice;
        {
            uint256 maxPrice = MidnightTickLib.tickToPrice(params.config.maxBuyTick);
            uint256 fee      = _settlementFee(market.midnight, params.marketId, market.maturity);

            require(maxPrice >= fee, "MidnightLib/max-buy-tick-below-fee");

            maxTickPrice = maxPrice - fee;
        }

        uint256 creditBefore  = _credit(market, params.marketId, address(params.proxy));
        uint256 balanceBefore = IERC20(market.loanToken).balanceOf(address(params.proxy));

        // The proxy is Midnight's payer for the whole batch.
        ERC20Lib.approve(params.proxy, market.loanToken, market.midnight, params.assetsBound);

        uint256 totalUnits = _takeBatch(params, false, maxTickPrice, 0);

        ERC20Lib.approve(params.proxy, market.loanToken, market.midnight, 0);

        assetsSpent = balanceBefore - IERC20(market.loanToken).balanceOf(address(params.proxy));

        require(assetsSpent <= params.assetsBound, "MidnightLib/max-assets-in-exceeded");

        // The proxy never holds debt, so a buy increases credit by exactly the units taken.
        require(
            _credit(market, params.marketId, address(params.proxy)) == creditBefore + totalUnits,
            "MidnightLib/credit-delta-mismatch"
        );

        _requireDebtFree(market.midnight, params.marketId, address(params.proxy));

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeMarketKey(params.buyRateLimitId, params.marketId),
            assetsSpent
        );
    }

    function sell(TakeParams memory params) external returns (uint256 assetsReceived) {
        require(params.config.minSellTick != 0, "MidnightLib/sell-not-enabled");
        require(params.assetsBound != 0,        "MidnightLib/min-assets-out-not-set");

        _validateBatch(params);

        Market memory market = params.offers[0].market;

        // Selling receives the tick price less the settlement fee, so the fee is added onto the bound.
        uint256 minTickPrice =
            MidnightTickLib.tickToPrice(params.config.minSellTick) +
            _settlementFee(market.midnight, params.marketId, market.maturity);

        uint256 creditBefore  = _credit(market, params.marketId, address(params.proxy));
        uint256 balanceBefore = IERC20(market.loanToken).balanceOf(address(params.proxy));

        uint256 totalUnits = _takeBatch(params, true, minTickPrice, creditBefore);

        assetsReceived = IERC20(market.loanToken).balanceOf(address(params.proxy)) - balanceBefore;

        require(assetsReceived >= params.assetsBound, "MidnightLib/min-assets-out-not-met");

        require(
            creditBefore == _credit(market, params.marketId, address(params.proxy)) + totalUnits,
            "MidnightLib/credit-delta-mismatch"
        );

        _requireDebtFree(market.midnight, params.marketId, address(params.proxy));

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeMarketKey(params.sellRateLimitId, params.marketId),
            assetsReceived
        );

        _restoreBuyLimit(params.rateLimits, params.buyRateLimitId, params.marketId, assetsReceived);
    }

    function redeem(RedeemParams memory params) external returns (uint256 assetsWithdrawn) {
        // Redemption reads no config value, but an onboarded config is what authenticates the market.
        require(params.config.minSellTick != 0, "MidnightLib/market-not-onboarded");

        // Unlike sell, the market is resolved on the configured venue, so this reverts for ids
        // created under a previous venue until governance repoints back.
        bytes32       marketId = params.marketId;
        Market memory market   = IMidnight(params.midnight).toMarket(marketId);

        // Redemption is at par out of repayments, so units are capped by both sides of the pool.
        uint256 units        = params.units;
        uint256 credit       = _credit(market, marketId, address(params.proxy));
        uint256 withdrawable = IMidnight(market.midnight).withdrawable(marketId);

        if (units > credit)       units = credit;
        if (units > withdrawable) units = withdrawable;

        require(units != 0, "MidnightLib/zero-units");

        uint256 balanceBefore = IERC20(market.loanToken).balanceOf(address(params.proxy));

        params.proxy.doCall(
            market.midnight,
            abi.encodeCall(
                IMidnight.withdraw,
                (market, units, address(params.proxy), address(params.proxy))
            )
        );

        assetsWithdrawn = IERC20(market.loanToken).balanceOf(address(params.proxy)) - balanceBefore;

        require(assetsWithdrawn >= params.minAssetsOut, "MidnightLib/min-assets-out-not-met");

        _requireDebtFree(market.midnight, marketId, address(params.proxy));

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeMarketKey(params.redeemRateLimitId, marketId),
            assetsWithdrawn
        );

        _restoreBuyLimit(params.rateLimits, params.buyRateLimitId, marketId, assetsWithdrawn);
    }

    /**********************************************************************************************/
    /*** Internal functions                                                                     ***/
    /**********************************************************************************************/

    // `tickPriceBound` is the fee-adjusted bound on the raw tick price, a ceiling when buying and a
    // floor when selling. `creditCap` is the sellable position and is ignored when buying.
    function _takeBatch(
        TakeParams memory params,
        bool    selling,
        uint256 tickPriceBound,
        uint256 creditCap
    )
        internal returns (uint256 totalUnits)
    {
        for (uint256 i = 0; i < params.offers.length; i++) {
            Offer memory offer = params.offers[i];

            // The id commits to the whole market, so this authenticates the venue and its config.
            require(MidnightIdLib.toId(offer.market) == params.marketId, "MidnightLib/market-mismatch");

            require(offer.buy == selling,  "MidnightLib/invalid-offer-direction");
            require(params.units[i] != 0,  "MidnightLib/zero-units");

            uint256 price = MidnightTickLib.tickToPrice(offer.tick);
            uint256 units = params.units[i];

            if (selling) {
                require(price >= tickPriceBound, "MidnightLib/sell-price-too-low");

                // Credit drifts down with fee accrual and slashing, and the excess would be naked debt.
                if (units > creditCap) units = creditCap;
                if (units == 0)        break;

                creditCap -= units;
            } else {
                require(price <= tickPriceBound, "MidnightLib/buy-price-too-high");

                // Paying ourselves would net the transfer to zero, hiding the spend from the rate limit.
                require(
                    offer.receiverIfMakerIsSeller != address(params.proxy),
                    "MidnightLib/invalid-offer-receiver"
                );
            }

            totalUnits += units;

            // Midnight requires the unused receiver to be zero; taker mode uses no taker callback.
            params.proxy.doCall(
                offer.market.midnight,
                abi.encodeCall(
                    IMidnight.take,
                    (
                        offer,
                        params.ratifierData[i],
                        units,
                        address(params.proxy),
                        selling ? address(params.proxy) : address(0),
                        address(0),
                        new bytes(0)
                    )
                )
            );
        }
    }

    function _validateBatch(TakeParams memory params) internal pure {
        require(params.offers.length != 0, "MidnightLib/empty-batch");
        require(
            params.offers.length == params.ratifierData.length &&
            params.offers.length == params.units.length,
            "MidnightLib/invalid-batch-length"
        );
    }

    // Reverts on a market that has never been touched (`touchMarket`, permissionless, once per market).
    function _settlementFee(address midnight, bytes32 marketId, uint256 maturity)
        internal view returns (uint256)
    {
        uint256 timeToMaturity = maturity > block.timestamp ? maturity - block.timestamp : 0;

        return IMidnight(midnight).settlementFee(marketId, timeToMaturity);
    }

    function _credit(Market memory market, bytes32 marketId, address user)
        internal view returns (uint256 credit)
    {
        // Stored credit is stale, so slashing and fee accrual come from the protocol's own view.
        ( credit, , ) = IMidnight(market.midnight).updatePositionView(market, marketId, user);
    }

    function _requireDebtFree(address midnight, bytes32 marketId, address user) internal view {
        require(IMidnight(midnight).debt(marketId, user) == 0, "MidnightLib/debt-not-zero");
    }

    // Restores entry capacity by the assets returned; skipped if no buy limit is set, never blocking.
    function _restoreBuyLimit(
        IRateLimits rateLimits,
        bytes32     buyRateLimitId,
        bytes32     marketId,
        uint256     amount
    )
        internal
    {
        bytes32 key = RateLimitHelpers.makeMarketKey(buyRateLimitId, marketId);

        if (rateLimits.getRateLimitData(key).maxAmount != 0) {
            rateLimits.triggerRateLimitIncrease(key, amount);
        }
    }

}
