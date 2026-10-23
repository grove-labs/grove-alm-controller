// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

library RateLimitIds {

    bytes32 public constant LIMIT_ASSET_TRANSFER = keccak256("LIMIT_ASSET_TRANSFER");
    bytes32 public constant LIMIT_SUSDE_COOLDOWN = keccak256("LIMIT_SUSDE_COOLDOWN");
    bytes32 public constant LIMIT_USDE_BURN      = keccak256("LIMIT_USDE_BURN");
    bytes32 public constant LIMIT_USDE_MINT      = keccak256("LIMIT_USDE_MINT");
    bytes32 public constant LIMIT_USDS_MINT      = keccak256("LIMIT_USDS_MINT");

}
