// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import { IALMProxy }   from "../interfaces/IALMProxy.sol";
import { IRateLimits } from "../interfaces/IRateLimits.sol";
import { ERC20Lib }    from "../libraries/common/ERC20Lib.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";
interface ICurvePoolLike is IERC20 {
    function add_liquidity(
        uint256[] memory amounts,
        uint256   minMintAmount,
        address   receiver
    ) external;
    function balances(uint256 index) external view returns (uint256);
    function coins(uint256 index) external view returns (address);
    function exchange(
        int128  inputIndex,
        int128  outputIndex,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external returns (uint256 tokensOut);
    function get_virtual_price() external view returns (uint256);
    function N_COINS() external view returns (uint256);
    function remove_liquidity(
        uint256   burnAmount,
        uint256[] memory minAmounts,
        address   receiver,
        bool      claimAdminFees
    ) external;
    function stored_rates() external view returns (uint256[] memory);
}

library CurveLib {

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/

    struct SwapCurveParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        address     pool;
        bytes32     rateLimitId;
        uint256     inputIndex;
        uint256     outputIndex;
        uint256     amountIn;
        uint256     minAmountOut;
        uint256     maxSlippage;
    }

    struct AddLiquidityParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        address     pool;
        bytes32     addLiquidityRateLimitId;
        bytes32     swapRateLimitId;
        uint256     minLpAmount;
        uint256     maxSlippage;
        uint256[]   depositAmounts;
    }

    struct RemoveLiquidityParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        address     pool;
        bytes32     rateLimitId;
        uint256     lpBurnAmount;
        uint256[]   minWithdrawAmounts;
        uint256     maxSlippage;
    }

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    // Swap limit is keyed per input token and charged in token units
    function swap(SwapCurveParams calldata params) external returns (uint256 amountOut) {
        require(params.inputIndex != params.outputIndex, "CurveLib/invalid-indices");

        require(params.maxSlippage != 0, "CurveLib/max-slippage-not-set");

        ICurvePoolLike curvePool = ICurvePoolLike(params.pool);

        uint256 numCoins = curvePool.N_COINS();
        require(
            params.inputIndex < numCoins && params.outputIndex < numCoins,
            "CurveLib/index-too-high"
        );

        _validateSwapMinAmountOut(params, curvePool.stored_rates());

        address tokenIn  = curvePool.coins(params.inputIndex);
        address tokenOut = curvePool.coins(params.outputIndex);

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetDestinationKey(params.rateLimitId, tokenIn, params.pool),
            params.amountIn
        );

        ERC20Lib.approve(params.proxy, tokenIn, params.pool, params.amountIn);

        uint256 startingBalance = IERC20(tokenOut).balanceOf(address(params.proxy));

        _callExchange(params, curvePool);

        amountOut = IERC20(tokenOut).balanceOf(address(params.proxy)) - startingBalance;

        // Clear approvals of dust
        ERC20Lib.approve(params.proxy, tokenIn, params.pool, 0);

        require(amountOut >= params.minAmountOut, "CurveLib/min-amount-out-not-met");
    }

    function addLiquidity(AddLiquidityParams calldata params) external returns (uint256 shares) {
        require(params.maxSlippage != 0, "CurveLib/max-slippage-not-set");

        ICurvePoolLike curvePool = ICurvePoolLike(params.pool);

        uint256 virtualPrice = curvePool.get_virtual_price();

        // Prevent adding liquidity to unseeded pools
        require(virtualPrice != 0, "CurveLib/virtual-price-zero");

        address[] memory tokens = _getTokens(curvePool);

        require(params.depositAmounts.length == tokens.length, "CurveLib/invalid-deposit-amounts");

        // Normalized to provide 36 decimal precision when multiplied by asset amount
        uint256[] memory rates = curvePool.stored_rates();

        // Aggregate the value of the deposited assets (e.g. USD)
        uint256 valueDeposited;
        for (uint256 i = 0; i < tokens.length; i++) {
            ERC20Lib.approve(params.proxy, tokens[i], params.pool, params.depositAmounts[i]);
            valueDeposited += params.depositAmounts[i] * rates[i];
        }
        valueDeposited /= 1e18;

        // Ensure minimum LP amount expected is greater than max slippage amount.
        require(
            params.minLpAmount >= valueDeposited * params.maxSlippage / virtualPrice,
            "CurveLib/min-amount-not-met"
        );

        uint256 startingShares = curvePool.balanceOf(address(params.proxy));

        params.proxy.doCall(
            params.pool,
            abi.encodeCall(
                curvePool.add_liquidity,
                (params.depositAmounts, params.minLpAmount, address(params.proxy))
            )
        );

        shares = curvePool.balanceOf(address(params.proxy)) - startingShares;

        require(shares >= params.minLpAmount, "CurveLib/min-shares-not-met");

        // Clear approvals of dust
        for (uint256 i = 0; i < tokens.length; i++) {
            ERC20Lib.approve(params.proxy, tokens[i], params.pool, 0);
        }

        _decreaseAddLiquidityRateLimits(params, curvePool, tokens, rates, shares);
    }

    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        returns (uint256[] memory withdrawnTokens)
    {
        require(params.maxSlippage != 0, "CurveLib/max-slippage-not-set");

        ICurvePoolLike curvePool = ICurvePoolLike(params.pool);

        address[] memory tokens = _getTokens(curvePool);

        require(params.minWithdrawAmounts.length == tokens.length, "CurveLib/invalid-min-withdraw-amounts");

        // Normalized to provide 36 decimal precision when multiplied by asset amount
        uint256[] memory rates = curvePool.stored_rates();

        // Aggregate the minimum values of the withdrawn assets (e.g. USD)
        uint256 valueMinWithdrawn;
        uint256[] memory startingBalances = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            valueMinWithdrawn   += params.minWithdrawAmounts[i] * rates[i];
            startingBalances[i]  = IERC20(tokens[i]).balanceOf(address(params.proxy));
        }
        valueMinWithdrawn /= 1e18;

        // Check that the aggregated minimums are greater than the max slippage amount
        require(
            valueMinWithdrawn >= params.lpBurnAmount
                * curvePool.get_virtual_price()
                * params.maxSlippage
                / 1e36,
            "CurveLib/min-amount-not-met"
        );

        params.proxy.doCall(
            params.pool,
            abi.encodeCall(
                curvePool.remove_liquidity,
                (params.lpBurnAmount, params.minWithdrawAmounts, address(params.proxy), false)
            )
        );

        withdrawnTokens = new uint256[](tokens.length);

        // Aggregate value withdrawn to reduce the pool-level rate limit
        uint256 valueWithdrawn;
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 withdrawn = IERC20(tokens[i]).balanceOf(address(params.proxy)) - startingBalances[i];

            require(withdrawn >= params.minWithdrawAmounts[i], "CurveLib/min-amount-out-not-met");

            withdrawnTokens[i]  = withdrawn;
            valueWithdrawn     += withdrawn * rates[i];

            params.rateLimits.triggerRateLimitDecrease(
                RateLimitHelpers.makeAssetDestinationKey(params.rateLimitId, tokens[i], params.pool),
                withdrawn
            );
        }

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, params.pool),
            valueWithdrawn / 1e18
        );
    }

    /**********************************************************************************************/
    /*** Internal functions                                                                     ***/
    /**********************************************************************************************/

    function _validateSwapMinAmountOut(SwapCurveParams calldata params, uint256[] memory rates) internal pure {
        // Below code is simplified from the following logic.
        // `maxSlippage` was multiplied first to avoid precision loss.
        //   valueIn   = amountIn * rates[inputIndex] / 1e18  // 18 decimal precision, USD
        //   tokensOut = valueIn * 1e18 / rates[outputIndex]  // Token precision, token amount
        //   result    = tokensOut * maxSlippage / 1e18
        uint256 minimumMinAmountOut = params.amountIn
            * rates[params.inputIndex]
            * params.maxSlippage
            / rates[params.outputIndex]
            / 1e18;

        require(
            params.minAmountOut >= minimumMinAmountOut,
            "CurveLib/min-amount-not-met"
        );
    }

    function _callExchange(SwapCurveParams calldata params, ICurvePoolLike curvePool) internal {
        params.proxy.doCall(
            params.pool,
            abi.encodeCall(
                curvePool.exchange,
                (
                    int128(int256(params.inputIndex)),   // safe cast because of 8 token max
                    int128(int256(params.outputIndex)),  // safe cast because of 8 token max
                    params.amountIn,
                    params.minAmountOut,
                    address(params.proxy)
                )
            )
        );
    }

    function _getTokens(ICurvePoolLike curvePool) internal view returns (address[] memory tokens) {
        tokens = new address[](curvePool.N_COINS());

        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i] = curvePool.coins(i);
        }
    }

    // The minted shares are worth a pro-rata slice of every pool balance. Any input amount above
    // that slice was effectively swapped into the other coins and is charged to that token's swap
    // limit; the slice itself is what was deposited and is charged to the per-token deposit limit
    // and, in value terms, to the pool-level deposit limit.
    function _decreaseAddLiquidityRateLimits(
        AddLiquidityParams calldata params,
        ICurvePoolLike              curvePool,
        address[] memory            tokens,
        uint256[] memory            rates,
        uint256                     shares
    )
        internal
    {
        uint256 totalSupply = curvePool.totalSupply();

        uint256 valueDeposited;
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 deposited = curvePool.balances(i) * shares / totalSupply;
            uint256 input     = params.depositAmounts[i];

            params.rateLimits.triggerRateLimitDecrease(
                RateLimitHelpers.makeAssetDestinationKey(params.swapRateLimitId, tokens[i], params.pool),
                input > deposited ? input - deposited : 0
            );
            params.rateLimits.triggerRateLimitDecrease(
                RateLimitHelpers.makeAssetDestinationKey(params.addLiquidityRateLimitId, tokens[i], params.pool),
                deposited
            );

            valueDeposited += deposited * rates[i];
        }

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.addLiquidityRateLimitId, params.pool),
            valueDeposited / 1e18
        );
    }

}
