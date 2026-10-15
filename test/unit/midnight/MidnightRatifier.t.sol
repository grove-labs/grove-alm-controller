// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import "forge-std/Test.sol";

import { ERC20Mock } from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import { ALMProxy }          from "../../../src/ALMProxy.sol";
import { ForeignController } from "../../../src/ForeignController.sol";
import { RateLimits }        from "../../../src/RateLimits.sol";

import { IForeignControllerLike, MidnightRatifier } from "../../../src/MidnightRatifier.sol";

import { MidnightLib } from "../../../src/libraries/MidnightLib.sol";

import { CollateralParams, Market, Offer } from "../../../src/interfaces/MidnightInterfaces.sol";

import { MidnightIdLib }   from "../../../src/libraries/midnight/MidnightIdLib.sol";
import { MAX_TICK, MidnightTickLib } from "../../../src/libraries/midnight/MidnightTickLib.sol";
import {
    COLLATERAL_PARAMS_TYPEHASH,
    MARKET_TYPEHASH,
    OFFER_TYPEHASH,
    MidnightHashLib
} from "../../../src/libraries/midnight/MidnightHashLib.sol";

import { UnitTestBase } from "../UnitTestBase.t.sol";

contract MockMidnightVenue {

    mapping(bytes32 => bytes) internal _markets;

    function setMarket(bytes32 id, Market memory market) external {
        _markets[id] = abi.encode(market);
    }

    function toMarket(bytes32 id) external view returns (Market memory) {
        return abi.decode(_markets[id], (Market));
    }

    function setIsAuthorized(address, bool, address) external {}

    function setConsumed(bytes32, uint128, address) external {}

    function lossFactor(bytes32) external pure returns (uint128) {
        return 0;
    }

}

contract MidnightRatifierTestBase is UnitTestBase {

    uint16 constant MAX_BUY_TICK       = 4000;
    uint16 constant MIN_SELL_TICK      = 3000;
    uint16 constant MIN_BUY_YIELD      = 0;
    uint16 constant MAX_SELL_YIELD     = 100;
    uint16 constant MAX_CONTINUOUS_FEE = 250;

    uint256 constant BUY_TICK  = 4000;
    uint256 constant SELL_TICK = 4350;

    uint256 constant MAX_OFFER_SIZE   = 1_000_000e18;
    uint256 constant MAX_OFFER_WINDOW = 7 days;

    bytes32 constant BUY_GROUP  = keccak256("buyGroup");
    bytes32 constant SELL_GROUP = keccak256("sellGroup");

    ALMProxy          proxy;
    RateLimits        rateLimits;
    ForeignController controller;
    MockMidnightVenue venue;
    MidnightRatifier  ratifier;
    ERC20Mock         loanToken;

    address strategy = makeAddr("strategy");
    address taker    = makeAddr("taker");

    address quoter;
    uint256 quoterKey;

    bytes32 marketId;
    uint256 maturity;

    function setUp() public virtual {
        ( quoter, quoterKey ) = makeAddrAndKey("quoter");

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

        ratifier = new MidnightRatifier(
            admin,
            address(venue),
            address(proxy),
            address(controller),
            address(rateLimits),
            quoter,
            MAX_OFFER_WINDOW
        );

        maturity = block.timestamp + 365 days;
        marketId = MidnightIdLib.toId(_market());

        venue.setMarket(marketId, _market());

        vm.startPrank(admin);
        proxy.grantRole(proxy.CONTROLLER(), address(controller));
        rateLimits.grantRole(rateLimits.CONTROLLER(), address(controller));

        controller.setMidnightMarketConfig(
            marketId,
            MAX_BUY_TICK,
            MIN_SELL_TICK,
            MIN_BUY_YIELD,
            MAX_SELL_YIELD,
            MAX_CONTINUOUS_FEE,
            type(uint128).max
        );
        controller.setMidnightMakeConfig(marketId, MAX_OFFER_SIZE);
        controller.setMidnightGroups(marketId, BUY_GROUP, SELL_GROUP);

        rateLimits.setRateLimitData(
            controller.midnightStrategyKey(strategy, marketId), MAX_OFFER_SIZE, 0
        );
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

    function _feeCapCeiling() internal pure returns (uint256) {
        return MidnightLib.continuousFeePerSecond(MAX_CONTINUOUS_FEE);
    }

    function _buyOffer() internal view returns (Offer memory) {
        return Offer({
            market                  : _market(),
            buy                     : true,
            maker                   : address(proxy),
            start                   : block.timestamp,
            expiry                  : block.timestamp + 1 days,
            tick                    : BUY_TICK,
            group                   : BUY_GROUP,
            callback                : strategy,
            callbackData            : "",
            receiverIfMakerIsSeller : address(0),
            ratifier                : address(ratifier),
            reduceOnly              : false,
            maxUnits                : 0,
            maxAssets               : uint128(MAX_OFFER_SIZE),
            continuousFeeCap        : _feeCapCeiling()
        });
    }

    function _sellOffer() internal view returns (Offer memory) {
        return Offer({
            market                  : _market(),
            buy                     : false,
            maker                   : address(proxy),
            start                   : block.timestamp,
            expiry                  : block.timestamp + 1 days,
            tick                    : SELL_TICK,
            group                   : SELL_GROUP,
            callback                : address(0),
            callbackData            : "",
            receiverIfMakerIsSeller : address(proxy),
            ratifier                : address(ratifier),
            reduceOnly              : true,
            maxUnits                : 0,
            maxAssets               : uint128(MAX_OFFER_SIZE),
            continuousFeeCap        : _feeCapCeiling()
        });
    }

    function _sign(Offer memory offer) internal view returns (bytes memory) {
        ( uint8 v, bytes32 r, bytes32 s ) = vm.sign(quoterKey, ratifier.hashOffer(offer));

        return abi.encodePacked(r, s, v);
    }

    function _ratify(Offer memory offer) internal view returns (bytes32) {
        return ratifier.isRatified(offer, _sign(offer), taker);
    }

    // The signature must be produced before expectRevert, since hashOffer is itself a call.
    function _expectRatifyRevert(Offer memory offer, bytes memory reason) internal {
        bytes memory sig = _sign(offer);

        vm.expectRevert(reason);
        ratifier.isRatified(offer, sig, taker);
    }

    function _expectTamperedRevert(Offer memory signed, Offer memory mutated) internal {
        bytes memory sig = _sign(signed);

        vm.expectRevert("MidnightRatifier/invalid-signature");
        ratifier.isRatified(mutated, sig, taker);
    }

}

contract ConstructorTests is MidnightRatifierTestBase {

    function test_constructor() public view {
        assertEq(ratifier.midnight(),            address(venue));
        assertEq(ratifier.proxy(),               address(proxy));
        assertEq(ratifier.controller(),           address(controller));
        assertEq(address(ratifier.rateLimits()), address(rateLimits));
        assertEq(ratifier.quoter(),              quoter);
        assertEq(ratifier.maxOfferWindow(),      MAX_OFFER_WINDOW);

        assertTrue(ratifier.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_constructor_callbackSuccessMatchesProtocol() public view {
        assertEq(
            ratifier.CALLBACK_SUCCESS(),
            0x7f87788ea698181ea4d28d1576d0ba4fc92c0dbe5bf75b43692af2ce91dbaea2
        );
    }

    function test_constructor_invalidAdmin() public {
        vm.expectRevert("MidnightRatifier/invalid-admin");
        new MidnightRatifier(
            address(0), address(venue), address(proxy), address(controller), address(rateLimits),
            quoter, MAX_OFFER_WINDOW
        );
    }

    function test_constructor_invalidMidnight() public {
        vm.expectRevert("MidnightRatifier/invalid-midnight");
        new MidnightRatifier(
            admin, address(0), address(proxy), address(controller), address(rateLimits),
            quoter, MAX_OFFER_WINDOW
        );
    }

    function test_constructor_invalidProxy() public {
        vm.expectRevert("MidnightRatifier/invalid-proxy");
        new MidnightRatifier(
            admin, address(venue), address(0), address(controller), address(rateLimits),
            quoter, MAX_OFFER_WINDOW
        );
    }

    function test_constructor_invalidController() public {
        vm.expectRevert("MidnightRatifier/invalid-controller");
        new MidnightRatifier(
            admin, address(venue), address(proxy), address(0), address(rateLimits),
            quoter, MAX_OFFER_WINDOW
        );
    }

    function test_constructor_invalidRateLimits() public {
        vm.expectRevert("MidnightRatifier/invalid-rate-limits");
        new MidnightRatifier(
            admin, address(venue), address(proxy), address(controller), address(0),
            quoter, MAX_OFFER_WINDOW
        );
    }

    function test_constructor_invalidQuoter() public {
        vm.expectRevert("MidnightRatifier/invalid-quoter");
        new MidnightRatifier(
            admin, address(venue), address(proxy), address(controller), address(rateLimits),
            address(0), MAX_OFFER_WINDOW
        );
    }

    function test_constructor_invalidOfferWindow() public {
        vm.expectRevert("MidnightRatifier/invalid-offer-window");
        new MidnightRatifier(
            admin, address(venue), address(proxy), address(controller), address(rateLimits),
            quoter, 0
        );
    }

}

contract SetQuoterTests is MidnightRatifierTestBase {

    event QuoterSet(address indexed oldQuoter, address indexed newQuoter);

    function test_setQuoter_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", address(this), DEFAULT_ADMIN_ROLE
        ));
        ratifier.setQuoter(makeAddr("newQuoter"));
    }

    function test_setQuoter_invalidQuoter() public {
        vm.prank(admin);
        vm.expectRevert("MidnightRatifier/invalid-quoter");
        ratifier.setQuoter(address(0));
    }

    function test_setQuoter() public {
        address newQuoter = makeAddr("newQuoter");

        vm.prank(admin);
        vm.expectEmit(address(ratifier));
        emit QuoterSet(quoter, newQuoter);
        ratifier.setQuoter(newQuoter);

        assertEq(ratifier.quoter(), newQuoter);
    }

    function test_setQuoter_retiresRestingOffers() public {
        Offer memory offer = _buyOffer();
        bytes  memory sig  = _sign(offer);

        assertEq(ratifier.isRatified(offer, sig, taker), ratifier.CALLBACK_SUCCESS());

        vm.prank(admin);
        ratifier.setQuoter(makeAddr("newQuoter"));

        vm.expectRevert("MidnightRatifier/invalid-signature");
        ratifier.isRatified(offer, sig, taker);
    }

}

contract IsRatifiedBuyTests is MidnightRatifierTestBase {

    function test_isRatified_buy() public view {
        assertEq(_ratify(_buyOffer()), ratifier.CALLBACK_SUCCESS());
    }

    function test_isRatified_buy_makerNotProxy() public {
        Offer memory offer = _buyOffer();
        offer.maker = makeAddr("attacker");

        _expectRatifyRevert(offer, "MidnightRatifier/maker-not-proxy");
    }

    function test_isRatified_buy_ratifierMismatch() public {
        Offer memory offer = _buyOffer();
        offer.ratifier = makeAddr("otherRatifier");

        _expectRatifyRevert(offer, "MidnightRatifier/ratifier-mismatch");
    }

    function test_isRatified_buy_invalidMidnight() public {
        Offer memory offer = _buyOffer();
        offer.market.midnight = makeAddr("otherMidnight");

        _expectRatifyRevert(offer, "MidnightRatifier/invalid-midnight");
    }

    function test_isRatified_buy_receiverMustBeZero() public {
        Offer memory offer = _buyOffer();
        offer.receiverIfMakerIsSeller = address(proxy);

        _expectRatifyRevert(offer, "MidnightRatifier/invalid-receiver");
    }

    function test_isRatified_buy_wrongSigner() public {
        ( , uint256 otherKey ) = makeAddrAndKey("notTheQuoter");

        Offer memory offer = _buyOffer();

        ( uint8 v, bytes32 r, bytes32 s ) = vm.sign(otherKey, ratifier.hashOffer(offer));

        vm.expectRevert("MidnightRatifier/invalid-signature");
        ratifier.isRatified(offer, abi.encodePacked(r, s, v), taker);
    }

    function test_isRatified_buy_malformedSignature() public {
        vm.expectRevert("MidnightRatifier/invalid-signature");
        ratifier.isRatified(_buyOffer(), hex"dead", taker);
    }

    function test_isRatified_buy_signatureIsCheckedBeforeEveryOtherGuard() public {
        Offer memory offer = _buyOffer();

        offer.maker            = makeAddr("notTheProxy");
        offer.continuousFeeCap = _feeCapCeiling() + 1;
        offer.tick             = MAX_BUY_TICK + 1;
        offer.group            = keccak256("notTheBuyGroup");

        vm.expectRevert("MidnightRatifier/invalid-signature");
        ratifier.isRatified(offer, hex"dead", taker);
    }

    function test_isRatified_buy_makeNotEnabled() public {
        vm.prank(admin);
        controller.setMidnightMakeConfig(marketId, 0);

        _expectRatifyRevert(_buyOffer(), "MidnightRatifier/make-not-enabled");
    }

    function test_isRatified_buy_offerExpired() public {
        Offer memory offer = _buyOffer();

        bytes memory sig = _sign(offer);

        vm.warp(offer.expiry + 1);

        vm.expectRevert("MidnightRatifier/offer-expired");
        ratifier.isRatified(offer, sig, taker);
    }

    function test_isRatified_buy_invalidOfferWindow() public {
        Offer memory offer = _buyOffer();
        offer.start  = block.timestamp + 2 days;
        offer.expiry = block.timestamp + 1 days;

        _expectRatifyRevert(offer, "MidnightRatifier/invalid-offer-window");
    }

    function test_isRatified_buy_offerWindowTooLong() public {
        Offer memory offer = _buyOffer();
        offer.expiry = offer.start + MAX_OFFER_WINDOW + 1;

        _expectRatifyRevert(offer, "MidnightRatifier/offer-window-too-long");
    }

    function test_isRatified_buy_windowExactlyAtTheBound() public view {
        Offer memory offer = _buyOffer();
        offer.expiry = offer.start + MAX_OFFER_WINDOW;

        assertEq(_ratify(offer), ratifier.CALLBACK_SUCCESS());
    }

    function test_isRatified_buy_offerTooLargeByAssets() public {
        Offer memory offer = _buyOffer();
        offer.maxAssets = uint128(MAX_OFFER_SIZE + 1);

        _expectRatifyRevert(offer, "MidnightRatifier/offer-too-large");
    }

    function test_isRatified_buy_offerTooLargeByUnits() public {
        Offer memory offer = _buyOffer();
        offer.maxAssets = 0;
        offer.maxUnits  = uint128(MAX_OFFER_SIZE + 1);

        _expectRatifyRevert(offer, "MidnightRatifier/offer-too-large");
    }

    function test_isRatified_buy_sizeExactlyAtTheBound() public view {
        Offer memory offer = _buyOffer();
        offer.maxAssets = uint128(MAX_OFFER_SIZE);

        assertEq(_ratify(offer), ratifier.CALLBACK_SUCCESS());
    }

    function test_isRatified_buy_feeCapTooHigh() public {
        Offer memory offer = _buyOffer();
        offer.continuousFeeCap = _feeCapCeiling() + 1;

        _expectRatifyRevert(offer, "MidnightRatifier/fee-cap-too-high");
    }

    function test_isRatified_buy_groupMismatch() public {
        Offer memory offer = _buyOffer();
        offer.group = SELL_GROUP;

        _expectRatifyRevert(offer, "MidnightRatifier/group-mismatch");
    }

    function test_isRatified_buy_groupNotDesignated() public {
        vm.prank(admin);
        controller.setMidnightGroups(marketId, bytes32(0), SELL_GROUP);

        Offer memory offer = _buyOffer();
        offer.group = bytes32(0);

        _expectRatifyRevert(offer, "MidnightRatifier/group-not-designated");
    }

    function test_isRatified_buy_tickTooHigh() public {
        Offer memory offer = _buyOffer();
        offer.tick = MAX_BUY_TICK + 1;

        _expectRatifyRevert(offer, "MidnightRatifier/tick-too-high");
    }

    function test_isRatified_buy_priceTooHigh() public {
        vm.prank(admin);
        controller.setMidnightMarketConfig(
            marketId, MAX_BUY_TICK, MIN_SELL_TICK, 1000, MAX_SELL_YIELD, MAX_CONTINUOUS_FEE,
            type(uint128).max
        );

        _expectRatifyRevert(_buyOffer(), "MidnightRatifier/price-too-high");
    }

    function test_isRatified_buy_callbackNotKeyed() public {
        Offer memory offer = _buyOffer();
        offer.callback = makeAddr("unkeyedStrategy");

        _expectRatifyRevert(offer, "MidnightRatifier/callback-not-keyed");
    }

    function test_isRatified_buy_callbackKeyIsPairScoped() public {
        bytes32 otherKey = controller.midnightStrategyKey(strategy, keccak256("otherMarket"));
        bytes32 thisKey  = controller.midnightStrategyKey(strategy, marketId);

        vm.startPrank(admin);
        rateLimits.setRateLimitData(otherKey, MAX_OFFER_SIZE, 0);
        rateLimits.setRateLimitData(thisKey,  0, 0);
        vm.stopPrank();

        _expectRatifyRevert(_buyOffer(), "MidnightRatifier/callback-not-keyed");
    }

}

contract IsRatifiedSellTests is MidnightRatifierTestBase {

    function test_isRatified_sell() public view {
        assertEq(_ratify(_sellOffer()), ratifier.CALLBACK_SUCCESS());
    }

    function test_isRatified_sell_receiverMustBeProxy() public {
        Offer memory offer = _sellOffer();
        offer.receiverIfMakerIsSeller = makeAddr("attacker");

        _expectRatifyRevert(offer, "MidnightRatifier/invalid-receiver");
    }

    function test_isRatified_sell_receiverZeroIsRejected() public {
        Offer memory offer = _sellOffer();
        offer.receiverIfMakerIsSeller = address(0);

        _expectRatifyRevert(offer, "MidnightRatifier/invalid-receiver");
    }

    function test_isRatified_sell_notReduceOnly() public {
        Offer memory offer = _sellOffer();
        offer.reduceOnly = false;

        _expectRatifyRevert(offer, "MidnightRatifier/sell-not-reduce-only");
    }

    function test_isRatified_sell_tickTooLow() public {
        Offer memory offer = _sellOffer();
        offer.tick = MIN_SELL_TICK - 1;

        _expectRatifyRevert(offer, "MidnightRatifier/tick-too-low");
    }

    function test_isRatified_sell_priceTooLow() public {
        Offer memory offer = _sellOffer();
        offer.tick = 4250;

        _expectRatifyRevert(offer, "MidnightRatifier/price-too-low");
    }

    function test_isRatified_sell_callbackMustBeZero() public {
        Offer memory offer = _sellOffer();
        offer.callback = strategy;

        _expectRatifyRevert(offer, "MidnightRatifier/callback-must-be-zero");
    }

    function test_isRatified_sell_groupMismatch() public {
        Offer memory offer = _sellOffer();
        offer.group = BUY_GROUP;

        _expectRatifyRevert(offer, "MidnightRatifier/group-mismatch");
    }

    function test_isRatified_sell_groupNotDesignated() public {
        vm.prank(admin);
        controller.setMidnightGroups(marketId, BUY_GROUP, bytes32(0));

        Offer memory offer = _sellOffer();
        offer.group = bytes32(0);

        _expectRatifyRevert(offer, "MidnightRatifier/group-not-designated");
    }

    function _lowestPassingSellTick() internal view returns (uint256) {
        uint256 floor = MidnightLib.minSellPrice(MAX_SELL_YIELD, maturity - block.timestamp, 0);

        for (uint256 tick = MIN_SELL_TICK; tick <= MAX_TICK; ++tick) {
            if (MidnightTickLib.tickToPrice(tick) >= floor) return tick;
        }

        revert("no passing tick");
    }

    function test_isRatified_sell_floorIgnoresTheFeeCeiling() public {
        uint256 boundary = _lowestPassingSellTick();

        Offer memory passing = _sellOffer();
        passing.tick = boundary;

        Offer memory failing = _sellOffer();
        failing.tick = boundary - 1;

        assertEq(_ratify(passing), ratifier.CALLBACK_SUCCESS());
        _expectRatifyRevert(failing, "MidnightRatifier/price-too-low");

        vm.prank(admin);
        controller.setMidnightMarketConfig(
            marketId,
            MAX_BUY_TICK,
            MIN_SELL_TICK,
            MIN_BUY_YIELD,
            MAX_SELL_YIELD,
            MAX_CONTINUOUS_FEE * 10,
            type(uint128).max
        );

        assertEq(_lowestPassingSellTick(), boundary);

        assertEq(_ratify(passing), ratifier.CALLBACK_SUCCESS());
        _expectRatifyRevert(failing, "MidnightRatifier/price-too-low");
    }

}

contract SignatureCoverageTests is MidnightRatifierTestBase {

    function test_signatureCovers_start() public {
        Offer memory mutated = _buyOffer();
        mutated.start = block.timestamp - 1;

        _expectTamperedRevert(_buyOffer(), mutated);
    }

    function test_signatureCovers_expiry() public {
        Offer memory mutated = _buyOffer();
        mutated.expiry = block.timestamp + 2 days;

        _expectTamperedRevert(_buyOffer(), mutated);
    }

    function test_signatureCovers_tick() public {
        Offer memory mutated = _buyOffer();
        mutated.tick = BUY_TICK - 1;

        _expectTamperedRevert(_buyOffer(), mutated);
    }

    function test_signatureCovers_group() public {
        Offer memory mutated = _buyOffer();
        mutated.group = keccak256("someOtherGroup");

        _expectTamperedRevert(_buyOffer(), mutated);
    }

    function test_signatureCovers_callback() public {
        Offer memory mutated = _buyOffer();
        mutated.callback = makeAddr("otherStrategy");

        _expectTamperedRevert(_buyOffer(), mutated);
    }

    function test_signatureCovers_callbackData() public {
        Offer memory mutated = _buyOffer();
        mutated.callbackData = hex"01";

        _expectTamperedRevert(_buyOffer(), mutated);
    }

    function test_signatureCovers_reduceOnly() public {
        Offer memory mutated = _buyOffer();
        mutated.reduceOnly = true;

        _expectTamperedRevert(_buyOffer(), mutated);
    }

    function test_signatureCovers_maxUnits() public {
        Offer memory mutated = _buyOffer();
        mutated.maxUnits = 1;

        _expectTamperedRevert(_buyOffer(), mutated);
    }

    function test_signatureCovers_maxAssets() public {
        Offer memory mutated = _buyOffer();
        mutated.maxAssets = uint128(MAX_OFFER_SIZE - 1);

        _expectTamperedRevert(_buyOffer(), mutated);
    }

    function test_signatureCovers_continuousFeeCap() public {
        Offer memory mutated = _buyOffer();
        mutated.continuousFeeCap = _feeCapCeiling() - 1;

        _expectTamperedRevert(_buyOffer(), mutated);
    }

    function test_signatureCovers_market() public {
        Offer memory mutated = _buyOffer();
        mutated.market.rcfThreshold = 1;

        _expectTamperedRevert(_buyOffer(), mutated);
    }

}

contract ControllerViewDecodeTests is MidnightRatifierTestBase {

    function test_marketConfigDecodesAsOneStruct() public view {
        MidnightLib.MarketConfig memory config
            = IForeignControllerLike(address(controller)).midnightMarketConfigs(marketId);

        assertEq(config.maxBuyTick,       MAX_BUY_TICK);
        assertEq(config.minSellTick,      MIN_SELL_TICK);
        assertEq(config.minBuyYield,      MIN_BUY_YIELD);
        assertEq(config.maxSellYield,     MAX_SELL_YIELD);
        assertEq(config.maxContinuousFee, MAX_CONTINUOUS_FEE);
        assertEq(config.maxLossFactor,    type(uint128).max);
        assertEq(config.maturity,         maturity);
        assertEq(config.maxOfferSize,     MAX_OFFER_SIZE);
        assertEq(config.loanToken,        address(loanToken));
    }

    function test_offerGroupsDecode() public view {
        MidnightLib.OfferGroups memory groups
            = IForeignControllerLike(address(controller)).midnightOfferGroups(marketId);

        assertEq(groups.buyGroup,  BUY_GROUP);
        assertEq(groups.sellGroup, SELL_GROUP);
    }

    function test_strategyKeyMatchesTheController() public view {
        assertEq(
            IForeignControllerLike(address(controller)).midnightStrategyKey(strategy, marketId),
            controller.midnightStrategyKey(strategy, marketId)
        );
    }

}

contract NeverCallsMidnightTests is MidnightRatifierTestBase {

    function test_isRatified_succeedsWhenMidnightRevertsOnEveryCall() public {
        Offer memory offer = _buyOffer();
        bytes  memory sig  = _sign(offer);

        vm.etch(address(venue), hex"fe");

        assertEq(ratifier.isRatified(offer, sig, taker), ratifier.CALLBACK_SUCCESS());
    }

    function test_isRatified_sellSucceedsWhenMidnightRevertsOnEveryCall() public {
        Offer memory offer = _sellOffer();
        bytes  memory sig  = _sign(offer);

        vm.etch(address(venue), hex"fe");

        assertEq(ratifier.isRatified(offer, sig, taker), ratifier.CALLBACK_SUCCESS());
    }

    function test_hashOffer_succeedsWhenMidnightRevertsOnEveryCall() public {
        Offer memory offer = _buyOffer();

        bytes32 before = ratifier.hashOffer(offer);

        vm.etch(address(venue), hex"fe");

        assertEq(ratifier.hashOffer(offer), before);
    }

    function test_containsNoStateChangingCallOpcode() public view {
        bytes memory code = _strippedCode(address(ratifier));

        uint256 statics;
        uint256 i;

        while (i < code.length) {
            uint8 op = uint8(code[i]);

            // PUSH1..PUSH32: skip the immediate so constants are never read as opcodes.
            if (op >= 0x60 && op <= 0x7F) {
                i += 1 + (op - 0x5F);
                continue;
            }

            assertTrue(op != 0xF1, "CALL present");
            assertTrue(op != 0xF2, "CALLCODE present");
            assertTrue(op != 0xF4, "DELEGATECALL present");
            assertTrue(op != 0xF0, "CREATE present");
            assertTrue(op != 0xF5, "CREATE2 present");
            assertTrue(op != 0xFF, "SELFDESTRUCT present");

            if (op == 0xFA) ++statics;

            ++i;
        }

        // Control: the walk reaches real call opcodes, so the assertions above are not vacuous.
        assertGt(statics, 0);
    }

    // Trailing CBOR metadata is data, not code; walking it finds opcodes that do not exist.
    function _strippedCode(address target) internal view returns (bytes memory stripped) {
        bytes memory raw = target.code;

        uint256 length = (uint256(uint8(raw[raw.length - 2])) << 8) | uint8(raw[raw.length - 1]);

        assertLt(length + 2, raw.length);

        stripped = new bytes(raw.length - length - 2);

        for (uint256 i; i < stripped.length; ++i) stripped[i] = raw[i];
    }

}

contract Eip712VectorTests is Test {

    address constant MIDNIGHT = 0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A;
    address constant RATIFIER = 0x1111111111111111111111111111111111111111;
    address constant PROXY    = 0x2222222222222222222222222222222222222222;
    address constant CALLBACK = 0x3333333333333333333333333333333333333333;
    address constant LOAN     = 0x4444444444444444444444444444444444444444;

    uint256 constant CHAIN_ID = 8453;
    uint256 constant MATURITY = 2000000000;

    MidnightRatifier ratifier;

    function setUp() public {
        vm.chainId(CHAIN_ID);

        deployCodeTo(
            "MidnightRatifier.sol:MidnightRatifier",
            abi.encode(
                address(this),
                MIDNIGHT,
                PROXY,
                makeAddr("controller"),
                makeAddr("rateLimits"),
                makeAddr("quoter"),
                7 days
            ),
            RATIFIER
        );

        ratifier = MidnightRatifier(RATIFIER);
    }

    function _vectorMarket() internal pure returns (Market memory) {
        return Market({
            chainId          : CHAIN_ID,
            midnight         : MIDNIGHT,
            loanToken        : LOAN,
            collateralParams : new CollateralParams[](0),
            maturity         : MATURITY,
            rcfThreshold     : 0,
            enterGate        : address(0),
            liquidatorGate   : address(0)
        });
    }

    function _vectorOffer() internal pure returns (Offer memory) {
        return Offer({
            market                  : _vectorMarket(),
            buy                     : true,
            maker                   : PROXY,
            start                   : 1700000000,
            expiry                  : 1700086400,
            tick                    : 3500,
            group                   : bytes32(uint256(0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)),
            callback                : CALLBACK,
            callbackData            : "",
            receiverIfMakerIsSeller : address(0),
            ratifier                : RATIFIER,
            reduceOnly              : false,
            maxUnits                : 0,
            maxAssets               : 1000000000000000000000,
            continuousFeeCap        : 250
        });
    }

    function _vectorOfferWithCollateral() internal pure returns (Offer memory) {
        CollateralParams[] memory params = new CollateralParams[](2);

        params[0] = CollateralParams({
            token             : 0x5555555555555555555555555555555555555555,
            lltv              : 800000000000000000,
            liquidationCursor : 50000000000000000,
            oracle            : 0x6666666666666666666666666666666666666666
        });
        params[1] = CollateralParams({
            token             : 0x7777777777777777777777777777777777777777,
            lltv              : 900000000000000000,
            liquidationCursor : 60000000000000000,
            oracle            : 0x8888888888888888888888888888888888888888
        });

        Offer memory offer = _vectorOffer();

        offer.market.collateralParams = params;
        offer.buy                     = false;
        offer.tick                    = 4400;
        offer.callback                = address(0);
        offer.callbackData            = hex"deadbeef";
        offer.receiverIfMakerIsSeller = PROXY;
        offer.reduceOnly              = true;
        offer.maxUnits                = 500000000000000000000;
        offer.maxAssets               = 0;

        return offer;
    }

    function test_vector_offerTypehash() public view {
        assertEq(
            ratifier.OFFER_TYPEHASH(),
            0x9905214264a9fb7b6cc1b0e33db7a04687c6e4185a84755d29914314aa9d8906
        );
    }

    function test_vector_domainTypehash() public view {
        assertEq(
            ratifier.DOMAIN_TYPEHASH(),
            0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f
        );
    }

    function test_vector_marketId() public pure {
        assertEq(
            MidnightIdLib.toId(_vectorMarket()),
            0xcac3c8dd212531da67de90f011c76cd5d2e4498d504203c878763b8a25367ee9
        );
    }

    function test_vector_marketHash() public pure {
        assertEq(
            MidnightHashLib.hashMarket(_vectorMarket()),
            0xd0630db03c836b1de748ec0a7ee870a84de4115b40d01b5e719117eab13da93c
        );
    }

    function test_vector_offerStructHash() public pure {
        assertEq(
            MidnightHashLib.hashOffer(_vectorOffer()),
            0x219f7c152077ed914f88f2ead9f3e130b612fe6541345a707b0004efc8f978d6
        );
    }

    function test_vector_domainSeparator() public view {
        assertEq(
            ratifier.DOMAIN_SEPARATOR(),
            0xb0122d94e78afd1c9d2efc7601bdb6e4251263aeef99bbe04ad25536b7cc5ba4
        );
    }

    function test_vector_digest() public view {
        assertEq(
            ratifier.hashOffer(_vectorOffer()),
            0xa7ed3d43992138c3031c9a21cca8bd63d7195765bfeae88dff7b3836fef4680a
        );
    }

    function test_vector_collateralParamsHash() public pure {
        CollateralParams[] memory params = _vectorOfferWithCollateral().market.collateralParams;

        assertEq(
            MidnightHashLib.hashCollateralParams(params[0]),
            0xfe57851550819ded1ddf2368b296e90df1dc7e51c1d43f249aa268cba438e602
        );
        assertEq(
            MidnightHashLib.hashCollateralParams(params[1]),
            0x14860994a350cc64c434021bb33d863f42819b12fdf2815286bf9fd098b80453
        );
    }

    function test_vector_marketHashWithCollateral() public pure {
        assertEq(
            MidnightHashLib.hashMarket(_vectorOfferWithCollateral().market),
            0x0c2602fa60f1264063f83451f6d7596ae70b97ad33b6f2545b6a098068d682c3
        );
    }

    function test_vector_digestWithCollateral() public view {
        assertEq(
            ratifier.hashOffer(_vectorOfferWithCollateral()),
            0xb7c9838990c214ac21db0d7e390998b40f141d9223a0c91385eadda2b4017f27
        );
    }

    function test_vector_typehashesMatchUpstreamTypeStrings() public pure {
        bytes memory collateralParamsType =
            "CollateralParams(address token,uint256 lltv,uint256 liquidationCursor,address oracle)";

        bytes memory marketType =
            "Market(uint256 chainId,address midnight,address loanToken,"
            "CollateralParams[] collateralParams,uint256 maturity,uint256 rcfThreshold,"
            "address enterGate,address liquidatorGate)";

        bytes memory offerType =
            "Offer(Market market,bool buy,address maker,uint256 start,uint256 expiry,uint256 tick,"
            "bytes32 group,address callback,bytes callbackData,address receiverIfMakerIsSeller,"
            "address ratifier,bool reduceOnly,uint128 maxUnits,uint128 maxAssets,"
            "uint256 continuousFeeCap)";

        assertEq(COLLATERAL_PARAMS_TYPEHASH, keccak256(collateralParamsType));
        assertEq(MARKET_TYPEHASH, keccak256(bytes.concat(marketType, collateralParamsType)));
        assertEq(
            OFFER_TYPEHASH,
            keccak256(bytes.concat(offerType, collateralParamsType, marketType))
        );
    }

    function test_vector_domainSeparatorTracksChainId() public {
        bytes32 onBase = ratifier.DOMAIN_SEPARATOR();

        vm.chainId(1);

        assertTrue(ratifier.DOMAIN_SEPARATOR() != onBase);
    }

}
