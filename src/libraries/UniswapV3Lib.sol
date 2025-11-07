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
    uint256 internal constant Q192 = 2 ** 192;

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/

    struct UniV3Context {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     rateLimitId;
        address     pool;
        uint256     deadline;
    }

    struct SwapParams {
        address     router;
        address     tokenIn;
        uint256     amountIn;
        uint256     minAmountOut;
        int24       maxPriceTick;
        uint256     maxSlippage;
    }

    struct SwapCache {
        IUniswapV3PoolLike pool;
        address token0;
        address token1;
        address tokenOut;
        uint160 sqrtPriceX96;
        uint256 priceX192;
        uint256 expectedOut;
    }

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    // Rate limit decreased by value of token1 
    function swap(UniV3Context calldata context, SwapParams calldata params) external returns (uint256 amountOut) {
        SwapCache memory cache = _populateSwapCache(context, params);
        _validateSwap(context, params, cache);

        uint256 minOutBySlippage = cache.expectedOut * params.maxSlippage / 1e18;
        require(params.minAmountOut >= minOutBySlippage, "UniswapV3Lib/min-amount-not-met");

        _approve(context.proxy, params.tokenIn, params.router, params.amountIn);

        // uint160 sqrtPriceLimitX96;
        // if (params.maxPriceTick != type(int24).min) {
        //     sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(params.maxPriceTick);
        // }

        amountOut = _callSwap(context, params, cache);

        require(amountOut >= params.minAmountOut, "UniswapV3Lib/insufficient-output");

        context.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetDestinationKey(context.rateLimitId, params.tokenIn, context.pool),
            _scaleTo1e18(params.amountIn, IERC20Metadata(params.tokenIn).decimals())
        );
    }

    function _populateSwapCache(UniV3Context calldata context, SwapParams calldata params) internal returns (SwapCache memory) {
        IUniswapV3PoolLike pool = IUniswapV3PoolLike(context.pool);
        address token0 = pool.token0();
        address token1 = pool.token1();
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint256 priceX192 = _priceX192(sqrtPriceX96);

        // Note: expectedOut approximates the amount of tokenOut without crossing the tick. It is not meant to be used
        //       to approximate amountOut. 
        uint256 expectedOut;

         if (params.tokenIn == token0) {
            expectedOut = FullMath.mulDiv(params.amountIn, priceX192, Q192);
        } else {
            expectedOut = FullMath.mulDiv(params.amountIn, Q192, priceX192);
        }

        return SwapCache({
            pool: pool,
            token0: token0,
            token1: token1,
            tokenOut: token0 == params.tokenIn ? token1 : token0,
            sqrtPriceX96: sqrtPriceX96,
            priceX192: priceX192,
            expectedOut: expectedOut
        });
    }


    function _validateSwap(UniV3Context calldata context, SwapParams calldata params, SwapCache memory cache) internal {
        require(cache.token0 != address(0) && cache.token1 != address(0), "UniswapV3Lib/invalid-pool");
        require(
            params.tokenIn == cache.token0 || params.tokenIn == cache.token1,
            "UniswapV3Lib/invalid-token-pair"
        );
        require(params.maxSlippage > 0, "UniswapV3Lib/max-slippage-not-set");
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
                    sqrtPriceLimitX96: 0 // TODO fix
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
}
