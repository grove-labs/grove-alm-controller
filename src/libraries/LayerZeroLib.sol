// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IALMProxy }   from "../interfaces/IALMProxy.sol";
import { IRateLimits } from "../interfaces/IRateLimits.sol";

import { ILayerZero, MessagingFee, OFTReceipt, SendParam } from "../interfaces/ILayerZero.sol";

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

    function transferTokenLayerZero(TransferTokenParams memory params) external {
        params.rateLimits.triggerRateLimitDecrease(
            keccak256(abi.encode(params.rateLimitId, params.oftAddress, params.destinationEndpointId)),
            params.amount
        );

        if (ILayerZero(params.oftAddress).approvalRequired()) {
            ERC20Lib.approve(
                params.proxy,
                ILayerZero(params.oftAddress).token(),
                params.oftAddress,
                params.amount
            );
        }

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);

        SendParam memory sendParams = SendParam({
            dstEid       : params.destinationEndpointId,
            to           : params.layerZeroRecipient,
            amountLD     : params.amount,
            minAmountLD  : 0,
            extraOptions : options,
            composeMsg   : "",
            oftCmd       : ""
        });

        // Query the min amount received on the destination chain and set it.
        ( ,, OFTReceipt memory receipt ) = ILayerZero(params.oftAddress).quoteOFT(sendParams);
        sendParams.minAmountLD = receipt.amountReceivedLD;

        MessagingFee memory fee = ILayerZero(params.oftAddress).quoteSend(sendParams, false);

        params.proxy.doCallWithValue{value: fee.nativeFee}(
            params.oftAddress,
            abi.encodeCall(ILayerZero.send, (sendParams, fee, address(params.proxy))),
            fee.nativeFee
        );
    }

}
