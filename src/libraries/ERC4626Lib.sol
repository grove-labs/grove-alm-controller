// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

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
        uint256     maxExchangeRate;
    }

    struct WithdrawParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     rateLimitId;
        address     token;
        uint256     amount;
    }

    struct RedeemParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     rateLimitId;
        address     token;
        uint256     shares;
    }

    function deposit(DepositParams memory params) external returns (uint256 shares) {
        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, params.token),
            params.amount
        );

        address asset = IERC4626(params.token).asset();

        // Approve asset to token from the proxy (assumes the proxy has enough of the asset).
        ERC20Lib.approve(params.proxy, asset, params.token, params.amount);

        // Deposit asset into the token, proxy receives token shares, decode the resulting shares.
        shares = abi.decode(
            params.proxy.doCall(
                params.token,
                abi.encodeCall(IERC4626(params.token).deposit, (params.amount, address(params.proxy)))
            ),
            (uint256)
        );

        require(
            getExchangeRate(shares, params.amount) <= params.maxExchangeRate,
            "ERC4626Lib/exchange-rate-too-high"
        );
    }

    function withdraw(WithdrawParams memory params) external returns (uint256 shares) {
        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, params.token),
            params.amount
        );

        // Withdraw asset from a token, decode resulting shares.
        // Assumes proxy has adequate token shares.
        shares = abi.decode(
            params.proxy.doCall(
                params.token,
                abi.encodeCall(
                    IERC4626(params.token).withdraw,
                    (params.amount, address(params.proxy), address(params.proxy))
                )
            ),
            (uint256)
        );
    }

    function redeem(RedeemParams memory params) external returns (uint256 assets) {
        // Redeem shares for assets from the token, decode the resulting assets.
        // Assumes proxy has adequate token shares.
        assets = abi.decode(
            params.proxy.doCall(
                params.token,
                abi.encodeCall(
                    IERC4626(params.token).redeem,
                    (params.shares, address(params.proxy), address(params.proxy))
                )
            ),
            (uint256)
        );

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, params.token),
            assets
        );
    }

    function getExchangeRate(uint256 shares, uint256 assets) public pure returns (uint256) {
        // Return 0 for zero assets first, to handle the valid case of 0 shares and 0 assets.
        if (assets == 0) return 0;

        // Zero shares with non-zero assets is invalid (infinite exchange rate).
        if (shares == 0) revert("ERC4626Lib/zero-shares");

        return (EXCHANGE_RATE_PRECISION * assets) / shares;
    }

}
