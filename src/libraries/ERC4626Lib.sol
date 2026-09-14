// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC20 }   from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import { IALMProxy }   from "../interfaces/IALMProxy.sol";
import { IRateLimits } from "../interfaces/IRateLimits.sol";

import { ERC20Lib } from "./common/ERC20Lib.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";

library ERC4626Lib {

    uint256 public constant EXCHANGE_RATE_PRECISION = 1e36;

    struct DepositParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     rateLimitId;
        address     token;
        uint256     amount;
        uint256     minSharesOut;
        uint256     maxExchangeRate;
    }

    struct WithdrawParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     depositRateLimitId;
        bytes32     withdrawRateLimitId;
        address     token;
        uint256     amount;
        uint256     maxSharesIn;
    }

    struct RedeemParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     depositRateLimitId;
        bytes32     withdrawRateLimitId;
        address     token;
        uint256     shares;
        uint256     minAssetsOut;
    }

    function deposit(DepositParams memory params) external returns (uint256 shares) {
        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, params.token),
            params.amount
        );

        // Note that whitelist is done by rate limits.
        address asset = IERC4626(params.token).asset();

        // Approve asset to token from the proxy (assumes the proxy has enough of the asset).
        ERC20Lib.approve(params.proxy, asset, params.token, params.amount);

        // Shares are measured on the proxy rather than trusted from the vault's return value.
        uint256 startingShares = IERC20(params.token).balanceOf(address(params.proxy));

        params.proxy.doCall(
            params.token,
            abi.encodeCall(IERC4626(params.token).deposit, (params.amount, address(params.proxy)))
        );

        shares = IERC20(params.token).balanceOf(address(params.proxy)) - startingShares;

        require(shares >= params.minSharesOut, "ERC4626Lib/min-shares-out-not-met");

        require(
            getExchangeRate(shares, params.amount) <= params.maxExchangeRate,
            "ERC4626Lib/exchange-rate-too-high"
        );

        // Clear approval in case the vault pulled less than approved.
        ERC20Lib.approve(params.proxy, asset, params.token, 0);
    }

    // NOTE: !!! Rate limited at end of function !!!
    function withdraw(WithdrawParams memory params) external returns (uint256 shares) {
        address asset = IERC4626(params.token).asset();

        uint256 startingAssets = IERC20(asset).balanceOf(address(params.proxy));
        uint256 startingShares = IERC20(params.token).balanceOf(address(params.proxy));

        // Withdraw asset from a token, assumes proxy has adequate token shares.
        params.proxy.doCall(
            params.token,
            abi.encodeCall(
                IERC4626(params.token).withdraw,
                (params.amount, address(params.proxy), address(params.proxy))
            )
        );

        uint256 assets = IERC20(asset).balanceOf(address(params.proxy)) - startingAssets;

        shares = startingShares - IERC20(params.token).balanceOf(address(params.proxy));

        require(shares <= params.maxSharesIn, "ERC4626Lib/shares-burned-too-high");

        _rateLimitExit(params.rateLimits, params.withdrawRateLimitId, params.depositRateLimitId, params.token, assets);
    }

    // NOTE: !!! Rate limited at end of function !!!
    function redeem(RedeemParams memory params) external returns (uint256 assets) {
        address asset = IERC4626(params.token).asset();

        uint256 startingAssets = IERC20(asset).balanceOf(address(params.proxy));

        // Redeem shares for assets from the token, assumes proxy has adequate token shares.
        params.proxy.doCall(
            params.token,
            abi.encodeCall(
                IERC4626(params.token).redeem,
                (params.shares, address(params.proxy), address(params.proxy))
            )
        );

        assets = IERC20(asset).balanceOf(address(params.proxy)) - startingAssets;

        require(assets >= params.minAssetsOut, "ERC4626Lib/min-assets-out-not-met");

        _rateLimitExit(params.rateLimits, params.withdrawRateLimitId, params.depositRateLimitId, params.token, assets);
    }

    function getExchangeRate(uint256 shares, uint256 assets) public pure returns (uint256) {
        // Return 0 for zero assets first, to handle the valid case of 0 shares and 0 assets.
        if (assets == 0) return 0;

        // Zero shares with non-zero assets is invalid (infinite exchange rate).
        if (shares == 0) revert("ERC4626Lib/zero-shares");

        return (EXCHANGE_RATE_PRECISION * assets) / shares;
    }

    // Charges the withdraw limit by the assets actually received and gives that capacity back to
    // the deposit limit. The restore is skipped when no deposit limit is configured so that exits
    // are never blocked by it.
    function _rateLimitExit(
        IRateLimits rateLimits,
        bytes32     withdrawRateLimitId,
        bytes32     depositRateLimitId,
        address     token,
        uint256     assets
    )
        internal
    {
        rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(withdrawRateLimitId, token),
            assets
        );

        bytes32 depositKey = RateLimitHelpers.makeAssetKey(depositRateLimitId, token);

        if (rateLimits.getRateLimitData(depositKey).maxAmount != 0) {
            rateLimits.triggerRateLimitIncrease(depositKey, assets);
        }
    }

}
