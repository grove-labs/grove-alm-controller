// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import { IALMProxy }                from "../interfaces/IALMProxy.sol";
import { IRateLimits }              from "../interfaces/IRateLimits.sol";
import { IMidnight, Market, Offer } from "../interfaces/MidnightInterfaces.sol";

import { ERC20Lib }                  from "./common/ERC20Lib.sol";
import { MidnightIdLib }             from "./midnight/MidnightIdLib.sol";
import { MidnightTickLib, MAX_TICK } from "./midnight/MidnightTickLib.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";

library MidnightLib {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint32 public constant MAX_CONTINUOUS_FEE = uint32(uint256(0.01e18) / uint256(365 days));

    uint256 internal constant WAD           = 1e18;
    uint256 internal constant YEAR          = 365 days;
    uint256 internal constant YIELD_BP_RATE = 1e14;  // one basis point per year, WAD
    uint256 internal constant FEE_CBP_RATE  = 1e12;  // one centi-basis point per year, WAD

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/

    struct Fill {
        Offer   offer;
        bytes   ratifierData;
        uint256 units;
    }

    // minSellTick != 0 marks the market as onboarded; maxLossFactor is a fraction of type(uint128).max.
    struct MarketConfig {
        uint16  maxBuyTick;
        uint16  minSellTick;
        uint16  minBuyYield;       // basis points a year
        uint16  maxSellYield;      // basis points a year
        uint16  maxContinuousFee;  // centi-basis points a year
        uint128 maxLossFactor;
    }

    struct TakeParams {
        IALMProxy    proxy;
        IRateLimits  rateLimits;
        address      midnight;
        bytes32      buyRateLimitId;
        bytes32      sellRateLimitId;
        bytes32      marketId;
        MarketConfig config;
        Fill[]       fills;
        uint256      assetsBound;  // maxAssetsIn when buying, minAssetsOut when selling
    }

    struct TakeContext {
        bool    selling;
        uint256 tickPriceBound;
        uint256 yieldPriceBound;
        uint256 settlementFee;
        uint256 creditCap;  // Sellable position, ignored when buying.
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
        require(config.maxBuyTick <= MAX_TICK, "MidnightLib/max-buy-tick-oob");

        require(
            config.minSellTick != 0 && config.minSellTick <= MAX_TICK,
            "MidnightLib/min-sell-tick-oob"
        );

        require(
            continuousFeePerSecond(config.maxContinuousFee) <= MAX_CONTINUOUS_FEE,
            "MidnightLib/max-continuous-fee-oob"
        );

        // Zero would only clear at par and brick the exit, so onboarding has to name a ceiling.
        require(config.maxSellYield != 0, "MidnightLib/max-sell-yield-not-set");
    }

    /**********************************************************************************************/
    /*** Rate conversions                                                                       ***/
    /**********************************************************************************************/

    // Floors, so the effective ceiling never exceeds the annual rate governance named.
    function continuousFeePerSecond(uint256 cbpsPerYear) internal pure returns (uint256) {
        return cbpsPerYear * FEE_CBP_RATE / YEAR;
    }

    // Highest all-in price a buy can pay and still earn `minYield` basis points a year.
    function maxBuyPrice(uint256 minYield, uint256 timeToMaturity, uint256 continuousFee)
        internal pure returns (uint256)
    {
        return _yieldPrice(minYield, timeToMaturity, continuousFee, false);
    }

    // Lowest net price a sell can accept and still give up at most `maxYield` basis points a year.
    function minSellPrice(uint256 maxYield, uint256 timeToMaturity, uint256 continuousFee)
        internal pure returns (uint256)
    {
        return _yieldPrice(maxYield, timeToMaturity, continuousFee, true);
    }

    /**********************************************************************************************/
    /*** Taker functions                                                                        ***/
    /**********************************************************************************************/

    function buy(TakeParams memory params) external returns (uint256 assetsSpent) {
        require(params.config.maxBuyTick != 0, "MidnightLib/buy-not-enabled");
        require(params.assetsBound != 0,       "MidnightLib/max-assets-in-not-set");
        require(params.fills.length != 0,      "MidnightLib/empty-batch");

        Market memory market = params.fills[0].offer.market;

        require(market.midnight == params.midnight, "MidnightLib/invalid-midnight");

        _requireMarketId(market, params.marketId);

        uint256 continuousFee = IMidnight(market.midnight).continuousFee(params.marketId);

        require(
            continuousFee <= continuousFeePerSecond(params.config.maxContinuousFee),
            "MidnightLib/continuous-fee-too-high"
        );

        require(
            IMidnight(market.midnight).lossFactor(params.marketId) <= params.config.maxLossFactor,
            "MidnightLib/loss-factor-too-high"
        );

        uint256 timeToMaturity = _timeToMaturity(market.maturity);

        TakeContext memory ctx = TakeContext({
            selling         : false,
            tickPriceBound  : MidnightTickLib.tickToPrice(params.config.maxBuyTick),
            yieldPriceBound : maxBuyPrice(params.config.minBuyYield, timeToMaturity, continuousFee),
            settlementFee   : _settlementFee(market.midnight, params.marketId, timeToMaturity),
            creditCap       : 0
        });

        uint256 creditBefore  = _credit(market, params.marketId, address(params.proxy));
        uint256 balanceBefore = IERC20(market.loanToken).balanceOf(address(params.proxy));

        ERC20Lib.approve(params.proxy, market.loanToken, market.midnight, params.assetsBound);

        uint256 totalUnits = _takeBatch(params, ctx);

        ERC20Lib.approve(params.proxy, market.loanToken, market.midnight, 0);

        assetsSpent = balanceBefore - IERC20(market.loanToken).balanceOf(address(params.proxy));

        require(assetsSpent <= params.assetsBound, "MidnightLib/max-assets-in-exceeded");

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
        require(params.fills.length != 0,       "MidnightLib/empty-batch");

        Market memory market = params.fills[0].offer.market;

        _requireMarketId(market, params.marketId);

        // No ceiling on the continuous fee or the loss factor here: a market that has turned
        // against the position is exactly the one that has to stay exitable.
        uint256 continuousFee = IMidnight(market.midnight).continuousFee(params.marketId);

        uint256 timeToMaturity = _timeToMaturity(market.maturity);

        uint256 creditBefore  = _credit(market, params.marketId, address(params.proxy));
        uint256 balanceBefore = IERC20(market.loanToken).balanceOf(address(params.proxy));

        TakeContext memory ctx = TakeContext({
            selling         : true,
            tickPriceBound  : MidnightTickLib.tickToPrice(params.config.minSellTick),
            yieldPriceBound : minSellPrice(params.config.maxSellYield, timeToMaturity, continuousFee),
            settlementFee   : _settlementFee(market.midnight, params.marketId, timeToMaturity),
            creditCap       : creditBefore
        });

        uint256 totalUnits = _takeBatch(params, ctx);

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
        require(params.config.minSellTick != 0, "MidnightLib/market-not-onboarded");
        require(params.minAssetsOut != 0,       "MidnightLib/min-assets-out-not-set");

        bytes32       marketId = params.marketId;
        Market memory market   = IMidnight(params.midnight).toMarket(marketId);

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

    function _takeBatch(TakeParams memory params, TakeContext memory ctx)
        internal returns (uint256 totalUnits)
    {
        address receiverIfTakerIsSeller = ctx.selling ? address(params.proxy) : address(0);

        for (uint256 i = 0; i < params.fills.length; i++) {
            Fill  memory fill  = params.fills[i];
            Offer memory offer = fill.offer;

            _requireMarketId(offer.market, params.marketId);

            require(offer.buy == ctx.selling, "MidnightLib/invalid-offer-direction");
            require(fill.units != 0,          "MidnightLib/zero-units");

            uint256 price = MidnightTickLib.tickToPrice(offer.tick);
            uint256 units = fill.units;

            if (ctx.selling) {
                // The fee is taken out of the proceeds, so both floors bind on the gross price.
                require(
                    price >= ctx.tickPriceBound + ctx.settlementFee,
                    "MidnightLib/sell-price-too-low"
                );
                require(
                    price >= ctx.yieldPriceBound + ctx.settlementFee,
                    "MidnightLib/sell-yield-too-high"
                );

                // Credit can shrink from fee accrual and slashing between quote and take.
                if (units > ctx.creditCap) units = ctx.creditCap;
                if (units == 0)            break;

                ctx.creditCap -= units;
            } else {
                // The fee is paid on top of the price, so both ceilings bind on the all-in cost.
                require(
                    price + ctx.settlementFee <= ctx.tickPriceBound,
                    "MidnightLib/buy-price-too-high"
                );
                require(
                    price + ctx.settlementFee <= ctx.yieldPriceBound,
                    "MidnightLib/buy-yield-too-low"
                );

                // Paying ourselves would net the transfer to zero, hiding the spend from the rate limit.
                require(
                    offer.receiverIfMakerIsSeller != address(params.proxy),
                    "MidnightLib/invalid-offer-receiver"
                );
            }

            totalUnits += units;

            params.proxy.doCall(
                offer.market.midnight,
                abi.encodeCall(
                    IMidnight.take,
                    (
                        offer,
                        fill.ratifierData,
                        units,
                        address(params.proxy),
                        receiverIfTakerIsSeller,
                        address(0),
                        new bytes(0)
                    )
                )
            );
        }
    }

    // Rounds against the caller: down for the buy ceiling, up for the sell floor.
    function _yieldPrice(
        uint256 yieldBp,
        uint256 timeToMaturity,
        uint256 continuousFee,
        bool    roundUp
    )
        private pure returns (uint256)
    {
        // Midnight caps maturity 100 years out and the continuous fee at one percent a year, so
        // the crystallized fee stays below par.
        uint256 numerator   = (WAD - continuousFee * timeToMaturity) * YEAR * WAD;
        uint256 denominator = YEAR * WAD + yieldBp * YIELD_BP_RATE * timeToMaturity;

        return roundUp ? (numerator + denominator - 1) / denominator : numerator / denominator;
    }

    // The market travels in calldata and its maturity feeds the yield bounds, so callers bind the
    // id before deriving anything from it.
    function _requireMarketId(Market memory market, bytes32 marketId) internal pure {
        require(MidnightIdLib.toId(market) == marketId, "MidnightLib/market-mismatch");
    }

    function _timeToMaturity(uint256 maturity) internal view returns (uint256) {
        return maturity > block.timestamp ? maturity - block.timestamp : 0;
    }

    function _settlementFee(address midnight, bytes32 marketId, uint256 timeToMaturity)
        internal view returns (uint256)
    {
        return IMidnight(midnight).settlementFee(marketId, timeToMaturity);
    }

    function _credit(Market memory market, bytes32 marketId, address user)
        internal view returns (uint256 credit)
    {
        // Stored credit is stale; the view applies pending fee accrual and slashing.
        ( credit, , ) = IMidnight(market.midnight).updatePositionView(market, marketId, user);
    }

    function _requireDebtFree(address midnight, bytes32 marketId, address user) internal view {
        require(IMidnight(midnight).debt(marketId, user) == 0, "MidnightLib/debt-not-zero");
    }

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
