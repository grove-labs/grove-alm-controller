// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IAToken }            from "aave-v3-origin/src/core/contracts/interfaces/IAToken.sol";
import { IPool as IAavePool } from "aave-v3-origin/src/core/contracts/interfaces/IPool.sol";

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import { IALMProxy }   from "../interfaces/IALMProxy.sol";
import { IRateLimits } from "../interfaces/IRateLimits.sol";

import { ERC20Lib } from "./common/ERC20Lib.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";

interface IATokenWithPool is IAToken {
    function POOL() external view returns(address);
}

library AaveLib {

    struct DepositParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     rateLimitId;
        address     aToken;
        uint256     amount;
        uint256     maxSlippage;
    }

    struct WithdrawParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        bytes32     rateLimitId;
        address     aToken;
        uint256     amount;
    }

    function deposit(DepositParams memory params) external {
        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, params.aToken),
            params.amount
        );

        require(params.maxSlippage != 0, "AaveLib/max-slippage-not-set");

        IERC20    underlying = IERC20(IATokenWithPool(params.aToken).UNDERLYING_ASSET_ADDRESS());
        IAavePool pool       = IAavePool(IATokenWithPool(params.aToken).POOL());

        uint256 aTokenBalance = IERC20(params.aToken).balanceOf(address(params.proxy));

        // Approve underlying to Aave pool from the proxy (assumes the proxy has enough underlying).
        ERC20Lib.approve(params.proxy, address(underlying), address(pool), params.amount);

        // Deposit underlying into Aave pool, proxy receives aTokens.
        params.proxy.doCall(
            address(pool),
            abi.encodeCall(pool.supply, (address(underlying), params.amount, address(params.proxy), 0))
        );

        uint256 newATokens = IERC20(params.aToken).balanceOf(address(params.proxy)) - aTokenBalance;

        require(
            newATokens >= params.amount * params.maxSlippage / 1e18,
            "AaveLib/slippage-too-high"
        );
    }

    function withdraw(WithdrawParams memory params) external returns (uint256 amountWithdrawn) {
        IAavePool pool = IAavePool(IATokenWithPool(params.aToken).POOL());

        // Withdraw underlying from Aave pool, decode resulting amount withdrawn.
        // Assumes proxy has adequate aTokens.
        amountWithdrawn = abi.decode(
            params.proxy.doCall(
                address(pool),
                abi.encodeCall(
                    pool.withdraw,
                    (
                        IATokenWithPool(params.aToken).UNDERLYING_ASSET_ADDRESS(),
                        params.amount,
                        address(params.proxy)
                    )
                )
            ),
            (uint256)
        );

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, params.aToken),
            amountWithdrawn
        );
    }

}
