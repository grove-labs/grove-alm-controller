// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

library RateLimitKeysLib {

    bytes32 internal constant LIMIT_4626_DEPOSIT         = keccak256("LIMIT_4626_DEPOSIT");
    bytes32 internal constant LIMIT_4626_WITHDRAW        = keccak256("LIMIT_4626_WITHDRAW");
    bytes32 internal constant LIMIT_7540_DEPOSIT         = keccak256("LIMIT_7540_DEPOSIT");
    bytes32 internal constant LIMIT_7540_REDEEM          = keccak256("LIMIT_7540_REDEEM");
    bytes32 internal constant LIMIT_AAVE_DEPOSIT         = keccak256("LIMIT_AAVE_DEPOSIT");
    bytes32 internal constant LIMIT_AAVE_WITHDRAW        = keccak256("LIMIT_AAVE_WITHDRAW");
    bytes32 internal constant LIMIT_ASSET_TRANSFER       = keccak256("LIMIT_ASSET_TRANSFER");
    bytes32 internal constant LIMIT_CENTRIFUGE_TRANSFER  = keccak256("LIMIT_CENTRIFUGE_TRANSFER");
    bytes32 internal constant LIMIT_CURVE_DEPOSIT        = keccak256("LIMIT_CURVE_DEPOSIT");
    bytes32 internal constant LIMIT_CURVE_SWAP           = keccak256("LIMIT_CURVE_SWAP");
    bytes32 internal constant LIMIT_CURVE_WITHDRAW       = keccak256("LIMIT_CURVE_WITHDRAW");
    bytes32 internal constant LIMIT_LAYERZERO_TRANSFER   = keccak256("LIMIT_LAYERZERO_TRANSFER");
    bytes32 internal constant LIMIT_PENDLE_PT_REDEEM     = keccak256("LIMIT_PENDLE_PT_REDEEM");
    bytes32 internal constant LIMIT_PSM_DEPOSIT          = keccak256("LIMIT_PSM_DEPOSIT");
    bytes32 internal constant LIMIT_PSM_WITHDRAW         = keccak256("LIMIT_PSM_WITHDRAW");
    bytes32 internal constant LIMIT_SUSDE_COOLDOWN       = keccak256("LIMIT_SUSDE_COOLDOWN");
    bytes32 internal constant LIMIT_USDC_TO_CCTP         = keccak256("LIMIT_USDC_TO_CCTP");
    bytes32 internal constant LIMIT_USDC_TO_DOMAIN       = keccak256("LIMIT_USDC_TO_DOMAIN");
    bytes32 internal constant LIMIT_USDE_BURN            = keccak256("LIMIT_USDE_BURN");
    bytes32 internal constant LIMIT_USDE_MINT            = keccak256("LIMIT_USDE_MINT");
    bytes32 internal constant LIMIT_USDS_MINT            = keccak256("LIMIT_USDS_MINT");
    bytes32 internal constant LIMIT_USDS_TO_USDC         = keccak256("LIMIT_USDS_TO_USDC");
    bytes32 internal constant LIMIT_UNISWAP_V3_DEPOSIT   = keccak256("LIMIT_UNISWAP_V3_DEPOSIT");
    bytes32 internal constant LIMIT_UNISWAP_V3_SWAP      = keccak256("LIMIT_UNISWAP_V3_SWAP");
    bytes32 internal constant LIMIT_UNISWAP_V3_WITHDRAW  = keccak256("LIMIT_UNISWAP_V3_WITHDRAW");

}
