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

    address internal ausdUsdsPool;
    address internal usdsUsdcPool;

    IERC20 internal ausdBase;

    bytes32 uniswapV3_UsdsUsdcPool_UsdsSwapKey;
    bytes32 uniswapV3_UsdsUsdcPool_UsdcSwapKey;
    bytes32 uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey;
    bytes32 uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey;

    bytes32 uniswapV3_AusdUsdsPool_AusdSwapKey;
    bytes32 uniswapV3_AusdUsdsPool_UsdsSwapKey;
    bytes32 uniswapV3_AusdUsdsPool_AusdAddLiquidityKey;
    bytes32 uniswapV3_AusdUsdsPool_UsdsAddLiquidityKey;

    IERC20 internal token0;
    IERC20 internal token1;
    address internal pool;
    uint24 internal poolFee;
    uint8  internal token0Decimals;
    int24 internal initTick;

    function setUp() public virtual override  {
        super.setUp();

        ausdBase  = IERC20(address(new ERC20Mock()));

        ausdUsdsPool = _createPool(address(ausdBase), address(usdsBase), 100);
        usdsUsdcPool = _createPool(address(usdsBase), address(usdcBase), 100);

        vm.warp(block.timestamp + 2 hours); // Advance sufficient time for twap

        uniswapV3_UsdsUsdcPool_UsdsSwapKey          = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_SWAP(),    address(usdsBase), usdsUsdcPool);
        uniswapV3_UsdsUsdcPool_UsdcSwapKey         = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_SWAP(),     address(usdcBase), usdsUsdcPool);
        uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey  = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_DEPOSIT(), address(usdsBase), usdsUsdcPool);
        uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_DEPOSIT(),  address(usdcBase), usdsUsdcPool);

        uniswapV3_AusdUsdsPool_AusdSwapKey          = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_SWAP(),    address(ausdBase), ausdUsdsPool);
        uniswapV3_AusdUsdsPool_UsdsSwapKey         = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_SWAP(),     address(usdsBase), ausdUsdsPool);
        uniswapV3_AusdUsdsPool_AusdAddLiquidityKey  = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_DEPOSIT(), address(ausdBase), ausdUsdsPool);
        uniswapV3_AusdUsdsPool_UsdsAddLiquidityKey = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_DEPOSIT(),  address(usdsBase), ausdUsdsPool);

        vm.startPrank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(uniswapV3_UsdsUsdcPool_UsdsSwapKey,   1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3_UsdsUsdcPool_UsdcSwapKey,  1_000_000e18, uint256(1_000_000e18) / 1 days);

        rateLimits.setRateLimitData(uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey,   1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey,  1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3_AusdUsdsPool_AusdAddLiquidityKey,   1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3_AusdUsdsPool_UsdsAddLiquidityKey,  1_000_000e18, uint256(1_000_000e18) / 1 days);

        foreignController.setMaxSlippage(_getPool(), 0.98e18);
        foreignController.setUniswapV3SwapTwapSecondsAgo(_getPool(), 1 hours);
        foreignController.setUniswapV3PositionManager(UNISWAP_V3_POSITION_MANAGER);
        vm.stopPrank();

        
        token0         = IERC20(IUniswapV3PoolLike(_getPool()).token0());
        token1         = IERC20(IUniswapV3PoolLike(_getPool()).token1());        
        poolFee        = IUniswapV3PoolLike(_getPool()).fee();
        token0Decimals = IERC20Metadata(address(token0)).decimals();
        initTick       = TickMath.getTickAtSqrtRatio(_getInitialSqrtPriceX96(address(token0), address(token1)));

        vm.startPrank(GROVE_EXECUTOR);
        foreignController.setUniswapV3AddLiquidityLowerTickBound(_getPool(), initTick-1000);
        foreignController.setUniswapV3AddLiquidityUpperTickBound(_getPool(), initTick+1000);
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
        return usdsUsdcPool;
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

    function _minLiquidityPosition(uint256 amount0, uint256 amount1) internal pure returns (UniswapV3Lib.LiquidityPosition memory) {
        return UniswapV3Lib.LiquidityPosition({
            amount0 : amount0 * 98 / 100,
            amount1 : amount1 * 98 / 100
        });
    }

    function _addLiquidityAndValidate(
        uint256 currentTokenId,
        UniswapV3Lib.Tick memory tick,
        uint256 amount0,
        uint256 amount1,
        bytes32 token0RateLimitKey,
        bytes32 token1RateLimitKey
    )
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        uint256 token0RateLimitBefore = rateLimits.getCurrentRateLimit(token0RateLimitKey);
        uint256 token1RateLimitBefore = rateLimits.getCurrentRateLimit(token1RateLimitKey);

        (tokenId, liquidity, amount0Used, amount1Used) = _addLiquidity(
            currentTokenId,
            tick,
            UniswapV3Lib.LiquidityPosition({ amount0: amount0, amount1: amount1 }),
            _minLiquidityPosition(amount0, amount1)
        );

        uint256 token0RateLimitAfter = rateLimits.getCurrentRateLimit(token0RateLimitKey);
        uint256 token1RateLimitAfter = rateLimits.getCurrentRateLimit(token1RateLimitKey);

        assertEq(token0RateLimitBefore - token0RateLimitAfter, _scaleTo1e18(amount0, token0.decimals()), "token0 rate limit delta mismatch");
        assertEq(token1RateLimitBefore - token1RateLimitAfter, _scaleTo1e18(amount1, token1.decimals()), "token1 rate limit delta mismatch");
    }

    function _e2e_addLiquidityUniswapV3_equalParts(uint256 addAmount, bytes32 token0RateLimitKey, bytes32 token1RateLimitKey) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        uint256 amount0 = addAmount;
        uint256 amount1 = addAmount * 10**token1.decimals() / 10**token0.decimals();

        deal(address(token0), address(almProxy), amount0);
        deal(address(token1), address(almProxy), amount1);

        UniswapV3Lib.Tick memory tick = UniswapV3Lib.Tick({
            lower : initTick - 100,
            upper : initTick + 100
        });

        (tokenId, liquidity, amount0Used, amount1Used) = _addLiquidityAndValidate(
            0,
            tick,
            amount0,
            amount1,
            token0RateLimitKey,
            token1RateLimitKey
        );

        assertGt(liquidity, 0, "liquidity should be greater than 0");

        assertApproxEqRel(amount0, amount0Used, .05e18, "amount0Used should be within 5% of amount0");
        assertEq(amount1, amount1Used, "amount1Used should be within .05% of amount1");

        vm.warp(block.timestamp + 2 hours); // Advance sufficient time for twap

        amount0 *= 2;
        amount1 *= 2;

        deal(address(token0), address(almProxy), amount0);
        deal(address(token1), address(almProxy), amount1);

        (/* uint256 tokenId */, liquidity, amount0Used, amount1Used) = _addLiquidityAndValidate(
            tokenId,
            tick,
            amount0,
            amount1,
            token0RateLimitKey,
            token1RateLimitKey
        );

        assertGt(liquidity, 0, "liquidity should be greater than 0");

        assertApproxEqRel(amount0, amount0Used, .05e18, "amount0Used should be within 5% of amount0");
        assertEq(amount1, amount1Used, "amount1Used should be within .05% of amount1");
    }
}

contract MainnetControllerE2EUniswapV3UsdsUsdcTest is MainnetControllerE2EUniswapV3Test {
    function test_e2e_addLiquidityUniswapV3_equalParts(uint256 addAmount) public {
        addAmount = bound(addAmount, 1e18, 300_000e18);

        _e2e_addLiquidityUniswapV3_equalParts(addAmount, uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey, uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey);
    }

    function test_e2e_addLiquidityUniswapV3_skewToken0(uint256 addAmount0, uint256 addAmount1) public {
        
    }
}

contract MainnetControllerE2EUniswapV3AusdUsdsTest is MainnetControllerE2EUniswapV3Test {
    function _getPool() internal view override returns (address) {
        return ausdUsdsPool;
    }
    
    function test_e2e_addLiquidityUniswapV3_equalParts(uint256 addAmount) public {
        addAmount = bound(addAmount, 1e18, 300_000e18);

        _e2e_addLiquidityUniswapV3_equalParts(addAmount, uniswapV3_AusdUsdsPool_AusdAddLiquidityKey, uniswapV3_AusdUsdsPool_UsdsAddLiquidityKey);
    }

    function test_e2e_addLiquidityUniswapV3_skewToken0(uint256 addAmount0, uint256 addAmount1) public {
        
    }
}
