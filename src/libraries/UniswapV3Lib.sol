// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC20 }         from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { ERC20Lib } from "./ERC20Lib.sol";

import { IALMProxy }                                                    from "../interfaces/IALMProxy.sol";
import { IRateLimits }                                                  from "../interfaces/IRateLimits.sol";
import { ISwapRouter, IUniswapV3PoolLike, INonfungiblePositionManager } from "../interfaces/UniswapV3Interfaces.sol";

import { FullMath }   from "lib/dss-allocator/src/funnels/uniV3/FullMath.sol";
import { UniV3Utils } from "lib/dss-allocator/test/funnels/UniV3Utils.sol";
import { TickMath }   from "lib/dss-allocator/src/funnels/uniV3/TickMath.sol";
import { LiquidityAmounts } from "lib/dss-allocator/src/funnels/uniV3/LiquidityAmounts.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";


import { console } from "forge-std/console.sol";

library UniswapV3Lib {
    uint24 public constant MAX_TICK_DELTA = 887272; // From https://github.com/sky-ecosystem/dss-allocator/blob/dev/src/funnels/uniV3/TickMath.sol#L15

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/
    struct Tick {
        int24 lower;
        int24 upper;
    }

    struct LiquidityPosition {
        uint256 amount0;
        uint256 amount1;
    }

    struct UniswapV3PoolParams {
        uint24 swapMaxTickDelta;
        Tick addLiquidityTickBounds;
    }

    struct UniV3Context {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     rateLimitId;
        address     pool;
    }

    struct SwapParams {
        UniswapV3PoolParams poolParams;
        ISwapRouter         router;
        address             tokenIn;
        uint256             amountIn;
        uint256             minAmountOut;
        uint24              tickDelta; // The maximum that the tick can move by after completing the swap; cannot exceed MAX_TICK_DELTA
        uint256             maxSlippage;
    }

    struct SwapCache {
        address tokenOut;
        uint160 sqrtPriceLimitX96;
    }

    struct AddLiquidityParams {
        uint256                     tokenId; // 0 for a new position
        INonfungiblePositionManager positionManager;
        Tick                        tick;
        LiquidityPosition           amountDesired;
        LiquidityPosition           amountMin;
        Tick                        tickBounds;
        uint32                      twapSecondsAgo;
        uint256                     maxSlippage;
    }

    struct AddLiquidityCache {
        address token0;
        address token1;
        uint24  fee;
        uint160 sqrtPriceX96;
        uint256 priceX192;
        uint8   token0Decimals;
        uint8   token1Decimals;
        uint256 normalizedDesiredValue;
    }

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    // Rate limit decreased by value of token1 
    function swap(UniV3Context calldata context, SwapParams calldata params) external returns (uint256 amountOut) {
        require(address(params.router) != address(0), "UniswapV3Lib/router-not-set");
        SwapCache memory cache = _populateSwapCache(context, params);

        require(params.maxSlippage > 0,                                 "UniswapV3Lib/max-slippage-not-set");
        require(params.tickDelta <= params.poolParams.swapMaxTickDelta, "UniswapV3Lib/invalid-max-tick-delta");

        context.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetDestinationKey(context.rateLimitId, params.tokenIn, context.pool),
            params.amountIn
        );

        ERC20Lib.approve(context.proxy, params.tokenIn, address(params.router), params.amountIn);

        uint256 startingBalance = IERC20(cache.tokenOut).balanceOf(address(context.proxy));
        amountOut = _callSwap(context, params, cache);

        uint256 endingBalance = IERC20(cache.tokenOut).balanceOf(address(context.proxy));
        require(params.minAmountOut * 1e18 >= (endingBalance - startingBalance) * params.maxSlippage, "UniswapV3Lib/min-amount-not-met");
    }

    function addLiquidity(UniV3Context calldata context, AddLiquidityParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        require(
            params.amountDesired.amount0 > 0 || params.amountDesired.amount1 > 0,
            "UniswapV3Lib/zero-amount"
        );

        require(params.maxSlippage > 0, "UniswapV3Lib/max-slippage-not-set");
        require(params.twapSecondsAgo != 0, "UniswapV3Lib/zero-twap-seconds");

        IUniswapV3PoolLike pool = IUniswapV3PoolLike(context.pool);

        AddLiquidityCache memory cache = _populateAddLiquidityCache(pool);

        if (params.amountDesired.amount0 > 0) {
            _approve(context.proxy, cache.token0, address(params.positionManager), params.amountDesired.amount0);
            context.rateLimits.triggerRateLimitDecrease(
                RateLimitHelpers.makeAssetDestinationKey(context.rateLimitId, cache.token0, context.pool),
                _scaleTo1e18(params.amountDesired.amount0, cache.token0Decimals)
            );
        }
        if (params.amountDesired.amount1 > 0) {
            _approve(context.proxy, cache.token1, address(params.positionManager), params.amountDesired.amount1);
            context.rateLimits.triggerRateLimitDecrease(
                RateLimitHelpers.makeAssetDestinationKey(context.rateLimitId, cache.token1, context.pool),
                _scaleTo1e18(params.amountDesired.amount1, cache.token1Decimals)
            );
        }

        _validateAddLiquidityMinAmounts(context, params);

        if (params.tokenId == 0) {
            require(params.tick.lower >= params.tickBounds.lower, "UniswapV3Lib/invalid-tick-lower");
            require(params.tick.upper <= params.tickBounds.upper, "UniswapV3Lib/invalid-tick-upper");

            (tokenId, liquidity, amount0, amount1) = _mintLiquidity(context, params, cache);
        } else {
            require(params.positionManager.ownerOf(params.tokenId) == address(context.proxy), "UniswapV3Lib/proxy-does-not-own-token-id");

            (liquidity, amount0, amount1) = _addLiquidityToExistingPosition(context, params);
            tokenId = params.tokenId;
        }

        require(liquidity != 0, "UniswapV3Lib/no-liquidity-increased");
    }

    /**********************************************************************************************/
    /*** Helper functions                                                                       ***/
    /**********************************************************************************************/
    
    //-- Swap helper functions
    function _populateSwapCache(UniV3Context calldata context, SwapParams calldata params) internal view returns (SwapCache memory cache) {
        IUniswapV3PoolLike pool = IUniswapV3PoolLike(context.pool);
        address token0          = pool.token0();
        address token1          = pool.token1();

        require(
            params.tokenIn == token0 || params.tokenIn == token1,
            "UniswapV3Lib/invalid-token-pair"
        );

        (, int24 currentTick, , , , , ) = pool.slot0();

        cache.tokenOut = params.tokenIn == token0 ? token1 : token0;
        
        int24 delta = int24(params.tickDelta);
        int24 limitTick;
        if (params.tokenIn == token0) {
            limitTick = _max(currentTick - delta, TickMath.MIN_TICK);
        } else {
            limitTick = _min(currentTick + delta, TickMath.MAX_TICK);
        }

        cache.sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(limitTick);

        return cache;
    }

    function _min(int24 a, int24 b) internal pure returns (int24) {
        return a < b ? a : b;
    }

    function _max(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a : b;
    }

    function _callSwap(UniV3Context calldata context, SwapParams calldata params, SwapCache memory cache) internal returns (uint256 amountOut) {
        IUniswapV3PoolLike pool = IUniswapV3PoolLike(context.pool);

        bytes memory result = context.proxy.doCall(
            address(params.router),
            abi.encodeWithSelector(
                ISwapRouter.exactInputSingle.selector,
                ISwapRouter.ExactInputSingleParams({
                    tokenIn          : params.tokenIn,
                    tokenOut         : cache.tokenOut,
                    fee              : pool.fee(),
                    recipient        : address(context.proxy),
                    amountIn         : params.amountIn,
                    amountOutMinimum : params.minAmountOut,
                    sqrtPriceLimitX96: cache.sqrtPriceLimitX96
                })
            )
        );

        amountOut = abi.decode(result, (uint256));
    }

    //-- Add liquidity functions
    function _populateAddLiquidityCache(IUniswapV3PoolLike pool) internal view returns (AddLiquidityCache memory cache) {
        cache.token0 = pool.token0();
        cache.token1 = pool.token1();
        cache.fee = pool.fee();

        cache.token0Decimals = IERC20Metadata(cache.token0).decimals();
        cache.token1Decimals = IERC20Metadata(cache.token1).decimals();
    }

    function _mintLiquidity(UniV3Context calldata context, AddLiquidityParams calldata params, AddLiquidityCache memory cache)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        INonfungiblePositionManager.MintParams memory mintParams
            = INonfungiblePositionManager.MintParams({
                token0: cache.token0,
                token1: cache.token1,
                fee: cache.fee,
                tickLower: params.tick.lower,
                tickUpper: params.tick.upper,
                recipient: address(context.proxy),
                amount0Desired: params.amountDesired.amount0,
                amount1Desired: params.amountDesired.amount1,
                amount0Min: params.amountMin.amount0,
                amount1Min: params.amountMin.amount1,
                deadline: context.deadline
            });

        bytes memory result = context.proxy.doCall(
            address(params.positionManager),
            abi.encodeCall(
                INonfungiblePositionManager.mint,
                (mintParams)
            )
        );

        (tokenId, liquidity, amount0, amount1) = abi.decode(result, (uint256, uint128, uint256, uint256));
    }

    function _addLiquidityToExistingPosition(UniV3Context calldata context, AddLiquidityParams calldata params)
        internal
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseLiquidityParams
            = INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: params.tokenId,
                amount0Desired: params.amountDesired.amount0,
                amount1Desired: params.amountDesired.amount1,
                amount0Min: params.amountMin.amount0,
                amount1Min: params.amountMin.amount1,
                deadline: context.deadline
            });

        bytes memory result = context.proxy.doCall(
            address(params.positionManager),
            abi.encodeCall(
                INonfungiblePositionManager.increaseLiquidity,
                (increaseLiquidityParams)
            )
        );

        (liquidity, amount0, amount1) = abi.decode(result, (uint128, uint256, uint256));
    }

    function _validateAddLiquidityMinAmounts(UniV3Context calldata context, AddLiquidityParams calldata params) internal view {
        // Fetch twap tick
        (int24 twapTick, ) = UniswapV3OracleLib.consult(context.pool, params.twapSecondsAgo);

        uint160 sqrtTwapPriceX96   = TickMath.getSqrtRatioAtTick(twapTick);
        uint160 sqrtRatioLowerX96  = TickMath.getSqrtRatioAtTick(params.tick.lower);
        uint160 sqrtRatioUpperX96  = TickMath.getSqrtRatioAtTick(params.tick.upper);

        uint128 expectedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtTwapPriceX96,
            sqrtRatioLowerX96,
            sqrtRatioUpperX96,
            params.amountDesired.amount0,
            params.amountDesired.amount1
        );

        uint256 expectedAmount0;
        uint256 expectedAmount1;

        if (expectedLiquidity > 0) {
            if (twapTick <= params.tick.lower) {
                expectedAmount0 = UniV3Utils.getAmount0Delta(
                    sqrtRatioLowerX96,
                    sqrtRatioUpperX96,
                    expectedLiquidity,
                    false
                );
            } else if (twapTick >= params.tick.upper) {
                expectedAmount1 = UniV3Utils.getAmount1Delta(
                    sqrtRatioLowerX96,
                    sqrtRatioUpperX96,
                    expectedLiquidity,
                    false
                );
            } else {
                expectedAmount0 = UniV3Utils.getAmount0Delta(
                    sqrtTwapPriceX96,
                    sqrtRatioUpperX96,
                    expectedLiquidity,
                    false
                );
                expectedAmount1 = UniV3Utils.getAmount1Delta(
                    sqrtRatioLowerX96,
                    sqrtTwapPriceX96,
                    expectedLiquidity,
                    false
                );
                
            }
        }

        uint256 minAmount0Threshold = FullMath.mulDiv(expectedAmount0, params.maxSlippage, 1e18);
        uint256 minAmount1Threshold = FullMath.mulDiv(expectedAmount1, params.maxSlippage, 1e18);

        require(params.amountMin.amount0 >= minAmount0Threshold, "UniswapV3Lib/min-amount0-below-bound");
        require(params.amountMin.amount1 >= minAmount1Threshold, "UniswapV3Lib/min-amount1-below-bound");
    }
    
    //-- General helper functions
    function _scaleTo1e18(uint256 amount, uint8 decimals_) internal pure returns (uint256) {
        if (decimals_ == 18) {
            return amount;
        } else if (decimals_ < 18) {
            return amount * 10 ** (18 - decimals_);
        } else {
            return amount / 10 ** (decimals_ - 18);
        }
    }
}
