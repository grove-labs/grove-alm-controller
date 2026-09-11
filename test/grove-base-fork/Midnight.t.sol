// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { MockERC20 } from "erc20-helpers/MockERC20.sol";

import { CollateralParams, IMidnight, Market, Offer } from "../../src/interfaces/MidnightInterfaces.sol";

import { MidnightLib } from "../../src/libraries/MidnightLib.sol";

import { MidnightIdLib }   from "../../src/libraries/midnight/MidnightIdLib.sol";
import { MidnightTickLib } from "../../src/libraries/midnight/MidnightTickLib.sol";

import "./ForkTestBase.t.sol";

// The parts of the real singleton the tests drive directly, which the integration itself never calls.
interface IMidnightTestHarness {
    function configurator() external view returns (address);
    function consumed(address user, bytes32 group) external view returns (uint128);
    function isAuthorized(address onBehalf, address caller) external view returns (bool);
    function setFeeSetter(address newFeeSetter) external;
    function setMarketContinuousFee(bytes32 id, uint256 newContinuousFee) external;
    function setMarketSettlementFee(bytes32 id, uint256 index, uint256 newSettlementFee) external;
    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external;
    function supplyCollateral(Market memory market, uint256 collateralIndex, uint256 assets, address onBehalf)
        external;
    function repay(Market memory market, uint256 units, address onBehalf, address callback, bytes calldata data)
        external;
    function liquidate(
        Market  memory market,
        uint256 collateralIndex,
        uint256 seizedAssets,
        uint256 repaidUnits,
        address borrower,
        bool    postMaturityMode,
        address receiver,
        address callback,
        bytes   memory data
    ) external returns (uint256, uint256);
}

contract DummyRatifier {

    bytes32 constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    function isRatified(Offer memory, bytes memory, address) external pure returns (bytes32) {
        return CALLBACK_SUCCESS;
    }

}

contract FailingRatifier {

    function isRatified(Offer memory, bytes memory, address) external pure returns (bytes32) {
        return bytes32(0);
    }

}

contract MockOracle {

    uint256 public price;

    constructor(uint256 price_) {
        price = price_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

}

contract MidnightTestBase is ForkTestBase {

    address constant MIDNIGHT = MIDNIGHT_BASE;

    // Both already enabled on the Base singleton at the fork block.
    uint256 constant LLTV               = 0.86e18;
    uint256 constant LIQUIDATION_CURSOR = 0.3e18;

    // Midnight's default tick spacing; offer ticks have to be multiples of it.
    uint16 constant TICK_SPACING = 4;

    // tickToPrice(3372) is exactly 0.5e18, and price rises with the tick.
    uint16 constant TICK_98 = 4152;  // ~0.98
    uint16 constant TICK_99 = 4384;  // ~0.99

    uint256 constant MATURITY_PERIOD = 180 days;

    IMidnight            midnight = IMidnight(MIDNIGHT);
    IMidnightTestHarness harness  = IMidnightTestHarness(MIDNIGHT);

    MockERC20     loanToken;
    MockERC20     collateralToken;
    MockOracle    oracle;
    DummyRatifier ratifier;

    address maker = makeAddr("maker");

    Market  market;
    bytes32 marketId;

    bytes32 buyKey;
    bytes32 sellKey;
    bytes32 redeemKey;

    uint256 loanUnit;
    uint256 collateralUnit;

    uint256 offerNonce;

    function _getBlock() internal override pure returns (uint256) {
        return 51_000_000;  // Midnight was deployed on Base at block 48,286,884
    }

    // Overridden by the suites that run the same flows against tokens which are not 18 decimals.
    function _loanTokenDecimals()       internal virtual pure returns (uint8) { return 18; }
    function _collateralTokenDecimals() internal virtual pure returns (uint8) { return 18; }

    function setUp() public virtual override {
        super.setUp();

        loanUnit       = 10 ** _loanTokenDecimals();
        collateralUnit = 10 ** _collateralTokenDecimals();

        loanToken       = new MockERC20("Loan",       "LOAN", _loanTokenDecimals());
        collateralToken = new MockERC20("Collateral", "COLL", _collateralTokenDecimals());

        // A 1:1 valuation at ORACLE_PRICE_SCALE (1e36), scaled by the tokens' decimal difference.
        oracle   = new MockOracle(1e36 * loanUnit / collateralUnit);
        ratifier = new DummyRatifier();

        // Assigned field by field because solc cannot copy an array of structs into storage.
        market.chainId   = block.chainid;
        market.midnight  = MIDNIGHT;
        market.loanToken = address(loanToken);
        market.maturity  = block.timestamp + MATURITY_PERIOD;

        market.collateralParams.push(CollateralParams({
            token             : address(collateralToken),
            lltv              : LLTV,
            liquidationCursor : LIQUIDATION_CURSOR,
            oracle            : address(oracle)
        }));

        marketId = midnight.touchMarket(market);

        // The vendored id derivation has to agree with the protocol's own.
        assertEq(marketId, MidnightIdLib.toId(market));

        // The maker is the counterparty for every fill, collateralized so it can sell units.
        loanToken.mint(maker, 100_000_000 * loanUnit);
        collateralToken.mint(maker, 100_000_000 * collateralUnit);

        vm.startPrank(maker);
        harness.setIsAuthorized(address(ratifier), true, maker);
        loanToken.approve(MIDNIGHT, type(uint256).max);
        collateralToken.approve(MIDNIGHT, type(uint256).max);
        harness.supplyCollateral(market, 0, 10_000_000 * collateralUnit, maker);
        vm.stopPrank();

        loanToken.mint(address(almProxy), 10_000_000 * loanUnit);

        _wireRateLimitsAndConfig();
    }

    // Split out so the live market suite can point the same wiring at a different market id.
    function _wireRateLimitsAndConfig() internal {
        buyKey    = RateLimitHelpers.makeMarketKey(foreignController.LIMIT_MIDNIGHT_BUY(),    marketId);
        sellKey   = RateLimitHelpers.makeMarketKey(foreignController.LIMIT_MIDNIGHT_SELL(),   marketId);
        redeemKey = RateLimitHelpers.makeMarketKey(foreignController.LIMIT_MIDNIGHT_REDEEM(), marketId);

        vm.startPrank(GROVE_EXECUTOR);

        rateLimits.setRateLimitData(buyKey,    5_000_000 * loanUnit, (1_000_000 * loanUnit) / 1 days);
        rateLimits.setRateLimitData(sellKey,   5_000_000 * loanUnit, (1_000_000 * loanUnit) / 1 days);
        rateLimits.setRateLimitData(redeemKey, 5_000_000 * loanUnit, (1_000_000 * loanUnit) / 1 days);

        foreignController.setMidnightMarketConfig(
            marketId,
            MidnightLib.MarketConfig({
                maxBuyTick       : TICK_99,
                minSellTick      : TICK_98,
                maxContinuousFee : MidnightLib.MAX_CONTINUOUS_FEE,
                maxLossFactor    : 0
            })
        );

        vm.stopPrank();
    }

    /**********************************************************************************************/
    /*** Test helpers                                                                           ***/
    /**********************************************************************************************/

    // Consumed capacity is tracked per (maker, group), so each offer gets its own group by default.
    function _offer(bool buy, uint256 tick, uint128 maxUnits) internal returns (Offer memory) {
        return _offer(buy, tick, maxUnits, bytes32(++offerNonce), address(ratifier));
    }

    function _offer(bool buy, uint256 tick, uint128 maxUnits, bytes32 group, address ratifier_)
        internal view returns (Offer memory)
    {
        return Offer({
            market                  : market,
            buy                     : buy,
            maker                   : maker,
            start                   : 0,
            expiry                  : block.timestamp + 1 days,
            tick                    : tick,
            group                   : group,
            callback                : address(0),
            callbackData            : new bytes(0),
            // Midnight rejects a non-zero receiver on the leg where the maker is not the seller.
            receiverIfMakerIsSeller : buy ? address(0) : maker,
            ratifier                : ratifier_,
            reduceOnly              : false,
            maxUnits                : maxUnits,
            maxAssets               : 0,
            continuousFeeCap        : type(uint256).max
        });
    }

    function _batch(Offer memory offer, uint256 units)
        internal pure returns (Offer[] memory offers, bytes[] memory ratifierData, uint256[] memory unitsArray)
    {
        offers        = new Offer[](1);
        ratifierData  = new bytes[](1);
        unitsArray    = new uint256[](1);

        offers[0]     = offer;
        unitsArray[0] = units;
    }

    function _settlementFee() internal view returns (uint256) {
        uint256 timeToMaturity = market.maturity > block.timestamp ? market.maturity - block.timestamp : 0;

        return midnight.settlementFee(marketId, timeToMaturity);
    }

    // Mirrors Midnight's settlement arithmetic: pay the price plus the fee, receive it less the fee.
    function _buyerAssets(uint256 units, uint256 tick) internal view returns (uint256) {
        uint256 price = MidnightTickLib.tickToPrice(tick) + _settlementFee();

        return (units * price + 1e18 - 1) / 1e18;
    }

    function _sellerAssets(uint256 units, uint256 tick) internal view returns (uint256) {
        uint256 price = MidnightTickLib.tickToPrice(tick) - _settlementFee();

        return units * price / 1e18;
    }

    // What the maker receives when it is the seller: the offer price, rounded up, no fee (the fee
    // is added on the buyer's side).
    function _makerSellerAssets(uint256 units, uint256 tick) internal pure returns (uint256) {
        uint256 price = MidnightTickLib.tickToPrice(tick);

        return (units * price + 1e18 - 1) / 1e18;
    }

    function _setFees(uint256 settlementFeeIndex, uint256 settlementFee_, uint256 continuousFee_) internal {
        address configurator = harness.configurator();

        vm.prank(configurator);
        harness.setFeeSetter(address(this));

        if (settlementFee_ != 0) harness.setMarketSettlementFee(marketId, settlementFeeIndex, settlementFee_);
        if (continuousFee_ != 0) harness.setMarketContinuousFee(marketId, continuousFee_);
    }

    function _buy(Offer memory offer, uint256 units, uint256 maxAssetsIn) internal returns (uint256) {
        (
            Offer[] memory offers,
            bytes[] memory ratifierData,
            uint256[] memory unitsArray
        ) = _batch(offer, units);

        vm.prank(ALM_RELAYER);
        return foreignController.buyMidnight(marketId, offers, ratifierData, unitsArray, maxAssetsIn);
    }

    function _sell(Offer memory offer, uint256 units, uint256 minAssetsOut) internal returns (uint256) {
        (
            Offer[] memory offers,
            bytes[] memory ratifierData,
            uint256[] memory unitsArray
        ) = _batch(offer, units);

        vm.prank(ALM_RELAYER);
        return foreignController.sellMidnight(marketId, offers, ratifierData, unitsArray, minAssetsOut);
    }

    function _credit() internal view returns (uint256 credit) {
        ( credit, , ) = midnight.updatePositionView(market, marketId, address(almProxy));
    }

    function _setConfig(uint16 maxBuyTick, uint16 minSellTick, uint32 maxContinuousFee) internal {
        _setConfig(maxBuyTick, minSellTick, maxContinuousFee, 0);
    }

    function _setConfig(
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint32  maxContinuousFee,
        uint128 maxLossFactor
    )
        internal
    {
        vm.prank(GROVE_EXECUTOR);
        foreignController.setMidnightMarketConfig(
            marketId,
            MidnightLib.MarketConfig({
                maxBuyTick       : maxBuyTick,
                minSellTick      : minSellTick,
                maxContinuousFee : maxContinuousFee,
                maxLossFactor    : maxLossFactor
            })
        );
    }

    // Buys units into the proxy so the exit paths have a position to work with.
    function _seedCredit(uint256 units) internal returns (uint256 assetsSpent) {
        return _buy(_offer(false, TICK_98, uint128(units)), units, type(uint256).max);
    }

    function _repay(uint256 units) internal {
        vm.prank(maker);
        harness.repay(market, units, maker, address(0), "");
    }

    function _redeem(uint256 units, uint256 minAssetsOut) internal returns (uint256) {
        vm.prank(ALM_RELAYER);
        return foreignController.redeemMidnight(marketId, units, minAssetsOut);
    }

}

contract ForeignControllerMidnightBuyTests is MidnightTestBase {

    function test_buyMidnight_notRelayer() public {
        (
            Offer[] memory offers,
            bytes[] memory ratifierData,
            uint256[] memory units
        ) = _batch(_offer(false, TICK_98, 1e18), 1e18);

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.buyMidnight(marketId, offers, ratifierData, units, 1e18);
    }

    function test_buyMidnight_emptyBatch() public {
        vm.prank(ALM_RELAYER);
        vm.expectRevert("MidnightLib/empty-batch");
        foreignController.buyMidnight(marketId, new Offer[](0), new bytes[](0), new uint256[](0), 1e18);
    }

    function test_buyMidnight_invalidBatchLength() public {
        Offer[] memory offers = new Offer[](2);
        offers[0] = _offer(false, TICK_98, 1e18);
        offers[1] = offers[0];

        vm.prank(ALM_RELAYER);
        vm.expectRevert("MidnightLib/invalid-batch-length");
        foreignController.buyMidnight(marketId, offers, new bytes[](2), new uint256[](1), 1e18);
    }

    function test_buyMidnight_maxAssetsInNotSet() public {
        vm.expectRevert("MidnightLib/max-assets-in-not-set");
        _buy(_offer(false, TICK_98, 1e18), 1e18, 0);
    }

    function test_buyMidnight_zeroUnits() public {
        vm.expectRevert("MidnightLib/zero-units");
        _buy(_offer(false, TICK_98, 1e18), 0, 1e18);
    }

    function test_buyMidnight_buyNotEnabled() public {
        _setConfig(0, TICK_98, MidnightLib.MAX_CONTINUOUS_FEE);

        vm.expectRevert("MidnightLib/buy-not-enabled");
        _buy(_offer(false, TICK_98, 1e18), 1e18, 1e18);
    }

    function test_buyMidnight_marketNotOnboarded() public {
        Market memory otherMarket = market;
        otherMarket.maturity = market.maturity + 1 days;

        Offer memory offer = _offer(false, TICK_98, 1e18);
        offer.market = otherMarket;

        (
            Offer[] memory offers,
            bytes[] memory ratifierData,
            uint256[] memory units
        ) = _batch(offer, 1e18);

        // An unonboarded market has an all zero config, so entry is closed by the same kill switch.
        vm.prank(ALM_RELAYER);
        vm.expectRevert("MidnightLib/buy-not-enabled");
        foreignController.buyMidnight(MidnightIdLib.toId(otherMarket), offers, ratifierData, units, 1e18);
    }

    // The id has to match the offers; an onboarded id cannot lend its config to another market.
    function test_buyMidnight_marketIdMismatch() public {
        Market memory otherMarket = market;
        otherMarket.maturity = market.maturity + 1 days;

        Offer memory offer = _offer(false, TICK_98, 1e18);
        offer.market = otherMarket;

        vm.expectRevert("MidnightLib/market-mismatch");
        _buy(offer, 1e18, 1e18);
    }

    // Governance can onboard any id, but entries only go to the configured venue.
    function test_buyMidnight_invalidMidnight() public {
        Market memory otherMarket = market;
        otherMarket.midnight = makeAddr("otherMidnight");

        bytes32 otherId = MidnightIdLib.toId(otherMarket);

        vm.prank(GROVE_EXECUTOR);
        foreignController.setMidnightMarketConfig(
            otherId,
            MidnightLib.MarketConfig(TICK_99, TICK_98, MidnightLib.MAX_CONTINUOUS_FEE, 0)
        );

        Offer memory offer = _offer(false, TICK_98, 1e18);
        offer.market = otherMarket;

        (
            Offer[] memory offers,
            bytes[] memory ratifierData,
            uint256[] memory units
        ) = _batch(offer, 1e18);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("MidnightLib/invalid-midnight");
        foreignController.buyMidnight(otherId, offers, ratifierData, units, 1e18);
    }

    function test_buyMidnight_marketMismatchInBatch() public {
        Market memory otherMarket = market;
        otherMarket.maturity = market.maturity + 1 days;

        Offer[] memory offers = new Offer[](2);
        offers[0] = _offer(false, TICK_98, 1e18);
        offers[1] = _offer(false, TICK_98, 1e18);
        offers[1].market = otherMarket;

        uint256[] memory units = new uint256[](2);
        units[0] = 1e18;
        units[1] = 1e18;

        vm.prank(ALM_RELAYER);
        vm.expectRevert("MidnightLib/market-mismatch");
        foreignController.buyMidnight(marketId, offers, new bytes[](2), units, 10e18);
    }

    function test_buyMidnight_invalidOfferDirection() public {
        vm.expectRevert("MidnightLib/invalid-offer-direction");
        _buy(_offer(true, TICK_98, 1e18), 1e18, 1e18);
    }

    function test_buyMidnight_priceTooHigh() public {
        _setConfig(TICK_98 - TICK_SPACING, TICK_98, MidnightLib.MAX_CONTINUOUS_FEE);

        vm.expectRevert("MidnightLib/buy-price-too-high");
        _buy(_offer(false, TICK_98, 1e18), 1e18, 1e18);
    }

    // The governance bound is on the all-in price, so a non-zero settlement fee eats into it.
    function test_buyMidnight_priceBoundIncludesSettlementFee() public {
        _setFees(5, 0.0025e18, 0);

        uint256 allInPrice = MidnightTickLib.tickToPrice(TICK_98) + _settlementFee();

        assertGt(_settlementFee(), 0);

        // The lowest tick whose price covers the tick price plus the fee.
        uint16 boundTick = TICK_98;
        while (MidnightTickLib.tickToPrice(boundTick) < allInPrice) boundTick++;

        assertGt(boundTick, TICK_98);

        _setConfig(boundTick - 1, TICK_98, MidnightLib.MAX_CONTINUOUS_FEE);

        vm.expectRevert("MidnightLib/buy-price-too-high");
        _buy(_offer(false, TICK_98, 1e18), 1e18, 1e18);

        _setConfig(boundTick, TICK_98, MidnightLib.MAX_CONTINUOUS_FEE);

        assertEq(_buy(_offer(false, TICK_98, 1e18), 1e18, 1e18), _buyerAssets(1e18, TICK_98));
    }

    // The fee is reserved out of the tick bound, so a bound below the fee leaves no price to buy at.
    function test_buyMidnight_maxBuyTickBelowFee() public {
        _setFees(5, 0.0025e18, 0);

        assertLt(MidnightTickLib.tickToPrice(TICK_SPACING), _settlementFee());

        _setConfig(TICK_SPACING, TICK_98, MidnightLib.MAX_CONTINUOUS_FEE);

        vm.expectRevert("MidnightLib/max-buy-tick-below-fee");
        _buy(_offer(false, TICK_98, 1e18), 1e18, 1e18);
    }

    // Paying the maker at the proxy's own address would net the transfer to zero, hiding the spend.
    function test_buyMidnight_offerReceiverIsProxy() public {
        Offer memory offer = _offer(false, TICK_98, 1e18);
        offer.receiverIfMakerIsSeller = address(almProxy);

        vm.expectRevert("MidnightLib/invalid-offer-receiver");
        _buy(offer, 1e18, 1e18);

        // Any other receiver is the maker's business; the spend is still measured in full. With a fee
        // on, the maker gets the bare offer price and the proxy pays price plus fee.
        _setFees(5, 0.0025e18, 0);

        uint256 units    = 1_234.567e18;
        uint256 expected = _buyerAssets(units, TICK_98);
        uint256 toMaker  = _makerSellerAssets(units, TICK_98);

        assertGt(expected - toMaker, 0);

        address receiver = makeAddr("receiver");

        offer = _offer(false, TICK_98, uint128(units));
        offer.receiverIfMakerIsSeller = receiver;

        uint256 feeBefore = loanToken.balanceOf(MIDNIGHT);

        assertEq(_buy(offer, units, expected),            expected);
        assertEq(loanToken.balanceOf(receiver),           toMaker);
        assertEq(loanToken.balanceOf(MIDNIGHT) - feeBefore, expected - toMaker);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),  5_000_000e18 - expected);
    }

    // Onboarding does not consult the singleton, so a market nobody has touched yet can be configured
    // but not traded: the fee lookup is the first thing to hit the protocol.
    function test_buyMidnight_marketNotTouched() public {
        Market memory untouched = market;
        untouched.maturity = market.maturity + 1 days;

        bytes32 untouchedId = MidnightIdLib.toId(untouched);

        vm.prank(GROVE_EXECUTOR);
        foreignController.setMidnightMarketConfig(
            untouchedId,
            MidnightLib.MarketConfig(TICK_99, TICK_98, MidnightLib.MAX_CONTINUOUS_FEE, 0)
        );

        Offer memory offer = _offer(false, TICK_98, 1e18);
        offer.market = untouched;

        (
            Offer[] memory offers,
            bytes[] memory ratifierData,
            uint256[] memory units
        ) = _batch(offer, 1e18);

        vm.prank(ALM_RELAYER);
        vm.expectRevert(abi.encodeWithSignature("MarketNotCreated()"));
        foreignController.buyMidnight(untouchedId, offers, ratifierData, units, 1e18);

        assertEq(midnight.touchMarket(untouched), untouchedId);

        vm.prank(maker);
        harness.supplyCollateral(untouched, 0, 1_000_000e18, maker);

        bytes32 untouchedBuyKey =
            RateLimitHelpers.makeMarketKey(foreignController.LIMIT_MIDNIGHT_BUY(), untouchedId);

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(untouchedBuyKey, 5_000_000e18, 0);

        // Fees are zero on both markets, so the base market's quote carries over.
        vm.prank(ALM_RELAYER);
        assertEq(
            foreignController.buyMidnight(untouchedId, offers, ratifierData, units, 1e18),
            _buyerAssets(1e18, TICK_98)
        );
    }

    function test_buyMidnight_continuousFeeTooHigh() public {
        _setFees(0, 0, 1);

        _setConfig(TICK_99, TICK_98, 0);

        vm.expectRevert("MidnightLib/continuous-fee-too-high");
        _buy(_offer(false, TICK_98, 1e18), 1e18, 1e18);

        _setConfig(TICK_99, TICK_98, 1);

        assertEq(_buy(_offer(false, TICK_98, 1e18), 1e18, 1e18), _buyerAssets(1e18, TICK_98));
    }

    function test_buyMidnight_maxAssetsInTooLow() public {
        uint256 units       = 1_000e18;
        uint256 maxAssetsIn = _buyerAssets(units, TICK_98) - 1;

        Offer memory offer = _offer(false, TICK_98, uint128(units));

        // Midnight can only pull up to the approval, so the token itself stops the overspend.
        vm.expectRevert(stdError.arithmeticError);
        _buy(offer, units, maxAssetsIn);
    }

    function test_buyMidnight_ratifierFailed() public {
        Offer memory offer = _offer(false, TICK_98, 1e18, bytes32(0), address(new FailingRatifier()));

        vm.prank(maker);
        harness.setIsAuthorized(offer.ratifier, true, maker);

        vm.expectRevert(abi.encodeWithSignature("RatifierFailed()"));
        _buy(offer, 1e18, 1e18);
    }

    function test_buyMidnight_zeroMaxAmount() public {
        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(buyKey, 0, 0);

        vm.expectRevert("RateLimits/zero-maxAmount");
        _buy(_offer(false, TICK_98, 1e18), 1e18, 1e18);
    }

    function test_buyMidnight_rateLimitBoundary() public {
        uint256 units          = 1_000e18;
        uint256 expectedAssets = _buyerAssets(units, TICK_98);

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(buyKey, expectedAssets - 1, 0);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        _buy(_offer(false, TICK_98, uint128(units)), units, type(uint256).max);

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(buyKey, expectedAssets, 0);

        assertEq(_buy(_offer(false, TICK_98, uint128(units)), units, type(uint256).max), expectedAssets);

        assertEq(rateLimits.getCurrentRateLimit(buyKey), 0);
    }

    function test_buyMidnight() public {
        uint256 units          = 1_000_000e18;
        uint256 expectedAssets = _buyerAssets(units, TICK_98);

        assertEq(_credit(),                                    0);
        assertEq(midnight.debt(marketId, address(almProxy)),   0);
        assertEq(loanToken.balanceOf(address(almProxy)),       10_000_000e18);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),       5_000_000e18);

        // Bound above the fill so that a leftover approval would show, rather than be spent away.
        uint256 assetsSpent = _buy(_offer(false, TICK_98, uint128(units)), units, expectedAssets + 1_000e18);

        assertEq(assetsSpent,                                  expectedAssets);
        assertEq(_credit(),                                    units);
        assertEq(midnight.debt(marketId, address(almProxy)),   0);
        assertEq(loanToken.balanceOf(address(almProxy)),       10_000_000e18 - expectedAssets);
        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),       5_000_000e18 - expectedAssets);

        // A buy at a sub-par price is spending less than the units bought, which is the whole point.
        assertLt(expectedAssets, units);
    }

    function test_buyMidnight_batch() public {
        uint256 units0 = 600_000e18;
        uint256 units1 = 400_000e18;

        Offer[] memory offers = new Offer[](2);
        offers[0] = _offer(false, TICK_98, uint128(units0), "group-0", address(ratifier));
        offers[1] = _offer(false, TICK_99, uint128(units1), "group-1", address(ratifier));

        uint256[] memory units = new uint256[](2);
        units[0] = units0;
        units[1] = units1;

        uint256 expectedAssets = _buyerAssets(units0, TICK_98) + _buyerAssets(units1, TICK_99);

        vm.prank(ALM_RELAYER);
        uint256 assetsSpent = foreignController.buyMidnight(marketId, 
            offers, new bytes[](2), units, expectedAssets
        );

        assertEq(assetsSpent,                                      expectedAssets);
        assertEq(_credit(),                                        units0 + units1);
        assertEq(loanToken.balanceOf(address(almProxy)),           10_000_000e18 - expectedAssets);
        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),           5_000_000e18 - expectedAssets);
    }

    // One bad offer takes the whole batch down: no partial entry.
    function test_buyMidnight_batchIsAtomic() public {
        Offer[] memory offers = new Offer[](2);
        offers[0] = _offer(false, TICK_98, 1_000e18, "group-0", address(ratifier));
        offers[1] = _offer(false, TICK_99 + TICK_SPACING, 1_000e18, "group-1", address(ratifier));

        uint256[] memory units = new uint256[](2);
        units[0] = 1_000e18;
        units[1] = 1_000e18;

        vm.prank(ALM_RELAYER);
        vm.expectRevert("MidnightLib/buy-price-too-high");
        foreignController.buyMidnight(marketId, offers, new bytes[](2), units, type(uint256).max);

        assertEq(_credit(),                              0);
        assertEq(loanToken.balanceOf(address(almProxy)), 10_000_000e18);
    }

}

contract ForeignControllerMidnightSellTests is MidnightTestBase {

    uint256 constant SEEDED_UNITS = 1_000_000e18;

    uint256 buySpend;

    function setUp() public override {
        super.setUp();

        buySpend = _seedCredit(SEEDED_UNITS);
    }

    function test_sellMidnight_notRelayer() public {
        (
            Offer[] memory offers,
            bytes[] memory ratifierData,
            uint256[] memory units
        ) = _batch(_offer(true, TICK_99, 1e18), 1e18);

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.sellMidnight(marketId, offers, ratifierData, units, 1);
    }

    function test_sellMidnight_minAssetsOutNotSet() public {
        vm.expectRevert("MidnightLib/min-assets-out-not-set");
        _sell(_offer(true, TICK_99, 1e18), 1e18, 0);
    }

    // An unonboarded id has an all zero config, so exits from it are closed as well.
    function test_sellMidnight_sellNotEnabled() public {
        Market memory otherMarket = market;
        otherMarket.maturity = market.maturity + 1 days;

        Offer memory offer = _offer(true, TICK_99, 1e18);
        offer.market = otherMarket;

        (
            Offer[] memory offers,
            bytes[] memory ratifierData,
            uint256[] memory units
        ) = _batch(offer, 1e18);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("MidnightLib/sell-not-enabled");
        foreignController.sellMidnight(MidnightIdLib.toId(otherMarket), offers, ratifierData, units, 1);
    }

    function test_sellMidnight_invalidOfferDirection() public {
        vm.expectRevert("MidnightLib/invalid-offer-direction");
        _sell(_offer(false, TICK_99, 1e18), 1e18, 1);
    }

    function test_sellMidnight_priceTooLow() public {
        _setConfig(TICK_99, TICK_99 + TICK_SPACING, MidnightLib.MAX_CONTINUOUS_FEE);

        vm.expectRevert("MidnightLib/sell-price-too-low");
        _sell(_offer(true, TICK_99, 1e18), 1e18, 1);
    }

    // The floor is on what actually lands in the proxy, so the settlement fee eats into it.
    function test_sellMidnight_priceBoundIncludesSettlementFee() public {
        _setFees(5, 0.0025e18, 0);

        assertGt(_settlementFee(), 0);

        uint256 netPrice = MidnightTickLib.tickToPrice(TICK_99) - _settlementFee();

        // The highest floor tick the net price still clears.
        uint16 boundTick = TICK_99;
        while (MidnightTickLib.tickToPrice(boundTick) > netPrice) boundTick--;

        assertLt(boundTick, TICK_99);

        _setConfig(TICK_99, boundTick + 1, MidnightLib.MAX_CONTINUOUS_FEE);

        vm.expectRevert("MidnightLib/sell-price-too-low");
        _sell(_offer(true, TICK_99, 1e18), 1e18, 1);

        _setConfig(TICK_99, boundTick, MidnightLib.MAX_CONTINUOUS_FEE);

        assertEq(_sell(_offer(true, TICK_99, 1e18), 1e18, 1), _sellerAssets(1e18, TICK_99));
    }

    function test_sellMidnight_minAssetsOutNotMet() public {
        uint256 units        = 1_000e18;
        uint256 minAssetsOut = _sellerAssets(units, TICK_99) + 1;

        Offer memory offer = _offer(true, TICK_99, uint128(units));

        vm.expectRevert("MidnightLib/min-assets-out-not-met");
        _sell(offer, units, minAssetsOut);
    }

    function test_sellMidnight_zeroMaxAmount() public {
        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(sellKey, 0, 0);

        vm.expectRevert("RateLimits/zero-maxAmount");
        _sell(_offer(true, TICK_99, 1e18), 1e18, 1);
    }

    function test_sellMidnight_rateLimitBoundary() public {
        uint256 units    = 1_000e18;
        uint256 expected = _sellerAssets(units, TICK_99);

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(sellKey, expected - 1, 0);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        _sell(_offer(true, TICK_99, uint128(units)), units, 1);

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(sellKey, expected, 0);

        assertEq(_sell(_offer(true, TICK_99, uint128(units)), units, 1), expected);

        assertEq(rateLimits.getCurrentRateLimit(sellKey), 0);
    }

    function test_sellMidnight() public {
        uint256 units    = 400_000e18;
        uint256 expected = _sellerAssets(units, TICK_99);

        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));

        assertEq(_credit(),                              SEEDED_UNITS);
        assertEq(rateLimits.getCurrentRateLimit(buyKey), 5_000_000e18 - buySpend);

        uint256 assetsReceived = _sell(_offer(true, TICK_99, uint128(units)), units, expected);

        assertEq(assetsReceived,                             expected);
        assertEq(_credit(),                                  SEEDED_UNITS - units);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
        assertEq(loanToken.balanceOf(address(almProxy)),     balanceBefore + expected);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),    5_000_000e18 - expected);

        // Exiting hands back entry capacity, capped at the configured maximum.
        assertEq(rateLimits.getCurrentRateLimit(buyKey), 5_000_000e18 - buySpend + expected);
    }

    // An oversized ask is clamped rather than reverting or turning into naked debt.
    function test_sellMidnight_clampsUnitsToCredit() public {
        uint256 expected = _sellerAssets(SEEDED_UNITS, TICK_99);

        uint256 assetsReceived = _sell(
            _offer(true, TICK_99, uint128(SEEDED_UNITS * 2)),
            SEEDED_UNITS * 2,
            expected
        );

        assertEq(assetsReceived,                             expected);
        assertEq(_credit(),                                  0);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
    }

    function test_sellMidnight_batch() public {
        uint256 units0 = 600_000e18;
        uint256 units1 = 400_000e18;

        Offer[] memory offers = new Offer[](2);
        offers[0] = _offer(true, TICK_99, uint128(units0), "group-0", address(ratifier));
        offers[1] = _offer(true, TICK_99 + TICK_SPACING, uint128(units1), "group-1", address(ratifier));

        uint256[] memory units = new uint256[](2);
        units[0] = units0;
        units[1] = units1;

        uint256 expected      = _sellerAssets(units0, TICK_99) + _sellerAssets(units1, TICK_99 + TICK_SPACING);
        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));

        vm.prank(ALM_RELAYER);
        uint256 assetsReceived = foreignController.sellMidnight(marketId, offers, new bytes[](2), units, expected);

        assertEq(assetsReceived,                             expected);
        assertEq(_credit(),                                  0);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
        assertEq(loanToken.balanceOf(address(almProxy)),     balanceBefore + expected);
        assertEq(harness.consumed(maker, "group-0"),         units0);
        assertEq(harness.consumed(maker, "group-1"),         units1);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),    5_000_000e18 - expected);
    }

    // Running out of credit inside an offer clamps that fill rather than skipping or reverting it.
    function test_sellMidnight_batchClampsTheOfferThatExhaustsThePosition() public {
        uint256 units0 = 600_000e18;
        uint256 units1 = SEEDED_UNITS - units0;

        Offer[] memory offers = new Offer[](2);
        offers[0] = _offer(true, TICK_99, uint128(units0), "group-0", address(ratifier));
        offers[1] = _offer(true, TICK_99, uint128(SEEDED_UNITS), "group-1", address(ratifier));

        uint256[] memory units = new uint256[](2);
        units[0] = units0;
        units[1] = SEEDED_UNITS;

        uint256 expected = _sellerAssets(units0, TICK_99) + _sellerAssets(units1, TICK_99);

        vm.prank(ALM_RELAYER);
        uint256 assetsReceived = foreignController.sellMidnight(marketId, offers, new bytes[](2), units, expected);

        assertEq(assetsReceived,                             expected);
        assertEq(_credit(),                                  0);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
        assertEq(harness.consumed(maker, "group-0"),         units0);
        assertEq(harness.consumed(maker, "group-1"),         units1);
    }

    function test_sellMidnight_batchStopsWhenPositionIsExhausted() public {
        Offer[] memory offers = new Offer[](2);
        offers[0] = _offer(true, TICK_99, uint128(SEEDED_UNITS), "group-0", address(ratifier));
        offers[1] = _offer(true, TICK_99, uint128(SEEDED_UNITS), "group-1", address(ratifier));

        uint256[] memory units = new uint256[](2);
        units[0] = SEEDED_UNITS;
        units[1] = SEEDED_UNITS;

        uint256 expected = _sellerAssets(SEEDED_UNITS, TICK_99);

        vm.prank(ALM_RELAYER);
        uint256 assetsReceived = foreignController.sellMidnight(marketId, offers, new bytes[](2), units, expected);

        assertEq(assetsReceived, expected);
        assertEq(_credit(),      0);

        // The second offer was never reached, so its group budget is untouched.
        assertEq(harness.consumed(maker, "group-0"), SEEDED_UNITS);
        assertEq(harness.consumed(maker, "group-1"), 0);
    }

    // Exits stay open when entry is shut off, both by the kill switch and by the fee guard.
    function test_sellMidnight_worksWhenBuysAreBlocked() public {
        _setFees(0, 0, 1);
        _setConfig(0, TICK_98, 0);

        uint256 units    = 400_000e18;
        uint256 expected = _sellerAssets(units, TICK_99);

        vm.expectRevert("MidnightLib/buy-not-enabled");
        _buy(_offer(false, TICK_98, uint128(units)), units, type(uint256).max);

        assertEq(_sell(_offer(true, TICK_99, uint128(units)), units, expected), expected);
    }

    // With no entry capacity configured, exiting still works and simply has nothing to give back.
    function test_sellMidnight_buyLimitNotConfigured() public {
        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(buyKey, 0, 0);

        uint256 units    = 400_000e18;
        uint256 expected = _sellerAssets(units, TICK_99);

        assertEq(_sell(_offer(true, TICK_99, uint128(units)), units, expected), expected);

        assertEq(rateLimits.getCurrentRateLimit(buyKey), 0);
    }

}

contract ForeignControllerMidnightRedeemTests is MidnightTestBase {

    uint256 constant SEEDED_UNITS = 1_000_000e18;

    function setUp() public override {
        super.setUp();

        _seedCredit(SEEDED_UNITS);
    }

    function test_redeemMidnight_notRelayer() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.redeemMidnight(marketId, 1e18, 0);
    }

    function test_redeemMidnight_invalidMidnight() public {
        Market memory otherMarket = market;
        otherMarket.midnight = makeAddr("otherMidnight");

        // A market on another venue has a different id, so governance never onboarded it.
        vm.prank(ALM_RELAYER);
        vm.expectRevert("MidnightLib/market-not-onboarded");
        foreignController.redeemMidnight(MidnightIdLib.toId(otherMarket), 1e18, 0);
    }

    function test_redeemMidnight_zeroUnits() public {
        vm.prank(ALM_RELAYER);
        vm.expectRevert("MidnightLib/zero-units");
        foreignController.redeemMidnight(marketId, 1e18, 0);
    }

    function test_redeemMidnight_minAssetsOutNotMet() public {
        _repay(100_000e18);

        // Units are clamped to what the pool can serve, so the floor is on the assets actually out.
        vm.prank(ALM_RELAYER);
        vm.expectRevert("MidnightLib/min-assets-out-not-met");
        foreignController.redeemMidnight(marketId, SEEDED_UNITS, 100_000e18 + 1);

        assertEq(_redeem(SEEDED_UNITS, 100_000e18), 100_000e18);
    }

    function test_redeemMidnight_zeroMaxAmount() public {
        _repay(SEEDED_UNITS);

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(redeemKey, 0, 0);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.redeemMidnight(marketId, 1e18, 0);
    }

    function test_redeemMidnight_rateLimitBoundary() public {
        _repay(SEEDED_UNITS);

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(redeemKey, 1_000e18 - 1, 0);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.redeemMidnight(marketId, 1_000e18, 0);

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(redeemKey, 1_000e18, 0);

        assertEq(_redeem(1_000e18, 1_000e18), 1_000e18);
    }

    function test_redeemMidnight() public {
        _repay(SEEDED_UNITS);

        uint256 units         = 400_000e18;
        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));
        uint256 buyLimit      = rateLimits.getCurrentRateLimit(buyKey);

        uint256 assetsWithdrawn = _redeem(units, units);

        // Credit redeems at par: one unit of credit for one unit of the loan token.
        assertEq(assetsWithdrawn,                            units);
        assertEq(_credit(),                                  SEEDED_UNITS - units);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
        assertEq(loanToken.balanceOf(address(almProxy)),      balanceBefore + units);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey),   5_000_000e18 - units);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),      buyLimit + units);
    }

    function test_redeemMidnight_clampsUnitsToWithdrawable() public {
        _repay(100_000e18);

        assertEq(midnight.withdrawable(marketId), 100_000e18);

        uint256 assetsWithdrawn = _redeem(SEEDED_UNITS, 0);

        assertEq(assetsWithdrawn,                 100_000e18);
        assertEq(_credit(),                       SEEDED_UNITS - 100_000e18);
        assertEq(midnight.withdrawable(marketId), 0);
    }

    function test_redeemMidnight_clampsUnitsToCredit() public {
        _repay(SEEDED_UNITS);

        uint256 assetsWithdrawn = _redeem(SEEDED_UNITS * 2, SEEDED_UNITS);

        assertEq(assetsWithdrawn, SEEDED_UNITS);
        assertEq(_credit(),       0);
    }

    function test_redeemMidnight_marketNotOnboarded() public {
        Market memory otherMarket = market;
        otherMarket.maturity = market.maturity + 1 days;

        vm.prank(ALM_RELAYER);
        vm.expectRevert("MidnightLib/market-not-onboarded");
        foreignController.redeemMidnight(MidnightIdLib.toId(otherMarket), 1e18, 0);
    }

    // The library resolves the market from the venue, so an id Midnight never touched cannot redeem.
    function test_redeemMidnight_marketNotCreated() public {
        bytes32 unknownId = keccak256("unknown");

        vm.prank(GROVE_EXECUTOR);
        foreignController.setMidnightMarketConfig(
            unknownId,
            MidnightLib.MarketConfig(TICK_99, TICK_98, MidnightLib.MAX_CONTINUOUS_FEE, 0)
        );

        vm.prank(ALM_RELAYER);
        vm.expectRevert(abi.encodeWithSignature("MarketNotCreated()"));
        foreignController.redeemMidnight(unknownId, 1e18, 0);
    }

}

contract ForeignControllerMidnightSlashingTests is MidnightTestBase {

    uint256 constant SEEDED_UNITS = 1_000_000e18;

    address liquidator = makeAddr("liquidator");

    function setUp() public override {
        super.setUp();

        _seedCredit(SEEDED_UNITS);
    }

    // Craters the price, then liquidates repaying and seizing nothing, which socializes the bad debt.
    function _slash() internal {
        oracle.setPrice(1e36 / 100);

        vm.prank(liquidator);
        harness.liquidate(market, 0, 0, 0, maker, false, liquidator, address(0), "");

        assertGt(midnight.lossFactor(marketId), 0);
    }

    // Mirrors Midnight's own write down: credit is scaled by the unslashed share of the market.
    function _postSlashCredit(uint256 credit) internal view returns (uint256) {
        return credit * (type(uint128).max - midnight.lossFactor(marketId)) / type(uint128).max;
    }

    function test_buyMidnight_lossFactorTooHigh() public {
        _slash();

        // The price recovers, the realized loss does not.
        oracle.setPrice(1e36);

        uint128 lossFactor = midnight.lossFactor(marketId);

        vm.expectRevert("MidnightLib/loss-factor-too-high");
        _buy(_offer(false, TICK_98, 1e18), 1e18, 1e18);

        _setConfig(TICK_99, TICK_98, MidnightLib.MAX_CONTINUOUS_FEE, lossFactor - 1);

        vm.expectRevert("MidnightLib/loss-factor-too-high");
        _buy(_offer(false, TICK_98, 1e18), 1e18, 1e18);

        _setConfig(TICK_99, TICK_98, MidnightLib.MAX_CONTINUOUS_FEE, lossFactor);

        assertEq(_buy(_offer(false, TICK_98, 1e18), 1e18, 1e18), _buyerAssets(1e18, TICK_98));
    }

    // Slashing writes down the position, so the credit delta is measured against the new balance.
    function test_sellMidnight_afterSlashing() public {
        uint256 creditBefore = _credit();

        _slash();

        uint256 slashedCredit = _postSlashCredit(creditBefore);

        assertLt(slashedCredit, creditBefore);
        assertEq(_credit(),     slashedCredit);

        uint256 expected = _sellerAssets(slashedCredit, TICK_99);

        // The oversized ask is clamped to the slashed position instead of turning into naked debt.
        assertEq(_sell(_offer(true, TICK_99, uint128(SEEDED_UNITS)), SEEDED_UNITS, expected), expected);

        assertEq(_credit(),                                  0);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
    }

    function test_redeemMidnight_afterSlashing() public {
        _slash();

        uint256 slashedCredit = _credit();

        _repay(slashedCredit);

        assertEq(_redeem(SEEDED_UNITS, slashedCredit), slashedCredit);

        assertEq(_credit(), 0);
    }

    // Exits are never gated on the loss factor: the only way out of an impaired market is to use them.
    function test_midnightExits_workWhenEntryIsGatedOnLossFactor() public {
        _slash();
        oracle.setPrice(1e36);

        uint256 slashedCredit = _credit();

        vm.expectRevert("MidnightLib/loss-factor-too-high");
        _buy(_offer(false, TICK_98, 1e18), 1e18, 1e18);

        uint256 sold = slashedCredit / 2;

        assertEq(
            _sell(_offer(true, TICK_99, uint128(sold)), sold, _sellerAssets(sold, TICK_99)),
            _sellerAssets(sold, TICK_99)
        );

        _repay(slashedCredit - sold);

        assertEq(_redeem(slashedCredit - sold, slashedCredit - sold), slashedCredit - sold);
    }

}

contract ForeignControllerMidnightMaturityTests is MidnightTestBase {

    uint256 constant SEEDED_UNITS = 1_000_000e18;

    function setUp() public override {
        super.setUp();

        _seedCredit(SEEDED_UNITS);

        vm.warp(market.maturity + 1);
    }

    // Midnight refuses to let a seller take on new debt after maturity, so entering is simply over.
    function test_buyMidnight_postMaturity() public {
        vm.expectRevert(abi.encodeWithSignature("CannotIncreaseDebtPostMaturity()"));
        _buy(_offer(false, TICK_98, 1e18), 1e18, 1e18);
    }

    // Exiting still works, because the maker is the buyer and only reduces its own debt.
    function test_sellMidnight_postMaturity() public {
        uint256 units    = 400_000e18;
        uint256 expected = _sellerAssets(units, TICK_99);

        assertEq(_sell(_offer(true, TICK_99, uint128(units)), units, expected), expected);

        assertEq(_credit(),                               SEEDED_UNITS - units);
        assertEq(rateLimits.getCurrentRateLimit(sellKey), 5_000_000e18 - expected);
    }

    function test_redeemMidnight_postMaturity() public {
        _repay(SEEDED_UNITS);

        assertEq(_redeem(SEEDED_UNITS, SEEDED_UNITS), SEEDED_UNITS);

        assertEq(_credit(), 0);
    }

    // Time to maturity has to be floored at zero rather than underflow into the long dated fees.
    function test_sellMidnight_postMaturityPricesAtTheFloorFee() public {
        _setFees(0, 0.000014e18, 0);  // the protocol's own cap for the zero day slot
        _setFees(5, 0.0025e18,   0);

        assertEq(_settlementFee(), 0.000014e18);
        assertEq(_settlementFee(), midnight.settlementFee(marketId, 0));

        uint256 units    = 400_000e18;
        uint256 expected = _sellerAssets(units, TICK_99);

        assertEq(_sell(_offer(true, TICK_99, uint128(units)), units, expected), expected);
    }

}

// A maker callback that tries to make the proxy a party or a payer. Failures are swallowed so the
// outer call still lands and its end state can be asserted.
contract HostileCallback {

    bytes32 constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address public immutable midnight;

    bool public tookOffer;
    bool public withdrew;
    bool public authorized;
    bool public repaid;

    uint256 public allowanceSeen;  // the proxy's live approval at the time of the callback

    constructor(address midnight_) {
        midnight = midnight_;
    }

    function approveMidnight(address token) external {
        IERC20(token).approve(midnight, type(uint256).max);
    }

    function onSell(
        bytes32,
        Market  memory market,
        uint256,
        uint256,
        uint256,
        address,
        address,
        bytes   memory data
    )
        external returns (bytes32)
    {
        (address proxy, Offer memory attackOffer, uint256 units) =
            abi.decode(data, (address, Offer, uint256));

        allowanceSeen = IERC20(market.loanToken).allowance(proxy, midnight);

        // Spend the approval still open for the rest of the batch, via an offer the proxy makes.
        try IMidnight(midnight).take(attackOffer, "", units, address(this), address(0), address(0), "") {
            tookOffer = true;
        } catch {}

        // Move the proxy's position out from under it.
        try IMidnight(midnight).withdraw(market, units, proxy, address(this)) {
            withdrew = true;
        } catch {}

        // Become an operator of the proxy for later.
        try IMidnightTestHarness(midnight).setIsAuthorized(address(this), true, proxy) {
            authorized = true;
        } catch {}

        // Name the proxy as the payer of someone else's repayment; zero units isolates that check.
        try IMidnightTestHarness(midnight).repay(market, 0, address(this), proxy, "") {
            repaid = true;
        } catch {}

        return CALLBACK_SUCCESS;
    }

}

contract ForeignControllerMidnightCallbackTests is MidnightTestBase {

    HostileCallback hostile;

    function setUp() public override {
        super.setUp();

        hostile = new HostileCallback(MIDNIGHT);

        loanToken.mint(address(hostile), 10_000_000e18);
        hostile.approveMidnight(address(loanToken));
    }

    // An offer that would make the proxy the payer, unratifiable because the proxy authorizes nobody.
    function _attackOffer(uint256 units) internal view returns (Offer memory offer) {
        offer = Offer({
            market                  : market,
            buy                     : true,
            maker                   : address(almProxy),
            start                   : 0,
            expiry                  : block.timestamp + 1 days,
            tick                    : TICK_98,
            group                   : "attack",
            callback                : address(0),
            callbackData            : new bytes(0),
            receiverIfMakerIsSeller : address(0),
            ratifier                : address(ratifier),
            reduceOnly              : false,
            maxUnits                : uint128(units),
            maxAssets               : 0,
            continuousFeeCap        : type(uint256).max
        });
    }

    function test_buyMidnight_hostileMakerCallbackIsContained() public {
        uint256 units    = 1_000e18;
        uint256 expected = _buyerAssets(units, TICK_98);

        Offer memory offer = _offer(false, TICK_98, uint128(units));
        offer.callback     = address(hostile);
        offer.callbackData = abi.encode(address(almProxy), _attackOffer(units), units);

        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));

        // A bound above the fill leaves a live approval open while the callback runs; the exact
        // bound would be spent before `onSell` and make the `take` leg fail on allowance alone.
        assertEq(_buy(offer, units, type(uint256).max), expected);

        assertGt(hostile.allowanceSeen(), _buyerAssets(units, TICK_98));

        assertFalse(hostile.tookOffer());
        assertFalse(hostile.withdrew());
        assertFalse(hostile.authorized());
        assertFalse(hostile.repaid());

        // The proxy paid exactly the fill and nothing else, and holds no leftover approval.
        assertEq(loanToken.balanceOf(address(almProxy)),            balanceBefore - expected);
        assertEq(loanToken.balanceOf(address(hostile)),             10_000_000e18);
        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT),  0);
        assertEq(_credit(),                                        units);
        assertEq(midnight.debt(marketId, address(almProxy)),        0);
        assertFalse(harness.isAuthorized(address(almProxy), address(hostile)));
    }

    // Consuming the rest of the batch from inside the first fill cannot leave the proxy half entered.
    function test_buyMidnight_hostileMakerCallbackCannotPartiallyFill() public {
        uint256 units = 1_000e18;

        Offer[] memory offers = new Offer[](2);
        offers[0] = _offer(false, TICK_98, uint128(units), "group-0", address(ratifier));
        offers[1] = _offer(false, TICK_98, uint128(units), "group-1", address(ratifier));

        // The callback takes the batch's second offer for itself, exhausting that offer's budget.
        offers[0].callback     = address(hostile);
        offers[0].callbackData = abi.encode(address(almProxy), offers[1], units);

        uint256[] memory unitsArray = new uint256[](2);
        unitsArray[0] = units;
        unitsArray[1] = units;

        vm.prank(ALM_RELAYER);
        vm.expectRevert(abi.encodeWithSignature("ConsumedUnits()"));
        foreignController.buyMidnight(marketId, offers, new bytes[](2), unitsArray, type(uint256).max);

        assertEq(_credit(),                                       0);
        assertEq(loanToken.balanceOf(address(almProxy)),           10_000_000e18);
        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
    }

}

// A maker callback that socializes a third borrower's bad debt while the proxy's fill is in flight,
// then restores the price so the maker's own health check still passes.
contract SlashingCallback {

    bytes32 constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    IMidnightTestHarness public immutable midnight;
    MockOracle           public immutable oracle;
    address              public immutable victim;
    uint256              public immutable price;

    constructor(address midnight_, MockOracle oracle_, address victim_) {
        midnight = IMidnightTestHarness(midnight_);
        oracle   = oracle_;
        victim   = victim_;
        price    = oracle_.price();
    }

    function approveMidnight(address token) external {
        IERC20(token).approve(address(midnight), type(uint256).max);
    }

    function _slash(Market memory market) internal {
        oracle.setPrice(price / 100);
        midnight.liquidate(market, 0, 0, 0, victim, false, address(this), address(0), "");
        oracle.setPrice(price);
    }

    // Maker is the seller: runs after the transfers of the proxy's buy.
    function onSell(bytes32, Market memory market, uint256, uint256, uint256, address, address, bytes memory)
        external returns (bytes32)
    {
        _slash(market);
        return CALLBACK_SUCCESS;
    }

    // Maker is the buyer: runs before the transfers of the proxy's sell, and this contract is the payer.
    function onBuy(bytes32, Market memory market, uint256, uint256, uint256, address, bytes memory)
        external returns (bytes32)
    {
        _slash(market);
        return CALLBACK_SUCCESS;
    }

}

contract ForeignControllerMidnightMidBatchSlashTests is MidnightTestBase {

    uint256 constant VICTIM_UNITS = 1_000_000e18;

    address victim = makeAddr("victim");

    SlashingCallback slasher;

    function setUp() public override {
        super.setUp();

        // A second borrower whose debt backs the proxy's credit and can be written off mid-fill.
        collateralToken.mint(victim, 2_000_000e18);

        vm.startPrank(victim);
        harness.setIsAuthorized(address(ratifier), true, victim);
        collateralToken.approve(MIDNIGHT, type(uint256).max);
        harness.supplyCollateral(market, 0, 2_000_000e18, victim);
        vm.stopPrank();

        Offer memory victimOffer = _offer(false, TICK_98, uint128(VICTIM_UNITS));
        victimOffer.maker                   = victim;
        victimOffer.receiverIfMakerIsSeller = victim;

        _buy(victimOffer, VICTIM_UNITS, type(uint256).max);

        slasher = new SlashingCallback(MIDNIGHT, oracle, victim);

        loanToken.mint(address(slasher), 10_000_000e18);
        slasher.approveMidnight(address(loanToken));
    }

    // The exact credit delta check is what catches a write down landing inside the batch.
    function test_buyMidnight_slashedMidBatch() public {
        uint256 creditBefore = _credit();

        Offer memory offer = _offer(false, TICK_98, 1_000e18);
        offer.callback = address(slasher);

        vm.expectRevert("MidnightLib/credit-delta-mismatch");
        _buy(offer, 1_000e18, type(uint256).max);

        assertEq(_credit(),                       creditBefore);
        assertEq(midnight.lossFactor(marketId),   0);
        assertEq(midnight.debt(marketId, victim), VICTIM_UNITS);
    }

    function test_sellMidnight_slashedMidBatch() public {
        uint256 creditBefore = _credit();
        uint256 units        = VICTIM_UNITS / 2;

        Offer memory offer = _offer(true, TICK_99, uint128(units));
        offer.callback = address(slasher);

        vm.expectRevert("MidnightLib/credit-delta-mismatch");
        _sell(offer, units, 1);

        assertEq(_credit(),                       creditBefore);
        assertEq(midnight.lossFactor(marketId),   0);
        assertEq(midnight.debt(marketId, victim), VICTIM_UNITS);
    }

}

contract ForeignControllerMidnightRateLimitPolicyTests is MidnightTestBase {

    uint256 constant SEEDED_UNITS = 1_000_000e18;

    function setUp() public override {
        super.setUp();

        _seedCredit(SEEDED_UNITS);
    }

    // The intended production setting: exit keys unlimited, so only the entry key ever gates.
    function test_midnightExits_workWithUnlimitedExitKeysAndNoBuyKey() public {
        vm.startPrank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(buyKey, 0, 0);
        rateLimits.setUnlimitedRateLimitData(sellKey);
        rateLimits.setUnlimitedRateLimitData(redeemKey);
        vm.stopPrank();

        uint256 sold     = SEEDED_UNITS / 2;
        uint256 expected = _sellerAssets(sold, TICK_99);

        assertEq(_sell(_offer(true, TICK_99, uint128(sold)), sold, expected), expected);

        _repay(SEEDED_UNITS - sold);

        assertEq(_redeem(SEEDED_UNITS - sold, SEEDED_UNITS - sold), SEEDED_UNITS - sold);

        assertEq(_credit(),                                 0);
        assertEq(rateLimits.getCurrentRateLimit(buyKey),    0);
        assertEq(rateLimits.getCurrentRateLimit(sellKey),   type(uint256).max);
        assertEq(rateLimits.getCurrentRateLimit(redeemKey), type(uint256).max);
    }

    // Selling above the entry price hands back more than was spent; the restore stops at the cap.
    function test_sellMidnight_restoreIsCappedAtMaxAmount() public {
        uint256 expected = _sellerAssets(SEEDED_UNITS, TICK_99);

        assertGt(expected, _buyerAssets(SEEDED_UNITS, TICK_98));

        assertEq(_sell(_offer(true, TICK_99, uint128(SEEDED_UNITS)), SEEDED_UNITS, expected), expected);

        assertEq(rateLimits.getCurrentRateLimit(buyKey), 5_000_000e18);
    }

    // A permitted continuous fee accrues against the position, and the decayed credit still exits whole.
    function test_midnight_continuousFeeRoundTrip() public {
        _setFees(0, 0, MidnightLib.MAX_CONTINUOUS_FEE);

        uint256 units = 1_000_000e18;

        assertEq(_buy(_offer(false, TICK_98, uint128(units)), units, type(uint256).max), _buyerAssets(units, TICK_98));

        uint256 creditAtEntry = _credit();

        vm.warp(block.timestamp + 90 days);

        uint256 creditAfterDecay = _credit();

        assertLt(creditAfterDecay, creditAtEntry);
        assertGt(creditAfterDecay, creditAtEntry - creditAtEntry / 100);  // 1% a year is the cap

        uint256 expected = _sellerAssets(creditAfterDecay, TICK_99);

        assertEq(_sell(_offer(true, TICK_99, uint128(creditAfterDecay)), creditAfterDecay, expected), expected);

        assertEq(_credit(),                                  0);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
    }

}

contract ForeignControllerMidnightAuthorizationTests is MidnightTestBase {

    // Taker mode authorizes nobody, which is what contains a maker callback. Maker mode will have to
    // authorize a ratifier and replace this invariant with limits on what that ratifier signs.
    function test_midnight_proxyAuthorizesNobody() public {
        uint256 units = 1_000_000e18;

        _seedCredit(units);
        _sell(_offer(true, TICK_99, uint128(units / 2)), units / 2, 1);

        _repay(units / 4);

        assertEq(_redeem(units / 4, units / 4), units / 4);

        assertFalse(harness.isAuthorized(address(almProxy), address(foreignController)));
        assertFalse(harness.isAuthorized(address(almProxy), ALM_RELAYER));
        assertFalse(harness.isAuthorized(address(almProxy), GROVE_EXECUTOR));
        assertFalse(harness.isAuthorized(address(almProxy), maker));
        assertFalse(harness.isAuthorized(address(almProxy), address(ratifier)));
        assertFalse(harness.isAuthorized(address(almProxy), MIDNIGHT));

        // Nor does it leave an allowance behind between calls.
        assertEq(loanToken.allowance(address(almProxy), MIDNIGHT), 0);
    }

}

// Both legs are denominated in the loan token, so decimals travel through the price arithmetic. No
// mainstream USD stablecoin has 8 decimals; real USDC covers 6 in the live market suite.
abstract contract MidnightDecimalsTestBase is MidnightTestBase {

    function test_midnight_roundTrip() public {
        uint256 units       = 1_000_000 * loanUnit;
        uint256 buySpend    = _buyerAssets(units, TICK_98);
        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));

        assertEq(loanToken.decimals(), _loanTokenDecimals());

        assertEq(_buy(_offer(false, TICK_98, uint128(units)), units, buySpend), buySpend);

        assertEq(_credit(),                              units);
        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore - buySpend);
        assertLt(buySpend,                               units);

        uint256 sellUnits    = units / 2;
        uint256 sellProceeds = _sellerAssets(sellUnits, TICK_99);

        assertEq(_sell(_offer(true, TICK_99, uint128(sellUnits)), sellUnits, sellProceeds), sellProceeds);

        assertEq(_credit(), units - sellUnits);

        _repay(units - sellUnits);

        assertEq(_redeem(units - sellUnits, units - sellUnits), units - sellUnits);

        assertEq(_credit(),                              0);
        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore - buySpend + sellProceeds + units - sellUnits);
    }

}

contract ForeignControllerMidnightSixDecimalsTests is MidnightDecimalsTestBase {

    function _loanTokenDecimals() internal override pure returns (uint8) { return 6; }

}

contract ForeignControllerMidnightEightDecimalsTests is MidnightDecimalsTestBase {

    function _loanTokenDecimals()       internal override pure returns (uint8) { return 8; }
    function _collateralTokenDecimals() internal override pure returns (uint8) { return 8; }

}

contract ForeignControllerMidnightLiveMarketTests is MidnightTestBase {

    // A market Midnight governance created on Base at block 48,417,793: real USDC loan token, real
    // cbBTC collateral at 0.98 LLTV, maturing 2026-12-25.
    bytes32 constant LIVE_MARKET_ID = 0xf3c7f4711fe76099bb55aabeeceb0010892e6fac3cde4c90415345b8079e1f3c;

    function setUp() public override {
        super.setUp();

        Market memory liveMarket = midnight.toMarket(LIVE_MARKET_ID);

        // The reality check: the vendored derivation has to reproduce an id the protocol assigned.
        assertEq(MidnightIdLib.toId(liveMarket), LIVE_MARKET_ID);

        // Field by field because solc cannot copy an array of structs into storage.
        delete market.collateralParams;

        market.chainId        = liveMarket.chainId;
        market.midnight       = liveMarket.midnight;
        market.loanToken      = liveMarket.loanToken;
        market.maturity       = liveMarket.maturity;
        market.rcfThreshold   = liveMarket.rcfThreshold;
        market.enterGate      = liveMarket.enterGate;
        market.liquidatorGate = liveMarket.liquidatorGate;

        for (uint256 i = 0; i < liveMarket.collateralParams.length; i++) {
            market.collateralParams.push(liveMarket.collateralParams[i]);
        }

        marketId        = LIVE_MARKET_ID;
        loanToken       = MockERC20(liveMarket.loanToken);                        // never minted, dealt
        collateralToken = MockERC20(liveMarket.collateralParams[0].token);
        loanUnit        = 10 ** loanToken.decimals();
        collateralUnit  = 10 ** collateralToken.decimals();

        assertEq(loanToken.decimals(),           6);
        assertEq(collateralToken.decimals(),     8);
        assertEq(midnight.tickSpacing(marketId), TICK_SPACING);
        assertGt(market.maturity,                block.timestamp);

        deal(address(loanToken),       maker,             100_000_000 * loanUnit);
        deal(address(loanToken),       address(almProxy), 10_000_000  * loanUnit);
        deal(address(collateralToken), maker,             1_000       * collateralUnit);

        vm.startPrank(maker);
        loanToken.approve(MIDNIGHT, type(uint256).max);
        collateralToken.approve(MIDNIGHT, type(uint256).max);
        harness.supplyCollateral(market, 0, 1_000 * collateralUnit, maker);
        vm.stopPrank();

        _wireRateLimitsAndConfig();
    }

    // Governance onboarding of a market that already exists lands under the protocol's own id.
    function test_midnightLiveMarket_configIsKeyedByProtocolId() public view {
        ( uint16 maxBuyTick, uint16 minSellTick, , ) =
            foreignController.midnightMarketConfigs(LIVE_MARKET_ID);

        assertEq(maxBuyTick,  TICK_99);
        assertEq(minSellTick, TICK_98);
    }

    function test_midnightLiveMarket_roundTrip() public {
        uint256 units         = 1_000_000 * loanUnit;
        uint256 buySpend      = _buyerAssets(units, TICK_98);
        uint256 balanceBefore = loanToken.balanceOf(address(almProxy));

        assertEq(_buy(_offer(false, TICK_98, uint128(units)), units, buySpend), buySpend);

        assertEq(_credit(),                              units);
        assertEq(midnight.debt(marketId, maker),         units);
        assertEq(loanToken.balanceOf(address(almProxy)), balanceBefore - buySpend);
        assertLt(buySpend,                               units);

        uint256 sellUnits    = units / 2;
        uint256 sellProceeds = _sellerAssets(sellUnits, TICK_99);

        assertEq(_sell(_offer(true, TICK_99, uint128(sellUnits)), sellUnits, sellProceeds), sellProceeds);

        assertEq(_credit(), units - sellUnits);

        _repay(units - sellUnits);

        assertEq(_redeem(units - sellUnits, units - sellUnits), units - sellUnits);

        assertEq(_credit(),                                  0);
        assertEq(midnight.debt(marketId, address(almProxy)), 0);
        assertEq(
            loanToken.balanceOf(address(almProxy)),
            balanceBefore - buySpend + sellProceeds + units - sellUnits
        );
    }

}
