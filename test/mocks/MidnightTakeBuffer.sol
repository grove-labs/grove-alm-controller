// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IERC20 }          from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }       from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

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

contract MidnightTakeBuffer is ReentrancyGuard {

    using SafeERC20 for IERC20;

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    event Rescued(address indexed token, uint256 amount);

    /**********************************************************************************************/
    /*** Errors                                                                                 ***/
    /**********************************************************************************************/

    error ZeroMidnight();
    error ZeroProxy();

    error AddressNotMidnight();
    error AddressNotProxy();
    error AddressNotStrategy();
    error NothingToRescue();
    error NotSupported();

    /**********************************************************************************************/
    /*** Constants and Immutables                                                               ***/
    /**********************************************************************************************/

    bytes32 public constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address public immutable midnight;
    address public immutable proxy;

    constructor(address midnight_, address proxy_) {
        if (midnight_ == address(0)) revert ZeroMidnight();
        if (proxy_    == address(0)) revert ZeroProxy();

        midnight = midnight_;
        proxy    = proxy_;
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
        nonReentrant
        returns (bytes32)
    {
        _onlyMidnight(msg.sender);
        _onlyProxy(buyer);

        return CALLBACK_SUCCESS;
    }

    function onSell(
        bytes32,
        Market  memory market,
        uint256,
        uint256,
        uint256,
        address        seller,
        address        receiver,
        bytes   memory
    )
        external
        nonReentrant
        returns (bytes32)
    {
        _onlyMidnight(msg.sender);
        _onlyProxy(seller);
        _onlyStrategy(receiver);

        IERC20(market.loanToken).forceApprove(
            proxy, IERC20(market.loanToken).balanceOf(address(this))
        );

        revert NotSupported();
    }

    function rescue(address) external pure {
        revert NotSupported();
    }

    /**********************************************************************************************/
    /*** Internal Functions                                                                     ***/
    /**********************************************************************************************/

    function _onlyMidnight(address midnight_) internal view {
        if (midnight_ != midnight) revert AddressNotMidnight();
    }

    function _onlyProxy(address proxy_) internal view {
        if (proxy_ != proxy) revert AddressNotProxy();
    }

    function _onlyStrategy(address strategy_) internal view {
        if (strategy_ != address(this)) revert AddressNotStrategy();
    }

}
