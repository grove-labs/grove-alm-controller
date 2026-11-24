// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";

import { TokenOutput } from "../../../src/interfaces/PendleInterfaces.sol";

contract MockPendleRouter {

    uint256 immutable shortfall;

    constructor(uint256 shortfall_) {
        shortfall = shortfall_;
    }

    function redeemPyToToken(address receiver, address, uint256, TokenOutput calldata output)
        external returns (uint256 netTokenOut)
    {
        netTokenOut = output.minTokenOut - shortfall;
        IERC20(output.tokenOut).transfer(receiver, netTokenOut);
    }

}
