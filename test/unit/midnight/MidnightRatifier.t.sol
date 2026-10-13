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
        ( bytes32 buyGroup, bytes32 sellGroup )
            = IForeignControllerLike(address(controller)).midnightOfferGroups(marketId);

        assertEq(buyGroup,  BUY_GROUP);
        assertEq(sellGroup, SELL_GROUP);
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

    function test_vector_offerTypehash() public view {
        assertEq(
            ratifier.OFFER_TYPEHASH(),
            0xc55435cccba59b4cd8469c72337e53a659ead153107662471386b052c92268a7
        );
    }

    function test_vector_domainTypehash() public view {
        assertEq(
            ratifier.DOMAIN_TYPEHASH(),
            0xd87cd6ef79d4e2b95e15ce8abf732db51ec771f1ca2edccf22a46c729ac56472
        );
    }

    function test_vector_marketId() public pure {
        assertEq(
            MidnightIdLib.toId(_vectorMarket()),
            0xcac3c8dd212531da67de90f011c76cd5d2e4498d504203c878763b8a25367ee9
        );
    }

    function test_vector_domainSeparator() public view {
        assertEq(
            ratifier.DOMAIN_SEPARATOR(),
            0xafbda2149aff51065c80b739ebe32ea6c5445f2ea9c45dfa4c9f545611619b9f
        );
    }

    function test_vector_digest() public view {
        assertEq(
            ratifier.hashOffer(_vectorOffer()),
            0xb2434cd92d66ecc14a5223c30b63343a94585ffb28705ec8a7d7fcfdcb94a4cf
        );
    }

    function test_vector_domainSeparatorTracksChainId() public {
        bytes32 onBase = ratifier.DOMAIN_SEPARATOR();

        vm.chainId(1);

        assertTrue(ratifier.DOMAIN_SEPARATOR() != onBase);
    }

}
