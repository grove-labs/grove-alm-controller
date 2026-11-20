// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IERC20 }    from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

struct CollateralParams {
    address token;
    uint256 lltv;
    uint256 liquidationCursor;
    address oracle;
}

struct Market {
    uint256            chainId;
    address            midnight;
    address            loanToken;
    CollateralParams[] collateralParams;
    uint256            maturity;
    uint256            rcfThreshold;
    address            enterGate;
    address            liquidatorGate;
}

contract MidnightTakeBuffer {

    using SafeERC20 for IERC20;

    /**********************************************************************************************/
    /*** Errors                                                                                 ***/
    /**********************************************************************************************/

    error ZeroMidnight();
    error ZeroProxy();

    error BuyerNotProxy();
    error NotMidnight();

    /**********************************************************************************************/
    /*** Constants and Immutables                                                               ***/
    /**********************************************************************************************/

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address public immutable proxy;
    address public immutable midnight;

    constructor(address proxy_, address midnight_) {
        if (proxy_    == address(0)) revert ZeroProxy();
        if (midnight_ == address(0)) revert ZeroMidnight();

        proxy    = proxy_;
        midnight = midnight_;
    }

    /**********************************************************************************************/
    /*** External Functions                                                                     ***/
    /**********************************************************************************************/

    function approve(address token) external {
        IERC20(token).forceApprove(proxy,    type(uint256).max);
        IERC20(token).forceApprove(midnight, type(uint256).max);
    }

    function onBuy(
        bytes32,
        Market  memory,
        uint256,
        uint256,
        uint256,
        address        buyer,
        bytes   memory
    )
        external
        view
        returns (bytes32)
    {
        if (msg.sender != midnight) revert NotMidnight();
        if (buyer      != proxy)    revert BuyerNotProxy();

        return CALLBACK_SUCCESS;
    }

}
