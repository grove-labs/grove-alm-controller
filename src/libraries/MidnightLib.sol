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

    struct MarketConfig {
        uint16  maxBuyTick;
        uint16  minSellTick;       // non-zero marks the market as onboarded
        uint16  minBuyYield;       // basis points a year
        uint16  maxSellYield;      // basis points a year
        uint16  maxContinuousFee;  // centi-basis points a year
        uint128 maxLossFactor;     // fraction of type(uint128).max
    }

    struct TakeParams {
        IALMProxy    proxy;
        IRateLimits  rateLimits;
        address      midnight;
        bytes32      buyRateLimitId;
        bytes32      sellRateLimitId;
        bytes32      marketId;
        MarketConfig config;
        Offer        offer;
        bytes        ratifierData;
        uint256      units;
        uint256      assetsBound;  // maxAssetsIn when buying, minAssetsOut when selling
    }

    struct TakeContext {
        bool    selling;
        uint256 tickPriceBound;
        uint256 yieldPriceBound;
        uint256 settlementFee;
    }

    struct RedeemParams {
        IALMProxy    proxy;
        IRateLimits  rateLimits;
        address      midnight;
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
            _continuousFeePerSecond(config.maxContinuousFee) <= MAX_CONTINUOUS_FEE,
            "MidnightLib/max-continuous-fee-oob"
        );

        // Zero would only clear at par and brick the exit, so onboarding has to name a ceiling.
        require(config.maxSellYield != 0, "MidnightLib/max-sell-yield-not-set");
    }

    /**********************************************************************************************/
    /*** Taker functions                                                                        ***/
    /**********************************************************************************************/

    function buy(TakeParams memory params) external returns (uint256 assetsSpent) {
        require(params.config.maxBuyTick != 0, "MidnightLib/buy-not-enabled");
        require(params.assetsBound != 0,       "MidnightLib/max-assets-in-not-set");

        Market memory market = params.offer.market;

        require(market.midnight == params.midnight, "MidnightLib/invalid-midnight");

        _requireMarketId(market, params.marketId);

        uint256 continuousFee = IMidnight(market.midnight).continuousFee(params.marketId);

        require(
            continuousFee <= _continuousFeePerSecond(params.config.maxContinuousFee),
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
            yieldPriceBound : _maxBuyPrice(params.config.minBuyYield, timeToMaturity, continuousFee),
            settlementFee   : _settlementFee(market.midnight, params.marketId, timeToMaturity)
        });

        ( uint256 creditBefore, ) = _position(market, params.marketId, address(params.proxy));

        uint256 balanceBefore = IERC20(market.loanToken).balanceOf(address(params.proxy));

        ERC20Lib.approve(params.proxy, market.loanToken, market.midnight, params.assetsBound);

        ( uint256 buyerAssets, ) = _take(params, ctx);

        ERC20Lib.approve(params.proxy, market.loanToken, market.midnight, 0);

        assetsSpent = balanceBefore - IERC20(market.loanToken).balanceOf(address(params.proxy));

        // An inflow during the callback nets against the spend, so Midnight's figure is the floor.
        if (assetsSpent < buyerAssets) assetsSpent = buyerAssets;

        require(assetsSpent <= params.assetsBound, "MidnightLib/max-assets-in-exceeded");

        ( uint256 creditAfter, ) = _position(market, params.marketId, address(params.proxy));

        require(creditAfter == creditBefore + params.units, "MidnightLib/credit-delta-mismatch");

        _requireDebtFree(market.midnight, params.marketId, address(params.proxy));

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeBytes32Key(params.buyRateLimitId, params.marketId),
            assetsSpent
        );
    }

    function sell(TakeParams memory params) external returns (uint256 assetsReceived) {
        require(params.config.minSellTick != 0, "MidnightLib/sell-not-enabled");
        require(params.assetsBound != 0,        "MidnightLib/min-assets-out-not-set");

        Market memory market = params.offer.market;

        require(market.midnight == params.midnight, "MidnightLib/invalid-midnight");

        _requireMarketId(market, params.marketId);

        uint256 timeToMaturity = _timeToMaturity(market.maturity);

        ( uint256 creditBefore, uint256 pendingFee ) =
            _position(market, params.marketId, address(params.proxy));

        // Credit drifts down with fee accrual and slashing; the excess would be naked debt.
        if (params.units > creditBefore) params.units = creditBefore;

        require(params.units != 0, "MidnightLib/no-credit-to-sell");

        uint256 balanceBefore = IERC20(market.loanToken).balanceOf(address(params.proxy));

        TakeContext memory ctx = TakeContext({
            selling         : true,
            tickPriceBound  : MidnightTickLib.tickToPrice(params.config.minSellTick),
            yieldPriceBound : _minSellPrice(
                params.config.maxSellYield, timeToMaturity, creditBefore, pendingFee
            ),
            settlementFee   : _settlementFee(market.midnight, params.marketId, timeToMaturity)
        });

        _take(params, ctx);

        assetsReceived = IERC20(market.loanToken).balanceOf(address(params.proxy)) - balanceBefore;

        require(assetsReceived >= params.assetsBound, "MidnightLib/min-assets-out-not-met");

        ( uint256 creditAfter, ) = _position(market, params.marketId, address(params.proxy));

        require(creditBefore == creditAfter + params.units, "MidnightLib/credit-delta-mismatch");

        _requireDebtFree(market.midnight, params.marketId, address(params.proxy));

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeBytes32Key(params.sellRateLimitId, params.marketId),
            assetsReceived
        );
    }

    function redeem(RedeemParams memory params) external returns (uint256 assetsWithdrawn) {
        require(params.config.minSellTick != 0, "MidnightLib/market-not-onboarded");
        require(params.minAssetsOut != 0,       "MidnightLib/min-assets-out-not-set");

        bytes32       marketId = params.marketId;
        Market memory market   = IMidnight(params.midnight).toMarket(marketId);

        ( uint256 credit, ) = _position(market, marketId, address(params.proxy));

        uint256 units        = params.units;
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
            RateLimitHelpers.makeBytes32Key(params.redeemRateLimitId, marketId),
            assetsWithdrawn
        );
    }

    /**********************************************************************************************/
    /*** Internal functions                                                                     ***/
    /**********************************************************************************************/

    function _take(TakeParams memory params, TakeContext memory ctx)
        internal returns (uint256 buyerAssets, uint256 sellerAssets)
    {
        Offer memory offer = params.offer;

        require(offer.buy == ctx.selling, "MidnightLib/invalid-offer-direction");
        require(params.units != 0,        "MidnightLib/zero-units");

        uint256 price = MidnightTickLib.tickToPrice(offer.tick);

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

        bytes memory result = params.proxy.doCall(
            offer.market.midnight,
            abi.encodeCall(
                IMidnight.take,
                (
                    offer,
                    params.ratifierData,
                    params.units,
                    address(params.proxy),
                    ctx.selling ? address(params.proxy) : address(0),
                    address(0),
                    new bytes(0)
                )
            )
        );

        ( buyerAssets, sellerAssets ) = abi.decode(result, (uint256, uint256));
    }

    function _continuousFeePerSecond(uint256 cbpsPerYear) internal pure returns (uint256) {
        return cbpsPerYear * FEE_CBP_RATE / YEAR;
    }

    function _maxBuyPrice(uint256 minYield, uint256 timeToMaturity, uint256 continuousFee)
        internal pure returns (uint256)
    {
        return _yieldPrice(minYield, timeToMaturity, continuousFee * timeToMaturity, false);
    }

    function _minSellPrice(
        uint256 maxYield,
        uint256 timeToMaturity,
        uint256 credit,
        uint256 pendingFee
    )
        internal pure returns (uint256)
    {
        if (credit == 0) return WAD;

        return _yieldPrice(maxYield, timeToMaturity, pendingFee * WAD / credit, true);
    }

    // Rounds against the caller: down for the buy ceiling, up for the sell floor.
    function _yieldPrice(
        uint256 yieldBp,
        uint256 timeToMaturity,
        uint256 pendingFeePerUnit,
        bool    roundUp
    )
        private pure returns (uint256)
    {
        // Midnight caps maturity and the continuous fee, so the pending fee stays below par.
        uint256 numerator   = (WAD - pendingFeePerUnit) * YEAR * WAD;
        uint256 denominator = YEAR * WAD + yieldBp * YIELD_BP_RATE * timeToMaturity;

        return roundUp ? (numerator + denominator - 1) / denominator : numerator / denominator;
    }

    // The market arrives in calldata and feeds the yield bounds, so bind it to the id first.
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

    function _position(Market memory market, bytes32 marketId, address user)
        internal view returns (uint256 credit, uint256 pendingFee)
    {
        ( credit, pendingFee, ) =
            IMidnight(market.midnight).updatePositionView(market, marketId, user);
    }

    function _requireDebtFree(address midnight, bytes32 marketId, address user) internal view {
        require(IMidnight(midnight).debt(marketId, user) == 0, "MidnightLib/debt-not-zero");
    }

}
