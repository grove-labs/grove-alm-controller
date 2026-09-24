// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import "../UnitTestBase.t.sol";

import { MidnightLib } from "../../../src/libraries/MidnightLib.sol";

contract MidnightLibWrapper {

    function continuousFeePerSecond(uint256 cbpsPerYear) public pure returns (uint256) {
        return MidnightLib.continuousFeePerSecond(cbpsPerYear);
    }

    function maxBuyPrice(uint256 minYield, uint256 timeToMaturity, uint256 continuousFee)
        public pure returns (uint256)
    {
        return MidnightLib.maxBuyPrice(minYield, timeToMaturity, continuousFee);
    }

    function minSellPrice(uint256 maxYield, uint256 timeToMaturity, uint256 continuousFee)
        public pure returns (uint256)
    {
        return MidnightLib.minSellPrice(maxYield, timeToMaturity, continuousFee);
    }

}

contract MidnightLibTestBase is UnitTestBase {

    uint256 internal constant MAX_TIME_TO_MATURITY = 100 * 365 days;  // Midnight's own ceiling.

    MidnightLibWrapper wrapper;

    function setUp() public {
        wrapper = new MidnightLibWrapper();
    }

}

contract MidnightLibContinuousFeeTests is MidnightLibTestBase {

    function test_continuousFeePerSecond_ceilingMatchesUpstream() public view {
        assertEq(wrapper.continuousFeePerSecond(1_00_00), MidnightLib.MAX_CONTINUOUS_FEE);
    }

    function test_continuousFeePerSecond_zero() public view {
        assertEq(wrapper.continuousFeePerSecond(0), 0);
    }

    function test_continuousFeePerSecond_floors() public view {
        assertEq(wrapper.continuousFeePerSecond(1), uint256(1e12) / uint256(365 days));

        assertLe(wrapper.continuousFeePerSecond(1) * 365 days, 1e12);
    }

    function testFuzz_continuousFeePerSecond_nonDecreasing(uint16 cbps) public view {
        cbps = uint16(bound(cbps, 1, type(uint16).max));

        assertGe(wrapper.continuousFeePerSecond(cbps), wrapper.continuousFeePerSecond(cbps - 1));
    }

}

contract MidnightLibYieldPriceTests is MidnightLibTestBase {

    // Simple interest on cost: the yield a price implies over the term, annualized ACT/365.
    function _earnsAtLeast(uint256 price, uint256 ttm, uint256 fee, uint256 yieldBp)
        internal pure returns (bool)
    {
        uint256 payoff = MidnightLib.WAD - fee * ttm;

        if (price > payoff) return false;

        return (payoff - price) * MidnightLib.YEAR * MidnightLib.WAD
            >= yieldBp * MidnightLib.YIELD_BP_RATE * ttm * price;
    }

    function _givesUpAtMost(uint256 price, uint256 ttm, uint256 fee, uint256 yieldBp)
        internal pure returns (bool)
    {
        uint256 payoff = MidnightLib.WAD - fee * ttm;

        if (price > payoff) return true;

        return (payoff - price) * MidnightLib.YEAR * MidnightLib.WAD
            <= yieldBp * MidnightLib.YIELD_BP_RATE * ttm * price;
    }

    // Par discounted by 1.05, floored for the buy ceiling and ceilinged for the sell floor.
    function test_yieldPrice_anchors() public view {
        assertEq(wrapper.maxBuyPrice(5_00, 365 days, 0),  952380952380952380);
        assertEq(wrapper.minSellPrice(5_00, 365 days, 0), 952380952380952381);
    }

    // Pinned against an independent model of the same formula.
    function test_yieldPrice_modelAnchors() public view {
        assertEq(wrapper.maxBuyPrice(1_00,   30 days, 0),  999178757185874623);
        assertEq(wrapper.maxBuyPrice(4_00,  180 days, 0),  980655561526061257);
        assertEq(wrapper.maxBuyPrice(10_00, 360 days, 0),  910224438902743142);
        assertEq(wrapper.minSellPrice(4_00, 180 days, 0),  980655561526061258);
        assertEq(wrapper.minSellPrice(10_00, 30 days, 0),  991847826086956522);

        assertEq(
            wrapper.maxBuyPrice(4_00, 180 days, MidnightLib.MAX_CONTINUOUS_FEE),
            975819451920351638
        );
    }

    // The bound is the exact price at which the yield is met: one wei the wrong way is not.
    function testFuzz_yieldPrice_impliedYieldIsTight(
        uint256 yieldBp,
        uint256 timeToMaturity,
        uint256 continuousFee
    )
        public view
    {
        yieldBp        = bound(yieldBp, 0, type(uint16).max);
        timeToMaturity = bound(timeToMaturity, 0, MAX_TIME_TO_MATURITY);
        continuousFee  = bound(continuousFee, 0, MidnightLib.MAX_CONTINUOUS_FEE);

        uint256 buyCap    = wrapper.maxBuyPrice(yieldBp, timeToMaturity, continuousFee);
        uint256 sellFloor = wrapper.minSellPrice(yieldBp, timeToMaturity, continuousFee);

        assertTrue(_earnsAtLeast(buyCap,      timeToMaturity, continuousFee, yieldBp));
        assertFalse(_earnsAtLeast(buyCap + 1, timeToMaturity, continuousFee, yieldBp));

        assertTrue(_givesUpAtMost(sellFloor,      timeToMaturity, continuousFee, yieldBp));
        assertFalse(_givesUpAtMost(sellFloor - 1, timeToMaturity, continuousFee, yieldBp));
    }

    function test_yieldPrice_zeroTimeToMaturity() public view {
        assertEq(wrapper.maxBuyPrice(50_00, 0, MidnightLib.MAX_CONTINUOUS_FEE),  1e18);
        assertEq(wrapper.minSellPrice(50_00, 0, MidnightLib.MAX_CONTINUOUS_FEE), 1e18);
    }

    // A zero bound is not a disabled bound: it still refuses a price above what a unit pays back.
    function test_yieldPrice_zeroYield() public view {
        uint256 fee = MidnightLib.MAX_CONTINUOUS_FEE;

        assertEq(wrapper.maxBuyPrice(0, 180 days, 0),   1e18);
        assertEq(wrapper.maxBuyPrice(0, 180 days, fee), 1e18 - fee * 180 days);
    }

    function test_yieldPrice_netsContinuousFee() public view {
        uint256 fee = MidnightLib.MAX_CONTINUOUS_FEE;

        assertLt(wrapper.maxBuyPrice(4_00, 180 days, fee),  wrapper.maxBuyPrice(4_00, 180 days, 0));
        assertLt(wrapper.minSellPrice(4_00, 180 days, fee), wrapper.minSellPrice(4_00, 180 days, 0));
    }

    // At both of Midnight's ceilings at once the payoff still stays above zero.
    function test_yieldPrice_extremeInputs() public view {
        uint256 fee    = MidnightLib.MAX_CONTINUOUS_FEE;
        uint256 yield_ = type(uint16).max;

        assertGt(wrapper.maxBuyPrice(yield_, MAX_TIME_TO_MATURITY, fee),  0);
        assertLe(wrapper.minSellPrice(yield_, MAX_TIME_TO_MATURITY, fee), 1e18);
    }

    function testFuzz_yieldPrice_nonIncreasingInYield(uint256 yieldBp, uint256 timeToMaturity)
        public view
    {
        yieldBp        = bound(yieldBp, 1, type(uint16).max);
        timeToMaturity = bound(timeToMaturity, 0, MAX_TIME_TO_MATURITY);

        assertLe(
            wrapper.maxBuyPrice(yieldBp, timeToMaturity, 0),
            wrapper.maxBuyPrice(yieldBp - 1, timeToMaturity, 0)
        );
        assertLe(
            wrapper.minSellPrice(yieldBp, timeToMaturity, 0),
            wrapper.minSellPrice(yieldBp - 1, timeToMaturity, 0)
        );
    }

    function testFuzz_yieldPrice_nonIncreasingInTerm(uint256 timeToMaturity) public view {
        timeToMaturity = bound(timeToMaturity, 1, MAX_TIME_TO_MATURITY);

        assertLe(
            wrapper.maxBuyPrice(4_00, timeToMaturity, 0),
            wrapper.maxBuyPrice(4_00, timeToMaturity - 1, 0)
        );
    }

    function testFuzz_yieldPrice_roundingBrackets(
        uint256 yieldBp,
        uint256 timeToMaturity,
        uint256 continuousFee
    )
        public view
    {
        yieldBp        = bound(yieldBp, 0, type(uint16).max);
        timeToMaturity = bound(timeToMaturity, 0, MAX_TIME_TO_MATURITY);
        continuousFee  = bound(continuousFee, 0, MidnightLib.MAX_CONTINUOUS_FEE);

        uint256 buyCap    = wrapper.maxBuyPrice(yieldBp, timeToMaturity, continuousFee);
        uint256 sellFloor = wrapper.minSellPrice(yieldBp, timeToMaturity, continuousFee);

        assertGe(sellFloor, buyCap);
        assertLe(sellFloor - buyCap, 1);
        assertLe(sellFloor, 1e18);
    }

}
