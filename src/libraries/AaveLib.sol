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
        address   underlying = IATokenWithPool(params.aToken).UNDERLYING_ASSET_ADDRESS();
        IAavePool pool       = IAavePool(IATokenWithPool(params.aToken).POOL());

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAddressAddressAddressKey(
                params.rateLimitId, underlying, address(pool), params.aToken
            ),
            params.amount
        );

        require(params.maxSlippage != 0, "AaveLib/max-slippage-not-set");

        uint256 aTokenBalance = IERC20(params.aToken).balanceOf(address(params.proxy));

        ERC20Lib.approve(params.proxy, underlying, address(pool), params.amount);

        params.proxy.doCall(
            address(pool),
            abi.encodeCall(pool.supply, (underlying, params.amount, address(params.proxy), 0))
        );

        uint256 newATokens = IERC20(params.aToken).balanceOf(address(params.proxy)) - aTokenBalance;

        require(
            newATokens >= params.amount * params.maxSlippage / 1e18,
            "AaveLib/slippage-too-high"
        );

        ERC20Lib.approve(params.proxy, underlying, address(pool), 0);
    }

    function withdraw(WithdrawParams memory params) external returns (uint256 amountWithdrawn) {
        IERC20    underlying = IERC20(IATokenWithPool(params.aToken).UNDERLYING_ASSET_ADDRESS());
        IAavePool pool       = IAavePool(IATokenWithPool(params.aToken).POOL());

        uint256 underlyingBalance = underlying.balanceOf(address(params.proxy));

        params.proxy.doCall(
            address(pool),
            abi.encodeCall(pool.withdraw, (address(underlying), params.amount, address(params.proxy)))
        );

        amountWithdrawn = underlying.balanceOf(address(params.proxy)) - underlyingBalance;

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAddressAddressKey(params.rateLimitId, address(pool), params.aToken),
            amountWithdrawn
        );
    }

}
