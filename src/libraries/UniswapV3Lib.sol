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

import { RateLimitHelpers } from "../RateLimitHelpers.sol";


library UniswapV3Lib {
    uint24 public constant MAX_TICK_DELTA = 887272; // From https://github.com/sky-ecosystem/dss-allocator/blob/dev/src/funnels/uniV3/TickMath.sol#L15

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/
    struct UniswapV3PoolParams {
        uint24 swapMaxTickDelta;
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

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    // Rate limit decreased by value of token1 
    function swap(UniV3Context calldata context, SwapParams calldata params) external returns (uint256 amountOut) {
        require(address(params.router) != address(0), "UniswapV3Lib/router-not-set");
        SwapCache memory cache = _populateSwapCache(context, params);

        require(params.maxSlippage > 0,                                 "UniswapV3Lib/max-slippage-not-set");
        require(params.tickDelta <= params.poolParams.swapMaxTickDelta, "UniswapV3Lib/invalid-max-tick-delta");

        ERC20Lib.approve(context.proxy, params.tokenIn, address(params.router), params.amountIn);

        uint256 startingBalance = ERC20Lib.balanceOf(context.proxy, cache.tokenOut);
        amountOut = _callSwap(context, params, cache);

        uint256 endingBalance = ERC20Lib.balanceOf(context.proxy, cache.tokenOut);
        require(params.minAmountOut * 1e18 >= (endingBalance - startingBalance) * params.maxSlippage, "UniswapV3Lib/min-amount-not-met");

        context.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetDestinationKey(context.rateLimitId, params.tokenIn, context.pool),
            params.amountIn
        );
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
            limitTick = currentTick - delta;
            if (limitTick < TickMath.MIN_TICK) limitTick = TickMath.MIN_TICK;
        } else {
            limitTick = currentTick + delta;
            if (limitTick > TickMath.MAX_TICK) limitTick = TickMath.MAX_TICK;
        }

        cache.sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(limitTick);

        return cache;
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
}
