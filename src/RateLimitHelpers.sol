// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

library RateLimitHelpers {

    function makeAssetKey(bytes32 key, address asset) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, asset));
    }

    function makeAssetDestinationKey(bytes32 key, address asset, address destination) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, asset, destination));
    }

    function makeDomainKey(bytes32 key, uint32 domain) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, domain));
    }

    function makeAddressUint256Key(bytes32 key, address addr, uint256 value) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, addr, value));
    }

    function makeAddressUint256AddressUint16AddressKey(bytes32 key, address addr1, uint256 value1, address addr2, uint16 value2, address addr3) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, addr1, value1, addr2, value2, addr3));
    }

}
