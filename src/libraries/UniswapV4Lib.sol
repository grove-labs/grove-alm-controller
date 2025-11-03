// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC20 } from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IALMProxy }   from "../interfaces/IALMProxy.sol";
import { IRateLimits } from "../interfaces/IRateLimits.sol";

import { RateLimitHelpers } from "../RateLimitHelpers.sol";

import { FullMath } from "lib/dss-allocator/src/funnels/uniV3/FullMath.sol";
import { UniV3Utils } from "lib/dss-allocator/test/funnels/UniV3Utils.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IUniswapV3PoolLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

interface INonfungiblePositionManager {

    struct MintParams {
        address token0;
        address token1;
        uint24  fee;
        int24   tickLower;
        int24   tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

library UniswapV3Lib {

    uint256 internal constant Q96  = 2 ** 96;
    uint256 internal constant Q192 = 2 ** 192;

    bytes1 internal constant COMMAND_V3_SWAP_EXACT_IN = 0x00;

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/

    struct SwapParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        address     router;
        address     pool;
        bytes32     rateLimitId;
        address     tokenIn;
        uint256     amountIn;
        uint256     minAmountOut;
        uint256     maxSlippage;
        uint256     deadline;
    }

    struct AddLiquidityParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        address     positionManager;
        address     pool;
        bytes32     addLiquidityRateLimitId;
        bytes32     swapRateLimitId;
        int24       tickLower;
        int24       tickUpper;
        uint256     amount0Desired;
        uint256     amount1Desired;
        uint256     amount0Min;
        uint256     amount1Min;
        uint256     maxSlippage;
        uint256     deadline;
    }

    struct AddLiquidityCache {
        address token0;
        address token1;
        uint24  fee;
        uint160 sqrtPriceX96;
        uint256 priceX192;
        uint8   token0Decimals;
        uint256 normalizedDesiredValue;
    }

    struct RemoveLiquidityParams {
        IALMProxy   proxy;
        IRateLimits rateLimits;
        address     positionManager;
        address     pool;
        bytes32     rateLimitId;
        uint256     tokenId;
        uint128     liquidity;
        uint256     amount0Min;
        uint256     amount1Min;
        uint256     maxSlippage;
        uint256     deadline;
    }

    struct RemoveLiquidityCache {
        address token0;
        address token1;
        uint160 sqrtPriceX96;
        uint8   token0Decimals;
        uint256 priceX192;
        int24   tickLower;
        int24   tickUpper;
        uint24  fee;
        uint128 positionLiquidity;
    }

    /**********************************************************************************************/
    /*** External functions                                                                     ***/
    /**********************************************************************************************/

    function swap(SwapParams calldata params) external returns (uint256 amountOut) {
        require(params.maxSlippage != 0, "UniswapV3Lib/max-slippage-not-set");

        IUniswapV3PoolLike pool = IUniswapV3PoolLike(params.pool);

        address token0 = pool.token0();
        address token1 = pool.token1();
        require(token0 != address(0) && token1 != address(0), "UniswapV3Lib/invalid-pool");
        require(
            params.tokenIn == token0 || params.tokenIn == token1,
            "UniswapV3Lib/invalid-token-pair"
        );

        address tokenOut = params.tokenIn == token0 ? token1 : token0;

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint256 priceX192 = _priceX192(sqrtPriceX96);

        uint256 expectedOut;
        uint256 valueInToken0;

        if (params.tokenIn == token0) {
            expectedOut = FullMath.mulDiv(params.amountIn, priceX192, Q192);
            valueInToken0 = params.amountIn;
        } else {
            expectedOut = FullMath.mulDiv(params.amountIn, Q192, priceX192);
            valueInToken0 = FullMath.mulDiv(params.amountIn, Q192, priceX192);
        }

        uint256 minOutBySlippage = expectedOut * params.maxSlippage / 1e18;
        require(params.minAmountOut >= minOutBySlippage, "UniswapV3Lib/min-amount-not-met");

        uint8 token0Decimals = IERC20Metadata(token0).decimals();
        uint256 normalizedValue = _scaleTo1e18(valueInToken0, token0Decimals);

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, params.pool),
            normalizedValue
        );

        _transfer(params.proxy, params.tokenIn, params.router, params.amountIn);

        uint256 tokenOutBalanceBefore = IERC20(tokenOut).balanceOf(address(params.proxy));

        bytes memory commands = abi.encodePacked(COMMAND_V3_SWAP_EXACT_IN);
        bytes[] memory inputs = new bytes[](1);
        bytes memory path = abi.encodePacked(params.tokenIn, pool.fee(), tokenOut);
        inputs[0] = abi.encode(
            address(params.proxy),
            params.amountIn,
            params.minAmountOut,
            path,
            false
        );

        params.proxy.doCall(
            params.router,
            abi.encodeCall(
                IUniversalRouter.execute,
                (commands, inputs, params.deadline)
            )
        );

        uint256 tokenOutBalanceAfter = IERC20(tokenOut).balanceOf(address(params.proxy));
        require(tokenOutBalanceAfter >= tokenOutBalanceBefore, "UniswapV3Lib/invalid-amount-out");
        amountOut = tokenOutBalanceAfter - tokenOutBalanceBefore;
    }

    function addLiquidity(AddLiquidityParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        require(params.maxSlippage != 0, "UniswapV3Lib/max-slippage-not-set");

        IUniswapV3PoolLike pool = IUniswapV3PoolLike(params.pool);

        AddLiquidityCache memory cache;
        cache.token0 = pool.token0();
        cache.token1 = pool.token1();
        cache.fee = pool.fee();

        require(
            params.amount0Desired != 0 || params.amount1Desired != 0,
            "UniswapV3Lib/zero-liquidity"
        );

        (cache.sqrtPriceX96, , , , , , ) = pool.slot0();
        cache.priceX192 = _priceX192(cache.sqrtPriceX96);
        cache.token0Decimals = IERC20Metadata(cache.token0).decimals();

        (uint256 expectedAmount0, uint256 expectedAmount1) = UniV3Utils.getExpectedAmounts(
            cache.token0,
            cache.token1,
            cache.fee,
            params.tickLower,
            params.tickUpper,
            0,
            params.amount0Desired,
            params.amount1Desired,
            false
        );

        cache.normalizedDesiredValue = _scaleTo1e18(
            _valueInToken0(cache.priceX192, expectedAmount0, expectedAmount1),
            cache.token0Decimals
        );

        if (params.amount0Desired != 0) {
            _approve(params.proxy, cache.token0, params.positionManager, params.amount0Desired);
        }
        if (params.amount1Desired != 0) {
            _approve(params.proxy, cache.token1, params.positionManager, params.amount1Desired);
        }

        INonfungiblePositionManager.MintParams memory mintParams
            = INonfungiblePositionManager.MintParams({
                token0: cache.token0,
                token1: cache.token1,
                fee: cache.fee,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                recipient: address(params.proxy),
                deadline: params.deadline
            });

        bytes memory result = params.proxy.doCall(
            params.positionManager,
            abi.encodeCall(
                INonfungiblePositionManager.mint,
                (mintParams)
            )
        );

        (tokenId, liquidity, amount0, amount1) = abi.decode(result, (uint256, uint128, uint256, uint256));
        require(liquidity != 0, "UniswapV3Lib/no-liquidity-minted");

        uint256 normalizedMintedValue = _scaleTo1e18(
            _valueInToken0(cache.priceX192, amount0, amount1),
            cache.token0Decimals
        );

        uint256 minimumAcceptedValue = cache.normalizedDesiredValue * params.maxSlippage / 1e18;
        require(
            normalizedMintedValue >= minimumAcceptedValue,
            "UniswapV3Lib/min-amount-not-met"
        );

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.addLiquidityRateLimitId, params.pool),
            normalizedMintedValue
        );

        if (params.swapRateLimitId != bytes32(0)) {
            uint256 valueDelta = cache.normalizedDesiredValue > normalizedMintedValue
                ? cache.normalizedDesiredValue - normalizedMintedValue
                : normalizedMintedValue - cache.normalizedDesiredValue;

            if (valueDelta != 0) {
                params.rateLimits.triggerRateLimitDecrease(
                    RateLimitHelpers.makeAssetKey(params.swapRateLimitId, params.pool),
                    valueDelta / 2
                );
            }
        }
    }

    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        returns (uint256 amount0Collected, uint256 amount1Collected)
    {
        require(params.maxSlippage != 0, "UniswapV3Lib/max-slippage-not-set");

        IUniswapV3PoolLike pool = IUniswapV3PoolLike(params.pool);

        RemoveLiquidityCache memory cache;

        cache.token0 = pool.token0();
        cache.token1 = pool.token1();
        cache.fee    = pool.fee();

        {
            uint128 owed0;
            uint128 owed1;
            address positionToken0;
            address positionToken1;
            uint24  positionFee;
            (
                ,
                ,
                positionToken0,
                positionToken1,
                positionFee,
                cache.tickLower,
                cache.tickUpper,
                cache.positionLiquidity,
                ,
                ,
                owed0,
                owed1
            ) = INonfungiblePositionManager(params.positionManager).positions(params.tokenId);

            require(
                params.liquidity != 0 || owed0 != 0 || owed1 != 0,
                "UniswapV3Lib/nothing-to-withdraw"
            );

            require(positionToken0 == cache.token0 && positionToken1 == cache.token1, "UniswapV3Lib/invalid-position");
            require(positionFee == cache.fee, "UniswapV3Lib/fee-mismatch");
        }

        require(params.liquidity <= cache.positionLiquidity, "UniswapV3Lib/liquidity-too-high");

        (cache.sqrtPriceX96, , , , , , ) = pool.slot0();
        cache.token0Decimals = IERC20Metadata(cache.token0).decimals();
        cache.priceX192 = _priceX192(cache.sqrtPriceX96);

        (uint256 expectedAmount0, uint256 expectedAmount1) = UniV3Utils.getExpectedAmounts(
            cache.token0,
            cache.token1,
            cache.fee,
            cache.tickLower,
            cache.tickUpper,
            params.liquidity,
            0,
            0,
            true
        );

        uint256 expectedValue = _scaleTo1e18(
            _valueInToken0(cache.priceX192, expectedAmount0, expectedAmount1),
            cache.token0Decimals
        );
        uint256 minimumAcceptedValue = expectedValue * params.maxSlippage / 1e18;

        _decreaseLiquidityCall(
            params.proxy,
            params.positionManager,
            params.tokenId,
            params.liquidity,
            params.amount0Min,
            params.amount1Min,
            params.deadline
        );

        (amount0Collected, amount1Collected) = _collectAll(
            params.proxy,
            params.positionManager,
            params.tokenId,
            address(params.proxy)
        );

        uint256 normalizedCollectedValue = _scaleTo1e18(
            _valueInToken0(cache.priceX192, amount0Collected, amount1Collected),
            cache.token0Decimals
        );

        require(
            normalizedCollectedValue >= minimumAcceptedValue,
            "UniswapV3Lib/min-amount-not-met"
        );

        params.rateLimits.triggerRateLimitDecrease(
            RateLimitHelpers.makeAssetKey(params.rateLimitId, params.pool),
            normalizedCollectedValue
        );
    }

    /**********************************************************************************************/
    /*** Helper functions                                                                       ***/
    /**********************************************************************************************/

    function _transfer(
        IALMProxy proxy,
        address   token,
        address   recipient,
        uint256   amount
    )
        internal
    {
        bytes memory transferData = abi.encodeCall(IERC20.transfer, (recipient, amount));
        bytes memory transferReturnData = proxy.doCall(token, transferData);

        require(
            transferReturnData.length == 0 || abi.decode(transferReturnData, (bool)),
            "UniswapV3Lib/transfer-failed"
        );
    }

    function _approve(
        IALMProxy proxy,
        address   token,
        address   spender,
        uint256   amount
    )
        internal
    {
        bytes memory approveData = abi.encodeCall(IERC20.approve, (spender, amount));

        ( bool success, bytes memory data )
            = address(proxy).call(abi.encodeCall(IALMProxy.doCall, (token, approveData)));

        bytes memory approveCallReturnData;

        if (success) {
            approveCallReturnData = abi.decode(data, (bytes));
            if (approveCallReturnData.length == 0 || abi.decode(approveCallReturnData, (bool))) {
                return;
            }
        }

        proxy.doCall(token, abi.encodeCall(IERC20.approve, (spender, 0)));

        approveCallReturnData = proxy.doCall(token, approveData);

        require(
            approveCallReturnData.length == 0 || abi.decode(approveCallReturnData, (bool)),
            "UniswapV3Lib/approve-failed"
        );
    }

    function _priceX192(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1);
    }

    function _valueInToken0(uint256 priceX192, uint256 amount0, uint256 amount1) internal pure returns (uint256) {
        if (amount1 == 0) {
            return amount0;
        }

        uint256 amount1AsToken0 = FullMath.mulDiv(amount1, Q192, priceX192);
        return amount0 + amount1AsToken0;
    }

    function _scaleTo1e18(uint256 amount, uint8 decimals_) internal pure returns (uint256) {
        if (decimals_ == 18) {
            return amount;
        } else if (decimals_ < 18) {
            return amount * 10 ** (18 - decimals_);
        } else {
            return amount / 10 ** (decimals_ - 18);
        }
    }

    function _decreaseLiquidityCall(
        IALMProxy proxy,
        address positionManager,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    )
        internal
    {
        proxy.doCall(
            positionManager,
            abi.encodeCall(
                INonfungiblePositionManager.decreaseLiquidity,
                (INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: deadline
                }))
            )
        );
    }

    function _collectAll(
        IALMProxy proxy,
        address positionManager,
        uint256 tokenId,
        address recipient
    )
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        bytes memory result = proxy.doCall(
            positionManager,
            abi.encodeCall(
                INonfungiblePositionManager.collect,
                (INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: recipient,
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                }))
            )
        );

        (amount0, amount1) = abi.decode(result, (uint256, uint256));
    }

}
