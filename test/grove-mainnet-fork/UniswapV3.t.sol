// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import "./ForkTestBase.t.sol";
import { INonfungiblePositionManager } from "../../src/libraries/UniswapV3Lib.sol";
import {console} from "forge-std/console.sol";

contract UniswapV3TestBase is ForkTestBase {
    address constant UNISWAP_V3_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant UNISWAP_V3_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNISWAP_V3_POOL = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;

    bytes32 uniswapV3AddLiquidityKey;
    bytes32 uniswapV3SwapKey;
    bytes32 uniswapV3RemoveLiquidityKey;

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
    }

    function _getBlock() internal pure override returns (uint256) {
        return 22225000;  // April 8, 2025
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
