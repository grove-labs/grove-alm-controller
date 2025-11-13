// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { console }                from "forge-std/console.sol";
import { IERC20 }                 from "forge-std/interfaces/IERC20.sol";
import { stdStorage, StdStorage } from "forge-std/StdStorage.sol";

import { IERC20Metadata } from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { UniV3Utils } from "lib/dss-allocator/test/funnels/UniV3Utils.sol";
import { FullMath }   from "lib/dss-allocator/src/funnels/uniV3/FullMath.sol";
import { TickMath }   from "lib/dss-allocator/src/funnels/uniV3/TickMath.sol";

import { INonfungiblePositionManager, IUniswapV3PoolLike, UniswapV3Lib } from "../../src/libraries/UniswapV3Lib.sol";

import "./ForkTestBase.t.sol";

/// @title An interface for a contract that is capable of deploying Uniswap V3 Pools
/// @notice A contract that constructs a pool must implement this to pass arguments to the pool
/// @dev This is used to avoid having constructor arguments in the pool contract, which results in the init code hash
/// of the pool being constant allowing the CREATE2 address of the pool to be cheaply computed on-chain
interface IUniswapV3Factory {
    /// @notice Creates a pool for the given two tokens and fee
    /// @param tokenA One of the two tokens in the desired pool
    /// @param tokenB The other of the two tokens in the desired pool
    /// @param fee The desired fee for the pool
    /// @dev tokenA and tokenB may be passed in either order: token0/token1 or token1/token0. tickSpacing is retrieved
    /// from the fee. The call will revert if the pool already exists, the fee is invalid, or the token arguments
    /// are invalid.
    /// @return pool The address of the newly created pool
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address pool);
}

contract UniswapV3TestBase is ForkTestBase {
    address constant UNISWAP_V3_ROUTER              = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant UNISWAP_V3_POSITION_MANAGER    = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address constant UNISWAP_V3_FACTORY             = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;

    int24 internal constant DEFAULT_TICK_LOWER      = -600;
    int24 internal constant DEFAULT_TICK_UPPER      = 600;

    address internal usdsAusdPool;
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

    IERC20  internal token0;
    IERC20  internal token1;
    address internal pool;
    uint24  internal poolFee;
    uint8   internal token0Decimals;
    int24   internal initTick;

    function setUp() public virtual override  {
        super.setUp();

        ausdBase  = IERC20(address(new ERC20Mock()));

        usdsAusdPool = _createPool(address(ausdBase), address(usdsBase), 100);
        usdsUsdcPool = _createPool(address(usdsBase), address(usdcBase), 100);

        vm.warp(block.timestamp + 2 hours); // Advance sufficient time for twap

        uniswapV3_UsdsUsdcPool_UsdsSwapKey         = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_SWAP(),    address(usdsBase), usdsUsdcPool);
        uniswapV3_UsdsUsdcPool_UsdcSwapKey         = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_SWAP(),     address(usdcBase), usdsUsdcPool);
        uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_DEPOSIT(), address(usdsBase), usdsUsdcPool);
        uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_DEPOSIT(),  address(usdcBase), usdsUsdcPool);

        uniswapV3_AusdUsdsPool_AusdSwapKey         = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_SWAP(),    address(ausdBase), usdsAusdPool);
        uniswapV3_AusdUsdsPool_UsdsSwapKey         = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_SWAP(),     address(usdsBase), usdsAusdPool);
        uniswapV3_AusdUsdsPool_AusdAddLiquidityKey = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_DEPOSIT(), address(ausdBase), usdsAusdPool);
        uniswapV3_AusdUsdsPool_UsdsAddLiquidityKey = RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_DEPOSIT(),  address(usdsBase), usdsAusdPool);

        vm.startPrank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(uniswapV3_UsdsUsdcPool_UsdsSwapKey,   1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3_UsdsUsdcPool_UsdcSwapKey,   1_000_000e6,  uint256(1_000_000e6) / 1 days);

        rateLimits.setRateLimitData(uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey,   1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey,   1_000_000e6,  uint256(1_000_000e6)  / 1 days);
        rateLimits.setRateLimitData(uniswapV3_AusdUsdsPool_AusdAddLiquidityKey,   1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(uniswapV3_AusdUsdsPool_UsdsAddLiquidityKey,   1_000_000e18, uint256(1_000_000e18) / 1 days);

        foreignController.setMaxSlippage(_getPool(), 0.98e18);
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

    // @dev According to Uniswap V3 docs, token0/token1 ordering is not enforced when creating a pool.
    function _createPool(
        address _tokenA,
        address _tokenB,
        uint24 _fee
    ) internal returns (address poolAddress) {
        IUniswapV3Factory factory = IUniswapV3Factory(UNISWAP_V3_FACTORY);
        poolAddress = factory.createPool(_tokenA, _tokenB, _fee);

        uint160 sqrtPriceX96 = _getInitialSqrtPriceX96(_tokenA, _tokenB);
        IUniswapV3PoolLike(poolAddress).initialize(sqrtPriceX96);
    }


    function _getSwapKey(address tokenIn) internal view returns (bytes32) {
        return RateLimitHelpers.makeAssetDestinationKey(foreignController.LIMIT_UNISWAP_V3_SWAP(), tokenIn, _getPool());
    }

    function _label() internal {
        vm.label(UNISWAP_V3_ROUTER,            'UniswapV3Router');
        vm.label(UNISWAP_V3_POSITION_MANAGER,  'UniswapV3PositionManager');
        vm.label(address(ausdBase),            'AUSD');
        vm.label(usdsUsdcPool,                 'USDS-USDC Pool');
        vm.label(usdsAusdPool,                 'AUSD-USDS Pool');
    }

    function _getPool() internal view virtual returns (address) {
        return usdsUsdcPool;
    }

    function _getBlock() internal pure override returns (uint256) {
        return 37973959;  // Nov 9, 2025
    }

    function _fundProxy(uint256 amount0Desired, uint256 amount1Desired) internal {
        deal(address(token0), address(almProxy), amount0Desired);
        deal(address(token1), address(almProxy), amount1Desired);
    }
}

contract ForeignControllerAddLiquidityFailureTests is UniswapV3TestBase {
    using stdStorage for StdStorage;

    function _defaultTickRange() internal view returns (UniswapV3Lib.Tick memory) {
        return UniswapV3Lib.Tick({ lower: initTick - 100, upper: initTick + 100 });
    }

    function _defaultDesiredPosition() internal view returns (UniswapV3Lib.TokenAmounts memory) {
        uint256 amount0 = 1000 * 10 ** uint256(token0Decimals);
        uint256 amount1 = 1000 * 10 ** uint256(IERC20Metadata(address(token1)).decimals());

        return UniswapV3Lib.TokenAmounts({ amount0: amount0, amount1: amount1 });
    }

    function _defaultMinPosition(UniswapV3Lib.TokenAmounts memory desired) internal pure returns (UniswapV3Lib.TokenAmounts memory) {
        return UniswapV3Lib.TokenAmounts({
            amount0: desired.amount0 * 99 / 100,
            amount1: desired.amount1 * 99 / 100
        });
    }

    function _prepareDefaultAddLiquidity()
        internal
        returns (
            UniswapV3Lib.Tick memory tick,
            UniswapV3Lib.TokenAmounts memory desired,
            UniswapV3Lib.TokenAmounts memory min
        )
    {
        tick = _defaultTickRange();
        desired = _defaultDesiredPosition();
        min = _defaultMinPosition(desired);
        _fundProxy(desired.amount0, desired.amount1);
    }

    function _mintExternalPosition() internal returns (uint256 tokenId) {
        address stranger = makeAddr("stranger-lp");
        uint256 amount0 = 5 * 10 ** uint256(token0Decimals);
        uint8 token1Decimals = IERC20Metadata(address(token1)).decimals();
        uint256 amount1 = 5 * 10 ** uint256(token1Decimals);

        deal(address(token0), stranger, amount0);
        deal(address(token1), stranger, amount1);

        vm.startPrank(stranger);
        token0.approve(UNISWAP_V3_POSITION_MANAGER, amount0);
        token1.approve(UNISWAP_V3_POSITION_MANAGER, amount1);
        (tokenId,,,) = INonfungiblePositionManager(UNISWAP_V3_POSITION_MANAGER).mint(
            INonfungiblePositionManager.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: poolFee,
                tickLower: initTick - 50,
                tickUpper: initTick + 50,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: stranger,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_notRelayer() public {
        (UniswapV3Lib.Tick memory tick, UniswapV3Lib.TokenAmounts memory desired, UniswapV3Lib.TokenAmounts memory min)
            = _prepareDefaultAddLiquidity();

        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                address(this),
                RELAYER
            )
        );
        foreignController.addLiquidityUniswapV3(
            _getPool(),
            0,
            tick,
            desired,
            min,
            block.timestamp + 1 hours
        );
    }

    function test_addLiquidityUniswapV3_positionManagerNotSet() public {
        (UniswapV3Lib.Tick memory tick, UniswapV3Lib.TokenAmounts memory desired, UniswapV3Lib.TokenAmounts memory min)
            = _prepareDefaultAddLiquidity();

        stdstore
            .target(address(foreignController))
            .sig("uniswapV3PositionManager()")
            .checked_write(address(0));

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("UniswapV3Lib/position-manager-not-set");
        foreignController.addLiquidityUniswapV3(
            _getPool(),
            0,
            tick,
            desired,
            min,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_zeroAmount() public {
        UniswapV3Lib.Tick memory tick = _defaultTickRange();
        UniswapV3Lib.TokenAmounts memory zeroPosition = UniswapV3Lib.TokenAmounts({
            amount0: 0,
            amount1: 0
        });

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("UniswapV3Lib/zero-amount");
        foreignController.addLiquidityUniswapV3(
            _getPool(),
            0,
            tick,
            zeroPosition,
            zeroPosition,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_maxSlippageNotSet() public {
        (UniswapV3Lib.Tick memory tick, UniswapV3Lib.TokenAmounts memory desired, UniswapV3Lib.TokenAmounts memory min)
            = _prepareDefaultAddLiquidity();

        vm.prank(GROVE_EXECUTOR);
        foreignController.setMaxSlippage(_getPool(), 0);

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("UniswapV3Lib/max-slippage-not-set");
        foreignController.addLiquidityUniswapV3(
            _getPool(),
            0,
            tick,
            desired,
            min,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_invalidTickLower() public {
        (UniswapV3Lib.Tick memory tick, UniswapV3Lib.TokenAmounts memory desired, UniswapV3Lib.TokenAmounts memory min)
            = _prepareDefaultAddLiquidity();
        tick.lower = initTick - 2000;

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("UniswapV3Lib/invalid-tick-lower");
        foreignController.addLiquidityUniswapV3(
            _getPool(),
            0,
            tick,
            desired,
            min,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_invalidTickUpper() public {
        (UniswapV3Lib.Tick memory tick, UniswapV3Lib.TokenAmounts memory desired, UniswapV3Lib.TokenAmounts memory min)
            = _prepareDefaultAddLiquidity();
        tick.upper = initTick + 2000;

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("UniswapV3Lib/invalid-tick-upper");
        foreignController.addLiquidityUniswapV3(
            _getPool(),
            0,
            tick,
            desired,
            min,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_minAmount0BelowBound() public {
        (UniswapV3Lib.Tick memory tick, UniswapV3Lib.TokenAmounts memory desired,) = _prepareDefaultAddLiquidity();
        UniswapV3Lib.TokenAmounts memory min = UniswapV3Lib.TokenAmounts({
            amount0: 0,
            amount1: desired.amount1 * 9/100
        });

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("UniswapV3Lib/min-amount-below-bound");
        foreignController.addLiquidityUniswapV3(
            _getPool(),
            0,
            tick,
            desired,
            min,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_minAmount1BelowBound() public {
        (UniswapV3Lib.Tick memory tick, UniswapV3Lib.TokenAmounts memory desired,) = _prepareDefaultAddLiquidity();
        UniswapV3Lib.TokenAmounts memory min = UniswapV3Lib.TokenAmounts({
            amount0: desired.amount0 * 98/100,
            amount1: 0
        });

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("UniswapV3Lib/min-amount-below-bound");
        foreignController.addLiquidityUniswapV3(
            _getPool(),
            0,
            tick,
            desired,
            min,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_proxyDoesNotOwnTokenId() public {
        uint256 tokenId = _mintExternalPosition();

        vm.warp(block.timestamp + 1 hours);
        (UniswapV3Lib.Tick memory tick, UniswapV3Lib.TokenAmounts memory desired, UniswapV3Lib.TokenAmounts memory min)
            = _prepareDefaultAddLiquidity();

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("UniswapV3Lib/proxy-does-not-own-token-id");
        foreignController.addLiquidityUniswapV3(
            _getPool(),
            tokenId,
            tick,
            desired,
            min,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_rateLimitExceeded_token0() public {
        uint256 amount0 = 2_000_000e18;
        uint256 amount1 = 0;

        _fundProxy(amount0, amount1);

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.addLiquidityUniswapV3(
            _getPool(),
            0,
            UniswapV3Lib.Tick({
                lower: initTick+50,
                upper: initTick+100
            }),
            UniswapV3Lib.TokenAmounts({
                amount0: amount0,
                amount1: amount1
            }),
            UniswapV3Lib.TokenAmounts({
                amount0: amount0 * 98 / 100,
                amount1: amount1 * 98 / 100
            }),
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_addLiquidityUniswapV3_rateLimitExceeded_token1() public {
        uint256 amount0 = 0;
        uint256 amount1 = 2_000_000e6;

        _fundProxy(amount0, amount1);

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.addLiquidityUniswapV3(
            _getPool(),
            0,
            UniswapV3Lib.Tick({
                lower: initTick-100,
                upper: initTick-50
            }),
            UniswapV3Lib.TokenAmounts({
                amount0: amount0,
                amount1: amount1
            }),
            UniswapV3Lib.TokenAmounts({
                amount0: amount0 * 98 / 100,
                amount1: amount1 * 98 / 100
            }),
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }
}

contract ForeignControllerAddLiquidityE2EUniswapV3Test is UniswapV3TestBase {
    function _addLiquidity(uint256 _tokenId, UniswapV3Lib.Tick memory _tick, UniswapV3Lib.TokenAmounts memory _desired, UniswapV3Lib.TokenAmounts memory _min) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
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

    function _minLiquidityPosition(uint256 amount0, uint256 amount1) internal pure returns (UniswapV3Lib.TokenAmounts memory) {
        return UniswapV3Lib.TokenAmounts({
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
            UniswapV3Lib.TokenAmounts({ amount0: amount0, amount1: amount1 }),
            _minLiquidityPosition(amount0, amount1)
        );

        uint256 token0RateLimitAfter = rateLimits.getCurrentRateLimit(token0RateLimitKey);
        uint256 token1RateLimitAfter = rateLimits.getCurrentRateLimit(token1RateLimitKey);

        assertEq(token0RateLimitBefore - token0RateLimitAfter, amount0Used, "token0 rate limit delta mismatch");
        assertEq(token1RateLimitBefore - token1RateLimitAfter, amount1Used, "token1 rate limit delta mismatch");
    }

    function _e2e_addLiquidityUniswapV3(uint256 addAmount0, uint256 addAmount1, int24 lowerTickDelta, int24 upperTickDelta, bytes32 token0RateLimitKey, bytes32 token1RateLimitKey) internal returns (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) {
        uint256 amount0 = addAmount0;
        uint256 amount1 = addAmount1;

        deal(address(token0), address(almProxy), amount0);
        deal(address(token1), address(almProxy), amount1);

        UniswapV3Lib.Tick memory tick = UniswapV3Lib.Tick({
            lower : initTick + lowerTickDelta,
            upper : initTick + upperTickDelta
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

contract ForeignControllerAddLiquidityE2EUniswapV3UsdsUsdcTest is ForeignControllerAddLiquidityE2EUniswapV3Test {
    function test_e2e_addLiquidityUniswapV3_equalParts(uint256 addAmount) public {
        addAmount = bound(addAmount, 1e18, 100_000e18);

        uint256 addAmount0 = addAmount;
        uint256 addAmount1 = addAmount * 10**token1.decimals() / 10**18;

        _e2e_addLiquidityUniswapV3(addAmount0, addAmount1, -100, 100, uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey, uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey);
    }

    function test_e2e_addLiquidityUniswapV3_token0Only(uint256 addAmount) public {
        addAmount = bound(addAmount, 1e18, 100_000e18);

        addAmount *= 10**token0.decimals() / 10**18;

        _e2e_addLiquidityUniswapV3(addAmount, 0, 50, 100, uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey, uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey);
    }

    function test_e2e_addLiquidityUniswapV3_token1Only(uint256 addAmount) public {
        addAmount = bound(addAmount, 1e18, 100_000e18);

        addAmount = addAmount * 10**token1.decimals() / 1e18;

        _e2e_addLiquidityUniswapV3(0, addAmount, -100, -50, uniswapV3_UsdsUsdcPool_UsdsAddLiquidityKey, uniswapV3_UsdsUsdcPool_UsdcAddLiquidityKey);
    }
}

contract ForeignControllerAddLiquidityE2EUniswapV3AusdUsdsTest is ForeignControllerAddLiquidityE2EUniswapV3Test {
    function _getPool() internal view override returns (address) {
        return usdsAusdPool;
    }

    function test_e2e_addLiquidityUniswapV3_equalParts(uint256 addAmount) public {
        addAmount = bound(addAmount, 1e18, 100_000e18);

        uint256 addAmount0 = addAmount;
        uint256 addAmount1 = addAmount * 10**token1.decimals() / 10**18;

        _e2e_addLiquidityUniswapV3(addAmount0, addAmount1, -100, 100, uniswapV3_AusdUsdsPool_UsdsAddLiquidityKey, uniswapV3_AusdUsdsPool_AusdAddLiquidityKey);
    }

    function test_e2e_addLiquidityUniswapV3_token0Only(uint256 addAmount) public {
        addAmount = bound(addAmount, 1e18, 100_000e18);

        addAmount *= 10**token0.decimals() / 10**18;

        _e2e_addLiquidityUniswapV3(addAmount, 0, 50, 100, uniswapV3_AusdUsdsPool_UsdsAddLiquidityKey, uniswapV3_AusdUsdsPool_AusdAddLiquidityKey);
    }

    function test_e2e_addLiquidityUniswapV3_token1Only(uint256 addAmount) public {
        addAmount = bound(addAmount, 1e18, 100_000e18);

        addAmount *= 10**token1.decimals() / 10**18;

        _e2e_addLiquidityUniswapV3(0, addAmount, -100, -50, uniswapV3_AusdUsdsPool_UsdsAddLiquidityKey, uniswapV3_AusdUsdsPool_AusdAddLiquidityKey);
    }
}
