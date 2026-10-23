// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import "../UnitTestBase.t.sol";

import { MidnightTickLib } from "../../../src/libraries/midnight/MidnightTickLib.sol";

contract MidnightTickLibWrapper {

    function tickToPrice(uint256 tick) public pure returns (uint256) {
        return MidnightTickLib.tickToPrice(tick);
    }

}

contract MidnightTickLibTests is UnitTestBase {

    MidnightTickLibWrapper wrapper;

    function setUp() public {
        wrapper = new MidnightTickLibWrapper();
    }

    // Pinned against an independent model of the upstream curve.
    function test_tickToPrice_modelTable() public view {
        uint16[31] memory ticks = [
            0,    250,  500,  750,  1000, 1250, 1500, 1750, 2000, 2250, 2500,
            2750, 3000, 3250, 3372, 3500, 3750, 4000, 4152, 4250, 4384, 4500,
            4750, 5000, 5250, 5500, 5750, 6000, 6250, 6500, 6744
        ];

        uint256[31] memory prices = [
            uint256(0),
            200_000_000_000,
            600_000_000_000,
            2_100_000_000_000,
            7_300_000_000_000,
            25_300_000_000_000,
            88_200_000_000_000,
            306_600_000_000_000,
            1_065_900_000_000_000,
            3_698_900_000_000_000,
            12_753_800_000_000_000,
            43_030_100_000_000_000,
            135_258_900_000_000_000,
            352_406_500_000_000_000,
            500_000_000_000_000_000,
            654_392_800_000_000_000,
            868_209_700_000_000_000,
            958_179_700_000_000_000,
            979_964_600_000_000_000,
            987_617_100_000_000_000,
            993_614_600_000_000_000,
            996_409_800_000_000_000,
            998_965_500_000_000_000,
            999_702_500_000_000_000,
            999_914_400_000_000_000,
            999_975_400_000_000_000,
            999_992_900_000_000_000,
            999_998_000_000_000_000,
            999_999_400_000_000_000,
            999_999_800_000_000_000,
            1_000_000_000_000_000_000
        ];

        for (uint256 i; i < ticks.length; ++i) {
            assertEq(wrapper.tickToPrice(ticks[i]), prices[i]);
        }
    }

}
