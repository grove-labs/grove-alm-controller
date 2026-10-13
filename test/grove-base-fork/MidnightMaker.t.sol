// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { MidnightMakerDeploy } from "../../deploy/MidnightMakerDeploy.sol";

import { MidnightRatifier }     from "../../src/MidnightRatifier.sol";
import { ProxyFundingStrategy } from "../../src/ProxyFundingStrategy.sol";

import "./Midnight.t.sol";

contract AttackerRatifier {

    function isRatified(Offer memory, bytes memory, address) external pure returns (bytes32) {
        return keccak256("morpho.midnight.callbackSuccess");
    }

}

contract MidnightMakerTestBase is MidnightTestBase {

    event MidnightFillFunded(
        bytes32 indexed id,
        address indexed strategy,
        uint256 assets,
        uint256 units
    );

    // The ratifier prices against the configured fee ceiling, so its buy bound is the tighter one.
    uint16 constant MAKER_BUY_TICK = TICK_98;

    uint256 constant MAX_OFFER_WINDOW = 7 days;
    uint256 constant MAX_OFFER_SIZE   = 2_000_000e18;
    uint256 constant STRATEGY_LIMIT   = 5_000_000e18;

    bytes32 constant BUY_GROUP  = "grove-midnight-buy";
    bytes32 constant SELL_GROUP = "grove-midnight-sell";

    MidnightRatifier     makerRatifier;
    ProxyFundingStrategy strategy;

    address quoter;
    uint256 quoterKey;

    address taker = makeAddr("taker");

    bytes32 strategyKey;

    function setUp() public virtual override {
        super.setUp();

        ( quoter, quoterKey ) = makeAddrAndKey("quoter");

        makerRatifier = MidnightRatifier(MidnightMakerDeploy.deployRatifier(
            GROVE_EXECUTOR,
            MIDNIGHT,
            address(almProxy),
            address(foreignController),
            address(rateLimits),
            quoter,
            MAX_OFFER_WINDOW
        ));

        strategy = ProxyFundingStrategy(MidnightMakerDeploy.deployFundingStrategy(
            MIDNIGHT, address(almProxy), address(foreignController)
        ));

        strategyKey = foreignController.midnightStrategyKey(address(strategy), marketId);

        vm.startPrank(GROVE_EXECUTOR);
        foreignController.setMidnightMakeConfig(marketId, MAX_OFFER_SIZE);
        foreignController.setMidnightGroups(marketId, BUY_GROUP, SELL_GROUP);
        foreignController.setMidnightRatifierAuthorization(address(makerRatifier), true);
        rateLimits.setRateLimitData(strategyKey, STRATEGY_LIMIT, STRATEGY_LIMIT / 1 days);
        vm.stopPrank();

        // Selling units into our buy offer puts the taker short, which Midnight collateralises.
        collateralToken.mint(taker, 100_000_000 * collateralUnit);
        loanToken.mint(taker, 100_000_000 * loanUnit);

        vm.startPrank(taker);
        loanToken.approve(MIDNIGHT, type(uint256).max);
        collateralToken.approve(MIDNIGHT, type(uint256).max);
        harness.supplyCollateral(market, 0, 10_000_000 * collateralUnit, taker);
        vm.stopPrank();
    }

    /**********************************************************************************************/
    /*** Test helpers                                                                           ***/
    /**********************************************************************************************/

    function _makerOffer(bool buy, uint256 tick, uint128 maxUnits)
        internal view returns (Offer memory)
    {
        return Offer({
            market                  : market,
            buy                     : buy,
            maker                   : address(almProxy),
            start                   : block.timestamp,
            expiry                  : block.timestamp + 1 days,
            tick                    : tick,
            group                   : buy ? BUY_GROUP : SELL_GROUP,
            callback                : buy ? address(strategy) : address(0),
            callbackData            : new bytes(0),
            receiverIfMakerIsSeller : buy ? address(0) : address(almProxy),
            ratifier                : address(makerRatifier),
            reduceOnly              : !buy,
            maxUnits                : maxUnits,
            maxAssets               : 0,
            continuousFeeCap        : MAX_CONTINUOUS_FEE_CBP
        });
    }

    function _sign(Offer memory offer) internal view returns (bytes memory) {
        return _signWith(quoterKey, offer);
    }

    function _signWith(uint256 key, Offer memory offer) internal view returns (bytes memory) {
        ( uint8 v, bytes32 r, bytes32 s ) = vm.sign(key, makerRatifier.hashOffer(offer));

        return abi.encodePacked(r, s, v);
    }

    function _take(Offer memory offer, uint256 units)
        internal returns (uint256 buyerAssets, uint256 sellerAssets)
    {
        bytes memory data = _sign(offer);

        vm.prank(taker);
        return midnight.take(
            offer, data, units, taker, offer.buy ? taker : address(0), address(0), ""
        );
    }

    // The signature must be produced before expectRevert, since hashOffer is itself a call.
    function _expectTakeRevert(Offer memory offer, uint256 units, bytes memory reason) internal {
        bytes memory data = _sign(offer);

        vm.prank(taker);
        vm.expectRevert(reason);
        midnight.take(offer, data, units, taker, offer.buy ? taker : address(0), address(0), "");
    }

    function _makerBuyerAssets(uint256 units, uint256 tick) internal pure returns (uint256) {
        return units * MidnightTickLib.tickToPrice(tick) / 1e18;
    }

    function _enableMake(uint256 maxOfferSize) internal {
        vm.prank(GROVE_EXECUTOR);
        foreignController.setMidnightMakeConfig(marketId, maxOfferSize);
    }

    function _setStrategyLimit(uint256 maxAmount) internal {
        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(strategyKey, maxAmount, maxAmount / 1 days);
    }

}

contract MidnightMakerBuyLifecycleTests is MidnightMakerTestBase {

    function test_makerBuy_lifecycle() public {
        uint256 units    = 1_000_000e18;
        uint256 expected = _makerBuyerAssets(units, MAKER_BUY_TICK);

        assertEq(_credit(),                                     0);
        assertEq(midnight.debt(marketId, address(almProxy)),    0);
        assertEq(loanToken.balanceOf(address(almProxy)),        10_000_000e18);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),        5_000_000e18);
        assertEq(rateLimits.getCurrentRateLimit(strategyKey),   STRATEGY_LIMIT);

        uint256 takerBalanceBefore = loanToken.balanceOf(taker);

        ( uint256 buyerAssets, uint256 sellerAssets )
            = _take(_makerOffer(true, MAKER_BUY_TICK, uint128(units)), units);

        assertEq(buyerAssets,  expected);
        assertEq(sellerAssets, units * (MidnightTickLib.tickToPrice(MAKER_BUY_TICK) - _settlementFee()) / 1e18);

        assertEq(_credit(),                                  units);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);

        assertEq(loanToken.balanceOf(address(almProxy)), 10_000_000e18 - buyerAssets);
        assertEq(loanToken.balanceOf(taker),             takerBalanceBefore + sellerAssets);

        assertEq(loanToken.balanceOf(address(strategy)),             0);
        assertEq(loanToken.allowance(address(strategy), MIDNIGHT),   0);
        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT),   0);

        assertEq(rateLimits.getCurrentRateLimit(buyKey),      5_000_000e18 - buyerAssets);
        assertEq(rateLimits.getCurrentRateLimit(strategyKey), STRATEGY_LIMIT - buyerAssets);
    }

    function test_makerBuy_fundingEventReconcilesWithTake() public {
        uint256 units = 500_000e18;

        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, uint128(units));

        bytes memory data = _sign(offer);

        vm.expectEmit(address(foreignController));
        emit MidnightFillFunded(
            marketId, address(strategy), _makerBuyerAssets(units, MAKER_BUY_TICK), units
        );

        vm.prank(taker);
        midnight.take(offer, data, units, taker, taker, address(0), "");
    }

    function test_makerBuy_partialFillsShareTheGroupCap() public {
        uint256 units = 1_000_000e18;

        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, uint128(units));

        _take(offer, 400_000e18);
        _take(offer, 600_000e18);

        assertEq(_credit(), units);

        _expectTakeRevert(offer, 1, abi.encodeWithSignature("ConsumedUnits()"));
    }

    function test_makerBuy_honoursTheOfferSizeCap() public {
        uint256 units = MAX_OFFER_SIZE + 1;

        _expectTakeRevert(
            _makerOffer(true, MAKER_BUY_TICK, uint128(units)), 1, "MidnightRatifier/offer-too-large"
        );
    }

    function test_makerBuy_priceCeilingBoundary() public {
        _take(_makerOffer(true, 4296, 1_000e18), 1_000e18);

        _expectTakeRevert(
            _makerOffer(true, 4300, 1_000e18), 1_000e18, "MidnightRatifier/price-too-high"
        );
    }

    function test_makerBuy_settlementFeeFallsEntirelyOnTheTaker() public {
        _setFees(5, 0.0025e18, 0);

        assertGt(_settlementFee(), 0);

        uint256 units = 500_000e18;

        uint256 takerBalanceBefore = loanToken.balanceOf(taker);

        ( uint256 buyerAssets, uint256 sellerAssets )
            = _take(_makerOffer(true, MAKER_BUY_TICK, uint128(units)), units);

        assertEq(buyerAssets,  _makerBuyerAssets(units, MAKER_BUY_TICK));
        assertLt(sellerAssets, buyerAssets);

        assertEq(loanToken.balanceOf(taker) - takerBalanceBefore, sellerAssets);
    }

    function test_makerBuy_strategyLimitBindsBeforeTheBuyLimit() public {
        _setStrategyLimit(1_000e18);

        _expectTakeRevert(
            _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18),
            1_000_000e18,
            "RateLimits/rate-limit-exceeded"
        );
    }

}

contract MidnightMakerSellLifecycleTests is MidnightMakerTestBase {

    uint256 constant SEEDED_UNITS = 1_000_000e18;

    function setUp() public override {
        super.setUp();

        _seedCredit(SEEDED_UNITS);
    }

    function test_makerSell_lifecycle() public {
        uint256 units = 400_000e18;

        uint256 proxyBalanceBefore = loanToken.balanceOf(address(almProxy));
        uint256 buyLimitBefore     = rateLimits.getCurrentRateLimit(buyKey);

        ( uint256 buyerAssets, uint256 sellerAssets )
            = _take(_makerOffer(false, TICK_98, uint128(units)), units);

        assertEq(sellerAssets, _makerSellerAssets(units, TICK_98));
        assertEq(
            buyerAssets,
            (units * (MidnightTickLib.tickToPrice(TICK_98) + _settlementFee()) + 1e18 - 1) / 1e18
        );

        assertEq(_credit(),                                  SEEDED_UNITS - units);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);

        assertEq(loanToken.balanceOf(address(almProxy)), proxyBalanceBefore + sellerAssets);

        assertEq(rateLimits.getCurrentRateLimit(buyKey),      buyLimitBefore);
        assertEq(rateLimits.getCurrentRateLimit(strategyKey), STRATEGY_LIMIT);
    }

    function test_makerSell_cannotGoShort() public {
        uint256 units = SEEDED_UNITS + 1;

        _expectTakeRevert(
            _makerOffer(false, TICK_98, uint128(units)),
            units,
            abi.encodeWithSignature("MakerCreditOrDebtIncreased()")
        );
    }

    function test_makerSell_neverRoutesThroughTheStrategy() public {
        _take(_makerOffer(false, TICK_98, uint128(400_000e18)), 400_000e18);

        assertEq(loanToken.balanceOf(address(strategy)),           0);
        assertEq(loanToken.allowance(address(strategy), MIDNIGHT), 0);
    }

}

contract MidnightMakerRetroactivityTests is MidnightMakerTestBase {

    uint256 units = 1_000_000e18;

    // Proves the offer was live before the change, so the later revert is the change and not the offer.
    function _restingBuyOffer() internal returns (Offer memory offer) {
        offer = _makerOffer(true, MAKER_BUY_TICK, uint128(units));

        _take(offer, 1);
    }

    function test_retroactivity_tighteningMaxBuyTick() public {
        Offer memory offer = _restingBuyOffer();

        _setConfig(MAKER_BUY_TICK - 4, TICK_98, MAX_CONTINUOUS_FEE_CBP);

        _expectTakeRevert(offer, 1, "MidnightRatifier/tick-too-high");
    }

    function test_retroactivity_unsettingThePairKey() public {
        Offer memory offer = _restingBuyOffer();

        _setStrategyLimit(0);

        _expectTakeRevert(offer, 1, "MidnightRatifier/callback-not-keyed");
    }

    function test_retroactivity_disablingMake() public {
        Offer memory offer = _restingBuyOffer();

        _enableMake(0);

        _expectTakeRevert(offer, 1, "MidnightRatifier/make-not-enabled");
    }

    function test_retroactivity_shrinkingTheOfferSizeCap() public {
        Offer memory offer = _restingBuyOffer();

        _enableMake(units - 1);

        _expectTakeRevert(offer, 1, "MidnightRatifier/offer-too-large");
    }

    function test_retroactivity_rotatingTheQuoter() public {
        Offer memory offer = _restingBuyOffer();

        vm.prank(GROVE_EXECUTOR);
        makerRatifier.setQuoter(makeAddr("newQuoter"));

        _expectTakeRevert(offer, 1, "MidnightRatifier/invalid-signature");
    }

    function test_retroactivity_expiry() public {
        Offer memory offer = _restingBuyOffer();

        vm.warp(offer.expiry + 1);

        _expectTakeRevert(offer, 1, abi.encodeWithSignature("OfferExpired()"));
    }

    function test_retroactivity_groupCancellationIsPerDirection() public {
        _seedCredit(500_000e18);

        Offer memory buyOffer  = _makerOffer(true,  MAKER_BUY_TICK, uint128(units));
        Offer memory sellOffer = _makerOffer(false, TICK_98, 400_000e18);

        vm.prank(ALM_RELAYER);
        foreignController.cancelMidnightOfferGroup(BUY_GROUP);

        _expectTakeRevert(buyOffer, 1, abi.encodeWithSignature("ConsumedUnits()"));

        ( , uint256 sellerAssets ) = _take(sellOffer, 400_000e18);

        assertEq(sellerAssets, _makerSellerAssets(400_000e18, TICK_98));
    }

    function test_retroactivity_deauthorisingTheRatifier() public {
        Offer memory offer = _restingBuyOffer();

        vm.prank(GROVE_EXECUTOR);
        foreignController.setMidnightRatifierAuthorization(address(makerRatifier), false);

        _expectTakeRevert(offer, 1, abi.encodeWithSignature("RatifierUnauthorized()"));
    }

}

contract MidnightMakerKillSwitchTests is MidnightMakerTestBase {

    uint256 constant UNITS = 1_000_000e18;

    function _expectFreshOfferRejected(bytes memory reason) internal {
        _expectTakeRevert(_makerOffer(true, MAKER_BUY_TICK, uint128(UNITS)), 1, reason);
    }

    function test_killSwitch_quoterRotationIsARotationNotABrick() public {
        ( address newQuoter, uint256 newQuoterKey ) = makeAddrAndKey("rotatedQuoter");

        vm.prank(GROVE_EXECUTOR);
        makerRatifier.setQuoter(newQuoter);

        _expectFreshOfferRejected("MidnightRatifier/invalid-signature");

        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, uint128(UNITS));

        bytes memory data = _signWith(newQuoterKey, offer);

        vm.prank(taker);
        midnight.take(offer, data, 1_000e18, taker, taker, address(0), "");

        assertEq(_credit(), 1_000e18);
    }

    function test_killSwitch_groupCancellationClosesTheWholeBuySide() public {
        vm.prank(ALM_RELAYER);
        foreignController.cancelMidnightOfferGroup(BUY_GROUP);

        _expectFreshOfferRejected(abi.encodeWithSignature("ConsumedUnits()"));

        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, uint128(UNITS));

        offer.group = "fresh-group";

        _expectTakeRevert(offer, 1, "MidnightRatifier/group-mismatch");
    }

    function test_killSwitch_pairKeyZeroing() public {
        _setStrategyLimit(0);

        _expectFreshOfferRejected("MidnightRatifier/callback-not-keyed");
    }

    function test_killSwitch_makeDisable() public {
        _enableMake(0);

        _expectFreshOfferRejected("MidnightRatifier/make-not-enabled");
    }

    function test_killSwitch_ratifierDeauthorisation() public {
        vm.prank(GROVE_EXECUTOR);
        foreignController.setMidnightRatifierAuthorization(address(makerRatifier), false);

        _expectFreshOfferRejected(abi.encodeWithSignature("RatifierUnauthorized()"));
    }

    function test_killSwitch_makeDisableLeavesTheTakerPathWorking() public {
        _enableMake(0);

        _expectFreshOfferRejected("MidnightRatifier/make-not-enabled");

        assertGt(_seedCredit(100_000e18), 0);
    }

}

contract MidnightMakerAttackTests is MidnightMakerTestBase {

    address attacker = makeAddr("attacker");

    function test_attack_fabricatedOfferWithAttackerRatifier() public {
        AttackerRatifier attackerRatifier = new AttackerRatifier();

        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18);

        offer.ratifier = address(attackerRatifier);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("RatifierUnauthorized()"));
        midnight.take(offer, "", 1, taker, taker, address(0), "");
    }

    function test_attack_attackerOfferNamingOurStrategy() public {
        AttackerRatifier attackerRatifier = new AttackerRatifier();

        collateralToken.mint(attacker, 100_000_000 * collateralUnit);

        vm.startPrank(attacker);
        collateralToken.approve(MIDNIGHT, type(uint256).max);
        harness.supplyCollateral(market, 0, 10_000_000 * collateralUnit, attacker);
        harness.setIsAuthorized(address(attackerRatifier), true, attacker);
        vm.stopPrank();

        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18);

        offer.maker    = attacker;
        offer.ratifier = address(attackerRatifier);

        vm.prank(taker);
        vm.expectRevert("ProxyFundingStrategy/buyer-not-proxy");
        midnight.take(offer, "", 1_000e18, taker, taker, address(0), "");
    }

    function test_attack_directFundFillFromANonKeyedAddress() public {
        vm.prank(attacker);
        vm.expectRevert("MidnightLib/strategy-not-keyed");
        foreignController.fundMidnightFill(marketId, 1, 1_000e18);
    }

    function test_attack_directFundFillFromTheKeyedStrategy() public {
        uint256 proxyBalanceBefore = loanToken.balanceOf(address(almProxy));

        vm.prank(address(strategy));
        foreignController.fundMidnightFill(marketId, 1_000e18, 1_000_000e18);

        assertEq(loanToken.balanceOf(address(strategy)), 1_000e18);
        assertEq(loanToken.balanceOf(address(almProxy)), proxyBalanceBefore - 1_000e18);

        strategy.skim(address(loanToken));

        assertEq(loanToken.balanceOf(address(strategy)), 0);
        assertEq(loanToken.balanceOf(address(almProxy)), proxyBalanceBefore);
    }

    function test_attack_directFundFillAboveThePriceBound() public {
        vm.prank(address(strategy));
        vm.expectRevert("MidnightLib/fill-price-too-high");
        foreignController.fundMidnightFill(marketId, 1_000_000e18, 1_000_000e18);
    }

    function test_attack_noOpTakePokeOnAConsumedOffer() public {
        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18);

        _take(offer, 1_000_000e18);

        _expectTakeRevert(offer, 1, abi.encodeWithSignature("ConsumedUnits()"));
    }

    function test_attack_takerCannotRedirectTheProxyPosition() public {
        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18);

        bytes memory data = _sign(offer);

        vm.prank(taker);
        midnight.take(offer, data, 1_000e18, taker, taker, address(0), "");

        assertEq(_credit(), 1_000e18);
    }

    function test_attack_proxyCannotTakeItsOwnOffer() public {
        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18);

        bytes memory data = _sign(offer);

        vm.prank(address(almProxy));
        vm.expectRevert(abi.encodeWithSignature("SelfTake()"));
        midnight.take(offer, data, 1, address(almProxy), address(almProxy), address(0), "");
    }

}

contract MidnightMakerInvariantTests is MidnightMakerTestBase {

    function test_invariant_debtStaysZeroAcrossAMixedBook() public {
        _seedCredit(1_000_000e18);

        _take(_makerOffer(true, MAKER_BUY_TICK, 800_000e18), 800_000e18);

        assertEq(midnight.debt(marketId, address(almProxy)), 0);

        _take(_makerOffer(false, TICK_98, 600_000e18), 600_000e18);

        assertEq(midnight.debt(marketId, address(almProxy)), 0);
        assertEq(_credit(), 1_000_000e18 + 800_000e18 - 600_000e18);
    }

    function test_invariant_limitsMatchTokenMovement() public {
        uint256 units = 900_000e18;

        uint256 proxyBalanceBefore = loanToken.balanceOf(address(almProxy));

        ( uint256 buyerAssets, ) = _take(_makerOffer(true, MAKER_BUY_TICK, uint128(units)), units);

        uint256 spent = proxyBalanceBefore - loanToken.balanceOf(address(almProxy));

        assertEq(spent, buyerAssets);
        assertEq(5_000_000e18    - rateLimits.getCurrentRateLimit(buyKey),      spent);
        assertEq(STRATEGY_LIMIT  - rateLimits.getCurrentRateLimit(strategyKey), spent);
    }

}
