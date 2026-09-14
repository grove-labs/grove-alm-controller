// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Morpho Association
pragma solidity ^0.8.21;

// Vendored from morpho-org/midnight @ 3e4e49e74cbc199b84f11afc94599929df215370,
// src/interfaces/IMidnight.sol. Structs are copied verbatim because the market id is a CREATE2
// address derived from abi.encode(market) (see MidnightIdLib). IMidnight is trimmed to the
// lend-side surface used here.

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

struct Offer {
    Market  market;
    bool    buy;
    address maker;
    uint256 start;
    uint256 expiry;
    uint256 tick;
    bytes32 group;
    address callback;
    bytes   callbackData;
    address receiverIfMakerIsSeller;
    address ratifier;
    bool    reduceOnly;
    uint128 maxUnits;
    uint128 maxAssets;  // buyerAssets if offer.buy else sellerAssets
    uint256 continuousFeeCap;
}

interface IMidnight {

    function take(
        Offer   memory offer,
        bytes   memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes   memory takerCallbackData
    ) external returns (uint256 buyerAssets, uint256 sellerAssets);

    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver) external;

    function touchMarket(Market memory market) external returns (bytes32);

    function updatePositionView(Market memory market, bytes32 id, address user)
        external view returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee);

    function toMarket(bytes32 id) external view returns (Market memory);

    function credit(bytes32 id, address user) external view returns (uint128);

    function debt(bytes32 id, address user) external view returns (uint128);

    function withdrawable(bytes32 id) external view returns (uint128);

    function lossFactor(bytes32 id) external view returns (uint128);

    function tickSpacing(bytes32 id) external view returns (uint8);

    function continuousFee(bytes32 id) external view returns (uint32);

    function settlementFee(bytes32 id, uint256 timeToMaturity) external view returns (uint256);

}
