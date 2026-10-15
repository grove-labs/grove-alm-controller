// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.21;

import { CollateralParams, Market, Offer } from "../../interfaces/MidnightInterfaces.sol";

// Vendored from morpho-org/midnight @ 70607569ac348e9880b512ffd3b574be55405932, src/ratifiers/libraries/HashLib.sol.
// Hashing only; the offer-tree helpers are omitted because we ratify single offers, not Merkle roots.
// The struct hashes must match upstream byte for byte or a signature produced against the published
// typehashes would not verify here.

/// @dev keccak256("CollateralParams(address token,uint256 lltv,uint256 liquidationCursor,address oracle)").
bytes32 constant COLLATERAL_PARAMS_TYPEHASH = 0x39ed3f928d24fd00574b1a02aba9c2483abcf5d9a3a366118c9a5aa29885b841;
/// @dev keccak256(bytes.concat(MARKET_TYPE, COLLATERAL_PARAMS_TYPE)).
bytes32 constant MARKET_TYPEHASH = 0x510b3862f3816a109c9340b76972e8a30984246be06e034ae12ed2934220391a;
/// @dev keccak256(bytes.concat(OFFER_TYPE, COLLATERAL_PARAMS_TYPE, MARKET_TYPE)).
bytes32 constant OFFER_TYPEHASH = 0x9905214264a9fb7b6cc1b0e33db7a04687c6e4185a84755d29914314aa9d8906;

library MidnightHashLib {

    function hashCollateralParams(CollateralParams memory collateralParams)
        internal pure returns (bytes32)
    {
        return keccak256(
            abi.encode(
                COLLATERAL_PARAMS_TYPEHASH,
                collateralParams.token,
                collateralParams.lltv,
                collateralParams.liquidationCursor,
                collateralParams.oracle
            )
        );
    }

    function hashMarket(Market memory market) internal pure returns (bytes32) {
        bytes32[] memory collateralParamsHashes = new bytes32[](market.collateralParams.length);

        for (uint256 i = 0; i < market.collateralParams.length; i++) {
            collateralParamsHashes[i] = hashCollateralParams(market.collateralParams[i]);
        }

        // Upstream keccaks the array body in assembly; packing the words is the same bytes.
        bytes32 collateralParamsHash = keccak256(abi.encodePacked(collateralParamsHashes));

        return keccak256(
            abi.encode(
                MARKET_TYPEHASH,
                market.chainId,
                market.midnight,
                market.loanToken,
                collateralParamsHash,
                market.maturity,
                market.rcfThreshold,
                market.enterGate,
                market.liquidatorGate
            )
        );
    }

    function hashOffer(Offer memory offer) internal pure returns (bytes32) {
        // Every encoded member is a static word, so concatenating the halves is identical to
        // upstream's single encode of all sixteen, which does not fit on the legacy-pipeline stack.
        return keccak256(bytes.concat(
            abi.encode(
                OFFER_TYPEHASH,
                hashMarket(offer.market),
                offer.buy,
                offer.maker,
                offer.start,
                offer.expiry,
                offer.tick,
                offer.group
            ),
            abi.encode(
                offer.callback,
                keccak256(offer.callbackData),
                offer.receiverIfMakerIsSeller,
                offer.ratifier,
                offer.reduceOnly,
                offer.maxUnits,
                offer.maxAssets,
                offer.continuousFeeCap
            )
        ));
    }

}
