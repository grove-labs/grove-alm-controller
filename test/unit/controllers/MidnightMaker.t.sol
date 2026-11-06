// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import "forge-std/Test.sol";

import { ERC20Mock } from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import { ALMProxy }          from "../../../src/ALMProxy.sol";
import { ForeignController } from "../../../src/ForeignController.sol";
import { RateLimits }        from "../../../src/RateLimits.sol";
import { RateLimitHelpers }  from "../../../src/RateLimitHelpers.sol";

import { CollateralParams, Market } from "../../../src/interfaces/MidnightInterfaces.sol";

import { MidnightLib }   from "../../../src/libraries/MidnightLib.sol";
import { MidnightIdLib } from "../../../src/libraries/midnight/MidnightIdLib.sol";

import { MidnightTickLib, MAX_TICK as MIDNIGHT_MAX_TICK } from "../../../src/libraries/midnight/MidnightTickLib.sol";

import { UnitTestBase } from "../UnitTestBase.t.sol";

contract MockMidnightVenue {

    error MarketNotCreated();

    mapping(bytes32 => bytes)   internal _markets;
    mapping(bytes32 => uint128) public   lossFactor;
    mapping(bytes32 => uint256) public   continuousFee;

    mapping(bytes32 => mapping(address => uint256)) public debt;
    mapping(bytes32 => mapping(address => uint128)) public credit;
    mapping(bytes32 => mapping(address => uint128)) public pendingFee;

    address public authorizedTarget;
    bool    public authorizedFlag;
    address public authorizedOnBehalf;
    uint256 public authorizeCalls;

    bytes32 public consumedGroup;
    uint128 public consumedAmount;
    address public consumedOnBehalf;
    uint256 public consumedCalls;

    function setMarket(bytes32 id, Market memory market) external {
        _markets[id] = abi.encode(market);
    }

    function setLossFactor(bytes32 id, uint128 value) external {
        lossFactor[id] = value;
    }

    function setContinuousFee(bytes32 id, uint256 value) external {
        continuousFee[id] = value;
    }

    function setDebt(bytes32 id, address user, uint256 value) external {
        debt[id][user] = value;
    }

    function setPosition(bytes32 id, address user, uint128 credit_, uint128 pendingFee_) external {
        credit[id][user]     = credit_;
        pendingFee[id][user] = pendingFee_;
    }

    function updatePositionView(Market memory, bytes32 id, address user)
        external view returns (uint128, uint128, uint128)
    {
        return ( credit[id][user], pendingFee[id][user], 0 );
    }

    function toMarket(bytes32 id) external view returns (Market memory) {
        if (_markets[id].length == 0) revert MarketNotCreated();

        return abi.decode(_markets[id], (Market));
    }

    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external {
        authorizedTarget   = authorized;
        authorizedFlag     = newIsAuthorized;
        authorizedOnBehalf = onBehalf;
        authorizeCalls++;
    }

    function setConsumed(bytes32 group, uint128 amount, address onBehalf) external {
        consumedGroup    = group;
        consumedAmount   = amount;
        consumedOnBehalf = onBehalf;
        consumedCalls++;
    }

}

contract MidnightMakerTestBase is UnitTestBase {

    event MidnightFillFunded(
        bytes32 indexed marketId,
        address indexed strategy,
        bool            buy,
        uint256         assets,
        uint256         units
    );
    event MidnightMakeDisabled(bytes32 indexed marketId);
    event MidnightMarketConfigSet(
        bytes32 indexed marketId,
        address loanToken,
        uint256 maturity,
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  minBuyYield,
        uint16  maxSellYield,
        uint16  maxContinuousFee,
        uint128 maxLossFactor,
        uint256 maxMakeOfferSize
    );
    event MidnightOfferGroupCancelled(bytes32 indexed group);
    event MidnightRatifierAuthorizationSet(address indexed ratifier, bool authorized);

    uint16 constant MAX_BUY_TICK   = 4000;
    uint16 constant MIN_SELL_TICK  = 3000;
    uint16 constant MAX_SELL_YIELD = 100;

    uint256 constant MAX_OFFER_SIZE = 1_000_000e18;
    uint256 constant WAD            = 1e18;

    ALMProxy          proxy;
    RateLimits        rateLimits;
    ForeignController controller;
    MockMidnightVenue venue;
    ERC20Mock         loanToken;

    address strategy = makeAddr("strategy");
    address ratifier = makeAddr("ratifier");

    bytes32 marketId;
    uint256 maturity;

    function setUp() public virtual {
        proxy      = new ALMProxy(admin);
        rateLimits = new RateLimits(admin);
        venue      = new MockMidnightVenue();
        loanToken  = new ERC20Mock();

        controller = new ForeignController(
            admin,
            address(proxy),
            address(rateLimits),
            makeAddr("psm"),
            makeAddr("usdc"),
            makeAddr("cctp"),
            makeAddr("pendleRouter"),
            makeAddr("uniswapV3Router"),
            makeAddr("uniswapV3PositionManager"),
            address(venue)
        );

        maturity = block.timestamp + 365 days;
        marketId = MidnightIdLib.toId(_market());

        venue.setMarket(marketId, _market());

        vm.startPrank(admin);
        proxy.grantRole(proxy.CONTROLLER(), address(controller));
        rateLimits.grantRole(rateLimits.CONTROLLER(), address(controller));
        controller.grantRole(RELAYER, relayer);
        controller.grantRole(FREEZER, freezer);
        vm.stopPrank();
    }

    function _market() internal view returns (Market memory) {
        return Market({
            chainId          : block.chainid,
            midnight         : address(venue),
            loanToken        : address(loanToken),
            collateralParams : new CollateralParams[](0),
            maturity         : maturity,
            rcfThreshold     : 0,
            enterGate        : address(0),
            liquidatorGate   : address(0)
        });
    }

    // Restates the current maxMakeOfferSize, since the setter writes every field.
    function _setConfig(
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  minBuyYield,
        uint16  maxSellYield,
        uint16  maxContinuousFee,
        uint128 maxLossFactor
    )
        internal
    {
        _setConfig(
            maxBuyTick,
            minSellTick,
            minBuyYield,
            maxSellYield,
            maxContinuousFee,
            maxLossFactor,
            controller.midnightMarketConfigs(marketId).maxMakeOfferSize
        );
    }

    function _setConfig(
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  minBuyYield,
        uint16  maxSellYield,
        uint16  maxContinuousFee,
        uint128 maxLossFactor,
        uint256 maxMakeOfferSize
    )
        internal
    {
        vm.prank(admin);
        controller.setMidnightMarketConfig(
            _market(),
            maxBuyTick,
            minSellTick,
            minBuyYield,
            maxSellYield,
            maxContinuousFee,
            maxLossFactor,
            maxMakeOfferSize
        );
    }

    function _onboardTake() internal {
        _setConfig(MAX_BUY_TICK, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, type(uint128).max);
    }

    function _enableMake() internal {
        _setMakeOfferSize(MAX_OFFER_SIZE);
    }

    // Restates the current bounds, since the setter writes every field.
    function _setMakeOfferSize(uint256 maxMakeOfferSize) internal {
        MidnightLib.MarketConfig memory config = controller.midnightMarketConfigs(marketId);

        _setConfig(
            config.maxBuyTick,
            config.minSellTick,
            config.minBuyYield,
            config.maxSellYield,
            config.maxContinuousFee,
            config.maxLossFactor,
            maxMakeOfferSize
        );
    }

    function _disableMake() internal {
        vm.prank(freezer);
        controller.disableMidnightMake(marketId);
    }

    function _buyKey() internal view returns (bytes32) {
        return RateLimitHelpers.makeBytes32Key(MidnightLib.LIMIT_MIDNIGHT_BUY, marketId);
    }

    function _sellKey() internal view returns (bytes32) {
        return RateLimitHelpers.makeBytes32Key(MidnightLib.LIMIT_MIDNIGHT_SELL, marketId);
    }

    function _setLimits(uint256 maxAmount) internal {
        vm.startPrank(admin);
        rateLimits.setRateLimitData(_buyKey(),  maxAmount, 0);
        rateLimits.setRateLimitData(_sellKey(), maxAmount, 0);
        vm.stopPrank();
    }

    function _strategyBuyKey(address strategy_) internal view returns (bytes32) {
        return RateLimitHelpers.makeAddressBytes32Key(
            MidnightLib.LIMIT_MIDNIGHT_STRATEGY_BUY, strategy_, marketId
        );
    }

    function _strategySellKey(address strategy_) internal view returns (bytes32) {
        return RateLimitHelpers.makeAddressBytes32Key(
            MidnightLib.LIMIT_MIDNIGHT_STRATEGY_SELL, strategy_, marketId
        );
    }

    function _onboardStrategy(uint256 maxAmount) internal {
        vm.startPrank(admin);
        rateLimits.setRateLimitData(_strategyBuyKey(strategy),  maxAmount, 0);
        rateLimits.setRateLimitData(_strategySellKey(strategy), maxAmount, 0);
        vm.stopPrank();
    }

    // Exactly what Midnight pays on a maker buy: floor(units * tickToPrice(tick) / WAD).
    function _honestAssets(uint256 units, uint16 tick) internal pure returns (uint256) {
        return units * MidnightTickLib.tickToPrice(tick) / WAD;
    }

    // Both sell floors sit at or below par, so pricing at par clears whichever binds.
    function _parAssets(uint256 units) internal pure returns (uint256) {
        return units;
    }

    function _minSellAssets(uint256 units, uint256 credit, uint256 pendingFee)
        internal view returns (uint256)
    {
        uint256 timeToMaturity = maturity > block.timestamp ? maturity - block.timestamp : 0;

        uint256 floor = MidnightTickLib.tickToPrice(MIN_SELL_TICK);

        uint256 yieldFloor =
            MidnightLib._minSellPrice(MAX_SELL_YIELD, timeToMaturity, credit, pendingFee);

        if (yieldFloor > floor) floor = yieldFloor;

        return (units * floor + WAD - 1) / WAD;
    }

}

contract ForeignControllerSetMidnightMarketConfigTests is MidnightMakerTestBase {

    // Midnight's own ceiling: 1% a year, in centi-basis points.
    uint16 constant MAX_CONTINUOUS_FEE_CBP = 1_00_00;

    uint16 constant MIN_BUY_YIELD = 1_00;

    function _set(Market memory market, uint16 maxBuyTick, uint256 maxMakeOfferSize) internal {
        controller.setMidnightMarketConfig(
            market, maxBuyTick, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, type(uint128).max, maxMakeOfferSize
        );
    }

    function _setBounds(
        uint16 maxBuyTick,
        uint16 minSellTick,
        uint16 maxSellYield,
        uint16 maxContinuousFee
    )
        internal
    {
        controller.setMidnightMarketConfig(
            _market(), maxBuyTick, minSellTick, 0, maxSellYield, maxContinuousFee, 0, MAX_OFFER_SIZE
        );
    }

    function _unauthorized(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            account,
            DEFAULT_ADMIN_ROLE
        );
    }

    function test_setMidnightMarketConfig_unauthorizedAccount() public {
        vm.expectRevert(_unauthorized(address(this)));
        _set(_market(), MAX_BUY_TICK, MAX_OFFER_SIZE);
    }

    function test_setMidnightMarketConfig_freezerCannotCall() public {
        vm.prank(freezer);
        vm.expectRevert(_unauthorized(freezer));
        _set(_market(), MAX_BUY_TICK, 0);

        vm.prank(freezer);
        vm.expectRevert(_unauthorized(freezer));
        _set(_market(), MAX_BUY_TICK, MAX_OFFER_SIZE);
    }

    function test_setMidnightMarketConfig_relayerCannotCall() public {
        vm.prank(relayer);
        vm.expectRevert(_unauthorized(relayer));
        _set(_market(), MAX_BUY_TICK, 0);

        vm.prank(relayer);
        vm.expectRevert(_unauthorized(relayer));
        _set(_market(), MAX_BUY_TICK, MAX_OFFER_SIZE);
    }

    function test_setMidnightMarketConfig_invalidMidnight() public {
        Market memory other = _market();
        other.midnight = makeAddr("otherVenue");

        venue.setMarket(MidnightIdLib.toId(other), other);

        vm.expectCall(address(venue), abi.encodeWithSelector(MockMidnightVenue.toMarket.selector), 0);

        vm.prank(admin);
        vm.expectRevert("MidnightLib/invalid-midnight");
        _set(other, MAX_BUY_TICK, MAX_OFFER_SIZE);
    }

    function test_setMidnightMarketConfig_maturityOutOfBounds() public {
        Market memory far = _market();
        far.maturity = uint256(type(uint64).max) + 1;

        venue.setMarket(MidnightIdLib.toId(far), far);

        vm.prank(admin);
        vm.expectRevert("MidnightLib/maturity-oob");
        _set(far, MAX_BUY_TICK, MAX_OFFER_SIZE);

        far.maturity = type(uint64).max;

        venue.setMarket(MidnightIdLib.toId(far), far);

        vm.prank(admin);
        _set(far, MAX_BUY_TICK, MAX_OFFER_SIZE);

        assertEq(controller.midnightMarketConfigs(MidnightIdLib.toId(far)).maturity, type(uint64).max);
    }

    function test_setMidnightMarketConfig_maxBuyTickOutOfBounds() public {
        vm.prank(admin);
        vm.expectRevert("MidnightLib/max-buy-tick-oob");
        _setBounds(uint16(MIDNIGHT_MAX_TICK + 1), MIN_SELL_TICK, MAX_SELL_YIELD, 0);
    }

    function test_setMidnightMarketConfig_minSellTickOutOfBounds() public {
        vm.startPrank(admin);

        vm.expectRevert("MidnightLib/min-sell-tick-oob");
        _setBounds(MAX_BUY_TICK, 0, MAX_SELL_YIELD, 0);

        vm.expectRevert("MidnightLib/min-sell-tick-oob");
        _setBounds(MAX_BUY_TICK, uint16(MIDNIGHT_MAX_TICK + 1), MAX_SELL_YIELD, 0);

        vm.stopPrank();
    }

    function test_setMidnightMarketConfig_maxContinuousFeeOutOfBounds() public {
        vm.prank(admin);
        vm.expectRevert("MidnightLib/max-continuous-fee-oob");
        _setBounds(MAX_BUY_TICK, MIN_SELL_TICK, MAX_SELL_YIELD, MAX_CONTINUOUS_FEE_CBP + 1);

        assertEq(
            MidnightLib._continuousFeePerSecond(MAX_CONTINUOUS_FEE_CBP),
            MidnightLib.MAX_CONTINUOUS_FEE
        );

        vm.prank(admin);
        _setBounds(MAX_BUY_TICK, MIN_SELL_TICK, MAX_SELL_YIELD, MAX_CONTINUOUS_FEE_CBP);
    }

    function test_setMidnightMarketConfig_maxSellYieldNotSet() public {
        vm.prank(admin);
        vm.expectRevert("MidnightLib/max-sell-yield-not-set");
        _setBounds(MAX_BUY_TICK, MIN_SELL_TICK, 0, 0);
    }

    function test_setMidnightMarketConfig_maxMakeOfferSizeOutOfBounds() public {
        vm.prank(admin);
        vm.expectRevert("MidnightLib/max-offer-size-oob");
        _set(_market(), MAX_BUY_TICK, uint256(type(uint128).max) + 1);

        vm.prank(admin);
        _set(_market(), MAX_BUY_TICK, type(uint128).max);

        assertEq(controller.midnightMarketConfigs(marketId).maxMakeOfferSize, type(uint128).max);
    }

    function test_setMidnightMarketConfig_marketNotCreated() public {
        Market memory fresh = _market();
        fresh.maturity = maturity + 1 days;

        vm.prank(admin);
        vm.expectRevert(MockMidnightVenue.MarketNotCreated.selector);
        _set(fresh, MAX_BUY_TICK, MAX_OFFER_SIZE);
    }

    function test_setMidnightMarketConfig_marketMismatch() public {
        Market memory other = _market();
        other.rcfThreshold = 1;

        venue.setMarket(marketId, other);

        vm.prank(admin);
        vm.expectRevert("MidnightLib/market-mismatch");
        _set(_market(), MAX_BUY_TICK, MAX_OFFER_SIZE);
    }

    function test_setMidnightMarketConfig_invalidMidnightBeforeMaturity() public {
        Market memory other = _market();
        other.midnight = makeAddr("otherVenue");
        other.maturity = uint256(type(uint64).max) + 1;

        vm.prank(admin);
        vm.expectRevert("MidnightLib/invalid-midnight");
        _set(other, MAX_BUY_TICK, MAX_OFFER_SIZE);
    }

    function test_setMidnightMarketConfig_maturityBeforeBounds() public {
        Market memory far = _market();
        far.maturity = uint256(type(uint64).max) + 1;

        vm.prank(admin);
        vm.expectRevert("MidnightLib/maturity-oob");
        _set(far, uint16(MIDNIGHT_MAX_TICK + 1), MAX_OFFER_SIZE);
    }

    function test_setMidnightMarketConfig_boundsBeforeMaxMakeOfferSize() public {
        vm.prank(admin);
        vm.expectRevert("MidnightLib/max-buy-tick-oob");
        _set(_market(), uint16(MIDNIGHT_MAX_TICK + 1), uint256(type(uint128).max) + 1);
    }

    function test_setMidnightMarketConfig_maxMakeOfferSizeBeforeVenueChecks() public {
        Market memory fresh = _market();
        fresh.maturity = maturity + 1 days;

        vm.prank(admin);
        vm.expectRevert("MidnightLib/max-offer-size-oob");
        _set(fresh, MAX_BUY_TICK, uint256(type(uint128).max) + 1);

        Market memory other = _market();
        other.rcfThreshold = 1;

        venue.setMarket(marketId, other);

        vm.prank(admin);
        vm.expectRevert("MidnightLib/max-offer-size-oob");
        _set(_market(), MAX_BUY_TICK, uint256(type(uint128).max) + 1);
    }

    function test_setMidnightMarketConfig() public {
        MidnightLib.MarketConfig memory config = controller.midnightMarketConfigs(marketId);

        assertEq(config.maxBuyTick,       0);
        assertEq(config.minSellTick,      0);
        assertEq(config.minBuyYield,      0);
        assertEq(config.maxSellYield,     0);
        assertEq(config.maxContinuousFee, 0);
        assertEq(config.maxLossFactor,    0);
        assertEq(config.maxMakeOfferSize, 0);
        assertEq(config.maturity,         0);
        assertEq(config.loanToken,        address(0));

        vm.prank(admin);
        vm.expectEmit(address(controller));
        emit MidnightMarketConfigSet(
            marketId,
            address(loanToken),
            maturity,
            4000,
            3000,
            MIN_BUY_YIELD,
            MAX_SELL_YIELD,
            100,
            1e18,
            MAX_OFFER_SIZE
        );
        controller.setMidnightMarketConfig(
            _market(), 4000, 3000, MIN_BUY_YIELD, MAX_SELL_YIELD, 100, 1e18, MAX_OFFER_SIZE
        );

        config = controller.midnightMarketConfigs(marketId);

        assertEq(config.maxBuyTick,       4000);
        assertEq(config.minSellTick,      3000);
        assertEq(config.minBuyYield,      MIN_BUY_YIELD);
        assertEq(config.maxSellYield,     MAX_SELL_YIELD);
        assertEq(config.maxContinuousFee, 100);
        assertEq(config.maxLossFactor,    1e18);
        assertEq(config.maxMakeOfferSize, MAX_OFFER_SIZE);
        assertEq(config.maturity,         maturity);
        assertEq(config.loanToken,        address(loanToken));

        config = controller.midnightMarketConfigs(keccak256("otherMarket"));

        assertEq(config.maxBuyTick,       0);
        assertEq(config.minSellTick,      0);
        assertEq(config.maxMakeOfferSize, 0);
        assertEq(config.maturity,         0);
        assertEq(config.loanToken,        address(0));

        vm.prank(admin);
        vm.expectEmit(address(controller));
        emit MidnightMarketConfigSet(
            marketId,
            address(loanToken),
            maturity,
            0,
            uint16(MIDNIGHT_MAX_TICK),
            0,
            type(uint16).max,
            MAX_CONTINUOUS_FEE_CBP,
            type(uint128).max,
            type(uint128).max
        );
        controller.setMidnightMarketConfig(
            _market(),
            0,
            uint16(MIDNIGHT_MAX_TICK),
            0,
            type(uint16).max,
            MAX_CONTINUOUS_FEE_CBP,
            type(uint128).max,
            type(uint128).max
        );

        config = controller.midnightMarketConfigs(marketId);

        assertEq(config.maxBuyTick,       0);
        assertEq(config.minSellTick,      MIDNIGHT_MAX_TICK);
        assertEq(config.minBuyYield,      0);
        assertEq(config.maxSellYield,     type(uint16).max);
        assertEq(config.maxContinuousFee, MAX_CONTINUOUS_FEE_CBP);
        assertEq(config.maxLossFactor,    type(uint128).max);
        assertEq(config.maxMakeOfferSize, type(uint128).max);
        assertEq(config.maturity,         maturity);
        assertEq(config.loanToken,        address(loanToken));
    }

    function test_setMidnightMarketConfig_restatesMaxMakeOfferSize() public {
        _onboardTake();
        _enableMake();

        vm.prank(admin);
        controller.setMidnightMarketConfig(
            _market(), MAX_BUY_TICK - 1, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, type(uint128).max, 0
        );

        MidnightLib.MarketConfig memory config = controller.midnightMarketConfigs(marketId);

        assertEq(config.maxBuyTick,       MAX_BUY_TICK - 1);
        assertEq(config.maxMakeOfferSize, 0);
        assertEq(config.maturity,         maturity);
        assertEq(config.loanToken,        address(loanToken));

        vm.prank(admin);
        controller.setMidnightMarketConfig(
            _market(), MAX_BUY_TICK - 1, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, type(uint128).max, 1
        );

        assertEq(controller.midnightMarketConfigs(marketId).maxMakeOfferSize, 1);
    }

    function test_setMidnightMarketConfig_adminZeroEmitsOnlyTheConfigEvent() public {
        _onboardTake();
        _enableMake();

        vm.recordLogs();

        vm.prank(admin);
        _set(_market(), MAX_BUY_TICK, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length,     1);
        assertEq(logs[0].emitter, address(controller));
        assertEq(logs[0].topics[0], MidnightLib.MidnightMarketConfigSet.selector);

        assertEq(controller.midnightMarketConfigs(marketId).maxMakeOfferSize, 0);
    }

}
contract ForeignControllerSetMidnightRatifierAuthorizationTests is MidnightMakerTestBase {

    function test_setMidnightRatifierAuthorization_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        controller.setMidnightRatifierAuthorization(ratifier, true);
    }

    function test_setMidnightRatifierAuthorization_zeroRatifier() public {
        vm.startPrank(admin);
        vm.expectRevert("FC/ratifier-zero-address");
        controller.setMidnightRatifierAuthorization(address(0), true);

        vm.expectRevert("FC/ratifier-zero-address");
        controller.setMidnightRatifierAuthorization(address(0), false);
        vm.stopPrank();

        assertEq(venue.authorizeCalls(), 0);
    }

    function test_setMidnightRatifierAuthorization() public {
        assertEq(venue.authorizeCalls(), 0);

        vm.prank(admin);
        vm.expectEmit(address(controller));
        emit MidnightRatifierAuthorizationSet(ratifier, true);
        controller.setMidnightRatifierAuthorization(ratifier, true);

        assertEq(venue.authorizeCalls(),     1);
        assertEq(venue.authorizedTarget(),   ratifier);
        assertEq(venue.authorizedFlag(),     true);
        assertEq(venue.authorizedOnBehalf(), address(proxy));
    }

    function test_setMidnightRatifierAuthorization_revoke() public {
        vm.startPrank(admin);
        controller.setMidnightRatifierAuthorization(ratifier, true);

        vm.expectEmit(address(controller));
        emit MidnightRatifierAuthorizationSet(ratifier, false);
        controller.setMidnightRatifierAuthorization(ratifier, false);
        vm.stopPrank();

        assertEq(venue.authorizeCalls(), 2);
        assertEq(venue.authorizedFlag(), false);
    }

}

contract ForeignControllerCancelMidnightOfferGroupTests is MidnightMakerTestBase {

    function test_cancelMidnightOfferGroup_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        controller.cancelMidnightOfferGroup(bytes32("buy"));
    }

    function test_cancelMidnightOfferGroup_adminIsNotEnough() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            admin,
            RELAYER
        ));
        controller.cancelMidnightOfferGroup(bytes32("buy"));
    }

    function test_cancelMidnightOfferGroup() public {
        vm.prank(relayer);
        vm.expectEmit(address(controller));
        emit MidnightOfferGroupCancelled(bytes32("buy"));
        controller.cancelMidnightOfferGroup(bytes32("buy"));

        assertEq(venue.consumedCalls(),    1);
        assertEq(venue.consumedGroup(),    bytes32("buy"));
        assertEq(venue.consumedAmount(),   type(uint128).max);
        assertEq(venue.consumedOnBehalf(), address(proxy));
    }

    function test_cancelMidnightOfferGroup_freezer() public {
        vm.prank(freezer);
        vm.expectEmit(address(controller));
        emit MidnightOfferGroupCancelled(bytes32("sell"));
        controller.cancelMidnightOfferGroup(bytes32("sell"));

        assertEq(venue.consumedCalls(),    1);
        assertEq(venue.consumedGroup(),    bytes32("sell"));
        assertEq(venue.consumedAmount(),   type(uint128).max);
        assertEq(venue.consumedOnBehalf(), address(proxy));
    }

    function testFuzz_cancelMidnightOfferGroup_relayerAnyGroupId(bytes32 group) public {
        vm.prank(relayer);
        vm.expectEmit(address(controller));
        emit MidnightOfferGroupCancelled(group);
        controller.cancelMidnightOfferGroup(group);

        assertEq(venue.consumedCalls(),    1);
        assertEq(venue.consumedGroup(),    group);
        assertEq(venue.consumedAmount(),   type(uint128).max);
        assertEq(venue.consumedOnBehalf(), address(proxy));
    }

    function testFuzz_cancelMidnightOfferGroup_freezerAnyGroupId(bytes32 group) public {
        vm.prank(freezer);
        vm.expectEmit(address(controller));
        emit MidnightOfferGroupCancelled(group);
        controller.cancelMidnightOfferGroup(group);

        assertEq(venue.consumedCalls(),    1);
        assertEq(venue.consumedGroup(),    group);
        assertEq(venue.consumedAmount(),   type(uint128).max);
        assertEq(venue.consumedOnBehalf(), address(proxy));
    }

    function test_cancelMidnightOfferGroup_manyGroupsOnAnUnconfiguredMarket() public {
        vm.prank(relayer);
        controller.cancelMidnightOfferGroup(bytes32(0));

        vm.prank(freezer);
        controller.cancelMidnightOfferGroup(keccak256("otherMarket-group"));

        vm.prank(relayer);
        controller.cancelMidnightOfferGroup(bytes32("buy"));

        assertEq(venue.consumedCalls(), 3);
        assertEq(venue.consumedGroup(), bytes32("buy"));
    }

}

contract ForeignControllerDisableMidnightMakeTests is MidnightMakerTestBase {

    function setUp() public override {
        super.setUp();

        _onboardTake();
        _enableMake();
    }

    function _unauthorized(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            account,
            FREEZER
        );
    }

    function _assertSameExceptMakeOfferSize(
        MidnightLib.MarketConfig memory before,
        MidnightLib.MarketConfig memory current
    )
        internal pure
    {
        assertEq(current.maxBuyTick,       before.maxBuyTick);
        assertEq(current.minSellTick,      before.minSellTick);
        assertEq(current.minBuyYield,      before.minBuyYield);
        assertEq(current.maxSellYield,     before.maxSellYield);
        assertEq(current.maxContinuousFee, before.maxContinuousFee);
        assertEq(current.maxLossFactor,    before.maxLossFactor);
        assertEq(current.maturity,         before.maturity);
        assertEq(current.loanToken,        before.loanToken);
        assertEq(current.maxMakeOfferSize, 0);
    }

    function test_disableMidnightMake_unauthorizedAccount() public {
        vm.expectRevert(_unauthorized(address(this)));
        controller.disableMidnightMake(marketId);

        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin));
        controller.disableMidnightMake(marketId);

        vm.prank(relayer);
        vm.expectRevert(_unauthorized(relayer));
        controller.disableMidnightMake(marketId);

        assertEq(controller.midnightMarketConfigs(marketId).maxMakeOfferSize, MAX_OFFER_SIZE);
    }

    function test_disableMidnightMake() public {
        MidnightLib.MarketConfig memory before = controller.midnightMarketConfigs(marketId);

        assertEq(before.maxMakeOfferSize, MAX_OFFER_SIZE);

        vm.prank(freezer);
        vm.expectEmit(address(controller));
        emit MidnightMakeDisabled(marketId);
        controller.disableMidnightMake(marketId);

        _assertSameExceptMakeOfferSize(before, controller.midnightMarketConfigs(marketId));
    }

    function test_disableMidnightMake_isIdempotent() public {
        MidnightLib.MarketConfig memory before = controller.midnightMarketConfigs(marketId);

        vm.prank(freezer);
        vm.expectEmit(address(controller));
        emit MidnightMakeDisabled(marketId);
        controller.disableMidnightMake(marketId);

        vm.prank(freezer);
        vm.expectEmit(address(controller));
        emit MidnightMakeDisabled(marketId);
        controller.disableMidnightMake(marketId);

        _assertSameExceptMakeOfferSize(before, controller.midnightMarketConfigs(marketId));
    }

    function test_disableMidnightMake_unconfiguredMarket() public {
        bytes32 unknown = keccak256("unconfiguredMarket");

        vm.prank(freezer);
        vm.expectEmit(address(controller));
        emit MidnightMakeDisabled(unknown);
        controller.disableMidnightMake(unknown);

        MidnightLib.MarketConfig memory config = controller.midnightMarketConfigs(unknown);

        assertEq(config.minSellTick,      0);
        assertEq(config.maxMakeOfferSize, 0);
        assertEq(config.loanToken,        address(0));
    }

    function test_disableMidnightMake_readsNothingFromTheVenue() public {
        MidnightLib.MarketConfig memory before = controller.midnightMarketConfigs(marketId);

        vm.etch(address(venue), hex"5f5ffd");

        vm.expectRevert();
        venue.toMarket(marketId);

        vm.expectCall(address(venue), abi.encodeWithSelector(MockMidnightVenue.toMarket.selector), 0);

        vm.prank(freezer);
        controller.disableMidnightMake(marketId);

        _assertSameExceptMakeOfferSize(before, controller.midnightMarketConfigs(marketId));
    }

    function test_disableMidnightMake_worksAfterTheProxyRoleIsRevoked() public {
        bytes32 controllerRole = proxy.CONTROLLER();

        vm.prank(admin);
        proxy.revokeRole(controllerRole, address(controller));

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(controller),
            controllerRole
        ));
        controller.cancelMidnightOfferGroup(bytes32("buy"));

        vm.prank(freezer);
        controller.disableMidnightMake(marketId);

        assertEq(controller.midnightMarketConfigs(marketId).maxMakeOfferSize, 0);
    }

    function test_disableMidnightMake_blocksFundFillAndFlipsTheView() public {
        _setLimits(MAX_OFFER_SIZE);
        _onboardStrategy(MAX_OFFER_SIZE);

        assertTrue(controller.midnight_isCallbackAllowed(marketId, strategy, true));
        assertTrue(controller.midnight_isCallbackAllowed(marketId, strategy, false));

        _disableMake();

        assertFalse(controller.midnight_isCallbackAllowed(marketId, strategy, true));
        assertFalse(controller.midnight_isCallbackAllowed(marketId, strategy, false));

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/make-not-enabled");
        controller.midnight_fundFill(marketId, true, 1e18, 1e18, 0);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/make-not-enabled");
        controller.midnight_fundFill(marketId, false, 1e18, 1e18, 0);
    }

    function test_disableMidnightMake_onlyTheAdminReEnables() public {
        _setLimits(MAX_OFFER_SIZE);
        _onboardStrategy(MAX_OFFER_SIZE);

        _disableMake();

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        controller.setMidnightMarketConfig(
            _market(), MAX_BUY_TICK, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, type(uint128).max, MAX_OFFER_SIZE
        );

        _enableMake();

        assertTrue(controller.midnight_isCallbackAllowed(marketId, strategy, true));
    }

}
contract ForeignControllerMidnightPeripheryViewTests is MidnightMakerTestBase {

    function test_midnightPeripherySelectors() public pure {
        assertEq(ForeignController.midnight_fundFill.selector,          bytes4(0xfb9e2099));
        assertEq(ForeignController.midnight_isCallbackAllowed.selector, bytes4(0x5c0f4590));
    }

    function test_midnightConfigSelectorsAndTopics() public pure {
        assertEq(ForeignController.setMidnightMarketConfig.selector, bytes4(0x58870eb3));
        assertEq(ForeignController.disableMidnightMake.selector,     bytes4(0x881e4d84));
        assertEq(ForeignController.midnightMarketConfigs.selector,   bytes4(0x8000ad90));

        assertEq(
            MidnightLib.MidnightMarketConfigSet.selector,
            0x284a24bcaff75572bcc183e25df42a627752d04ea48010f22d3412784815375d
        );
        assertEq(
            ForeignController.MidnightMakeDisabled.selector,
            0xe52b976e8352922cbd082842e7bc4497979a5a01536c7ce29c79c3e74080720e
        );
    }

    function test_midnightPreviousConfigSettersAreGone() public {
        vm.startPrank(admin);

        ( bool makeOk, ) = address(controller).call(
            abi.encodeWithSelector(bytes4(0x48f79a8a), marketId, uint256(0))
        );

        ( bool marketOk, ) = address(controller).call(abi.encodeWithSelector(
            bytes4(0x15801813), marketId, MAX_BUY_TICK, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, 0
        ));

        vm.stopPrank();

        assertFalse(makeOk);
        assertFalse(marketOk);
    }

    function test_midnightGroupDesignationIsGone() public {
        ( bool getOk, ) = address(controller).staticcall(
            abi.encodeWithSelector(bytes4(0x87d2a293), marketId)
        );

        vm.prank(admin);
        ( bool setOk, ) = address(controller).call(
            abi.encodeWithSelector(bytes4(0xa494afa4), marketId, bytes32("buy"), bytes32("sell"))
        );

        assertFalse(getOk);
        assertFalse(setOk);
    }

    function test_midnightViews_areStaticcallSafeOnUnknownMarkets() public view {
        bytes32 unknown = keccak256("unknownMarket");

        ( bool allowedOk, bytes memory allowedOut ) = address(controller).staticcall(
            abi.encodeCall(ForeignController.midnight_isCallbackAllowed, (unknown, strategy, true))
        );

        assertTrue(allowedOk);

        assertFalse(abi.decode(allowedOut, (bool)));
    }

    function test_midnightViews_areStaticcallSafeOnConfiguredMarkets() public {
        _onboardTake();
        _enableMake();
        _setLimits(MAX_OFFER_SIZE);
        _onboardStrategy(MAX_OFFER_SIZE);

        ( bool allowedOk, bytes memory allowedOut ) = address(controller).staticcall(
            abi.encodeCall(ForeignController.midnight_isCallbackAllowed, (marketId, strategy, true))
        );

        assertTrue(allowedOk);

        assertTrue(abi.decode(allowedOut, (bool)));
    }

    function test_midnightIsCallbackAllowed_rejectsZeroCallback() public {
        _onboardTake();
        _enableMake();
        _setLimits(MAX_OFFER_SIZE);

        vm.startPrank(admin);
        rateLimits.setRateLimitData(_strategyBuyKey(address(0)),  MAX_OFFER_SIZE, 0);
        rateLimits.setRateLimitData(_strategySellKey(address(0)), MAX_OFFER_SIZE, 0);
        vm.stopPrank();

        assertFalse(controller.midnight_isCallbackAllowed(marketId, address(0), true));
        assertFalse(controller.midnight_isCallbackAllowed(marketId, address(0), false));
    }

    function test_midnightIsCallbackAllowed_requiresMakeEnabled() public {
        _onboardTake();
        _setLimits(MAX_OFFER_SIZE);
        _onboardStrategy(MAX_OFFER_SIZE);

        assertFalse(controller.midnight_isCallbackAllowed(marketId, strategy, true));

        _enableMake();

        assertTrue(controller.midnight_isCallbackAllowed(marketId, strategy, true));
    }

    function test_midnightIsCallbackAllowed_requiresMarketKey() public {
        _onboardTake();
        _enableMake();
        _onboardStrategy(MAX_OFFER_SIZE);

        assertFalse(controller.midnight_isCallbackAllowed(marketId, strategy, true));

        _setLimits(MAX_OFFER_SIZE);

        assertTrue(controller.midnight_isCallbackAllowed(marketId, strategy, true));
    }

    function test_midnightIsCallbackAllowed_isDirectionScoped() public {
        _onboardTake();
        _enableMake();
        _setLimits(MAX_OFFER_SIZE);

        vm.prank(admin);
        rateLimits.setRateLimitData(_strategyBuyKey(strategy), MAX_OFFER_SIZE, 0);

        assertTrue(controller.midnight_isCallbackAllowed(marketId, strategy, true));
        assertFalse(controller.midnight_isCallbackAllowed(marketId, strategy, false));
    }

    function test_midnightIsCallbackAllowed_isStrategyAndMarketScoped() public {
        _onboardTake();
        _enableMake();
        _setLimits(MAX_OFFER_SIZE);
        _onboardStrategy(MAX_OFFER_SIZE);

        assertTrue(controller.midnight_isCallbackAllowed(marketId, strategy, true));

        assertFalse(controller.midnight_isCallbackAllowed(marketId, makeAddr("other"), true));
        assertFalse(
            controller.midnight_isCallbackAllowed(keccak256("otherMarket"), strategy, true)
        );
    }

    function test_midnightIsCallbackAllowed_buyRequiresMaxBuyTick() public {
        _onboardTake();
        _enableMake();
        _setLimits(MAX_OFFER_SIZE);
        _onboardStrategy(MAX_OFFER_SIZE);

        assertTrue(controller.midnight_isCallbackAllowed(marketId, strategy, true));

        _closeBuyEntry();

        assertEq(controller.midnightMarketConfigs(marketId).maxBuyTick,       0);
        assertEq(controller.midnightMarketConfigs(marketId).maxMakeOfferSize, MAX_OFFER_SIZE);

        assertFalse(controller.midnight_isCallbackAllowed(marketId, strategy, true));
    }

    function test_midnightIsCallbackAllowed_sellIgnoresMaxBuyTick() public {
        _onboardTake();
        _enableMake();
        _setLimits(MAX_OFFER_SIZE);
        _onboardStrategy(MAX_OFFER_SIZE);

        _closeBuyEntry();

        assertEq(controller.midnightMarketConfigs(marketId).maxBuyTick, 0);

        assertTrue(controller.midnight_isCallbackAllowed(marketId, strategy, false));
    }

    function _closeBuyEntry() internal {
        _setConfig(0, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, type(uint128).max);
    }

}

contract ForeignControllerMidnightFundFillTests is MidnightMakerTestBase {

    uint256 constant UNITS            = 1_000e18;
    uint256 constant POSITION_CREDIT  = 1_000_000e18;

    function setUp() public override {
        super.setUp();

        _onboardTake();
        _enableMake();

        // Unlimited, so the per-market keys are what the market-limit tests exercise.
        _onboardStrategy(type(uint256).max);

        // Fee-free credit, so the sell floor the controller derives is the tick floor.
        venue.setPosition(marketId, address(proxy), uint128(POSITION_CREDIT), 0);

        loanToken.mint(address(proxy), 10_000_000e18);
    }

    function test_midnight_fundFill_makeNotEnabled() public {
        _disableMake();

        _setLimits(MAX_OFFER_SIZE);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/make-not-enabled");
        controller.midnight_fundFill(marketId, true, 1, UNITS, 0);
    }

    function test_midnight_fundFill_zeroAssets() public {
        _setLimits(MAX_OFFER_SIZE);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/zero-assets");
        controller.midnight_fundFill(marketId, true, 0, UNITS, 0);
    }

    function test_midnight_fundFill_zeroUnits() public {
        _setLimits(MAX_OFFER_SIZE);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/zero-units");
        controller.midnight_fundFill(marketId, true, 1, 0, 0);
    }

    function test_midnight_fundFill_buyLiveContinuousFeeAboveCeiling() public {
        _setLimits(MAX_OFFER_SIZE);

        _setConfig(MAX_BUY_TICK, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 10, type(uint128).max);

        uint256 ceiling = MidnightLib._continuousFeePerSecond(10);

        venue.setContinuousFee(marketId, ceiling);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, true, 1, UNITS, 0);

        venue.setContinuousFee(marketId, ceiling + 1);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/continuous-fee-too-high");
        controller.midnight_fundFill(marketId, true, 1, UNITS, 0);
    }

    function test_midnight_fundFill_sellFloorBoundary() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 minAssets = _minSellAssets(UNITS, POSITION_CREDIT, 0);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/fill-price-too-low");
        controller.midnight_fundFill(marketId, false, minAssets - 1, UNITS, 0);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, false, minAssets, UNITS, 0);
    }

    function test_midnight_fundFill_sellFloorFallsWithTheCarriedPendingFee() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 carriedFee  = POSITION_CREDIT / 100;
        uint256 reportedFee = UNITS / 100;

        uint256 withFee = _minSellAssets(UNITS, POSITION_CREDIT, carriedFee);

        assertLt(withFee, _minSellAssets(UNITS, POSITION_CREDIT, 0));

        // The position carries no fee yet, so the reported fee alone cannot lower the floor.
        vm.prank(strategy);
        vm.expectRevert("MidnightLib/fill-price-too-low");
        controller.midnight_fundFill(marketId, false, withFee, UNITS, reportedFee);

        venue.setPosition(marketId, address(proxy), uint128(POSITION_CREDIT), uint128(carriedFee));

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, false, withFee, UNITS, reportedFee);
    }

    function test_midnight_fundFill_sellFloorIgnoresAnInflatedReportedFee() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 carriedFee = POSITION_CREDIT / 100;

        venue.setPosition(marketId, address(proxy), uint128(POSITION_CREDIT), uint128(carriedFee));

        uint256 minAssets = _minSellAssets(UNITS, POSITION_CREDIT, carriedFee);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/fill-price-too-low");
        controller.midnight_fundFill(marketId, false, minAssets - 1, UNITS, UNITS);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, false, minAssets, UNITS, UNITS);
    }

    function test_midnight_fundFill_sellFloorTightensWithALowerReportedFee() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 carriedFee  = POSITION_CREDIT / 100;
        uint256 reportedFee = UNITS / 200;

        venue.setPosition(marketId, address(proxy), uint128(POSITION_CREDIT), uint128(carriedFee));

        uint256 minAssets = _minSellAssets(UNITS, UNITS, reportedFee);

        assertGt(minAssets, _minSellAssets(UNITS, POSITION_CREDIT, carriedFee));

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/fill-price-too-low");
        controller.midnight_fundFill(marketId, false, minAssets - 1, UNITS, reportedFee);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, false, minAssets, UNITS, reportedFee);
    }

    function test_midnight_fundFill_sellFloorIsTheZeroFeeYieldFloorOnAFullExit() public {
        _setLimits(MAX_OFFER_SIZE);

        venue.setPosition(marketId, address(proxy), 0, 0);

        uint256 minAssets = _minSellAssets(UNITS, POSITION_CREDIT, 0);

        assertLt(minAssets, _parAssets(UNITS));
        assertGt(minAssets, _minSellAssets(UNITS, UNITS, UNITS / 100));

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/fill-price-too-low");
        controller.midnight_fundFill(marketId, false, minAssets - 1, UNITS, UNITS / 100);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, false, minAssets, UNITS, UNITS / 100);
    }

    function test_midnight_fundFill_buyIgnoresTheReportedFee() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/fill-price-too-high");
        controller.midnight_fundFill(marketId, true, assets + 1, UNITS, type(uint256).max);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, true, assets, UNITS, type(uint256).max);

        assertEq(loanToken.balanceOf(strategy), assets);
    }

    function test_midnight_fundFill_sellIntoDebtIsRejected() public {
        _setLimits(MAX_OFFER_SIZE);

        venue.setDebt(marketId, address(proxy), 1);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/debt-not-zero");
        controller.midnight_fundFill(marketId, false, _parAssets(UNITS), UNITS, 0);
    }

    function test_midnight_fundFill_buyIgnoresDebt() public {
        _setLimits(MAX_OFFER_SIZE);

        venue.setDebt(marketId, address(proxy), 1);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, true, 1, UNITS, 0);
    }

    function test_midnight_fundFill_unsetStrategyKeyReverts() public {
        _setLimits(MAX_OFFER_SIZE);
        _onboardStrategy(0);

        vm.prank(strategy);
        vm.expectRevert("RateLimits/zero-maxAmount");
        controller.midnight_fundFill(marketId, true, 1, UNITS, 0);

        vm.prank(strategy);
        vm.expectRevert("RateLimits/zero-maxAmount");
        controller.midnight_fundFill(marketId, false, _parAssets(UNITS), UNITS, 0);
    }

    function test_midnight_fundFill_strategyKeyIsMarketScoped() public {
        _setLimits(MAX_OFFER_SIZE);
        _onboardStrategy(0);

        vm.prank(admin);
        rateLimits.setRateLimitData(
            RateLimitHelpers.makeAddressBytes32Key(
                MidnightLib.LIMIT_MIDNIGHT_STRATEGY_BUY, strategy, keccak256("otherMarket")
            ),
            MAX_OFFER_SIZE,
            0
        );

        vm.prank(strategy);
        vm.expectRevert("RateLimits/zero-maxAmount");
        controller.midnight_fundFill(marketId, true, 1, UNITS, 0);
    }

    function test_midnight_fundFill_buyKeyDoesNotAuthorizeSell() public {
        _setLimits(MAX_OFFER_SIZE);
        _onboardStrategy(0);

        vm.prank(admin);
        rateLimits.setRateLimitData(_strategyBuyKey(strategy), MAX_OFFER_SIZE, 0);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, true, 1, UNITS, 0);

        vm.prank(strategy);
        vm.expectRevert("RateLimits/zero-maxAmount");
        controller.midnight_fundFill(marketId, false, _parAssets(UNITS), UNITS, 0);
    }

    function test_midnight_fundFill_decreasesStrategyAndMarketKeys() public {
        _setLimits(MAX_OFFER_SIZE);
        _onboardStrategy(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, true, assets, UNITS, 0);

        assertEq(rateLimits.getCurrentRateLimit(_buyKey()),                  MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(_strategyBuyKey(strategy)),  MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(_sellKey()),                 MAX_OFFER_SIZE);
        assertEq(rateLimits.getCurrentRateLimit(_strategySellKey(strategy)), MAX_OFFER_SIZE);
    }

    function test_midnight_fundFill_offboardedStrategyIsRejected() public {
        _setLimits(MAX_OFFER_SIZE);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, true, 1, UNITS, 0);

        _onboardStrategy(0);

        vm.prank(strategy);
        vm.expectRevert("RateLimits/zero-maxAmount");
        controller.midnight_fundFill(marketId, true, 1, UNITS, 0);
    }

    function test_midnight_fundFill_buyChecksTheFeeBeforeTheLossFactor() public {
        _setLimits(MAX_OFFER_SIZE);

        _setConfig(MAX_BUY_TICK, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 10, 100);

        venue.setContinuousFee(marketId, MidnightLib._continuousFeePerSecond(10) + 1);
        venue.setLossFactor(marketId, 101);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/continuous-fee-too-high");
        controller.midnight_fundFill(marketId, true, 1, UNITS, 0);
    }

    function test_midnight_fundFill_lossFactorTooHigh() public {
        _setLimits(MAX_OFFER_SIZE);

        _setConfig(MAX_BUY_TICK, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, 100);

        venue.setLossFactor(marketId, 101);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/loss-factor-too-high");
        controller.midnight_fundFill(marketId, true, 1, UNITS, 0);

        venue.setLossFactor(marketId, 100);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, true, 1, UNITS, 0);
    }

    function test_midnight_fundFill_honestFillAtTheBound() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, true, assets, UNITS, 0);

        assertEq(loanToken.balanceOf(strategy), assets);
    }

    function test_midnight_fundFill_oneTickTooExpensive() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK + 1);

        assertGt(assets, _honestAssets(UNITS, MAX_BUY_TICK));

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/fill-price-too-high");
        controller.midnight_fundFill(marketId, true, assets, UNITS, 0);
    }

    function test_midnight_fundFill_zeroMaxBuyTickRefusesEveryBuy() public {
        _setLimits(MAX_OFFER_SIZE);

        _setConfig(0, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, type(uint128).max);

        assertEq(controller.midnightMarketConfigs(marketId).maxMakeOfferSize, MAX_OFFER_SIZE);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/fill-price-too-high");
        controller.midnight_fundFill(marketId, true, 1, 1e30, 0);
    }

    function test_midnight_fundFill_oneWeiOverTheBound() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/fill-price-too-high");
        controller.midnight_fundFill(marketId, true, assets + 1, UNITS, 0);
    }

    function test_midnight_fundFill_yieldBoundCanBind() public {
        _setLimits(MAX_OFFER_SIZE);

        _setConfig(MAX_BUY_TICK, MIN_SELL_TICK, 5000, MAX_SELL_YIELD, 0, type(uint128).max);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/fill-price-too-high");
        controller.midnight_fundFill(marketId, true, assets, UNITS, 0);
    }

    function test_midnight_fundFill_buyDecrementsBuyOnly() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        assertEq(rateLimits.getCurrentRateLimit(_buyKey()),  MAX_OFFER_SIZE);
        assertEq(rateLimits.getCurrentRateLimit(_sellKey()), MAX_OFFER_SIZE);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, true, assets, UNITS, 0);

        assertEq(rateLimits.getCurrentRateLimit(_buyKey()),  MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(_sellKey()), MAX_OFFER_SIZE);
    }

    function test_midnight_fundFill_sellDecrementsSellAndLeavesBuy() public {
        uint256 assets = _parAssets(UNITS);

        vm.startPrank(admin);
        rateLimits.setRateLimitData(_sellKey(), MAX_OFFER_SIZE, 0);
        rateLimits.setRateLimitData(_buyKey(),  MAX_OFFER_SIZE, 0, 0, block.timestamp);
        vm.stopPrank();

        uint256 proxyPre = loanToken.balanceOf(address(proxy));

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, false, assets, UNITS, 0);

        assertEq(rateLimits.getCurrentRateLimit(_sellKey()), MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(_buyKey()),  0);

        assertEq(loanToken.balanceOf(strategy),       0);
        assertEq(loanToken.balanceOf(address(proxy)), proxyPre);
    }

    function test_midnight_fundFill_sellSkipsTheBuyPriceBound() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 wayOverBuyBound = _honestAssets(UNITS, MAX_BUY_TICK) * 10;

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, false, wayOverBuyBound, UNITS, 0);

        assertEq(rateLimits.getCurrentRateLimit(_sellKey()), MAX_OFFER_SIZE - wayOverBuyBound);
    }

    function test_midnight_fundFill_sellSkipsTheLossFactorGate() public {
        _setLimits(MAX_OFFER_SIZE);

        _setConfig(MAX_BUY_TICK, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, 100);

        venue.setLossFactor(marketId, 101);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/loss-factor-too-high");
        controller.midnight_fundFill(marketId, true, 1, UNITS, 0);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, false, _parAssets(UNITS), UNITS, 0);
    }

    function test_midnight_fundFill_offerSizeCeilingBinds() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        _setMakeOfferSize(assets - 1);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/offer-size-too-large");
        controller.midnight_fundFill(marketId, true, assets, UNITS, 0);

        _setMakeOfferSize(assets);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, true, assets, UNITS, 0);

        assertEq(rateLimits.getCurrentRateLimit(_buyKey()), MAX_OFFER_SIZE - assets);
    }

    function test_midnight_fundFill_offerSizeCeilingBindsOnSell() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets = _parAssets(UNITS);

        _setMakeOfferSize(assets - 1);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/offer-size-too-large");
        controller.midnight_fundFill(marketId, false, assets, UNITS, 0);
    }

    function test_midnight_fundFill_sellLimitBinds() public {
        uint256 assets = _parAssets(UNITS);

        vm.startPrank(admin);
        rateLimits.setRateLimitData(_sellKey(), assets - 1, 0);
        vm.stopPrank();

        vm.prank(strategy);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        controller.midnight_fundFill(marketId, false, assets, UNITS, 0);
    }

    function test_midnight_fundFill_buyLimitBinds() public {
        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.startPrank(admin);
        rateLimits.setRateLimitData(_buyKey(), assets - 1, 0);
        vm.stopPrank();

        vm.prank(strategy);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        controller.midnight_fundFill(marketId, true, assets, UNITS, 0);
    }

    function test_midnight_fundFill_paysTheCallerOnly() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets   = _honestAssets(UNITS, MAX_BUY_TICK);
        uint256 proxyPre = loanToken.balanceOf(address(proxy));

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, true, assets, UNITS, 0);

        assertEq(loanToken.balanceOf(strategy),       assets);
        assertEq(loanToken.balanceOf(address(proxy)), proxyPre - assets);
        assertEq(loanToken.balanceOf(ratifier),       0);
    }

    function test_midnight_fundFill_needsNoRole() public {
        address allowed = makeAddr("anotherStrategy");

        _setLimits(MAX_OFFER_SIZE);

        vm.startPrank(admin);
        rateLimits.setRateLimitData(_strategyBuyKey(allowed),  MAX_OFFER_SIZE, 0);
        rateLimits.setRateLimitData(_strategySellKey(allowed), MAX_OFFER_SIZE, 0);
        vm.stopPrank();

        assertFalse(controller.hasRole(RELAYER, allowed));

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.prank(allowed);
        controller.midnight_fundFill(marketId, true, assets, UNITS, 0);

        assertEq(loanToken.balanceOf(allowed), assets);
    }

    function test_midnight_fundFill_emitsFunded() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.prank(strategy);
        vm.expectEmit(address(controller));
        emit MidnightFillFunded(marketId, strategy, true, assets, UNITS);
        controller.midnight_fundFill(marketId, true, assets, UNITS, 0);
    }

    function test_midnight_fundFill_emitsFundedOnSell() public {
        _setLimits(MAX_OFFER_SIZE);

        vm.prank(strategy);
        vm.expectEmit(address(controller));
        emit MidnightFillFunded(marketId, strategy, false, 1_000e18, UNITS);
        controller.midnight_fundFill(marketId, false, 1_000e18, UNITS, 0);
    }

    function testFuzz_midnight_fundFill_honestFillNeverTrips(uint256 units, uint16 tick) public {
        units = bound(units, 1, 1_000_000e18);
        tick  = uint16(bound(tick, 0, MAX_BUY_TICK));

        _setLimits(type(uint128).max);

        uint256 assets = _honestAssets(units, tick);

        vm.assume(assets != 0);

        vm.prank(strategy);
        controller.midnight_fundFill(marketId, true, assets, units, 0);

        assertEq(loanToken.balanceOf(strategy), assets);
    }

}

contract ForeignControllerMidnightCallbackAllowedEquivalenceTests is MidnightMakerTestBase {

    function setUp() public override {
        super.setUp();

        _onboardTake();

        loanToken.mint(address(proxy), 1);
    }

    // Excluded checks, held passing by a 1-wei fill on a fee-free, debt-free market with a funded
    // proxy: zero-assets, zero-units, offer-size-too-large, rate-limit-exceeded, continuous fee,
    // loss factor, price other than a zero maxBuyTick, debt, transfer. The zero callback is also
    // excluded: the view hard-codes false for it.
    function testFuzz_midnightIsCallbackAllowed_matchesTheFundFillGates(
        address            callback,
        bool               buy,
        uint256            maxMakeOfferSize,
        uint256[4] memory  keyAmounts,
        uint8              zeroMask
    )
        public
    {
        vm.assume(callback != address(0));
        assumeNotForgeAddress(callback);

        maxMakeOfferSize = zeroMask & 1 == 0 ? bound(maxMakeOfferSize, 1, type(uint128).max) : 0;

        bool zeroMaxBuyTick = zeroMask & 32 != 0;

        for (uint256 i; i < 4; ++i) {
            keyAmounts[i] = zeroMask & (2 << i) == 0 ? bound(keyAmounts[i], 1, type(uint256).max) : 0;
        }

        vm.startPrank(admin);
        controller.setMidnightMarketConfig(
            _market(),
            zeroMaxBuyTick ? 0 : MAX_BUY_TICK,
            MIN_SELL_TICK,
            0,
            MAX_SELL_YIELD,
            0,
            type(uint128).max,
            maxMakeOfferSize
        );
        rateLimits.setRateLimitData(_strategyBuyKey(callback),  keyAmounts[0], 0);
        rateLimits.setRateLimitData(_strategySellKey(callback), keyAmounts[1], 0);
        rateLimits.setRateLimitData(_buyKey(),                  keyAmounts[2], 0);
        rateLimits.setRateLimitData(_sellKey(),                 keyAmounts[3], 0);
        vm.stopPrank();

        bool allowed = controller.midnight_isCallbackAllowed(marketId, callback, buy);

        vm.prank(callback);
        ( bool funded, bytes memory reason ) = address(controller).call(abi.encodeCall(
            ForeignController.midnight_fundFill, (marketId, buy, 1, buy ? WAD : 1, 0)
        ));

        assertEq(allowed, funded);

        if (!funded) {
            bytes32 reasonHash = keccak256(reason);

            assertTrue(
                reasonHash == keccak256(_revertReason("MidnightLib/make-not-enabled")) ||
                reasonHash == keccak256(_revertReason("RateLimits/zero-maxAmount")) ||
                (
                    buy && zeroMaxBuyTick &&
                    reasonHash == keccak256(_revertReason("MidnightLib/fill-price-too-high"))
                )
            );
        }
    }

    function _revertReason(string memory message) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", message);
    }

}
