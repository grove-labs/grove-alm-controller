// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import { IALMProxy }   from "../interfaces/IALMProxy.sol";
import { IRateLimits } from "../interfaces/IRateLimits.sol";
import { ERC20Lib }    from "./common/ERC20Lib.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";

interface IAaveV4Spoke {
    struct Reserve {
        address underlying;
        address hub;
        uint16  assetId;
        uint8   decimals;
        uint24  collateralRisk;
        uint8   flags;
        uint32  dynamicConfigKey;
    }
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf)
        external returns (uint256 suppliedShares, uint256 suppliedAmount);
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf)
        external returns (uint256 withdrawnShares, uint256 withdrawnAmount);
    function getReserve(uint256 reserveId) external view returns (Reserve memory);
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);
}

library AaveV4Lib {

    struct DepositParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     depositRateLimitId;
        address     spoke;
        uint256     reserveId;
        uint256     amount;
        uint256     maxSlippage;
    }

    struct WithdrawParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     depositRateLimitId;
        bytes32     withdrawRateLimitId;
        address     spoke;
        uint256     reserveId;
        uint256     amount;
    }

    function deposit(DepositParams memory params) external {
        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeSpokeReserveKey(params.depositRateLimitId, params.spoke, params.reserveId),
            params.amount
        );

        require(params.maxSlippage != 0, "AaveV4Lib/max-slippage-not-set");

        address underlying = IAaveV4Spoke(params.spoke).getReserve(params.reserveId).underlying;

        uint256 suppliedBefore
            = IAaveV4Spoke(params.spoke).getUserSuppliedAssets(params.reserveId, address(params.proxy));

        // Approve underlying to the Spoke from the proxy (assumes the proxy has enough underlying).
        ERC20Lib.approve(params.proxy, underlying, params.spoke, params.amount);

        // Supply underlying to the Spoke, increasing the proxy's supplied position.
        params.proxy.doCall(
            params.spoke,
            abi.encodeCall(IAaveV4Spoke.supply, (params.reserveId, params.amount, address(params.proxy)))
        );

        uint256 newSupplied
            = IAaveV4Spoke(params.spoke).getUserSuppliedAssets(params.reserveId, address(params.proxy))
              - suppliedBefore;

        require(
            newSupplied >= params.amount * params.maxSlippage / 1e18,
            "AaveV4Lib/slippage-too-high"
        );

        // Clear the approval in case the Spoke did not pull the full amount.
        ERC20Lib.approve(params.proxy, underlying, params.spoke, 0);
    }

    // NOTE: !!! Rate limited at end of function !!!
    function withdraw(WithdrawParams memory params) external returns (uint256 amountWithdrawn) {
        address underlying = IAaveV4Spoke(params.spoke).getReserve(params.reserveId).underlying;

        uint256 balanceBefore = IERC20(underlying).balanceOf(address(params.proxy));

        // Withdraw underlying from the Spoke to the proxy.
        // An amount greater than the max withdrawable signals a full withdrawal.
        params.proxy.doCall(
            params.spoke,
            abi.encodeCall(IAaveV4Spoke.withdraw, (params.reserveId, params.amount, address(params.proxy)))
        );

        // Measure the amount actually received rather than trusting the return value.
        amountWithdrawn = IERC20(underlying).balanceOf(address(params.proxy)) - balanceBefore;

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeSpokeReserveKey(params.withdrawRateLimitId, params.spoke, params.reserveId),
            amountWithdrawn
        );

        // Restore deposit capacity by the withdrawn amount; skipped if no deposit limit is set.
        bytes32 depositKey
            = RateLimitHelpers.makeSpokeReserveKey(params.depositRateLimitId, params.spoke, params.reserveId);
        if (params.rateLimits.getRateLimitData(depositKey).maxAmount != 0) {
            params.rateLimits.triggerRateLimitIncrease(depositKey, amountWithdrawn);
        }
    }

}
