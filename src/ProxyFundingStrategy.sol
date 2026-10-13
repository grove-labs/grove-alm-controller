// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { IERC20 }    from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { Market } from "./interfaces/MidnightInterfaces.sol";

interface IForeignControllerLike {
    function fundMidnightFill(bytes32 marketId, uint256 assets, uint256 units) external;
}

contract ProxyFundingStrategy is ReentrancyGuard {

    /**********************************************************************************************/
    /*** State variables                                                                        ***/
    /**********************************************************************************************/

    bytes32 public constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address public immutable controller;
    address public immutable midnight;
    address public immutable proxy;

    /**********************************************************************************************/
    /*** Initialization                                                                         ***/
    /**********************************************************************************************/

    constructor(address midnight_, address proxy_, address controller_) {
        require(midnight_   != address(0), "ProxyFundingStrategy/invalid-midnight");
        require(proxy_      != address(0), "ProxyFundingStrategy/invalid-proxy");
        require(controller_ != address(0), "ProxyFundingStrategy/invalid-controller");

        controller = controller_;
        midnight   = midnight_;
        proxy      = proxy_;
    }

    /**********************************************************************************************/
    /*** Midnight callback                                                                      ***/
    /**********************************************************************************************/

    function onBuy(
        bytes32        marketId,
        Market  memory market,
        uint256        buyerAssets,
        uint256        units,
        uint256,
        address        buyer,
        bytes   memory
    )
        external nonReentrant returns (bytes32)
    {
        require(msg.sender == midnight, "ProxyFundingStrategy/caller-not-midnight");
        require(buyer      == proxy,    "ProxyFundingStrategy/buyer-not-proxy");

        // A fill too small to price rounds to nothing to pay, and must still settle.
        if (buyerAssets == 0) return CALLBACK_SUCCESS;

        IForeignControllerLike(controller).fundMidnightFill(marketId, buyerAssets, units);

        SafeERC20.forceApprove(IERC20(market.loanToken), midnight, buyerAssets);

        return CALLBACK_SUCCESS;
    }

    /**********************************************************************************************/
    /*** Permissionless functions                                                               ***/
    /**********************************************************************************************/

    function skim(address token) external {
        SafeERC20.safeTransfer(IERC20(token), proxy, IERC20(token).balanceOf(address(this)));
    }

}
