// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC7540 } from "forge-std/interfaces/IERC7540.sol";

import { IERC4626 } from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { IALMProxy }   from "../interfaces/IALMProxy.sol";
import { IRateLimits } from "../interfaces/IRateLimits.sol";

import { ERC20Lib } from "./common/ERC20Lib.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";

library ERC7540Lib {

    bytes32 public constant LIMIT_7540_REQUEST_DEPOSIT = keccak256("LIMIT_7540_REQUEST_DEPOSIT");
    bytes32 public constant LIMIT_7540_CLAIM_DEPOSIT   = keccak256("LIMIT_7540_CLAIM_DEPOSIT");
    bytes32 public constant LIMIT_7540_REQUEST_REDEEM  = keccak256("LIMIT_7540_REQUEST_REDEEM");
    bytes32 public constant LIMIT_7540_CLAIM_REDEEM    = keccak256("LIMIT_7540_CLAIM_REDEEM");

    struct RequestDepositParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        address     token;
        uint256     amount;
    }

    struct RequestRedeemParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        address     token;
        uint256     shares;
    }

    struct ClaimParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        address     token;
    }

    function requestDeposit(RequestDepositParams memory params) external {
        address asset = IERC7540(params.token).asset();

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAddressAddressKey(LIMIT_7540_REQUEST_DEPOSIT, asset, params.token),
            params.amount
        );

        // Approve asset to vault from the proxy (assumes the proxy has enough of the asset).
        ERC20Lib.approve(params.proxy, asset, params.token, params.amount);

        // Submit deposit request by transferring assets
        params.proxy.doCall(
            params.token,
            abi.encodeCall(
                IERC7540(params.token).requestDeposit,
                (params.amount, address(params.proxy), address(params.proxy))
            )
        );

        ERC20Lib.approve(params.proxy, asset, params.token, 0);
    }

    function claimDeposit(ClaimParams memory params) external {
        _rateLimitExists(params.rateLimits, RateLimitHelpers.makeAssetKey(LIMIT_7540_CLAIM_DEPOSIT, params.token));

        uint256 shares = IERC7540(params.token).maxMint(address(params.proxy));

        // Claim shares from the vault to the proxy
        params.proxy.doCall(
            params.token,
            abi.encodeCall(IERC4626(params.token).mint, (shares, address(params.proxy)))
        );
    }

    function requestRedeem(RequestRedeemParams memory params) external {
        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(LIMIT_7540_REQUEST_REDEEM, params.token),
            IERC7540(params.token).convertToAssets(params.shares)
        );

        // Submit redeem request by transferring shares
        params.proxy.doCall(
            params.token,
            abi.encodeCall(
                IERC7540(params.token).requestRedeem,
                (params.shares, address(params.proxy), address(params.proxy))
            )
        );
    }

    function claimRedeem(ClaimParams memory params) external {
        _rateLimitExists(params.rateLimits, RateLimitHelpers.makeAssetKey(LIMIT_7540_CLAIM_REDEEM, params.token));

        uint256 assets = IERC7540(params.token).maxWithdraw(address(params.proxy));

        // Claim assets from the vault to the proxy
        params.proxy.doCall(
            params.token,
            abi.encodeCall(
                IERC7540(params.token).withdraw,
                (assets, address(params.proxy), address(params.proxy))
            )
        );
    }

    /**********************************************************************************************/
    /*** Rate Limit helper functions                                                            ***/
    /**********************************************************************************************/

    function _rateLimitExists(IRateLimits rateLimits, bytes32 key) internal view {
        require(
            rateLimits.getRateLimitData(key).maxAmount > 0,
            "ERC7540Lib/invalid-action"
        );
    }

}
