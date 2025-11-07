// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IALMProxy }   from "../interfaces/IALMProxy.sol";
import { IRateLimits } from "../interfaces/IRateLimits.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";

import { FullMath } from "lib/dss-allocator/src/funnels/uniV3/FullMath.sol";
import { UniV3Utils } from "lib/dss-allocator/test/funnels/UniV3Utils.sol";

import { ISwapRouter, IUniswapV3PoolLike, INonfungiblePositionManager } from "../interfaces/UniswapV3Interfaces.sol";

import { TickMath } from "lib/dss-allocator/src/funnels/uniV3/TickMath.sol";

import { console2 } from "forge-std/console2.sol";

library UniswapV3Lib {
    uint24 public constant MAX_TICK_DELTA = 887272; // From https://github.com/sky-ecosystem/dss-allocator/blob/dev/src/funnels/uniV3/TickMath.sol#L15
    uint256 internal constant Q192 = 2 ** 192;

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/
    struct UniswapV3PoolParams {
        uint24 swapMaxTickDelta;
        uint32 swapTwapSecondsAgo;
    }

    struct UniV3Context {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     rateLimitId;
        address     pool;
        uint256     deadline;
    }

    struct SwapParams {
        UniswapV3PoolParams poolParams;
        address             router;
        address             tokenIn;
        uint256             amountIn;
        uint256             minAmountOut;
        uint24              maxTickDelta; // The maximum that the tick can move by after completing the swap; type(uint24).max for no limit
        uint256             maxSlippage;
    }

    struct SwapCache {
        IUniswapV3PoolLike pool;
        address            token0;
        address            token1;
        address            tokenOut;
        uint160            sqrtPriceLimitX96;
        uint256            twapExpectedOut;
    }

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    // Rate limit decreased by value of token1 
    function swap(UniV3Context calldata context, SwapParams calldata params) external returns (uint256 amountOut) {
        SwapCache memory cache = _populateSwapCache(context, params);

        require(
            params.tokenIn == cache.token0 || params.tokenIn == cache.token1,
            "UniswapV3Lib/invalid-token-pair"
        );
        require(params.maxSlippage > 0, "UniswapV3Lib/max-slippage-not-set");
        require(params.maxTickDelta <= params.poolParams.swapMaxTickDelta, "UniswapV3Lib/invalid-max-tick-delta");

        uint256 minOutBySlippage = cache.twapExpectedOut * params.maxSlippage / 1e18;

        require(params.minAmountOut >= minOutBySlippage, "UniswapV3Lib/min-amount-not-met");

        _approve(context.proxy, params.tokenIn, params.router, params.amountIn);

        amountOut = _callSwap(context, params, cache);

        context.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetDestinationKey(context.rateLimitId, params.tokenIn, context.pool),
            _scaleTo1e18(params.amountIn, IERC20Metadata(params.tokenIn).decimals())
        );
    }

    function _populateSwapCache(UniV3Context calldata context, SwapParams calldata params) internal view returns (SwapCache memory) {
        IUniswapV3PoolLike pool = IUniswapV3PoolLike(context.pool);
        address token0 = pool.token0();
        address token1 = pool.token1();
        (, int24 currentTick, , , , , ) = pool.slot0();

        int24 delta = int24(params.maxTickDelta);

        address tokenOut = params.tokenIn == token0 ? token1 : token0;
        
        // Expected out is calculated by by converting amountIn to amountOut using the TWAP tick since some time ago
        (int24 twapExpectedOutTick, ) = _consult(context.pool, params.poolParams.swapTwapSecondsAgo); 
        uint256 twapExpectedOut = getQuoteAtTick(twapExpectedOutTick, uint128(params.amountIn), params.tokenIn, tokenOut);

        int24 limitTick;
        if (params.tokenIn == token0) {
            limitTick = currentTick - delta;
            if (limitTick < TickMath.MIN_TICK) limitTick = TickMath.MIN_TICK;
        } else {
            limitTick = currentTick + delta;
            if (limitTick > TickMath.MAX_TICK) limitTick = TickMath.MAX_TICK;
        }

        uint160 sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(limitTick);

        return SwapCache({
            pool: pool,
            token0: token0,
            token1: token1,
            tokenOut: tokenOut,
            sqrtPriceLimitX96: sqrtPriceLimitX96,
            twapExpectedOut: twapExpectedOut
        });
    }

    function _callSwap(UniV3Context calldata context, SwapParams calldata params, SwapCache memory cache) internal returns (uint256 amountOut) {
        address tokenOut = params.tokenIn == cache.token0 ? cache.token1 : cache.token0;

        bytes memory result = context.proxy.doCall(
            params.router,
            abi.encodeWithSelector(
                ISwapRouter.exactInputSingle.selector,
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: params.tokenIn,
                    tokenOut: tokenOut,
                    fee: cache.pool.fee(),
                    recipient: address(context.proxy),
                    deadline: context.deadline,
                    amountIn: params.amountIn,
                    amountOutMinimum: params.minAmountOut,
                    sqrtPriceLimitX96: cache.sqrtPriceLimitX96
                })
            )
        );

        amountOut = abi.decode(result, (uint256));
    }

    /**********************************************************************************************/
    /*** Helper functions                                                                       ***/
    /**********************************************************************************************/

    function _approve(
        IALMProxy proxy,
        address   token,
        address   spender,
        uint256   amount
    )
        internal
    {
        bytes memory approveData = abi.encodeWithSelector(IERC20.approve.selector, spender, amount);

        ( bool success, bytes memory data )
            = address(proxy).call(
                abi.encodeWithSelector(IALMProxy.doCall.selector, token, approveData)
            );

        bytes memory approveCallReturnData;

        if (success) {
            approveCallReturnData = abi.decode(data, (bytes));
            if (approveCallReturnData.length == 0 || abi.decode(approveCallReturnData, (bool))) {
                return;
            }
        }

        proxy.doCall(token, abi.encodeWithSelector(IERC20.approve.selector, spender, 0));

        approveCallReturnData = proxy.doCall(token, approveData);

        require(
            approveCallReturnData.length == 0 || abi.decode(approveCallReturnData, (bool)),
            "UniswapV3Lib/approve-failed"
        );
    }

    function _priceX192(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1);
    }

    function _scaleTo1e18(uint256 amount, uint8 decimals_) internal pure returns (uint256) {
        if (decimals_ == 18) {
            return amount;
        } else if (decimals_ < 18) {
            return amount * 10 ** (18 - decimals_);
        } else {
            return amount / 10 ** (decimals_ - 18);
        }
    }

    /// Taken from https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/OracleLibrary.sol
    /// @notice Calculates time-weighted means of tick and liquidity for a given Uniswap V3 pool
    /// @param pool Address of the pool that we want to observe
    /// @param secondsAgo Number of seconds in the past from which to calculate the time-weighted means
    /// @return arithmeticMeanTick The arithmetic mean tick from (block.timestamp - secondsAgo) to block.timestamp
    /// @return harmonicMeanLiquidity The harmonic mean liquidity from (block.timestamp - secondsAgo) to block.timestamp
    /// Changes: changed the require message, explicitly cast secondsAgo to int32, and UniswapV3PoolLike to IUniswapV3PoolLike
    function _consult(address pool, uint32 secondsAgo)
        internal
        view
        returns (int24 arithmeticMeanTick, uint128 harmonicMeanLiquidity)
    {
        require(secondsAgo != 0, 'UniswapV3Lib/consult-seconds-ago-not-zero');

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            IUniswapV3PoolLike(pool).observe(secondsAgos);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        uint160 secondsPerLiquidityCumulativesDelta =
            secondsPerLiquidityCumulativeX128s[1] - secondsPerLiquidityCumulativeX128s[0];

        arithmeticMeanTick = int24(tickCumulativesDelta / int32(secondsAgo));
        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int32(secondsAgo) != 0)) arithmeticMeanTick--;

        // We are multiplying here instead of shifting to ensure that harmonicMeanLiquidity doesn't overflow uint128
        uint192 secondsAgoX160 = uint192(secondsAgo) * type(uint160).max;
        harmonicMeanLiquidity = uint128(secondsAgoX160 / (uint192(secondsPerLiquidityCumulativesDelta) << 32));
    }

    /// Taken from https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/OracleLibrary.sol
    /// @notice Given a tick and a token amount, calculates the amount of token received in exchange
    /// @param tick Tick value used to calculate the quote
    /// @param baseAmount Amount of token to be converted
    /// @param baseToken Address of an ERC20 token contract used as the baseAmount denomination
    /// @param quoteToken Address of an ERC20 token contract used as the quoteAmount denomination
    /// @return quoteAmount Amount of quoteToken received for baseAmount of baseToken
    function getQuoteAtTick(
        int24 tick,
        uint128 baseAmount,
        address baseToken,
        address quoteToken
    ) internal pure returns (uint256 quoteAmount) {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
                : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
