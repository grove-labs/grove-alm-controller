// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { AccessControl } from "openzeppelin-contracts/contracts/access/AccessControl.sol";

import { ECDSA } from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

import { IRateLimits } from "./interfaces/IRateLimits.sol";

import { Offer } from "./interfaces/MidnightInterfaces.sol";

import { MidnightLib }     from "./libraries/MidnightLib.sol";
import {
    OFFER_TYPEHASH as CANONICAL_OFFER_TYPEHASH,
    MidnightHashLib
} from "./libraries/midnight/MidnightHashLib.sol";
import { MidnightIdLib }   from "./libraries/midnight/MidnightIdLib.sol";
import { MidnightTickLib } from "./libraries/midnight/MidnightTickLib.sol";

interface IForeignControllerLike {
    function midnightMarketConfigs(bytes32 marketId)
        external view returns (MidnightLib.MarketConfig memory);

    function midnightOfferGroups(bytes32 marketId)
        external view returns (MidnightLib.OfferGroups memory);

    function midnightStrategyKey(address strategy, bytes32 marketId) external view returns (bytes32);
}

contract MidnightRatifier is AccessControl {

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    event QuoterSet(address indexed oldQuoter, address indexed newQuoter);

    /**********************************************************************************************/
    /*** State variables                                                                        ***/
    /**********************************************************************************************/

    bytes32 public constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    bytes32 public constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    // No salt: hashMarket already binds the venue and the chain.
    bytes32 public constant OFFER_TYPEHASH = CANONICAL_OFFER_TYPEHASH;

    string public constant NAME    = "GroveMidnightRatifier";
    string public constant VERSION = "1";

    address public immutable controller;
    address public immutable midnight;
    address public immutable proxy;

    IRateLimits public immutable rateLimits;

    uint256 public immutable maxOfferWindow;

    address public quoter;

    /**********************************************************************************************/
    /*** Initialization                                                                         ***/
    /**********************************************************************************************/

    constructor(
        address admin_,
        address midnight_,
        address proxy_,
        address controller_,
        address rateLimits_,
        address quoter_,
        uint256 maxOfferWindow_
    ) {
        require(admin_          != address(0), "MidnightRatifier/invalid-admin");
        require(midnight_       != address(0), "MidnightRatifier/invalid-midnight");
        require(proxy_          != address(0), "MidnightRatifier/invalid-proxy");
        require(controller_     != address(0), "MidnightRatifier/invalid-controller");
        require(rateLimits_     != address(0), "MidnightRatifier/invalid-rate-limits");
        require(quoter_         != address(0), "MidnightRatifier/invalid-quoter");
        require(maxOfferWindow_ != 0,          "MidnightRatifier/invalid-offer-window");

        controller     = controller_;
        midnight       = midnight_;
        proxy          = proxy_;
        rateLimits     = IRateLimits(rateLimits_);
        maxOfferWindow = maxOfferWindow_;
        quoter         = quoter_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /**********************************************************************************************/
    /*** Admin functions                                                                        ***/
    /**********************************************************************************************/

    function setQuoter(address newQuoter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newQuoter != address(0), "MidnightRatifier/invalid-quoter");

        emit QuoterSet(quoter, newQuoter);

        quoter = newQuoter;
    }

    /**********************************************************************************************/
    /*** Ratification                                                                           ***/
    /**********************************************************************************************/

    function isRatified(Offer memory offer, bytes memory data, address)
        external view returns (bytes32)
    {
        // First, because every check below reads policy keyed by an id taken from the offer itself.
        _checkSignature(offer, data);

        bytes32 marketId = MidnightIdLib.toId(offer.market);

        _checkIdentity(offer);
        _checkPolicy(offer, marketId);

        return CALLBACK_SUCCESS;
    }

    /**********************************************************************************************/
    /*** View functions                                                                         ***/
    /**********************************************************************************************/

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256(bytes(NAME)),
            keccak256(bytes(VERSION)),
            block.chainid,
            address(this)
        ));
    }

    function hashOffer(Offer memory offer) external view returns (bytes32) {
        return _hashOffer(offer);
    }

    /**********************************************************************************************/
    /*** Internal functions                                                                     ***/
    /**********************************************************************************************/

    function _checkIdentity(Offer memory offer) internal view {
        require(offer.maker           == proxy,         "MidnightRatifier/maker-not-proxy");
        require(offer.ratifier        == address(this), "MidnightRatifier/ratifier-mismatch");
        require(offer.market.midnight == midnight,      "MidnightRatifier/invalid-midnight");

        // Midnight requires the unused receiver to be zero, so this field inverts with direction.
        require(
            offer.buy
                ? offer.receiverIfMakerIsSeller == address(0)
                : offer.receiverIfMakerIsSeller == proxy,
            "MidnightRatifier/invalid-receiver"
        );
    }

    function _checkSignature(Offer memory offer, bytes memory data) internal view {
        ( address signer, ECDSA.RecoverError err, )
            = ECDSA.tryRecover(_hashOffer(offer), data);

        require(
            err == ECDSA.RecoverError.NoError && signer == quoter,
            "MidnightRatifier/invalid-signature"
        );
    }

    function _checkPolicy(Offer memory offer, bytes32 marketId) internal view {
        MidnightLib.MarketConfig memory config
            = IForeignControllerLike(controller).midnightMarketConfigs(marketId);

        require(config.maxOfferSize != 0, "MidnightRatifier/make-not-enabled");

        require(offer.start     <= offer.expiry, "MidnightRatifier/invalid-offer-window");
        require(block.timestamp <= offer.expiry, "MidnightRatifier/offer-expired");

        require(
            offer.expiry - offer.start <= maxOfferWindow,
            "MidnightRatifier/offer-window-too-long"
        );

        require(
            (offer.maxAssets != 0 ? offer.maxAssets : offer.maxUnits) <= config.maxOfferSize,
            "MidnightRatifier/offer-too-large"
        );

        // Midnight compares this cap against the market's per-second rate, not the annual figure.
        require(
            offer.continuousFeeCap
                <= MidnightLib.continuousFeePerSecond(config.maxContinuousFee),
            "MidnightRatifier/fee-cap-too-high"
        );

        MidnightLib.OfferGroups memory groups
            = IForeignControllerLike(controller).midnightOfferGroups(marketId);

        bytes32 expectedGroup = offer.buy ? groups.buyGroup : groups.sellGroup;

        // Zero means not yet designated; matching on it would merge the buy and sell books.
        require(expectedGroup != 0,            "MidnightRatifier/group-not-designated");
        require(offer.group == expectedGroup,  "MidnightRatifier/group-mismatch");

        _checkPrice(offer, marketId, config);
    }

    function _checkPrice(
        Offer memory offer,
        bytes32 marketId,
        MidnightLib.MarketConfig memory config
    )
        internal view
    {
        uint256 timeToMaturity = config.maturity > block.timestamp
            ? config.maturity - block.timestamp
            : 0;

        uint256 feePerSecond = MidnightLib.continuousFeePerSecond(config.maxContinuousFee);
        uint256 offerPrice   = MidnightTickLib.tickToPrice(offer.tick);

        if (offer.buy) {
            require(offer.tick <= config.maxBuyTick, "MidnightRatifier/tick-too-high");

            require(
                offerPrice
                    <= MidnightLib.maxBuyPrice(config.minBuyYield, timeToMaturity, feePerSecond),
                "MidnightRatifier/price-too-high"
            );

            require(
                rateLimits.getRateLimitData(
                    IForeignControllerLike(controller).midnightStrategyKey(offer.callback, marketId)
                ).maxAmount != 0,
                "MidnightRatifier/callback-not-keyed"
            );
        } else {
            require(offer.reduceOnly,                 "MidnightRatifier/sell-not-reduce-only");
            require(offer.tick >= config.minSellTick, "MidnightRatifier/tick-too-low");

            // Fee is crystallized at purchase; a later rate cannot change what we already hold.
            require(
                offerPrice
                    >= MidnightLib.minSellPrice(config.maxSellYield, timeToMaturity, 0),
                "MidnightRatifier/price-too-low"
            );

            require(offer.callback == address(0), "MidnightRatifier/callback-must-be-zero");
        }
    }

    function _hashOffer(Offer memory offer) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(hex"1901", DOMAIN_SEPARATOR(), MidnightHashLib.hashOffer(offer))
        );
    }

}
