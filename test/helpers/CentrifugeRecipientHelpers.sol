// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

library CentrifugeRecipientHelpers {

    function addressToCentrifugeRecipient(address account) internal pure returns (bytes32) {
        return bytes32(bytes20(account));
    }

    // Same check as Centrifuge CastLib.toAddress, which the destination applies to the recipient.
    function centrifugeRecipientToAddress(bytes32 recipient) internal pure returns (address) {
        require(uint96(uint256(recipient)) == 0, "Input should be 20 bytes");
        return address(bytes20(recipient));
    }

}
