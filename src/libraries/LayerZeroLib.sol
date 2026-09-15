// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IALMProxy }   from "../interfaces/IALMProxy.sol";
import { IRateLimits } from "../interfaces/IRateLimits.sol";

import { ILayerZero, MessagingFee, SendParam } from "../interfaces/ILayerZero.sol";

import { ERC20Lib } from "./common/ERC20Lib.sol";

import { OptionsBuilder } from "layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

library LayerZeroLib {

    using OptionsBuilder for bytes;

    struct TransferTokenParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     rateLimitId;
        address     oftAddress;
        uint256     amount;
        uint32      destinationEndpointId;
        bytes32     layerZeroRecipient;
    }

    struct QuoteParams {
        IALMProxy proxy;
        address   oftAddress;
        uint256   amount;
        uint32    destinationEndpointId;
        bytes32   layerZeroRecipient;
    }

    function transferTokenLayerZero(TransferTokenParams memory params) external {
        ( SendParam memory sendParams, MessagingFee memory fee ) = quoteTransfer(QuoteParams({
            proxy                 : params.proxy,
            oftAddress            : params.oftAddress,
            amount                : params.amount,
            destinationEndpointId : params.destinationEndpointId,
            layerZeroRecipient    : params.layerZeroRecipient
        }));

        params.rateLimits.triggerRateLimitDecrease(
            keccak256(abi.encode(params.rateLimitId, params.oftAddress, params.destinationEndpointId)),
            params.amount
        );

        bool    approvalRequired = ILayerZero(params.oftAddress).approvalRequired();
        address token;

        if (approvalRequired) {
            token = ILayerZero(params.oftAddress).token();
            ERC20Lib.approve(params.proxy, token, params.oftAddress, params.amount);
        }

        params.proxy.doCallWithValue{value: fee.nativeFee}(
            params.oftAddress,
            abi.encodeCall(ILayerZero.send, (sendParams, fee, address(params.proxy))),
            fee.nativeFee
        );

        // The controller cannot receive ETH, so anything sent above the fee would be stuck here.
        uint256 excess = address(this).balance;
        if (excess != 0) {
            ( bool success, ) = address(params.proxy).call{value: excess}("");
            require(success, "LayerZeroLib/sweep-failed");
        }

        if (approvalRequired) {
            ERC20Lib.approve(params.proxy, token, params.oftAddress, 0);
        }
    }

    // Fee-only entry point for the controller's view; decoding the full SendParam there costs
    // ~500 bytes of controller bytecode for no relayer benefit.
    function quoteTransferFee(QuoteParams memory params)
        external view returns (MessagingFee memory fee)
    {
        ( , fee ) = quoteTransfer(params);
    }

    function quoteTransfer(QuoteParams memory params)
        internal view returns (SendParam memory sendParams, MessagingFee memory fee)
    {
        require(params.layerZeroRecipient != bytes32(0), "LayerZeroLib/recipient-not-set");

        // The OFT truncates to its shared decimals, so this is the exact amount that arrives; it is
        // computed here rather than taken from the OFT's own quote.
        uint256 decimalConversionRate = ILayerZero(params.oftAddress).decimalConversionRate();
        uint256 minAmountLD           = (params.amount / decimalConversionRate) * decimalConversionRate;

        require(minAmountLD != 0, "LayerZeroLib/zero-min-amount");

        sendParams = SendParam({
            dstEid       : params.destinationEndpointId,
            to           : params.layerZeroRecipient,
            amountLD     : params.amount,
            minAmountLD  : minAmountLD,
            extraOptions : OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0),
            composeMsg   : "",
            oftCmd       : ""
        });

        // Quoted from the proxy, which is the account that will call send.
        ( bool success, bytes memory returnData ) = address(params.proxy).staticcall(
            abi.encodeCall(
                IALMProxy.doCall,
                (params.oftAddress, abi.encodeCall(ILayerZero.quoteSend, (sendParams, false)))
            )
        );

        require(success, "LayerZeroLib/quote-send-failed");

        fee = abi.decode(abi.decode(returnData, (bytes)), (MessagingFee));
    }

}
