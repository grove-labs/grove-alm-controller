// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.21;

import { Market } from "../../interfaces/MidnightInterfaces.sol";

// Vendored from morpho-org/midnight @ 70607569ac348e9880b512ffd3b574be55405932, src/libraries/IdLib.sol (toId only).

library MidnightIdLib {

    /// @dev Used as a prefix to some data, to give a creation code that deploys the data as runtime bytecode.
    bytes constant SSTORE2_PREFIX = hex"600b380380600b5f395ff3";

    function toId(Market memory market) internal pure returns (bytes32) {
        // The packed pair cannot collide: SSTORE2_PREFIX is a fixed size.
        return keccak256(
            abi.encodePacked(
                uint8(0xff),
                market.midnight,
                uint256(0),
                keccak256(abi.encodePacked(SSTORE2_PREFIX, abi.encode(market)))
            )
        );
    }

}
