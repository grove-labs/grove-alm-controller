// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20Decimals is ERC20 {
    
    uint8 public immutable _decimals;
    
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol) {
        _decimals = decimals;
    }
    
}