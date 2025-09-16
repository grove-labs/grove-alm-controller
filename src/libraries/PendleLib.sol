// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import { IALMProxy }   from "../interfaces/IALMProxy.sol";
import { IRateLimits } from "../interfaces/IRateLimits.sol";

import {
    ApproxParams,
    IPendleMarket,
    IPendleRouter,
    ISY,
    LimitOrderData,
    SwapData,
    TokenInput,
    TokenOutput
} from "../interfaces/PendleInterfaces.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";

library PendleLib {

    address public constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;

    struct BuyPendlePTParams {
        IALMProxy     proxy;
        IRateLimits   rateLimits;
        IPendleMarket pendleMarket;
        bytes32       rateLimitId;
        uint256       tokenAmountIn;
        uint256       minPtOut;
    }

    struct SellPendlePTParams {
        IALMProxy     proxy;
        IRateLimits   rateLimits;
        IPendleMarket pendleMarket;
        bytes32       rateLimitId;
        uint256       ptAmountIn;
        uint256       minTokenOut;
    }

    struct RedeemPendlePTParams {
        IALMProxy     proxy;
        IRateLimits   rateLimits;
        IPendleMarket pendleMarket;
        bytes32       rateLimitId;
        uint256       pyAmountIn;
    }

    function createEmptyLimitOrderData() internal pure returns (LimitOrderData memory emptyLimitOrderData) {}

    function createEmptySwapData() internal pure returns (SwapData memory emptySwapData) {}

    function createSimpleTokenInput(address tokenIn, uint256 netTokenIn) internal pure returns (TokenInput memory simpleTokenInput) {
        simpleTokenInput = TokenInput({
            tokenIn     : tokenIn,
            netTokenIn  : netTokenIn,
            tokenMintSy : tokenIn,
            pendleSwap  : address(0),
            swapData    : createEmptySwapData()
        });
    }

    function createSimpleTokenOutput(address tokenOut, uint256 minTokenOut) internal pure returns (TokenOutput memory simpleTokenOutput) {
        simpleTokenOutput = TokenOutput({
            tokenOut      : tokenOut,
            minTokenOut   : minTokenOut,
            tokenRedeemSy : tokenOut,
            pendleSwap    : address(0),
            swapData      : createEmptySwapData()
        });
    }

    function createDefaultApproxParams() internal pure returns (ApproxParams memory defaultApproxParams) {
        defaultApproxParams = ApproxParams({
            guessMin      : 0,
            guessMax      : type(uint256).max,
            guessOffchain : 0,
            maxIteration  : 256,
            eps           : 1e14
        });
    }

    function buyPendlePT(BuyPendlePTParams memory params) internal {
        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, address(params.pendleMarket)),
            params.tokenAmountIn
        );

        address tokenIn = address(0);

        ApproxParams memory approxParams = createDefaultApproxParams();
        TokenInput memory tokenInput = createSimpleTokenInput(tokenIn, params.tokenAmountIn);
        LimitOrderData memory limitOrderData = createEmptyLimitOrderData();

        _approve(params.proxy, tokenIn, PENDLE_ROUTER, params.tokenAmountIn);

        params.proxy.doCall(
            address(params.pendleMarket),
            abi.encodeCall(
                IPendleRouter.swapExactTokenForPt, (
                    address(params.proxy),
                    address(params.pendleMarket),
                    params.minPtOut,
                    approxParams,
                    tokenInput,
                    limitOrderData
                )
            )
        );
    }

    function sellPendlePT(SellPendlePTParams memory params) internal {
        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, address(params.pendleMarket)),
            params.ptAmountIn
        );

        address pt = address(0);
        address tokenOut = address(0);

        TokenOutput memory tokenOutput = createSimpleTokenOutput(tokenOut, params.minTokenOut);
        LimitOrderData memory limitOrderData = createEmptyLimitOrderData();

        _approve(params.proxy, pt, PENDLE_ROUTER, params.ptAmountIn);

        params.proxy.doCall(
            address(params.pendleMarket),
            abi.encodeCall(
                IPendleRouter.swapExactPtForToken, (
                    address(params.proxy),
                    address(params.pendleMarket),
                    params.ptAmountIn,
                    tokenOutput,
                    limitOrderData
                )
            )
        );
    }

    function redeemPendlePT(RedeemPendlePTParams memory params) internal {
        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, address(params.pendleMarket)),
            params.pyAmountIn
        );

        require(params.pendleMarket.isExpired(), "PendleLib/market-not-expired");

        (address sy, address pt, address yt) = params.pendleMarket.readTokens();

        address tokenOut = ISY(sy).yieldToken();

        // expected to receive full amount, but the buffer is subtracted
        // to avoid reverts due to potential rounding errors
        uint256 minTokenOut = params.pyAmountIn * 1e18 / ISY(sy).exchangeRate() - 5;

        _approve(params.proxy, pt, PENDLE_ROUTER, params.pyAmountIn);

        params.proxy.doCall(
            PENDLE_ROUTER,
            abi.encodeCall(
                IPendleRouter.redeemPyToToken, (
                    address(params.proxy),
                    yt,
                    params.pyAmountIn,
                    createSimpleTokenOutput(tokenOut, minTokenOut)
                )
            )
        );
    }

    function _approve(
        IALMProxy proxy,
        address   token,
        address   spender,
        uint256   amount
    )
        internal
    {
        bytes memory approveData = abi.encodeCall(IERC20.approve, (spender, amount));

        // Call doCall on proxy to approve the token
        ( bool success, bytes memory data )
            = address(proxy).call(abi.encodeCall(IALMProxy.doCall, (token, approveData)));

        bytes memory approveCallReturnData;

        if (success) {
            // Data is the ABI-encoding of the approve call bytes return data, need to
            // decode it first
            approveCallReturnData = abi.decode(data, (bytes));
            // Approve was successful if 1) no return value or 2) true return value
            if (approveCallReturnData.length == 0 || abi.decode(approveCallReturnData, (bool))) {
                return;
            }
        }

        // If call was unsuccessful, set to zero and try again
        proxy.doCall(token, abi.encodeCall(IERC20.approve, (spender, 0)));

        approveCallReturnData = proxy.doCall(token, approveData);

        // Revert if approve returns false
        require(
            approveCallReturnData.length == 0 || abi.decode(approveCallReturnData, (bool)),
            "PendleLib/approve-failed"
        );
    }

}
