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

interface IAaveV4Hub {
    function getAssetDeficitRay(uint256 assetId) external view returns (uint256);
    function getAssetUnderlyingAndDecimals(uint256 assetId) external view returns (address, uint8);
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
        address     hub;
        uint16      assetId;
        uint256     maxDeficit;
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
        require(params.maxSlippage != 0, "AaveV4Lib/max-slippage-not-set");

        IAaveV4Spoke.Reserve memory reserve = IAaveV4Spoke(params.spoke).getReserve(params.reserveId);

        // The caller resolves maxDeficit from the (hub, assetId) it declares, before the reserve can
        // be read, so the declaration is only safe once checked against the Spoke: otherwise a
        // relayer could aim the lookup at an asset carrying a looser tolerance.
        require(
            reserve.hub == params.hub && reserve.assetId == params.assetId,
            "AaveV4Lib/invalid-hub-asset"
        );

        address underlying = reserve.underlying;

        (address hubUnderlying,) = IAaveV4Hub(reserve.hub).getAssetUnderlyingAndDecimals(reserve.assetId);
        require(hubUnderlying == underlying, "AaveV4Lib/invalid-hub-asset-metadata");

        // The Hub records the deficit (unbacked liquidity from bad debt) globally per asset, and
        // separately per reporting Spoke; eliminateDeficit burns shares from the caller Spoke, so
        // losses are not automatically distributed pro rata across suppliers. maxDeficit is a
        // deposit threshold on the Hub-wide reported deficit for the declared (hub, assetId).
        require(
            IAaveV4Hub(reserve.hub).getAssetDeficitRay(reserve.assetId) <= params.maxDeficit,
            "AaveV4Lib/deficit-too-high"
        );

        params.rateLimits.triggerRateLimitDecrease(
            _makeDepositKey(params.depositRateLimitId, params.spoke, params.reserveId, reserve),
            params.amount
        );

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
        IAaveV4Spoke.Reserve memory reserve = IAaveV4Spoke(params.spoke).getReserve(params.reserveId);

        address underlying = reserve.underlying;

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
            RateLimitHelpers.makeAddressUint256Key(params.withdrawRateLimitId, params.spoke, params.reserveId),
            amountWithdrawn
        );

        // Restore deposit capacity by the withdrawn amount; skipped if no deposit limit is set.
        // A reserve remapped to a different Hub asset resolves to an unconfigured key, so only the
        // restore is skipped, never the exit itself (the withdraw key omits the reserve's Hub data).
        bytes32 depositKey = _makeDepositKey(params.depositRateLimitId, params.spoke, params.reserveId, reserve);
        if (params.rateLimits.getRateLimitData(depositKey).maxAmount != 0) {
            params.rateLimits.triggerRateLimitIncrease(depositKey, amountWithdrawn);
        }
    }

    function _makeDepositKey(
        bytes32 rateLimitId,
        address spoke,
        uint256 reserveId,
        IAaveV4Spoke.Reserve memory reserve
    )
        internal pure returns (bytes32)
    {
        return RateLimitHelpers.makeAddressUint256AddressUint16AddressKey(
            rateLimitId,
            spoke,
            reserveId,
            reserve.hub,
            reserve.assetId,
            reserve.underlying
        );
    }

}
