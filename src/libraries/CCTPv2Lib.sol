// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import { IRateLimits } from "../interfaces/IRateLimits.sol";
import { IALMProxy }   from "../interfaces/IALMProxy.sol";
import { ICCTPv2Like } from "../interfaces/CCTPInterfaces.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";

import { ERC20Lib } from "./ERC20Lib.sol";

library CCTPv2Lib {

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/

    struct TransferUSDCToCCTPv2Params {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        ICCTPv2Like cctpV2;
        IERC20      usdc;
        bytes32     domainRateLimitId;
        bytes32     cctpRateLimitId;
        bytes32     mintRecipient;
        uint32      destinationDomain;
        uint256     usdcAmount;
    }

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    // NOTE: This is used to track individual transfers for offchain processing of CCTP v2 transactions
    event CCTPv2TransferInitiated(
        uint64  indexed nonce,
        uint32  indexed destinationDomain,
        bytes32 indexed mintRecipient,
        uint256 usdcAmount
    );

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    function transferUSDCToCCTPv2(TransferUSDCToCCTPv2Params calldata params) external {
        _rateLimited(params.rateLimits, params.cctpRateLimitId, params.usdcAmount);
        _rateLimited(
            params.rateLimits,
            RateLimitHelpers.makeDomainKey(params.domainRateLimitId, params.destinationDomain),
            params.usdcAmount
        );

        require(params.mintRecipient != 0, "MainnetController/domain-not-configured");

        // Approve USDC to CCTP v2 from the proxy (assumes the proxy has enough USDC)
        ERC20Lib.approve(params.proxy, address(params.usdc), address(params.cctpV2), params.usdcAmount);

        // If amount is larger than limit it must be split into multiple calls
        uint256 burnLimit = params.cctpV2.localMinter().burnLimitsPerMessage(address(params.usdc));

        // This variable will get reduced in the loop below
        uint256 usdcAmountTemp = params.usdcAmount;

        while (usdcAmountTemp > burnLimit) {
            _initiateCCTPv2Transfer(
                params.proxy,
                params.cctpV2,
                params.usdc,
                burnLimit,
                params.mintRecipient,
                params.destinationDomain
            );
            usdcAmountTemp -= burnLimit;
        }

        // Send remaining amount (if any)
        if (usdcAmountTemp > 0) {
            _initiateCCTPv2Transfer(
                params.proxy,
                params.cctpV2,
                params.usdc,
                usdcAmountTemp,
                params.mintRecipient,
                params.destinationDomain
            );
        }
    }

    /**********************************************************************************************/
    /*** Relayer helper functions                                                               ***/
    /**********************************************************************************************/

    function _initiateCCTPv2Transfer(
        IALMProxy proxy,
        ICCTPv2Like cctpV2,
        IERC20    usdc,
        uint256   usdcAmount,
        bytes32   mintRecipient,
        uint32    destinationDomain
    )
        internal
    {
        uint64 nonce = abi.decode(
            proxy.doCall(
                address(cctpV2),
                abi.encodeCall(
                    cctpV2.depositForBurn,
                    (
                        usdcAmount,
                        destinationDomain,
                        mintRecipient,
                        address(usdc),
                        bytes32(0), // destinationCaller = 0 means anyone can relay
                        0,          // maxFee = 0 for standard burns (no fast burn fee)
                        2_000       // minFinalityThreshold = 2000 for standard (finalized) messages
                    )
                )
            ),
            (uint64)
        );

        emit CCTPv2TransferInitiated(nonce, destinationDomain, mintRecipient, usdcAmount);
    }

    /**********************************************************************************************/
    /*** Rate Limit helper functions                                                            ***/
    /**********************************************************************************************/

    function _rateLimited(IRateLimits rateLimits, bytes32 key, uint256 amount) internal {
        rateLimits.triggerRateLimitDecrease(key, amount);
    }

}

