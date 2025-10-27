// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import "./ForkTestBase.t.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IERC20Metadata } from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { INonfungiblePositionManager, IUniswapV3PoolLike } from "../../src/libraries/UniswapV3Lib.sol";
import { UniV3Utils } from "lib/dss-allocator/test/funnels/UniV3Utils.sol";
import { FullMath } from "lib/dss-allocator/src/funnels/uniV3/FullMath.sol";

contract UniswapV3TestBase is ForkTestBase {
    address constant UNISWAP_V3_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant UNISWAP_V3_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNISWAP_V3_POOL = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;

    int24 internal constant DEFAULT_TICK_LOWER = -600;
    int24 internal constant DEFAULT_TICK_UPPER = 600;

    bytes32 uniswapV3AddLiquidityKey;
    bytes32 uniswapV3SwapKey;
    bytes32 uniswapV3RemoveLiquidityKey;

    IERC20 internal token0;
    IERC20 internal token1;
    uint24 internal poolFee;
    uint8  internal token0Decimals;

    uint256 internal constant Q192 = 2 ** 192;

    function setUp() public virtual override  {
        super.setUp();

        uniswapV3AddLiquidityKey  = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_UNISWAP_V3_DEPOSIT(),  UNISWAP_V3_POOL);
        uniswapV3SwapKey     = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_UNISWAP_V3_SWAP(),     UNISWAP_V3_POOL);
        uniswapV3RemoveLiquidityKey = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_UNISWAP_V3_WITHDRAW(), UNISWAP_V3_POOL);

        vm.startPrank(GROVE_PROXY);
        rateLimits.setRateLimitData(uniswapV3AddLiquidityKey,  2_000_000e18, uint256(2_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3SwapKey,     1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3RemoveLiquidityKey, 3_000_000e18, uint256(3_000_000e18) / 1 days);
        vm.stopPrank();

        // Set a higher slippage to allow for successes
        vm.startPrank(GROVE_PROXY);
        mainnetController.setMaxSlippage(UNISWAP_V3_POOL, 0.98e18);
        mainnetController.setUniswapV3PositionManager(UNISWAP_V3_POSITION_MANAGER);
        mainnetController.setUniswapV3Router(UNISWAP_V3_ROUTER);
        vm.stopPrank();

        token0 = IERC20(IUniswapV3PoolLike(UNISWAP_V3_POOL).token0());
        token1 = IERC20(IUniswapV3PoolLike(UNISWAP_V3_POOL).token1());
        poolFee = IUniswapV3PoolLike(UNISWAP_V3_POOL).fee();
        token0Decimals = IERC20Metadata(address(token0)).decimals();
    }

    function _getBlock() internal pure override returns (uint256) {
        return 22225000;  // April 8, 2025
    }

    function _fundProxy(uint256 amount0Desired, uint256 amount1Desired) internal {
        deal(address(token0), address(almProxy), amount0Desired);
        deal(address(token1), address(almProxy), amount1Desired);
    }

    function _addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired
    )
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        return _addLiquidity(DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, amount0Desired, amount1Desired, 0, 0);
    }

    function _addLiquidity(
        int24   tickLower,
        int24   tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    )
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        vm.startPrank(relayer);
        (tokenId, liquidity, amount0Used, amount1Used)
            = mainnetController.addLiquidityUniswapV3(
                UNISWAP_V3_POOL,
                tickLower,
                tickUpper,
                amount0Desired,
                amount1Desired,
                amount0Min,
                amount1Min,
                block.timestamp + 1 hours
            );
        vm.stopPrank();
    }

    function _addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    )
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        return _addLiquidity(DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, amount0Desired, amount1Desired, amount0Min, amount1Min);
    }

    function _removeLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    )
        internal
        returns (uint256 amount0Collected, uint256 amount1Collected)
    {
        vm.startPrank(relayer);
        (amount0Collected, amount1Collected) = mainnetController.removeLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            tokenId,
            liquidity,
            amount0Min,
            amount1Min,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function _getCurrentTick() internal view returns (int24 tick) {
        (, tick,, , , ,) = IUniswapV3PoolLike(UNISWAP_V3_POOL).slot0();
    }

    function _getPositionLiquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (, , , , , , , liquidity, , , ,) = INonfungiblePositionManager(UNISWAP_V3_POSITION_MANAGER).positions(tokenId);
    }

    function _getCurrentPriceX192() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolLike(UNISWAP_V3_POOL).slot0();
        return _priceX192(sqrtPriceX96);
    }

    function _priceX192(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1);
    }

    function _valueInToken0(
        uint256 priceX192,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint256) {
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

}

contract MainnetControllerAddLiquidityUniswapV3FailureTests is UniswapV3TestBase {

    function test_addLiquidityUniswapV3_notRelayer() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        mainnetController.addLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            DEFAULT_TICK_LOWER,
            DEFAULT_TICK_UPPER,
            1,
            1,
            0,
            0,
            block.timestamp + 1 hours
        );
    }

    function test_addLiquidityUniswapV3_positionManagerNotSet() public {
        vm.prank(GROVE_PROXY);
        mainnetController.setUniswapV3PositionManager(address(0));

        _fundProxy(1_000_000e6, 1_000_000e6);

        vm.startPrank(relayer);
        vm.expectRevert("MainnetController/position-manager-not-set");
        mainnetController.addLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            DEFAULT_TICK_LOWER,
            DEFAULT_TICK_UPPER,
            1_000_000e6,
            1_000_000e6,
            0,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_maxSlippageNotSet() public {
        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(UNISWAP_V3_POOL, 0);

        vm.startPrank(relayer);
        vm.expectRevert("MainnetController/max-slippage-not-set");
        mainnetController.addLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            DEFAULT_TICK_LOWER,
            DEFAULT_TICK_UPPER,
            1_000_000e6,
            1_000_000e6,
            0,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_zeroLiquidity() public {
        vm.startPrank(relayer);
        vm.expectRevert("UniswapV3Lib/zero-liquidity");
        mainnetController.addLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            DEFAULT_TICK_LOWER,
            DEFAULT_TICK_UPPER,
            0,
            0,
            0,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_zeroMaxAmount() public {
        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(uniswapV3AddLiquidityKey, 0, 0);

        _fundProxy(1_000_000e6, 1_000_000e6);

        vm.startPrank(relayer);
        vm.expectRevert("RateLimits/zero-maxAmount");
        mainnetController.addLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            DEFAULT_TICK_LOWER,
            DEFAULT_TICK_UPPER,
            1_000_000e6,
            1_000_000e6,
            0,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_rateLimitExceeded() public {
        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(uniswapV3AddLiquidityKey, 100e18, 100e18);

        _fundProxy(1_000_000e6, 1_000_000e6);

        vm.startPrank(relayer);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        mainnetController.addLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            DEFAULT_TICK_LOWER,
            DEFAULT_TICK_UPPER,
            1_000_000e6,
            1_000_000e6,
            0,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_swapRateLimitZeroMax() public {
        deal(address(usdc), address(almProxy), 1_000_000e6);

        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(uniswapV3SwapKey, 0, 0);

        vm.startPrank(relayer);
        vm.expectRevert("RateLimits/zero-maxAmount");
        mainnetController.swapUniswapV3(
            UNISWAP_V3_POOL,
            address(usdc),
            1_000_000e6,
            990_000e6,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }
}

contract MainnetControllerAddLiquidityUniswapV3SuccessTests is UniswapV3TestBase {
    function test_addLiquidityUniswapV3_balancedAmounts() public {
        uint256 amount0Desired = 1_000_000e6;
        uint256 amount1Desired = 1_000_000e6;

        _fundProxy(amount0Desired, amount1Desired);

        uint256 poolBalance0Before = token0.balanceOf(UNISWAP_V3_POOL);
        uint256 poolBalance1Before = token1.balanceOf(UNISWAP_V3_POOL);
        uint256 proxyBalance0Before = token0.balanceOf(address(almProxy));
        uint256 proxyBalance1Before = token1.balanceOf(address(almProxy));

        uint256 addLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3AddLiquidityKey);
        uint256 swapLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3SwapKey);

        (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
            = _addLiquidity(amount0Desired, amount1Desired);

        assertGt(tokenId, 0, "expected a position token to be minted");
        assertGt(liquidity, 0, "expected liquidity to be minted");
        assertGt(amount0Used, 0, "expected token0 to be used");
        assertGt(amount1Used, 0, "expected token1 to be used");

        assertEq(
            token0.balanceOf(address(almProxy)),
            proxyBalance0Before - amount0Used,
            "proxy should retain the leftover token0 balance"
        );
        assertEq(
            token1.balanceOf(address(almProxy)),
            proxyBalance1Before - amount1Used,
            "proxy should retain the leftover token1 balance"
        );

        assertEq(
            token0.balanceOf(UNISWAP_V3_POOL),
            poolBalance0Before + amount0Used,
            "pool token0 balance should increase by the used amount"
        );
        assertEq(
            token1.balanceOf(UNISWAP_V3_POOL),
            poolBalance1Before + amount1Used,
            "pool token1 balance should increase by the used amount"
        );

        uint256 addLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3AddLiquidityKey);
        uint256 swapLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3SwapKey);

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolLike(UNISWAP_V3_POOL).slot0();
        uint256 priceX192 = _priceX192(sqrtPriceX96);

        uint256 normalizedMintedValue = _scaleTo1e18(
            _valueInToken0(priceX192, amount0Used, amount1Used),
            token0Decimals
        );

        assertEq(
            addLimitBefore - addLimitAfter,
            normalizedMintedValue,
            "add liquidity limit should decrease by the minted value"
        );
        assertTrue(
            swapLimitAfter <= swapLimitBefore,
            "swap rate limit should not increase"
        );
    }

    function test_addLiquidityUniswapV3_imbalancedDepositReducesSwapLimit() public {
        uint256 amount0Desired = 1_000_000e6;
        uint256 amount1Desired = 200_000e6;

        _fundProxy(amount0Desired, amount1Desired);

        uint256 addLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3AddLiquidityKey);
        uint256 swapLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3SwapKey);

        (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
            = _addLiquidity(amount0Desired, amount1Desired);

        assertGt(tokenId, 0, "expected token id to be minted");
        assertGt(liquidity, 0, "expected liquidity to be minted");

        uint256 addLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3AddLiquidityKey);
        uint256 swapLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3SwapKey);

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolLike(UNISWAP_V3_POOL).slot0();
        uint256 priceX192 = _priceX192(sqrtPriceX96);

        uint256 normalizedDesiredValue = _scaleTo1e18(
            _desiredValue(priceX192, amount0Desired, amount1Desired),
            token0Decimals
        );
        uint256 normalizedMintedValue = _scaleTo1e18(
            _valueInToken0(priceX192, amount0Used, amount1Used),
            token0Decimals
        );

        uint256 valueDelta = normalizedDesiredValue > normalizedMintedValue
            ? normalizedDesiredValue - normalizedMintedValue
            : normalizedMintedValue - normalizedDesiredValue;

        assertEq(
            addLimitBefore - addLimitAfter,
            normalizedMintedValue,
            "add rate limit should decline by minted value"
        );
        assertEq(
            swapLimitBefore - swapLimitAfter,
            valueDelta / 2,
            "swap rate limit should reflect half of the value delta"
        );

        assertEq(
            token0.balanceOf(address(almProxy)),
            amount0Desired - amount0Used,
            "proxy should retain remaining token0"
        );
        assertEq(
            token1.balanceOf(address(almProxy)),
            amount1Desired - amount1Used,
            "proxy should retain remaining token1"
        );
    }

    function test_addLiquidityUniswapV3_singleSidedToken0Range() public {
        uint256 amount0Desired = 1_500_000e6;
        uint256 amount1Desired = 0;

        _fundProxy(amount0Desired, amount1Desired);

        int24 currentTick = _getCurrentTick();
        int24 tickLower = currentTick + 10;
        int24 tickUpper = tickLower + 1200;

        uint256 addLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3AddLiquidityKey);
        uint256 swapLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3SwapKey);

        (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
            = _addLiquidity(
                tickLower,
                tickUpper,
                amount0Desired,
                amount1Desired,
                0,
                0
            );

        assertGt(tokenId, 0, "expected token id to be minted");
        assertGt(liquidity, 0, "expected liquidity to be minted");
        assertGt(amount0Used, 0, "expected token0 to be used");
        assertEq(amount1Used, 0, "token1 should not be used when not provided");

        uint256 addLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3AddLiquidityKey);
        uint256 swapLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3SwapKey);

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolLike(UNISWAP_V3_POOL).slot0();
        uint256 priceX192 = _priceX192(sqrtPriceX96);

        uint256 normalizedDesiredValue = _scaleTo1e18(
            _desiredValue(tickLower, tickUpper, priceX192, amount0Desired, amount1Desired),
            token0Decimals
        );
        uint256 normalizedMintedValue = _scaleTo1e18(
            _valueInToken0(priceX192, amount0Used, amount1Used),
            token0Decimals
        );

        assertEq(
            addLimitBefore - addLimitAfter,
            normalizedMintedValue,
            "add limit reduction should equal minted value"
        );
        assertEq(
            normalizedDesiredValue,
            normalizedMintedValue,
            "single-sided range should have matching desired and minted values"
        );
        assertEq(
            swapLimitBefore,
            swapLimitAfter,
            "swap rate limit should remain unchanged when no swap is implied"
        );

        assertEq(
            token0.balanceOf(address(almProxy)),
            amount0Desired - amount0Used,
            "proxy should retain remaining token0"
        );
        assertEq(
            token1.balanceOf(address(almProxy)),
            0,
            "proxy should hold no token1 balance"
        );
    }

    function _desiredValue(
        int24 tickLower,
        int24 tickUpper,
        uint256 priceX192,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal view returns (uint256) {
        (uint256 expectedAmount0, uint256 expectedAmount1) = UniV3Utils.getExpectedAmounts(
            address(token0),
            address(token1),
            poolFee,
            tickLower,
            tickUpper,
            0,
            amount0Desired,
            amount1Desired,
            false
        );

        return _valueInToken0(priceX192, expectedAmount0, expectedAmount1);
    }

    function _desiredValue(
        uint256 priceX192,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal view returns (uint256) {
        return _desiredValue(DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER, priceX192, amount0Desired, amount1Desired);
    }
}

contract MainnetControllerRemoveLiquidityUniswapV3FailureTests is UniswapV3TestBase {

    function _mintPosition(uint256 amount0Desired, uint256 amount1Desired)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        _fundProxy(amount0Desired, amount1Desired);
        return _addLiquidity(amount0Desired, amount1Desired);
    }

    function test_removeLiquidityUniswapV3_notRelayer() public {
        (uint256 tokenId, uint128 liquidity,,) = _mintPosition(1_000_000e6, 1_000_000e6);

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        mainnetController.removeLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            tokenId,
            liquidity,
            0,
            0,
            block.timestamp + 1 hours
        );
    }

    function test_removeLiquidityUniswapV3_positionManagerNotSet() public {
        (uint256 tokenId, uint128 liquidity,,) = _mintPosition(1_000_000e6, 1_000_000e6);

        vm.prank(GROVE_PROXY);
        mainnetController.setUniswapV3PositionManager(address(0));

        vm.startPrank(relayer);
        vm.expectRevert("MainnetController/position-manager-not-set");
        mainnetController.removeLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            tokenId,
            liquidity,
            0,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_removeLiquidityUniswapV3_maxSlippageNotSet() public {
        (uint256 tokenId, uint128 liquidity,,) = _mintPosition(1_000_000e6, 1_000_000e6);

        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(UNISWAP_V3_POOL, 0);

        vm.startPrank(relayer);
        vm.expectRevert("MainnetController/max-slippage-not-set");
        mainnetController.removeLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            tokenId,
            liquidity,
            0,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_removeLiquidityUniswapV3_zeroMaxAmount() public {
        (uint256 tokenId, uint128 liquidity,,) = _mintPosition(1_000_000e6, 1_000_000e6);

        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(uniswapV3RemoveLiquidityKey, 0, 0);

        vm.startPrank(relayer);
        vm.expectRevert("RateLimits/zero-maxAmount");
        mainnetController.removeLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            tokenId,
            liquidity,
            0,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_removeLiquidityUniswapV3_liquidityTooHigh() public {
        (uint256 tokenId, uint128 liquidity,,) = _mintPosition(1_000_000e6, 1_000_000e6);

        vm.startPrank(relayer);
        vm.expectRevert("UniswapV3Lib/liquidity-too-high");
        mainnetController.removeLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            tokenId,
            liquidity + 1,
            0,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_removeLiquidityUniswapV3_nothingToWithdraw() public {
        (uint256 tokenId,,,) = _mintPosition(1_000_000e6, 1_000_000e6);

        vm.startPrank(relayer);
        vm.expectRevert("UniswapV3Lib/nothing-to-withdraw");
        mainnetController.removeLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            tokenId,
            0,
            0,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_removeLiquidityUniswapV3_minAmountNotMet_dueToStrictSlippage() public {
        (uint256 tokenId, uint128 liquidity,,) = _mintPosition(1_000_000e6, 1_000_000e6);

        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(UNISWAP_V3_POOL, 1.01e18);

        vm.startPrank(relayer);
        vm.expectRevert("MainnetController/min-amount-not-met");
        mainnetController.removeLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            tokenId,
            liquidity,
            0,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }
}

contract MainnetControllerRemoveLiquidityUniswapV3SuccessTests is UniswapV3TestBase {

    uint256 internal constant RATE_LIMIT_TOLERANCE = 2_000_000_000_000;  // accounts for rounding in 6-decimal tokens

    function _mintPosition(uint256 amount0Desired, uint256 amount1Desired)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        _fundProxy(amount0Desired, amount1Desired);
        return _addLiquidity(amount0Desired, amount1Desired);
    }

    function test_removeLiquidityUniswapV3_balancedAmounts() public {
        uint256 amount0Desired = 1_000_000e6;
        uint256 amount1Desired = 1_000_000e6;

        uint256 poolBalance0Initial = token0.balanceOf(UNISWAP_V3_POOL);
        uint256 poolBalance1Initial = token1.balanceOf(UNISWAP_V3_POOL);

        (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
            = _mintPosition(amount0Desired, amount1Desired);

        uint256 priceX192 = _getCurrentPriceX192();

        uint256 removeLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3RemoveLiquidityKey);

        uint256 proxyBalance0Before = token0.balanceOf(address(almProxy));
        uint256 proxyBalance1Before = token1.balanceOf(address(almProxy));

        (uint256 amount0Collected, uint256 amount1Collected) = _removeLiquidity(tokenId, liquidity, 0, 0);

        uint256 removeLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3RemoveLiquidityKey);

        assertGt(amount0Collected, 0, "expected token0 to be collected");
        assertGt(amount1Collected, 0, "expected token1 to be collected");
        assertApproxEqAbs(amount0Collected, amount0Used, 1, "collected token0 should match deposited amount");
        assertApproxEqAbs(amount1Collected, amount1Used, 1, "collected token1 should match deposited amount");

        uint256 normalizedMintedValue = _scaleTo1e18(
            _valueInToken0(priceX192, amount0Used, amount1Used),
            token0Decimals
        );

        assertApproxEqAbs(
            removeLimitBefore - removeLimitAfter,
            normalizedMintedValue,
            RATE_LIMIT_TOLERANCE,
            "withdraw limit should decrease by normalized minted value"
        );

        assertEq(
            token0.balanceOf(address(almProxy)),
            proxyBalance0Before + amount0Collected,
            "proxy should receive collected token0"
        );
        assertEq(
            token1.balanceOf(address(almProxy)),
            proxyBalance1Before + amount1Collected,
            "proxy should receive collected token1"
        );

        assertApproxEqAbs(
            token0.balanceOf(UNISWAP_V3_POOL),
            poolBalance0Initial,
            1,
            "pool token0 balance should revert to initial level"
        );
        assertApproxEqAbs(
            token1.balanceOf(UNISWAP_V3_POOL),
            poolBalance1Initial,
            1,
            "pool token1 balance should revert to initial level"
        );
        assertEq(_getPositionLiquidity(tokenId), 0, "position liquidity should be zero after full withdrawal");
    }

    function test_removeLiquidityUniswapV3_partialLiquidity() public {
        uint256 amount0Desired = 1_000_000e6;
        uint256 amount1Desired = 1_000_000e6;

        (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
            = _mintPosition(amount0Desired, amount1Desired);

        uint128 partialLiquidity = liquidity / 2;
        assertGt(partialLiquidity, 0, "partial liquidity should be non-zero");

        uint256 priceX192 = _getCurrentPriceX192();
        uint256 normalizedFullValue = _scaleTo1e18(
            _valueInToken0(priceX192, amount0Used, amount1Used),
            token0Decimals
        );

        uint256 removeLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3RemoveLiquidityKey);

        (uint256 amount0Collected, uint256 amount1Collected) = _removeLiquidity(tokenId, partialLiquidity, 0, 0);

        uint256 removeLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3RemoveLiquidityKey);

        assertGt(amount0Collected, 0, "should collect token0");
        assertGt(amount1Collected, 0, "should collect token1");

        uint256 expectedDecrease = normalizedFullValue * uint256(partialLiquidity) / uint256(liquidity);

        assertApproxEqAbs(
            removeLimitBefore - removeLimitAfter,
            expectedDecrease,
            RATE_LIMIT_TOLERANCE,
            "withdraw limit decrease should scale with withdrawn liquidity"
        );

        assertApproxEqAbs(
            uint256(_getPositionLiquidity(tokenId)),
            uint256(liquidity) - uint256(partialLiquidity),
            1,
            "remaining liquidity should reflect partial withdrawal"
        );
    }

    function test_removeLiquidityUniswapV3_respectsMinAmounts() public {
        uint256 amount0Desired = 1_000_000e6;
        uint256 amount1Desired = 1_000_000e6;

        (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
            = _mintPosition(amount0Desired, amount1Desired);

        uint256 amount0Min = amount0Used > 0 ? amount0Used - 1 : 0;
        uint256 amount1Min = amount1Used > 0 ? amount1Used - 1 : 0;

        (uint256 amount0Collected, uint256 amount1Collected) = _removeLiquidity(
            tokenId,
            liquidity,
            amount0Min,
            amount1Min
        );

        assertGe(amount0Collected, amount0Min, "collected token0 should satisfy minimum");
        assertGe(amount1Collected, amount1Min, "collected token1 should satisfy minimum");
    }

    function test_removeLiquidityUniswapV3_singleSidedToken0Range() public {
        uint256 amount0Desired = 1_500_000e6;
        uint256 amount1Desired = 0;

        _fundProxy(amount0Desired, amount1Desired);

        int24 currentTick = _getCurrentTick();
        int24 tickLower = currentTick + 10;
        int24 tickUpper = tickLower + 1200;

        (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
            = _addLiquidity(
                tickLower,
                tickUpper,
                amount0Desired,
                amount1Desired,
                0,
                0
            );

        uint256 priceX192 = _getCurrentPriceX192();

        uint256 removeLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3RemoveLiquidityKey);

        uint256 proxyBalance0Before = token0.balanceOf(address(almProxy));
        uint256 proxyBalance1Before = token1.balanceOf(address(almProxy));

        (uint256 amount0Collected, uint256 amount1Collected) = _removeLiquidity(tokenId, liquidity, 0, 0);

        uint256 removeLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3RemoveLiquidityKey);

        assertGt(amount0Collected, 0, "should collect token0 from single-sided range");
        assertEq(amount1Collected, 0, "no token1 should be collected from single-sided range");

        uint256 normalizedMintedValue = _scaleTo1e18(
            _valueInToken0(priceX192, amount0Used, amount1Used),
            token0Decimals
        );

        assertApproxEqAbs(
            removeLimitBefore - removeLimitAfter,
            normalizedMintedValue,
            RATE_LIMIT_TOLERANCE,
            "withdraw limit should decrease by normalized minted value"
        );

        assertEq(
            token0.balanceOf(address(almProxy)),
            proxyBalance0Before + amount0Collected,
            "proxy should receive collected token0"
        );
        assertEq(
            token1.balanceOf(address(almProxy)),
            proxyBalance1Before,
            "proxy should not receive token1"
        );

        assertEq(_getPositionLiquidity(tokenId), 0, "position should be fully exited");
    }
}


contract MainnetControllerE2EUniswapV3UsdcUsdtPoolTest is UniswapV3TestBase {

    function test_e2eSwapUniswapV3() public {

        uint256 swapAmount = 100_000e6;
        deal(address(usdc), address(almProxy), swapAmount);

        uint256 usdtBalanceBeforeSwap = usdt.balanceOf(address(almProxy));
        uint256 swapDeadline = block.timestamp + 1 hours;

        uint256 swapRateLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3SwapKey);

        vm.startPrank(relayer);
        uint256 amountOut = mainnetController.swapUniswapV3(
            UNISWAP_V3_POOL,
            address(usdc),
            swapAmount,
            99_000e6,
            swapDeadline
        );
        vm.stopPrank();

        assertGt(amountOut, 0, "amountOut should be greater than 0");
        assertApproxEqAbsDecimal(amountOut, swapAmount, .005e18, 6, "amountOut should be equal to swapAmount");
        assertEq(usdc.balanceOf(address(almProxy)), 0, "usdc balance of almProxy should be 0");
        assertEq(usdt.balanceOf(address(almProxy)), usdtBalanceBeforeSwap + amountOut, "usdt balance of almProxy should be equal to usdtBalanceBeforeSwap + amountOut");
        assertLt(rateLimits.getCurrentRateLimit(uniswapV3SwapKey), swapRateLimitBefore, "swap rate limit should be less than swapRateLimitBefore");
    }
    
    function test_e2e_addRemoveLiquidityUniswapV3() public {
        uint256 addAmount0 = 1_000_000e6;
        uint256 addAmount1 = 1_000_000e6;

        deal(address(usdc), address(almProxy), addAmount0);
        deal(address(usdt), address(almProxy), addAmount1);

        assertEq(usdc.balanceOf(address(almProxy)), addAmount0, "usdc balance of almProxy should be equal to addAmount0");
        assertEq(usdt.balanceOf(address(almProxy)), addAmount1, "usdt balance of almProxy should be equal to addAmount1");

        uint256 addDeadline = block.timestamp + 1 hours;

        uint256 addRateLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3AddLiquidityKey);

        uint256 poolUsdcBalanceBefore = IERC20(usdc).balanceOf(UNISWAP_V3_POOL);
        uint256 poolUsdtBalanceBefore = IERC20(usdt).balanceOf(UNISWAP_V3_POOL);

        vm.startPrank(relayer);
        (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
            = mainnetController.addLiquidityUniswapV3(
                UNISWAP_V3_POOL,
                -600,
                600,
                addAmount0,
                addAmount1,
                0,
                0,
                addDeadline
            );
        vm.stopPrank();

        uint256 poolUsdcBalanceAfterAdd = IERC20(usdc).balanceOf(UNISWAP_V3_POOL);
        uint256 poolUsdtBalanceAfterAdd = IERC20(usdt).balanceOf(UNISWAP_V3_POOL);

        assertGt(liquidity, 0, "liquidity should be greater than 0");
        assertGt(amount0Used, 0, "amount0Used should be greater than 0");
        assertGt(amount1Used, 0, "amount1Used should be greater than 0");

        assertEq(poolUsdcBalanceBefore + amount0Used, poolUsdcBalanceAfterAdd, "poolUsdcBalanceAfterAdd should be equal to poolUsdcBalanceBefore + amount0Used");
        assertEq(poolUsdtBalanceBefore + amount1Used, poolUsdtBalanceAfterAdd, "poolUsdtBalanceAfterAdd should be equal to poolUsdtBalanceBefore + amount1Used");

        uint256 addRateLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3AddLiquidityKey);
        assertLt(addRateLimitAfter, addRateLimitBefore, "addLiquidity rate limit should be less than addRateLimitBefore");

        uint256 usdcBalanceBeforeRemove = usdc.balanceOf(address(almProxy));
        uint256 usdtBalanceBeforeRemove = usdt.balanceOf(address(almProxy));
        uint256 removeRateLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3RemoveLiquidityKey);

        vm.startPrank(relayer);
        (uint256 amount0Collected, uint256 amount1Collected) = mainnetController.removeLiquidityUniswapV3(
            UNISWAP_V3_POOL,
            tokenId,
            liquidity,
            0,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        uint256 poolUsdcBalanceAfterRemove = IERC20(usdc).balanceOf(UNISWAP_V3_POOL);
        uint256 poolUsdtBalanceAfterRemove = IERC20(usdt).balanceOf(UNISWAP_V3_POOL);

        assertGt(amount0Collected, 0, "amount0Collected should be greater than 0");
        assertGt(amount1Collected, 0, "amount1Collected should be greater than 0");

        assertApproxEqAbs(amount0Collected, amount0Used, 1, "amount0Collected should roughly equal amount0Used");
        assertApproxEqAbs(amount1Collected, amount1Used, 1, "amount1Collected should roughly equal amount1Used");

        assertApproxEqAbs(poolUsdcBalanceAfterRemove, poolUsdcBalanceBefore, 1, "poolUsdcBalanceAfterRemove should return to the initial balance");
        assertApproxEqAbs(poolUsdtBalanceAfterRemove, poolUsdtBalanceBefore, 1, "poolUsdtBalanceAfterRemove should return to the initial balance");

        uint256 removeRateLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3RemoveLiquidityKey);
        assertLt(removeRateLimitAfter, removeRateLimitBefore, "removeLiquidity rate limit should be less than removeRateLimitBefore");

        assertEq(usdc.balanceOf(address(almProxy)), usdcBalanceBeforeRemove + amount0Collected, "usdc balance of almProxy should be equal to usdcBalanceBeforeRemove + amount0Collected");
        assertEq(usdt.balanceOf(address(almProxy)), usdtBalanceBeforeRemove + amount1Collected, "usdt balance of almProxy should be equal to usdtBalanceBeforeRemove + amount1Collected");
    }

}
