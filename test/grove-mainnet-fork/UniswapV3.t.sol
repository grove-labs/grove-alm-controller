// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import "./ForkTestBase.t.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IERC20Metadata } from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { INonfungiblePositionManager, IUniswapV3PoolLike } from "../../src/libraries/UniswapV3Lib.sol";
import { UniV3Utils } from "lib/dss-allocator/test/funnels/UniV3Utils.sol";
import { FullMath } from "lib/dss-allocator/src/funnels/uniV3/FullMath.sol";
import { UniswapV3Lib } from "../../src/libraries/UniswapV3Lib.sol";

contract UniswapV3TestBase is ForkTestBase {
    address constant UNISWAP_V3_ROUTER              = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant UNISWAP_V3_POSITION_MANAGER    = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNISWAP_V3_USDC_USDT_POOL      = 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6;
    address constant UNISWAP_V3_DAI_USDC_POOL       = 0x6c6Bc977E13Df9b0de53b251522280BB72383700; 

    int24 internal constant DEFAULT_TICK_LOWER      = -600;
    int24 internal constant DEFAULT_TICK_UPPER      = 600;

    bytes32 uniswapV3AddLiquidityKey;
    bytes32 uniswapV3_UsdcUsdtPool_UsdcSwapKey;
    bytes32 uniswapV3_UsdcUsdtPool_UsdtSwapKey;
    bytes32 uniswapV3RemoveLiquidityKey;

    bytes32 uniswapV3_DaiUsdcPool_DaiSwapKey;
    bytes32 uniswapV3_DaiUsdcPool_UsdcSwapKey;

    IERC20 internal token0;
    IERC20 internal token1;
    uint24 internal poolFee;
    uint8  internal token0Decimals;

    uint256 internal constant Q192 = 2 ** 192;

    function setUp() public virtual override  {
        super.setUp();

        uniswapV3_UsdcUsdtPool_UsdcSwapKey = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_UNISWAP_V3_SWAP(),     address(usdc), UNISWAP_V3_USDC_USDT_POOL);
        uniswapV3_UsdcUsdtPool_UsdtSwapKey = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_UNISWAP_V3_SWAP(),     address(usdt), UNISWAP_V3_USDC_USDT_POOL);

        uniswapV3_DaiUsdcPool_DaiSwapKey = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_UNISWAP_V3_SWAP(),     address(dai), UNISWAP_V3_DAI_USDC_POOL);
        uniswapV3_DaiUsdcPool_UsdcSwapKey = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_UNISWAP_V3_SWAP(),     address(usdc), UNISWAP_V3_DAI_USDC_POOL);

        uniswapV3AddLiquidityKey   = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_UNISWAP_V3_DEPOSIT(),  _getPool());
        uniswapV3RemoveLiquidityKey = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_UNISWAP_V3_WITHDRAW(), _getPool());

        vm.startPrank(GROVE_PROXY);
        rateLimits.setRateLimitData(uniswapV3_UsdcUsdtPool_UsdcSwapKey, 1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3_UsdcUsdtPool_UsdtSwapKey, 1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3_DaiUsdcPool_DaiSwapKey,   1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3_DaiUsdcPool_UsdcSwapKey,  1_000_000e18, uint256(1_000_000e18) / 1 days);

        vm.stopPrank();

        // Set a higher slippage to allow for successes
        vm.startPrank(GROVE_PROXY);
        mainnetController.setMaxSlippage(_getPool(), 0.98e18);
        // All trades must have no more than 200 ticks impact on the pool. For most stablecoin pools, a tick is 1bps
        mainnetController.setUniswapV3PoolParams(_getPool(), UniswapV3Lib.UniswapV3PoolParams({ swapMaxTickDelta: 200, swapTwapSecondsAgo: 1 hours }));
        mainnetController.setUniswapV3PositionManager(UNISWAP_V3_POSITION_MANAGER);
        mainnetController.setUniswapV3Router(UNISWAP_V3_ROUTER);
        vm.stopPrank();

        token0         = IERC20(IUniswapV3PoolLike(_getPool()).token0());
        token1         = IERC20(IUniswapV3PoolLike(_getPool()).token1());
        poolFee        = IUniswapV3PoolLike(_getPool()).fee();
        token0Decimals = IERC20Metadata(address(token0)).decimals();
    }

    
    function _getSwapKey(address tokenIn) internal view returns (bytes32) {
        return RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_UNISWAP_V3_SWAP(), tokenIn, _getPool());
    }
    
    function _label() internal {
        vm.label(UNISWAP_V3_ROUTER,            'UniswapV3Router');
        vm.label(UNISWAP_V3_POSITION_MANAGER,  'UniswapV3PositionManager');
        vm.label(UNISWAP_V3_USDC_USDT_POOL,    'USDC-USDT Pool');
        vm.label(UNISWAP_V3_DAI_USDC_POOL,     'DAI-USDC Pool');
    }

    function _getPool() internal pure virtual returns (address) {
        return UNISWAP_V3_USDC_USDT_POOL;
    }
    
    function _getBlock() internal pure override returns (uint256) {
        return 23677743;  // Oct 28, 2025
    }

    function _fundProxy(uint256 amount0Desired, uint256 amount1Desired) internal {
        deal(address(token0), address(almProxy), amount0Desired);
        deal(address(token1), address(almProxy), amount1Desired);
    }

    function _swap(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut
    )
        internal
        returns (uint256 amountOut)
    {
        vm.startPrank(relayer);
        amountOut = mainnetController.swapUniswapV3(
            _getPool(),
            tokenIn,
            amountIn,
            minAmountOut,
            200,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function _getCurrentPriceX192() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolLike(_getPool()).slot0();
        return _priceX192(sqrtPriceX96);
    }

    function _priceX192(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1);
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

contract MainnetControllerSwapUniswapV3FailureTests is UniswapV3TestBase {

    function test_swapUniswapV3_notRelayer() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        mainnetController.swapUniswapV3(
            _getPool(),
            address(token0),
            1,
            1,
            100,
            block.timestamp + 1 hours
        );
    }

    function test_swapUniswapV3_routerNotSet() public {
        uint256 amountIn = 100_000e6;
        _fundProxy(amountIn, 0);

        vm.prank(GROVE_PROXY);
        mainnetController.setUniswapV3Router(address(0));

        vm.startPrank(relayer);
        vm.expectRevert("MainnetController/router-not-set");
        mainnetController.swapUniswapV3(
            _getPool(),
            address(token0),
            amountIn,
            0,
            200,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_swapUniswapV3_maxSlippageNotSet() public {
        uint256 amountIn = 100_000e6;
        _fundProxy(amountIn, 0);

        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(_getPool(), 0);

        vm.startPrank(relayer);
        vm.expectRevert("UniswapV3Lib/max-slippage-not-set");
        mainnetController.swapUniswapV3(
            _getPool(),
            address(token0),
            amountIn,
            0,
            200,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_swapUniswapV3_invalidTokenIn() public {
        uint256 amountIn = 100_000e6;
        deal(address(dai), address(almProxy), amountIn);

        vm.startPrank(relayer);
        vm.expectRevert("UniswapV3Lib/invalid-token-pair");
        mainnetController.swapUniswapV3(
            _getPool(),
            address(dai),
            amountIn,
            0,
            200,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_swapUniswapV3_slippageTooHigh() public {
        uint256 amountIn = 150_000e6;
        _fundProxy(amountIn, 0);

        vm.startPrank(relayer);
        vm.expectRevert("Too little received");
        mainnetController.swapUniswapV3(
            _getPool(),
            address(token0),
            amountIn,
            amountIn * 9999/10000,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_swapUniswapV3_invalidMaxTickDelta() public {
        uint256 amountIn = 100_000e6;
        _fundProxy(amountIn, 0);

        vm.startPrank(relayer);
        vm.expectRevert("UniswapV3Lib/invalid-max-tick-delta");
        mainnetController.swapUniswapV3(
            _getPool(),
            address(token0),
            amountIn,
            0,
            type(uint24).max,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_swapUniswapV3_limitsAmountOutWhenCrossingMaxTick() public {
        uint256 amountIn = 2_000_000e6;
        _fundProxy(amountIn, 0);

        vm.startPrank(GROVE_PROXY);
        rateLimits.setRateLimitData(_getSwapKey(address(token0)), 2_000_000e18, uint256(2_000_000e18) / 1 days);
        vm.stopPrank();

        vm.startPrank(relayer);
        vm.expectRevert("Too little received");
        mainnetController.swapUniswapV3(
            _getPool(),
            address(token0),
            amountIn,
            amountIn * 999/1000,
            0, // amountOut will be capped to only liquidity that's within the current tick
            block.timestamp + 1 hours
        );

        vm.stopPrank();
    }

    function test_swapUniswapV3_minAmountNotMet() public {
        uint256 amountIn = 100_000e6;
        _fundProxy(amountIn, 0);

        vm.startPrank(relayer);
        vm.expectRevert("UniswapV3Lib/min-amount-not-met");
        mainnetController.swapUniswapV3(
            _getPool(),
            address(token0),
            amountIn,
            0,
            200,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }
}

contract MainnetControllerSwapUniswapV3SuccessTests is UniswapV3TestBase {

    function test_swapUniswapV3_token0ToToken1() public {
        uint256 amountIn = 250_000e6;
        _fundProxy(amountIn, 0);

        uint256 swapLimitBefore     = rateLimits.getCurrentRateLimit(_getSwapKey(address(token0)));
        uint256 token0BalanceBefore = token0.balanceOf(address(almProxy));
        uint256 token1BalanceBefore = token1.balanceOf(address(almProxy));

        uint256 amountOut = _swap(address(token0), amountIn, amountIn * 999/1000);

        uint256 swapLimitAfter  = rateLimits.getCurrentRateLimit(_getSwapKey(address(token0)));
        uint256 normalizedValue = _scaleTo1e18(amountIn, token0Decimals);

        assertApproxEqAbs(amountIn, amountOut, .0001e18, "swap output should be within 0.01% of amountIn");
        assertEq(
            token0.balanceOf(address(almProxy)),
            token0BalanceBefore - amountIn,
            "proxy should spend token0"
        );
        assertEq(
            token1.balanceOf(address(almProxy)),
            token1BalanceBefore + amountOut,
            "proxy should receive token1"
        );
        assertEq(
            swapLimitBefore - swapLimitAfter,
            normalizedValue,
            "swap rate limit should decrease by normalized token0 value"
        );
    }

    function test_swapUniswapV3_token1ToToken0() public {
        uint256 amountIn = 300_000e6;
        _fundProxy(0, amountIn);

        uint256 swapLimitBefore     = rateLimits.getCurrentRateLimit(_getSwapKey(address(token1)));
        uint256 token0BalanceBefore = token0.balanceOf(address(almProxy));
        uint256 token1BalanceBefore = token1.balanceOf(address(almProxy));

        uint256 amountOut = _swap(address(token1), amountIn, amountIn * 999/1000);

        uint256 swapLimitAfter = rateLimits.getCurrentRateLimit(_getSwapKey(address(token1)));

        assertApproxEqAbs(amountIn, amountOut, .0001e18, "swap output should be within 0.01% of amountIn");
        assertEq(
            token1.balanceOf(address(almProxy)),
            token1BalanceBefore - amountIn,
            "proxy should spend token1"
        );
        assertEq(
            token0.balanceOf(address(almProxy)),
            token0BalanceBefore + amountOut,
            "proxy should receive token0"
        );
        assertEq(
            swapLimitBefore - swapLimitAfter,
            _scaleTo1e18(amountIn, token1.decimals()),
            "swap rate limit should decrease by normalized value"
        );
    }
}


contract MainnetControllerE2EUniswapV3Test is UniswapV3TestBase {
    function _e2e_swapUniswapV3(uint256 swapAmount, IERC20 tokenIn, IERC20 tokenOut, bytes32 swapKey) internal {
        deal(address(tokenIn), address(almProxy), swapAmount);

        uint8 tokenInDecimals  = IERC20Metadata(address(tokenIn)).decimals();
        uint8 tokenOutDecimals = IERC20Metadata(address(tokenOut)).decimals();

        uint256 swapAmountOut = FullMath.mulDiv(swapAmount, 10**tokenOutDecimals, 10**tokenInDecimals);

        uint256 tokenOutBalanceBeforeSwap = tokenOut.balanceOf(address(almProxy));
        uint256 swapDeadline              = block.timestamp + 1 hours;

        uint256 swapRateLimitBefore = rateLimits.getCurrentRateLimit(swapKey);

        vm.startPrank(relayer);
        uint256 amountOut = mainnetController.swapUniswapV3(
            _getPool(),
            address(tokenIn),
            swapAmount,
            swapAmountOut * 999 / 1000,
            200, // allow for price impact of up to 2 points
            swapDeadline
        );
        vm.stopPrank();

        uint256 normalizedAmountOut = FullMath.mulDiv(amountOut, 10**tokenInDecimals, 10**tokenOutDecimals);

        assertApproxEqRel(normalizedAmountOut, swapAmount, .005e18, "normalizedAmountOut should be within 0.05% of swapAmount");
        assertEq(tokenIn.balanceOf(address(almProxy)), 0, "tokenIn balance of almProxy should be 0");
        assertEq(tokenOut.balanceOf(address(almProxy)), tokenOutBalanceBeforeSwap + amountOut, "tokenOut balance of almProxy should be equal to tokenOutBalanceBeforeSwap + amountOut");
        assertEq(rateLimits.getCurrentRateLimit(swapKey), swapRateLimitBefore - _scaleTo1e18(swapAmount, tokenIn.decimals()), "swap rate limit should be equal to swapRateLimitBefore - swapAmount");
    }
}

contract MainnetControllerE2EUniswapV3DaiUsdcTest is MainnetControllerE2EUniswapV3Test {
    function _getPool() internal pure override returns (address) {
        return UNISWAP_V3_DAI_USDC_POOL;
    }

    function test_e2e_swapUniswapV3_daiToUsdc(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 1e18, 1_000_000e18);

        _e2e_swapUniswapV3(swapAmount, dai, usdc, _getSwapKey(address(dai)));
    }

    function test_e2e_swapUniswapV3_daiToUsdc_large(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 1_000_000e18, 2_000_000e18);

        vm.startPrank(GROVE_PROXY);
        rateLimits.setRateLimitData(_getSwapKey(address(dai)), 2_000_000e18, uint256(2_000_000e18) / 1 days);
        vm.stopPrank();

        _e2e_swapUniswapV3(swapAmount, dai, usdc, _getSwapKey(address(dai)));
    }


    function test_e2e_swapUniswapV3_usdcToDai(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 1e6, 1_000_000e6);

        _e2e_swapUniswapV3(swapAmount, usdc, dai, _getSwapKey(address(usdc)));
    }

    function test_e2e_swapUniswapV3_usdcToDai_large(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 1_000_000e6, 2_000_000e6);

        vm.startPrank(GROVE_PROXY);
        rateLimits.setRateLimitData(_getSwapKey(address(usdc)), 2_000_000e18, uint256(2_000_000e18) / 1 days);
        vm.stopPrank();

        _e2e_swapUniswapV3(swapAmount, usdc, dai, _getSwapKey(address(usdc)));
    }
}

contract MainnetControllerE2EUniswapV3UsdcUsdtPoolTest is MainnetControllerE2EUniswapV3Test {
    function _getPool() internal pure override returns (address) {
        return UNISWAP_V3_USDC_USDT_POOL;
    }

    function test_e2e_swapUniswapV3_usdcToUsdt(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 1e6, 1_000_000e6);

        _e2e_swapUniswapV3(swapAmount, usdc, usdt, _getSwapKey(address(usdc)));
    }

    function test_e2e_swapUniswapV3_usdcToUsdt_large(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 1_000_000e6, 5_000_000e6);

        vm.startPrank(GROVE_PROXY);
        rateLimits.setRateLimitData(_getSwapKey(address(usdc)), 5_000_000e18, uint256(5_000_000e18) / 1 days);
        vm.stopPrank();

        _e2e_swapUniswapV3(swapAmount, usdc, usdt, _getSwapKey(address(usdc)));
    }

    function test_e2e_swapUniswapV3_usdtToUsdc(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 1e6, 1_000_000e6);

        _e2e_swapUniswapV3(swapAmount, usdt, usdc, _getSwapKey(address(usdt)));
    }

    function test_e2e_swapUniswapV3_usdtToUsdc_large(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 1_000_000e6, 5_000_000e6);

        vm.startPrank(GROVE_PROXY);
        rateLimits.setRateLimitData(_getSwapKey(address(usdt)), 5_000_000e18, uint256(5_000_000e18) / 1 days);
        vm.stopPrank();

        _e2e_swapUniswapV3(swapAmount, usdt, usdc, _getSwapKey(address(usdt)));
    }
}
