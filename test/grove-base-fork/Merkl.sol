// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { Base } from "lib/grove-address-registry/src/Base.sol";

import { MerklLib }         from "../../src/libraries/MerklLib.sol";
import { RateLimitHelpers } from "../../src/RateLimitHelpers.sol";

import "./ForkTestBase.t.sol";

interface IMerklDistributorLike {
    function toggleOperator(address user, address operator) external;
    function operators(address user, address operator) external view returns (uint256);
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}

contract MerklBaseTest is ForkTestBase {

    event OperatorToggled(address indexed user, address indexed operator, bool isWhitelisted);

    address operator1 = makeAddr("operator1");
    address operator2 = makeAddr("operator2");

    IMerklDistributorLike merklDistributor = IMerklDistributorLike(Base.MERKL_DISTRIBUTOR);

    function _toggleKey(address operator) internal view returns (bytes32) {
        return RateLimitHelpers.makeAddressAddressKey(
            MerklLib.LIMIT_MERKL_TOGGLE_OPERATOR, operator, address(merklDistributor)
        );
    }

    function _allowOperator(address operator) internal {
        vm.prank(GROVE_EXECUTOR);
        rateLimits.setUnlimitedRateLimitData(_toggleKey(operator));
    }

}

contract ForeignControllerToggleOperatorMerklFailureTests is MerklBaseTest {

    function test_toggleOperatorMerkl_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.toggleOperatorMerkl(address(merklDistributor), operator1);
    }

    function test_toggleOperatorMerkl_invalidAction() external {
        vm.expectRevert("MerklLib/invalid-action");
        vm.prank(relayer);
        foreignController.toggleOperatorMerkl(address(merklDistributor), operator1);
    }

    function test_toggleOperatorMerkl_otherOperatorKeyNotHonoured() external {
        _allowOperator(operator2);

        vm.expectRevert("MerklLib/invalid-action");
        vm.prank(relayer);
        foreignController.toggleOperatorMerkl(address(merklDistributor), operator1);
    }

    function test_toggleOperatorMerkl_otherDistributorKeyNotHonoured() external {
        address otherDistributor = makeAddr("otherDistributor");

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setUnlimitedRateLimitData(RateLimitHelpers.makeAddressAddressKey(
            MerklLib.LIMIT_MERKL_TOGGLE_OPERATOR, operator1, otherDistributor
        ));

        vm.expectRevert("MerklLib/invalid-action");
        vm.prank(relayer);
        foreignController.toggleOperatorMerkl(address(merklDistributor), operator1);
    }

    function test_toggleOperatorMerkl_reversedKeyNotHonoured() external {
        // The facet key is (id, operator, distributor); the reverse order does not authorize.
        vm.prank(GROVE_EXECUTOR);
        rateLimits.setUnlimitedRateLimitData(RateLimitHelpers.makeAddressAddressKey(
            MerklLib.LIMIT_MERKL_TOGGLE_OPERATOR, address(merklDistributor), operator1
        ));

        vm.expectRevert("MerklLib/invalid-action");
        vm.prank(relayer);
        foreignController.toggleOperatorMerkl(address(merklDistributor), operator1);
    }

}

contract ForeignControllerToggleOperatorMerklSuccessTests is MerklBaseTest {

    function setUp() public override {
        super.setUp();

        _allowOperator(operator1);
        _allowOperator(operator2);
    }

    function test_toggleOperatorMerkl_singleOperator() external {
        assertEq(merklDistributor.operators(address(almProxy), operator1), 0);

        vm.prank(relayer);
        vm.expectEmit(address(merklDistributor));
        emit OperatorToggled(address(almProxy), operator1, true);
        foreignController.toggleOperatorMerkl(address(merklDistributor), operator1);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 1);

        vm.prank(relayer);
        vm.expectEmit(address(merklDistributor));
        emit OperatorToggled(address(almProxy), operator1, false);
        foreignController.toggleOperatorMerkl(address(merklDistributor), operator1);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 0);

        vm.prank(relayer);
        vm.expectEmit(address(merklDistributor));
        emit OperatorToggled(address(almProxy), operator1, true);
        foreignController.toggleOperatorMerkl(address(merklDistributor), operator1);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 1);
    }

    function test_toggleOperatorMerkl_multipleOperators() external {
        assertEq(merklDistributor.operators(address(almProxy), operator1), 0);
        assertEq(merklDistributor.operators(address(almProxy), operator2), 0);

        vm.prank(relayer);
        foreignController.toggleOperatorMerkl(address(merklDistributor), operator1);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 1);
        assertEq(merklDistributor.operators(address(almProxy), operator2), 0);

        vm.prank(relayer);
        foreignController.toggleOperatorMerkl(address(merklDistributor), operator1);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 0);
        assertEq(merklDistributor.operators(address(almProxy), operator2), 0);

        vm.prank(relayer);
        foreignController.toggleOperatorMerkl(address(merklDistributor), operator1);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 1);
        assertEq(merklDistributor.operators(address(almProxy), operator2), 0);

        vm.prank(relayer);
        foreignController.toggleOperatorMerkl(address(merklDistributor), operator2);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 1);
        assertEq(merklDistributor.operators(address(almProxy), operator2), 1);
    }

}
