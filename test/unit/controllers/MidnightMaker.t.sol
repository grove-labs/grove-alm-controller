// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import "forge-std/Test.sol";

import { ERC20Mock } from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import { ALMProxy }          from "../../../src/ALMProxy.sol";
import { ForeignController } from "../../../src/ForeignController.sol";
import { RateLimits }        from "../../../src/RateLimits.sol";
import { RateLimitHelpers }  from "../../../src/RateLimitHelpers.sol";

import { CollateralParams, Market } from "../../../src/interfaces/MidnightInterfaces.sol";

import { MidnightLib }     from "../../../src/libraries/MidnightLib.sol";
import { MidnightIdLib }   from "../../../src/libraries/midnight/MidnightIdLib.sol";
import { MidnightTickLib } from "../../../src/libraries/midnight/MidnightTickLib.sol";

import { UnitTestBase } from "../UnitTestBase.t.sol";

contract MockMidnightVenue {

    mapping(bytes32 => bytes)   internal _markets;
    mapping(bytes32 => uint128) public   lossFactor;

    bool public marketCreated;

    address public authorizedTarget;
    bool    public authorizedFlag;
    address public authorizedOnBehalf;
    uint256 public authorizeCalls;

    bytes32 public consumedGroup;
    uint128 public consumedAmount;
    address public consumedOnBehalf;
    uint256 public consumedCalls;

    function setMarket(bytes32 id, Market memory market) external {
        _markets[id]  = abi.encode(market);
        marketCreated = true;
    }

    function setLossFactor(bytes32 id, uint128 value) external {
        lossFactor[id] = value;
    }

    function toMarket(bytes32 id) external view returns (Market memory) {
        require(marketCreated, "MockMidnight/market-not-created");
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
        uint256 assets,
        uint256 units
    );
    event MidnightGroupsSet(bytes32 indexed marketId, bytes32 buyGroup, bytes32 sellGroup);
    event MidnightMakeConfigSet(
        bytes32 indexed marketId,
        address loanToken,
        uint256 maturity,
        uint256 maxOfferSize
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

    function _onboardTake() internal {
        vm.prank(admin);
        controller.setMidnightMarketConfig(
            marketId, MAX_BUY_TICK, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, type(uint128).max
        );
    }

    function _enableMake() internal {
        vm.prank(admin);
        controller.setMidnightMakeConfig(marketId, MAX_OFFER_SIZE);
    }

    function _strategyKey() internal view returns (bytes32) {
        return controller.midnightStrategyKey(strategy, marketId);
    }

    function _buyKey() internal view returns (bytes32) {
        return RateLimitHelpers.makeBytes32Key(controller.LIMIT_MIDNIGHT_BUY(), marketId);
    }

    function _setLimits(uint256 maxAmount) internal {
        vm.startPrank(admin);
        rateLimits.setRateLimitData(_strategyKey(), maxAmount, 0);
        rateLimits.setRateLimitData(_buyKey(),      maxAmount, 0);
        vm.stopPrank();
    }

    // Exactly what Midnight pays on a maker buy: floor(units * tickToPrice(tick) / WAD).
    function _honestAssets(uint256 units, uint16 tick) internal pure returns (uint256) {
        return units * MidnightTickLib.tickToPrice(tick) / WAD;
    }

}

contract SetMidnightMakeConfigTests is MidnightMakerTestBase {

    function test_setMidnightMakeConfig_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        controller.setMidnightMakeConfig(marketId, MAX_OFFER_SIZE);
    }

    function test_setMidnightMakeConfig_marketNotOnboarded() public {
        vm.prank(admin);
        vm.expectRevert("MidnightLib/market-not-onboarded");
        controller.setMidnightMakeConfig(marketId, MAX_OFFER_SIZE);
    }

    function test_setMidnightMakeConfig_maxOfferSizeOutOfBounds() public {
        _onboardTake();

        vm.prank(admin);
        vm.expectRevert("MidnightLib/max-offer-size-oob");
        controller.setMidnightMakeConfig(marketId, uint256(type(uint128).max) + 1);

        vm.prank(admin);
        controller.setMidnightMakeConfig(marketId, uint256(type(uint128).max));
    }

    function test_setMidnightMakeConfig_invalidMidnight() public {
        _onboardTake();

        Market memory other = _market();
        other.midnight = makeAddr("otherVenue");

        venue.setMarket(marketId, other);

        vm.prank(admin);
        vm.expectRevert("MidnightLib/invalid-midnight");
        controller.setMidnightMakeConfig(marketId, MAX_OFFER_SIZE);
    }

    function test_setMidnightMakeConfig_maturityOutOfBounds() public {
        _onboardTake();

        Market memory far = _market();
        far.maturity = uint256(type(uint48).max) + 1;

        venue.setMarket(marketId, far);

        vm.prank(admin);
        vm.expectRevert("MidnightLib/maturity-oob");
        controller.setMidnightMakeConfig(marketId, MAX_OFFER_SIZE);
    }

    function test_setMidnightMakeConfig_marketNotCreatedOnVenue() public {
        _onboardTake();

        MockMidnightVenue fresh = new MockMidnightVenue();

        ForeignController other = new ForeignController(
            admin,
            address(proxy),
            address(rateLimits),
            makeAddr("psm"),
            makeAddr("usdc"),
            makeAddr("cctp"),
            makeAddr("pendleRouter"),
            makeAddr("uniswapV3Router"),
            makeAddr("uniswapV3PositionManager"),
            address(fresh)
        );

        vm.startPrank(admin);
        other.setMidnightMarketConfig(
            marketId, MAX_BUY_TICK, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, type(uint128).max
        );

        vm.expectRevert("MockMidnight/market-not-created");
        other.setMidnightMakeConfig(marketId, MAX_OFFER_SIZE);
        vm.stopPrank();
    }

    function test_setMidnightMakeConfig() public {
        _onboardTake();

        MidnightLib.MarketConfig memory config = controller.midnightMarketConfigs(marketId);

        assertEq(config.maturity,     0);
        assertEq(config.maxOfferSize, 0);
        assertEq(config.loanToken,    address(0));

        vm.prank(admin);
        vm.expectEmit(address(controller));
        emit MidnightMakeConfigSet(marketId, address(loanToken), maturity, MAX_OFFER_SIZE);
        controller.setMidnightMakeConfig(marketId, MAX_OFFER_SIZE);

        config = controller.midnightMarketConfigs(marketId);

        assertEq(config.maturity,     maturity);
        assertEq(config.maxOfferSize, MAX_OFFER_SIZE);
        assertEq(config.loanToken,    address(loanToken));
    }

    function test_setMidnightMakeConfig_zeroDisablesMake() public {
        _onboardTake();
        _enableMake();

        vm.prank(admin);
        controller.setMidnightMakeConfig(marketId, 0);

        assertEq(controller.midnightMarketConfigs(marketId).maxOfferSize, 0);
    }

    function test_setMidnightMarketConfig_preservesMakeConfig() public {
        _onboardTake();
        _enableMake();

        vm.prank(admin);
        controller.setMidnightMarketConfig(
            marketId, MAX_BUY_TICK - 1, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, type(uint128).max
        );

        MidnightLib.MarketConfig memory config = controller.midnightMarketConfigs(marketId);

        assertEq(config.maxBuyTick,   MAX_BUY_TICK - 1);
        assertEq(config.maturity,     maturity);
        assertEq(config.maxOfferSize, MAX_OFFER_SIZE);
        assertEq(config.loanToken,    address(loanToken));
    }

}

contract SetMidnightGroupsTests is MidnightMakerTestBase {

    function test_setMidnightGroups_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        controller.setMidnightGroups(marketId, bytes32("buy"), bytes32("sell"));
    }

    function test_setMidnightGroups() public {
        MidnightLib.OfferGroups memory groups = controller.midnightOfferGroups(marketId);

        assertEq(groups.buyGroup,  bytes32(0));
        assertEq(groups.sellGroup, bytes32(0));

        vm.prank(admin);
        vm.expectEmit(address(controller));
        emit MidnightGroupsSet(marketId, bytes32("buy"), bytes32("sell"));
        controller.setMidnightGroups(marketId, bytes32("buy"), bytes32("sell"));

        groups = controller.midnightOfferGroups(marketId);

        assertEq(groups.buyGroup,  bytes32("buy"));
        assertEq(groups.sellGroup, bytes32("sell"));

        groups = controller.midnightOfferGroups(keccak256("otherMarket"));

        assertEq(groups.buyGroup,  bytes32(0));
        assertEq(groups.sellGroup, bytes32(0));
    }

    function test_setMidnightGroups_directionsAreIndependent() public {
        vm.startPrank(admin);
        controller.setMidnightGroups(marketId, bytes32("buy"), bytes32("sell"));
        controller.setMidnightGroups(marketId, bytes32("buy2"), bytes32("sell"));
        vm.stopPrank();

        MidnightLib.OfferGroups memory groups = controller.midnightOfferGroups(marketId);

        assertEq(groups.buyGroup,  bytes32("buy2"));
        assertEq(groups.sellGroup, bytes32("sell"));
    }

}

contract SetMidnightRatifierAuthorizationTests is MidnightMakerTestBase {

    function test_setMidnightRatifierAuthorization_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        controller.setMidnightRatifierAuthorization(ratifier, true);
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

contract CancelMidnightOfferGroupTests is MidnightMakerTestBase {

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

}

contract MidnightStrategyKeyTests is MidnightMakerTestBase {

    function test_midnightStrategyKey_matchesHelperDerivation() public view {
        assertEq(
            controller.midnightStrategyKey(strategy, marketId),
            RateLimitHelpers.makeAddressBytes32Key(
                controller.LIMIT_MIDNIGHT_STRATEGY(), strategy, marketId
            )
        );
    }

    function test_midnightStrategyKey_isPairScoped() public {
        bytes32 key = controller.midnightStrategyKey(strategy, marketId);

        assertTrue(key != controller.midnightStrategyKey(makeAddr("other"), marketId));
        assertTrue(key != controller.midnightStrategyKey(strategy, keccak256("otherMarket")));
    }

}

contract FundMidnightFillTests is MidnightMakerTestBase {

    uint256 constant UNITS = 1_000e18;

    function setUp() public override {
        super.setUp();

        _onboardTake();
        _enableMake();

        loanToken.mint(address(proxy), 10_000_000e18);
    }

    function test_fundMidnightFill_makeNotEnabled() public {
        vm.prank(admin);
        controller.setMidnightMakeConfig(marketId, 0);

        _setLimits(MAX_OFFER_SIZE);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/make-not-enabled");
        controller.fundMidnightFill(marketId, 1, UNITS);
    }

    function test_fundMidnightFill_strategyNotKeyed() public {
        vm.prank(strategy);
        vm.expectRevert("MidnightLib/strategy-not-keyed");
        controller.fundMidnightFill(marketId, 1, UNITS);
    }

    function test_fundMidnightFill_keyIsPairScoped() public {
        bytes32 otherKey = controller.midnightStrategyKey(strategy, keccak256("otherMarket"));

        vm.prank(admin);
        rateLimits.setRateLimitData(otherKey, MAX_OFFER_SIZE, 0);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/strategy-not-keyed");
        controller.fundMidnightFill(marketId, 1, UNITS);
    }

    function test_fundMidnightFill_lossFactorTooHigh() public {
        _setLimits(MAX_OFFER_SIZE);

        vm.prank(admin);
        controller.setMidnightMarketConfig(
            marketId, MAX_BUY_TICK, MIN_SELL_TICK, 0, MAX_SELL_YIELD, 0, 100
        );

        venue.setLossFactor(marketId, 101);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/loss-factor-too-high");
        controller.fundMidnightFill(marketId, 1, UNITS);

        venue.setLossFactor(marketId, 100);

        vm.prank(strategy);
        controller.fundMidnightFill(marketId, 1, UNITS);
    }

    function test_fundMidnightFill_honestFillAtTheBound() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.prank(strategy);
        controller.fundMidnightFill(marketId, assets, UNITS);

        assertEq(loanToken.balanceOf(strategy), assets);
    }

    function test_fundMidnightFill_oneTickTooExpensive() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK + 1);

        assertGt(assets, _honestAssets(UNITS, MAX_BUY_TICK));

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/fill-price-too-high");
        controller.fundMidnightFill(marketId, assets, UNITS);
    }

    function test_fundMidnightFill_oneWeiOverTheBound() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/fill-price-too-high");
        controller.fundMidnightFill(marketId, assets + 1, UNITS);
    }

    function test_fundMidnightFill_yieldBoundCanBind() public {
        _setLimits(MAX_OFFER_SIZE);

        vm.prank(admin);
        controller.setMidnightMarketConfig(
            marketId, MAX_BUY_TICK, MIN_SELL_TICK, 5000, MAX_SELL_YIELD, 0, type(uint128).max
        );

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.prank(strategy);
        vm.expectRevert("MidnightLib/fill-price-too-high");
        controller.fundMidnightFill(marketId, assets, UNITS);
    }

    function test_fundMidnightFill_decrementsBothKeys() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        assertEq(rateLimits.getCurrentRateLimit(_strategyKey()), MAX_OFFER_SIZE);
        assertEq(rateLimits.getCurrentRateLimit(_buyKey()),      MAX_OFFER_SIZE);

        vm.prank(strategy);
        controller.fundMidnightFill(marketId, assets, UNITS);

        assertEq(rateLimits.getCurrentRateLimit(_strategyKey()), MAX_OFFER_SIZE - assets);
        assertEq(rateLimits.getCurrentRateLimit(_buyKey()),      MAX_OFFER_SIZE - assets);
    }

    function test_fundMidnightFill_strategyLimitBinds() public {
        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.startPrank(admin);
        rateLimits.setRateLimitData(_strategyKey(), assets - 1, 0);
        rateLimits.setRateLimitData(_buyKey(),      MAX_OFFER_SIZE, 0);
        vm.stopPrank();

        vm.prank(strategy);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        controller.fundMidnightFill(marketId, assets, UNITS);
    }

    function test_fundMidnightFill_buyLimitBinds() public {
        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.startPrank(admin);
        rateLimits.setRateLimitData(_strategyKey(), MAX_OFFER_SIZE, 0);
        rateLimits.setRateLimitData(_buyKey(),      assets - 1, 0);
        vm.stopPrank();

        vm.prank(strategy);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        controller.fundMidnightFill(marketId, assets, UNITS);
    }

    function test_fundMidnightFill_paysTheCallerOnly() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets   = _honestAssets(UNITS, MAX_BUY_TICK);
        uint256 proxyPre = loanToken.balanceOf(address(proxy));

        vm.prank(strategy);
        controller.fundMidnightFill(marketId, assets, UNITS);

        assertEq(loanToken.balanceOf(strategy),       assets);
        assertEq(loanToken.balanceOf(address(proxy)), proxyPre - assets);
        assertEq(loanToken.balanceOf(ratifier),       0);
    }

    function test_fundMidnightFill_needsNoRole() public {
        address keyed    = makeAddr("anotherStrategy");
        bytes32 keyedKey = controller.midnightStrategyKey(keyed, marketId);
        bytes32 buyKey   = _buyKey();

        vm.startPrank(admin);
        rateLimits.setRateLimitData(keyedKey, MAX_OFFER_SIZE, 0);
        rateLimits.setRateLimitData(buyKey,   MAX_OFFER_SIZE, 0);
        vm.stopPrank();

        assertFalse(controller.hasRole(RELAYER, keyed));

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.prank(keyed);
        controller.fundMidnightFill(marketId, assets, UNITS);

        assertEq(loanToken.balanceOf(keyed), assets);
    }

    function test_fundMidnightFill_emitsFunded() public {
        _setLimits(MAX_OFFER_SIZE);

        uint256 assets = _honestAssets(UNITS, MAX_BUY_TICK);

        vm.prank(strategy);
        vm.expectEmit(address(controller));
        emit MidnightFillFunded(marketId, strategy, assets, UNITS);
        controller.fundMidnightFill(marketId, assets, UNITS);
    }

    function testFuzz_fundMidnightFill_honestFillNeverTrips(uint256 units, uint16 tick) public {
        units = bound(units, 1, 1_000_000e18);
        tick  = uint16(bound(tick, 0, MAX_BUY_TICK));

        _setLimits(type(uint128).max);

        uint256 assets = _honestAssets(units, tick);

        vm.prank(strategy);
        controller.fundMidnightFill(marketId, assets, units);

        assertEq(loanToken.balanceOf(strategy), assets);
    }

}
