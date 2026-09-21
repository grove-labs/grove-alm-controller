// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import { IPSM3 } from "spark-psm/src/interfaces/IPSM3.sol";

import { IALMProxy }   from "../interfaces/IALMProxy.sol";
import { IRateLimits } from "../interfaces/IRateLimits.sol";

import { ERC20Lib } from "./common/ERC20Lib.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";

library PSM3Lib {

    struct DepositParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     rateLimitId;
        IPSM3       psm;
        address     asset;
        uint256     amount;
    }

    struct WithdrawParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     rateLimitId;
        IPSM3       psm;
        address     asset;
        uint256     maxAmount;
    }

    function deposit(DepositParams memory params) external returns (uint256 shares) {
        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, params.asset),
            params.amount
        );

        ERC20Lib.approve(params.proxy, params.asset, address(params.psm), params.amount);

        shares = abi.decode(
            params.proxy.doCall(
                address(params.psm),
                abi.encodeCall(IPSM3.deposit, (params.asset, address(params.proxy), params.amount))
            ),
            (uint256)
        );

        ERC20Lib.approve(params.proxy, params.asset, address(params.psm), 0);
    }

    function withdraw(WithdrawParams memory params) external returns (uint256 assetsWithdrawn) {
        uint256 startingAssets = IERC20(params.asset).balanceOf(address(params.proxy));

        params.proxy.doCall(
            address(params.psm),
            abi.encodeCall(IPSM3.withdraw, (params.asset, address(params.proxy), params.maxAmount))
        );

        // Charge what actually arrived rather than what the PSM reports.
        assetsWithdrawn = IERC20(params.asset).balanceOf(address(params.proxy)) - startingAssets;

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, params.asset),
            assetsWithdrawn
        );
    }

}
