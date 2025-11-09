// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import "./ForkTestBase.t.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IERC20Metadata } from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { INonfungiblePositionManager, IUniswapV3PoolLike } from "../../src/libraries/UniswapV3Lib.sol";
import { IUniswapV3Factory } from "../../src/interfaces/UniswapV3Interfaces.sol";
import { UniV3Utils } from "lib/dss-allocator/test/funnels/UniV3Utils.sol";
import { FullMath } from "lib/dss-allocator/src/funnels/uniV3/FullMath.sol";
import { UniswapV3Lib } from "../../src/libraries/UniswapV3Lib.sol";
import { TickMath } from "lib/dss-allocator/src/funnels/uniV3/TickMath.sol";
import { console } from "forge-std/console.sol";

contract UniswapV3TestBase is ForkTestBase {
    address constant UNISWAP_V3_ROUTER              = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant UNISWAP_V3_POSITION_MANAGER    = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1; 
    address constant UNISWAP_V3_FACTORY             = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

    int24 internal constant DEFAULT_TICK_LOWER      = -600;
    int24 internal constant DEFAULT_TICK_UPPER      = 600;

    bytes32 uniswapV3_UsdcUsdtPool_UsdcSwapKey;
    bytes32 uniswapV3_UsdcUsdtPool_UsdtSwapKey;
    bytes32 uniswapV3_UsdcUsdtPool_UsdcAddLiquidityKey;
    bytes32 uniswapV3_UsdcUsdtPool_UsdtAddLiquidityKey;
    

    bytes32 uniswapV3_UsdsUsdcPool_UsdsSwapKey;
    bytes32 uniswapV3_UsdsUsdcPool_UsdcSwapKey;
    bytes32 uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey;
    bytes32 uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey;

    IERC20 internal token0;
    IERC20 internal token1;
    address internal pool;
    uint24 internal poolFee;
    uint8  internal token0Decimals;
    int24 internal initTick;

    function setUp() public virtual override  {
        super.setUp();

        pool = _createPool(address(usdsBase), address(usdcBase), 100);
        vm.warp(block.timestamp + 2 hours); // Advance sufficient time for twap
        
        token0         = IERC20(IUniswapV3PoolLike(_getPool()).token0());
        token1         = IERC20(IUniswapV3PoolLike(_getPool()).token1());        
        poolFee        = IUniswapV3PoolLike(_getPool()).fee();
        token0Decimals = IERC20Metadata(address(token0)).decimals();
        initTick       = TickMath.getTickAtSqrtRatio(_getInitialSqrtPriceX96(address(token0), address(token1)));

        uniswapV3_UsdsUsdcPool_UsdsSwapKey          = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_SWAP(),     address(usdsBase),  pool);
        uniswapV3_UsdsUsdcPool_UsdcSwapKey         = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_SWAP(),     address(usdcBase), pool);
        uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey  = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_DEPOSIT(),  address(usdsBase),  pool);
        uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_DEPOSIT(),  address(usdcBase), pool);


        vm.startPrank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(uniswapV3_UsdsUsdcPool_UsdsSwapKey,   1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3_UsdsUsdcPool_UsdcSwapKey,  1_000_000e18, uint256(1_000_000e18) / 1 days);

        rateLimits.setRateLimitData(uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey,   1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey,  1_000_000e18, uint256(1_000_000e18) / 1 days);

        // Set a higher slippage to allow for successes
        foreignController.setMaxSlippage(_getPool(), 0.98e18);
        foreignController.setUniswapV3SwapTwapSecondsAgo(_getPool(), 1 hours);
        
        foreignController.setUniswapV3AddLiquidityLowerTickBound(_getPool(), initTick-1000);
        foreignController.setUniswapV3AddLiquidityUpperTickBound(_getPool(), initTick+1000);
        
        foreignController.setUniswapV3PositionManager(UNISWAP_V3_POSITION_MANAGER);
        vm.stopPrank();

        _label();
    }

    function _getInitialSqrtPriceX96(address _token0, address _token1) internal view returns (uint160) {
        uint8 decimals0 = IERC20Metadata(_token0).decimals();
        uint8 decimals1 = IERC20Metadata(_token1).decimals();

        // rawPrice = 10^(dec1 - dec0)
        int256 exp = int256(uint256(decimals1)) - int256(uint256(decimals0));

        if (exp >= 0) {
            return uint160((uint256(1) << 96) * 10 ** uint256(exp / 2));
        } else {
            return uint160((uint256(1) << 96) / 10 ** uint256(-exp / 2));
        }
    }

    function _createPool(
        address _token0, 
        address _token1, 
        uint24 _fee
    ) internal returns (address poolAddress) {
        IUniswapV3Factory factory = IUniswapV3Factory(UNISWAP_V3_FACTORY);
        poolAddress = factory.createPool(_token0, _token1, _fee);

        uint160 sqrtPriceX96 = _getInitialSqrtPriceX96(_token0, _token1);
        IUniswapV3PoolLike(poolAddress).initialize(sqrtPriceX96);
    }

    
    function _getSwapKey(address tokenIn) internal view returns (bytes32) {
        return RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_SWAP(), tokenIn, _getPool());
    }
    
    function _label() internal {
        vm.label(UNISWAP_V3_ROUTER,            'UniswapV3Router');
        vm.label(UNISWAP_V3_POSITION_MANAGER,  'UniswapV3PositionManager');
        vm.label(pool,                         'USDS-USDC Pool');
    }

    function _getPool() internal view virtual returns (address) {
        return pool;
    }
    
    function _getBlock() internal pure override returns (uint256) {
        return 23677743;  // Oct 28, 2025
    }

    function _fundProxy(uint256 amount0Desired, uint256 amount1Desired) internal {
        deal(address(token0), address(almProxy), amount0Desired);
        deal(address(token1), address(almProxy), amount1Desired);
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


contract MainnetControllerE2EUniswapV3Test is UniswapV3TestBase {
    function _addLiquidity(uint256 _tokenId, UniswapV3Lib.Tick memory _tick, UniswapV3Lib.LiquidityPosition memory _desired, UniswapV3Lib.LiquidityPosition memory _min) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        vm.startPrank(ALM_RELAYER);
        (tokenId, liquidity, amount0Used, amount1Used)
            = foreignController.addLiquidityUniswapV3(
                _getPool(),
                _tokenId,
                _tick,
                _desired,
                _min,
                block.timestamp + 1 hours
            );
        vm.stopPrank();
    }
    
    function test_e2e_addLiquidityUniswapV3() public {
        uint256 addAmount0 = 100_000e18;
        uint256 addAmount1 = 100_000e6;

        deal(address(usdsBase), address(almProxy), addAmount0);
        deal(address(usdcBase), address(almProxy), addAmount1);

        assertEq(usdsBase.balanceOf(address(almProxy)), addAmount0, "usds balance of almProxy should be equal to addAmount0");
        assertEq(usdcBase.balanceOf(address(almProxy)), addAmount1, "usdc balance of almProxy should be equal to addAmount1");

        uint256 addUsdsRateLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey);
        uint256 addUsdcRateLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey);

        UniswapV3Lib.Tick memory tick = UniswapV3Lib.Tick({
            lower : initTick - 100,
            upper : initTick + 100
        });

        UniswapV3Lib.LiquidityPosition memory desired = UniswapV3Lib.LiquidityPosition({
            amount0 : addAmount0,
            amount1 : addAmount1
        });

        UniswapV3Lib.LiquidityPosition memory min = UniswapV3Lib.LiquidityPosition({
            amount0 : addAmount0 * 98 / 100,
            amount1 : addAmount1 * 98 / 100
        });

        (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) = _addLiquidity(
            0, 
            tick,
            desired,
            min
        );

        assertGt(liquidity, 0, "liquidity should be greater than 0");

        assertApproxEqRel(addAmount0, amount0Used, .05e18, "amount0Used should be within 5% of addAmount0");
        assertEq(addAmount1, amount1Used, "amount1Used should be within .05% of addAmount1");

        uint256 addUsdsRateLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey);
        uint256 addUsdcRateLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey);
        assertEq(addUsdsRateLimitBefore - addUsdsRateLimitAfter, _scaleTo1e18(addAmount0, usdsBase.decimals()), "addUsdsLiquidity rate limit should be less than addUsdsRateLimitBefore");
        assertEq(addUsdcRateLimitBefore - addUsdcRateLimitAfter, _scaleTo1e18(addAmount1, usdcBase.decimals()), "addUsdcLiquidity rate limit should be less than addUsdcRateLimitBefore");

        vm.warp(block.timestamp + 2 hours); // Advance sufficient time for twap

        addAmount0 = 200_000e18;
        addAmount1 = 200_000e6;

        desired = UniswapV3Lib.LiquidityPosition({
            amount0 : addAmount0,
            amount1 : addAmount1
        });

        min = UniswapV3Lib.LiquidityPosition({
            amount0 : addAmount0 * 98 / 100,
            amount1 : addAmount1 * 98 / 100
        });

        deal(address(usdsBase), address(almProxy), addAmount0);
        deal(address(usdcBase), address(almProxy), addAmount1);

        assertEq(usdsBase.balanceOf(address(almProxy)), addAmount0, "usds balance of almProxy should be equal to addAmount0");
        assertEq(usdcBase.balanceOf(address(almProxy)), addAmount1, "usdc balance of almProxy should be equal to addAmount1");

        addUsdsRateLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey);
        addUsdcRateLimitBefore = rateLimits.getCurrentRateLimit(uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey);

        (/*uint256 tokenId*/, liquidity, amount0Used, amount1Used)
            = _addLiquidity(
                tokenId,
                tick,
                desired,
                min
            );

        assertGt(liquidity, 0, "liquidity should be greater than 0");

        assertApproxEqRel(addAmount0, amount0Used, .05e18, "amount0Used should be within 5% of addAmount0");
        assertEq(addAmount1, amount1Used, "amount1Used should be within .05% of addAmount1");

        addUsdsRateLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey);
        addUsdcRateLimitAfter = rateLimits.getCurrentRateLimit(uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey);
        assertEq(addUsdsRateLimitBefore - addUsdsRateLimitAfter, _scaleTo1e18(addAmount0, usdsBase.decimals()), "addUsdsLiquidity rate limit should be less than addUsdsRateLimitBefore");
        assertEq(addUsdcRateLimitBefore - addUsdcRateLimitAfter, _scaleTo1e18(addAmount1, usdcBase.decimals()), "addUsdcLiquidity rate limit should be less than addUsdcRateLimitBefore");
    }
}
