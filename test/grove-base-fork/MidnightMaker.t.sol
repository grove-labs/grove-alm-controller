// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import "./Midnight.t.sol";

interface IFundFillLike {
    function midnight_fundFill(
        bytes32 marketId,
        bool    buy,
        uint256 assets,
        uint256 units
    ) external;
}

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

// Offer policy lives in the periphery ratifier; everything economic is the controller's.
contract PermissiveRatifier {

    function isRatified(Offer memory, bytes memory, address) external pure returns (bytes32) {
        return keccak256("morpho.midnight.callbackSuccess");
    }

}

// Mirrors the periphery's ProxyBasicFillStrategy, the callback shape production will use.
contract MirrorFundingStrategy {

    bytes32 public constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address public immutable midnight;
    address public immutable proxy;
    address public immutable controller;

    constructor(address midnight_, address proxy_, address controller_) {
        midnight   = midnight_;
        proxy      = proxy_;
        controller = controller_;
    }

    function onBuy(
        bytes32 marketId,
        Market  memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256 pendingFeeIncrease,
        address buyer,
        bytes   memory
    )
        external returns (bytes32)
    {
        require(msg.sender == midnight, "ProxyBasicFillStrategy/not-midnight");
        require(buyer      == proxy,    "ProxyBasicFillStrategy/buyer-not-proxy");

        if (buyerAssets == 0) return CALLBACK_SUCCESS;

        IFundFillLike(controller).midnight_fundFill(
            marketId, true, buyerAssets, units
        );

        IERC20Like(market.loanToken).approve(midnight, buyerAssets);

        return CALLBACK_SUCCESS;
    }

    function onSell(
        bytes32 marketId,
        Market  memory,
        uint256 sellerAssets,
        uint256 units,
        uint256 pendingFeeDecrease,
        address seller,
        address receiver,
        bytes   memory
    )
        external returns (bytes32)
    {
        require(msg.sender == midnight, "ProxyBasicFillStrategy/not-midnight");
        require(seller     == proxy,    "ProxyBasicFillStrategy/seller-not-proxy");
        require(receiver   == proxy,    "ProxyBasicFillStrategy/receiver-not-proxy");

        if (units == 0) return CALLBACK_SUCCESS;

        IFundFillLike(controller).midnight_fundFill(
            marketId, false, sellerAssets, units
        );

        return CALLBACK_SUCCESS;
    }

    function rescue(address token) external {
        uint256 amount = IERC20Like(token).balanceOf(address(this));

        require(amount != 0, "ProxyBasicFillStrategy/nothing-to-rescue");

        IERC20Like(token).transfer(proxy, amount);
    }

}

contract MidnightMakerTestBase is MidnightTestBase {

    event MidnightFillFunded(
        bytes32 indexed id,
        address indexed strategy,
        bool            buy,
        uint256         assets,
        uint256         units
    );

    // The controller prices against the configured fee ceiling, so its buy bound is the tighter one.
    uint16 constant MAKER_BUY_TICK = TICK_98;

    // A buy of one unit rounds to zero assets and never reaches the controller.
    uint256 constant PROBE_UNITS = 1e18;

    uint256 constant MAX_OFFER_SIZE   = 2_000_000e18;

    bytes32 constant BUY_GROUP  = "grove-midnight-buy";
    bytes32 constant SELL_GROUP = "grove-midnight-sell";

    PermissiveRatifier    makerRatifier;
    MirrorFundingStrategy strategy;

    address taker = makeAddr("taker");

    function setUp() public virtual override {
        super.setUp();

        makerRatifier = new PermissiveRatifier();

        strategy = new MirrorFundingStrategy(
            MIDNIGHT, address(almProxy), address(foreignController)
        );

        vm.startPrank(GROVE_EXECUTOR);
        foreignController.setMidnightMakeConfig(marketId, MAX_OFFER_SIZE);
        foreignController.setMidnightGroups(marketId, BUY_GROUP, SELL_GROUP);
        foreignController.setMidnightRatifierAuthorization(address(makerRatifier), true);
        rateLimits.setRateLimitData(_strategyBuyKey(address(strategy)),  5_000_000e18, 0);
        rateLimits.setRateLimitData(_strategySellKey(address(strategy)), 5_000_000e18, 0);
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
            callback                : address(strategy),
            callbackData            : new bytes(0),
            receiverIfMakerIsSeller : buy ? address(0) : address(almProxy),
            ratifier                : address(makerRatifier),
            reduceOnly              : !buy,
            maxUnits                : maxUnits,
            maxAssets               : 0,
            continuousFeeCap        : MidnightLib._continuousFeePerSecond(MAX_CONTINUOUS_FEE_CBP)
        });
    }

    function _take(Offer memory offer, uint256 units)
        internal returns (uint256 buyerAssets, uint256 sellerAssets)
    {
        vm.prank(taker);
        return midnight.take(
            offer, "", units, taker, offer.buy ? taker : address(0), address(0), ""
        );
    }

    function _expectTakeRevert(Offer memory offer, uint256 units, bytes memory reason) internal {
        vm.prank(taker);
        vm.expectRevert(reason);
        midnight.take(
            offer, "", units, taker, offer.buy ? taker : address(0), address(0), ""
        );
    }

    function _makerBuyerAssets(uint256 units, uint256 tick) internal pure returns (uint256) {
        return units * MidnightTickLib.tickToPrice(tick) / 1e18;
    }

    function _enableMake(uint256 maxOfferSize) internal {
        vm.prank(GROVE_EXECUTOR);
        foreignController.setMidnightMakeConfig(marketId, maxOfferSize);
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

    function _onboardStrategy(address strategy_, uint256 maxAmount) internal {
        vm.startPrank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(_strategyBuyKey(strategy_),  maxAmount, 0);
        rateLimits.setRateLimitData(_strategySellKey(strategy_), maxAmount, 0);
        vm.stopPrank();
    }

}

contract MidnightMakerBuyLifecycleTests is MidnightMakerTestBase {

    // A buy rounding to zero assets short-circuits in the strategy, so no controller check runs.
    function test_makerBuy_dustFillNeverReachesTheController() public {
        assertEq(_makerBuyerAssets(1, MAKER_BUY_TICK), 0);

        _enableMake(0);
        _onboardStrategy(address(strategy), 0);

        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18);

        uint256 proxyBefore = loanToken.balanceOf(address(almProxy));
        uint256 buyBefore   = rateLimits.getCurrentRateLimit(buyKey);

        _take(offer, 1);

        assertEq(loanToken.balanceOf(address(almProxy)), proxyBefore);
        assertEq(rateLimits.getCurrentRateLimit(buyKey), buyBefore);
    }

    function test_makerBuy_lifecycle() public {
        uint256 units    = 1_000_000e18;
        uint256 expected = _makerBuyerAssets(units, MAKER_BUY_TICK);

        assertEq(_credit(),                                     0);
        assertEq(midnight.debt(marketId, address(almProxy)),    0);
        assertEq(loanToken.balanceOf(address(almProxy)),        10_000_000e18);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),        5_000_000e18);

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

        assertEq(rateLimits.getCurrentRateLimit(buyKey),  5_000_000e18 - buyerAssets);
    }

    function test_makerBuy_fundingEventReconcilesWithTake() public {
        uint256 units = 500_000e18;

        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, uint128(units));

        vm.expectEmit(address(foreignController));
        emit MidnightFillFunded(
            marketId, address(strategy), true, _makerBuyerAssets(units, MAKER_BUY_TICK), units
        );

        vm.prank(taker);
        midnight.take(offer, "", units, taker, taker, address(0), "");
    }

    function test_makerBuy_partialFillsShareTheGroupCap() public {
        uint256 units = 1_000_000e18;

        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, uint128(units));

        _take(offer, 400_000e18);
        _take(offer, 600_000e18);

        assertEq(_credit(), units);

        _expectTakeRevert(offer, 1, abi.encodeWithSignature("ConsumedUnits()"));
    }

    function test_makerBuy_priceCeilingBoundary() public {
        _take(_makerOffer(true, 4296, 1_000e18), 1_000e18);

        _expectTakeRevert(
            _makerOffer(true, 4300, 2_000e18), 1_000e18, "MidnightLib/fill-price-too-high"
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

    function test_makerBuy_offerSizeCeilingBindsBeforeTheBuyLimit() public {
        _enableMake(1_000e18);

        _expectTakeRevert(
            _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18),
            1_000_000e18,
            "MidnightLib/offer-size-too-large"
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

        assertEq(rateLimits.getCurrentRateLimit(buyKey),  buyLimitBefore);
        assertEq(rateLimits.getCurrentRateLimit(sellKey), 5_000_000e18 - sellerAssets);
    }

    function test_makerSell_cannotGoShort() public {
        uint256 units = SEEDED_UNITS + 1;

        _expectTakeRevert(
            _makerOffer(false, TICK_98, uint128(units)),
            units,
            abi.encodeWithSignature("MakerCreditOrDebtIncreased()")
        );
    }

    function test_makerSell_strategyMovesNoAssets() public {
        _take(_makerOffer(false, TICK_98, uint128(400_000e18)), 400_000e18);

        assertEq(loanToken.balanceOf(address(strategy)),           0);
        assertEq(loanToken.allowance(address(strategy), MIDNIGHT), 0);
        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
    }

    function test_makerSell_exhaustedSellLimitMakesTheAskUnfillable() public {
        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(sellKey, 1, 0);

        _expectTakeRevert(
            _makerOffer(false, TICK_98, uint128(400_000e18)),
            400_000e18,
            "RateLimits/rate-limit-exceeded"
        );
    }

    function test_makerSell_offerSizeCeilingMakesTheAskUnfillable() public {
        _enableMake(1);

        _expectTakeRevert(
            _makerOffer(false, TICK_98, uint128(400_000e18)),
            400_000e18,
            "MidnightLib/offer-size-too-large"
        );
    }

    function test_makerSell_disabledMakeMakesTheAskUnfillable() public {
        _enableMake(0);

        _expectTakeRevert(
            _makerOffer(false, TICK_98, uint128(400_000e18)),
            400_000e18,
            "MidnightLib/make-not-enabled"
        );
    }

}

contract MidnightMakerRetroactivityTests is MidnightMakerTestBase {

    uint256 units = 1_000_000e18;

    // Proves the offer was live before the change, so the later revert is the change and not the offer.
    function _restingBuyOffer() internal returns (Offer memory offer) {
        offer = _makerOffer(true, MAKER_BUY_TICK, uint128(units));

        _take(offer, PROBE_UNITS);
    }

    function test_retroactivity_tighteningMaxBuyTick() public {
        Offer memory offer = _restingBuyOffer();

        _setConfig(MAKER_BUY_TICK - 4, TICK_98, MAX_CONTINUOUS_FEE_CBP);

        _expectTakeRevert(offer, PROBE_UNITS, "MidnightLib/fill-price-too-high");
    }

    function test_retroactivity_offboardingTheStrategy() public {
        Offer memory offer = _restingBuyOffer();

        _onboardStrategy(address(strategy), 0);

        _expectTakeRevert(offer, PROBE_UNITS, "RateLimits/zero-maxAmount");
    }

    function test_retroactivity_disablingMake() public {
        Offer memory offer = _restingBuyOffer();

        _enableMake(0);

        _expectTakeRevert(offer, PROBE_UNITS, "MidnightLib/make-not-enabled");
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
        _expectTakeRevert(_makerOffer(true, MAKER_BUY_TICK, uint128(UNITS)), PROBE_UNITS, reason);
    }

    function test_killSwitch_groupCancellationClosesTheWholeBuySide() public {
        vm.prank(ALM_RELAYER);
        foreignController.cancelMidnightOfferGroup(BUY_GROUP);

        _expectFreshOfferRejected(abi.encodeWithSignature("ConsumedUnits()"));
    }

    function test_killSwitch_strategyOffboarding() public {
        _onboardStrategy(address(strategy), 0);

        _expectFreshOfferRejected("RateLimits/zero-maxAmount");
    }

    function test_killSwitch_makeDisable() public {
        _enableMake(0);

        _expectFreshOfferRejected("MidnightLib/make-not-enabled");
    }

    function test_killSwitch_ratifierDeauthorisation() public {
        vm.prank(GROVE_EXECUTOR);
        foreignController.setMidnightRatifierAuthorization(address(makerRatifier), false);

        _expectFreshOfferRejected(abi.encodeWithSignature("RatifierUnauthorized()"));
    }

    function test_killSwitch_makeDisableLeavesTheTakerPathWorking() public {
        _enableMake(0);

        _expectFreshOfferRejected("MidnightLib/make-not-enabled");

        assertGt(_seedCredit(100_000e18), 0);
    }

}

contract MidnightMakerAttackTests is MidnightMakerTestBase {

    // The taker picks takerCallback, so it can name our strategy and fire the opposite callback.
    function test_attack_takerNamesOurStrategyAsItsOwnCallbackOnMakerBuy() public {
        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18);

        vm.prank(taker);
        vm.expectRevert("ProxyBasicFillStrategy/seller-not-proxy");
        midnight.take(offer, "", PROBE_UNITS, taker, taker, address(strategy), "");
    }

    function test_attack_takerNamesOurStrategyAsItsOwnCallbackOnMakerSell() public {
        _seedCredit(1_000_000e18);

        Offer memory offer = _makerOffer(false, TICK_98, 1_000_000e18);

        vm.prank(taker);
        vm.expectRevert("ProxyBasicFillStrategy/buyer-not-proxy");
        midnight.take(offer, "", PROBE_UNITS, taker, address(0), address(strategy), "");
    }

    address attacker = makeAddr("attacker");

    function test_attack_fabricatedOfferWithAttackerRatifier() public {
        PermissiveRatifier attackerRatifier = new PermissiveRatifier();

        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18);

        offer.ratifier = address(attackerRatifier);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("RatifierUnauthorized()"));
        midnight.take(offer, "", 1, taker, taker, address(0), "");
    }

    function test_attack_attackerOfferNamingOurStrategy() public {
        PermissiveRatifier attackerRatifier = new PermissiveRatifier();

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
        vm.expectRevert("ProxyBasicFillStrategy/buyer-not-proxy");
        midnight.take(offer, "", 1_000e18, taker, taker, address(0), "");
    }

    function test_attack_directFundFillFromAnUnfundedAddress() public {
        vm.prank(attacker);
        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.midnight_fundFill(marketId, true, 1, 1_000e18);
    }

    function test_attack_directFundFillFromTheOnboardedStrategy() public {
        uint256 proxyBalanceBefore = loanToken.balanceOf(address(almProxy));

        vm.prank(address(strategy));
        foreignController.midnight_fundFill(marketId, true, 1_000e18, 1_000_000e18);

        assertEq(loanToken.balanceOf(address(strategy)), 1_000e18);
        assertEq(loanToken.balanceOf(address(almProxy)), proxyBalanceBefore - 1_000e18);

        strategy.rescue(address(loanToken));

        assertEq(loanToken.balanceOf(address(strategy)), 0);
        assertEq(loanToken.balanceOf(address(almProxy)), proxyBalanceBefore);
    }

    function test_attack_directFundFillAboveThePriceBound() public {
        vm.prank(address(strategy));
        vm.expectRevert("MidnightLib/fill-price-too-high");
        foreignController.midnight_fundFill(marketId, true, 1_000_000e18, 1_000_000e18);
    }

    function test_attack_directSellFillCannotCreateBuyCapacity() public {
        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(buyKey, 5_000_000e18, 0, 1_000_000e18, block.timestamp);

        vm.prank(address(strategy));
        foreignController.midnight_fundFill(marketId, false, 500_000e18, 500_000e18);

        assertEq(loanToken.balanceOf(address(strategy)), 0);

        assertEq(rateLimits.getCurrentRateLimit(buyKey),  1_000_000e18);
        assertEq(rateLimits.getCurrentRateLimit(sellKey), 5_000_000e18 - 500_000e18);
    }

    function test_attack_noOpTakePokeOnAConsumedOffer() public {
        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18);

        _take(offer, 1_000_000e18);

        _expectTakeRevert(offer, 1, abi.encodeWithSignature("ConsumedUnits()"));
    }

    function test_attack_takerCannotRedirectTheProxyPosition() public {
        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18);

        vm.prank(taker);
        midnight.take(offer, "", 1_000e18, taker, taker, address(0), "");

        assertEq(_credit(), 1_000e18);
    }

    function test_attack_proxyCannotTakeItsOwnOffer() public {
        Offer memory offer = _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18);

        vm.prank(address(almProxy));
        vm.expectRevert(abi.encodeWithSignature("SelfTake()"));
        midnight.take(offer, "", 1, address(almProxy), address(almProxy), address(0), "");
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
        assertEq(5_000_000e18 - rateLimits.getCurrentRateLimit(buyKey), spent);
    }

}

contract MidnightMakerMaturityTests is MidnightMakerTestBase {

    function _straddlingBuyOffer() internal view returns (Offer memory offer) {
        offer = _makerOffer(true, MAKER_BUY_TICK, 1_000_000e18);

        offer.start  = market.maturity - 1 hours;
        offer.expiry = market.maturity + 1 hours;
    }

    function test_maturity_protocolBlocksAShortSellerPostMaturity() public {
        Offer memory offer = _straddlingBuyOffer();

        vm.warp(market.maturity + 30 minutes);

        _expectTakeRevert(
            offer, 1_000e18, abi.encodeWithSignature("CannotIncreaseDebtPostMaturity()")
        );
    }

    function test_maturity_creditHoldingTakerCanStillFill() public {
        _seedCredit(1_000_000e18);

        _take(_makerOffer(false, TICK_98, 500_000e18), 500_000e18);

        Offer memory offer = _straddlingBuyOffer();

        vm.warp(market.maturity + 30 minutes);

        uint256 creditBefore = _credit();

        ( uint256 buyerAssets, ) = _take(offer, 100_000e18);

        assertEq(_credit(),                                  creditBefore + 100_000e18);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);

        // At maturity the yield bound stops binding, so maxBuyTick is the only price guard left.
        assertLe(buyerAssets, 100_000e18 * MidnightTickLib.tickToPrice(MAKER_BUY_TICK) / 1e18);
    }

}

contract FundFillReenterer {

    bytes32 constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address public immutable midnight;

    address public controller;
    bytes32 public marketId;

    bool  public reentered;
    bytes public revertData;

    constructor(address midnight_) {
        midnight = midnight_;
    }

    function approveMidnight(address token) external {
        IERC20(token).approve(midnight, type(uint256).max);
    }

    function arm(address controller_, bytes32 marketId_) external {
        controller = controller_;
        marketId   = marketId_;
    }

    function onBuy(
        bytes32, Market memory, uint256, uint256 units, uint256, address, bytes memory
    )
        external returns (bytes32)
    {
        _reenter(units);
        return CALLBACK_SUCCESS;
    }

    function onSell(
        bytes32, Market memory, uint256, uint256 units, uint256, address, address, bytes memory
    )
        external returns (bytes32)
    {
        _reenter(units);
        return CALLBACK_SUCCESS;
    }

    // Deliberately well inside any configured price bound, so the guard is the only thing left.
    function _reenter(uint256 units) internal {
        (bool ok, bytes memory ret) = controller.call(
            abi.encodeWithSignature(
                "midnight_fundFill(bytes32,bool,uint256,uint256)",
                marketId, true, units / 2, units
            )
        );

        reentered  = ok;
        revertData = ret;
    }

}

contract MidnightMakerReentrancyTests is MidnightMakerTestBase {

    FundFillReenterer reenterer;

    function setUp() public override {
        super.setUp();

        reenterer = new FundFillReenterer(MIDNIGHT);

        reenterer.arm(address(foreignController), marketId);

        loanToken.mint(address(reenterer), 10_000_000e18);
        reenterer.approveMidnight(address(loanToken));

        _enableMake(MAX_OFFER_SIZE);

        // Onboarded like a real strategy, so only the reentrancy guard is left to stop it.
        _onboardStrategy(address(reenterer), 5_000_000e18);
    }

    function _assertGuardBlockedTheFill() internal view {
        assertFalse(reenterer.reentered());

        assertEq(
            reenterer.revertData(),
            abi.encodeWithSignature("ReentrancyGuardReentrantCall()")
        );
    }

    function test_buyMidnight_makerCallbackCannotFundFill() public {
        uint256 units    = 1_000e18;
        uint256 expected = _buyerAssets(units, TICK_99);

        Offer memory offer = _offer(false, TICK_99, uint128(units));
        offer.callback     = address(reenterer);

        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));

        assertEq(_buy(offer, units, type(uint256).max), expected);

        _assertGuardBlockedTheFill();

        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore - expected);
        assertEq(_credit(),                              units);

        // The proxy pays on this leg, so nothing should have reached the callback at all.
        assertEq(loanToken.balanceOf(address(reenterer)), 10_000_000e18);
    }

    function test_sellMidnight_makerCallbackCannotFundFill() public {
        uint256 units = 1_000e18;

        _seedCredit(units);

        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));

        Offer memory offer = _offer(true, TICK_99, uint128(units));
        offer.callback     = address(reenterer);

        uint256 received = _sell(offer, units, 1);

        _assertGuardBlockedTheFill();

        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore + received);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);

        // The callback is the payer on this leg, so it is out exactly the buyer's side and no more.
        assertEq(
            loanToken.balanceOf(address(reenterer)),
            10_000_000e18 - _buyerAssets(units, TICK_99)
        );
    }

    function test_midnight_fundFill_unfundedCallerIsRejectedOutrightAnyway() public {
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.midnight_fundFill(marketId, true, 1, 1_000e18);
    }

}
