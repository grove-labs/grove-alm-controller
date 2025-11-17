// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { Ethereum } from "lib/grove-address-registry/src/Ethereum.sol";

import { IMerklDistributorLike } from "../../src/interfaces/MerklInterfaces.sol";

import "./ForkTestBase.t.sol";

contract MerklBaseTest is ForkTestBase {

    event OperatorToggled(address indexed user, address indexed operator, bool isWhitelisted);

    address operator1 = makeAddr("operator1");
    address operator2 = makeAddr("operator2");

    IMerklDistributorLike merklDistributor = IMerklDistributorLike(Ethereum.MERKL_DISTRIBUTOR);
}

contract MainnetControllerToggleOperatorMerklFailureTests is MerklBaseTest {

    function test_toggleOperatorMerkl_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        mainnetController.toggleOperatorMerkl(operator1);
    }

}

contract MainnetControllerToggleOperatorMerklSuccessTests is MerklBaseTest {

    function test_toggleOperatorMerkl_singleOperator() external {
        assertEq(merklDistributor.operators(address(almProxy), operator1), 0);

        vm.prank(relayer);
        vm.expectEmit(address(merklDistributor));
        emit OperatorToggled(address(almProxy), operator1, true);
        mainnetController.toggleOperatorMerkl(operator1);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 1);

        vm.prank(relayer);
        vm.expectEmit(address(merklDistributor));
        emit OperatorToggled(address(almProxy), operator1, false);
        mainnetController.toggleOperatorMerkl(operator1);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 0);

        vm.prank(relayer);
        vm.expectEmit(address(merklDistributor));
        emit OperatorToggled(address(almProxy), operator1, true);
        mainnetController.toggleOperatorMerkl(operator1);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 1);

    }

    function test_toggleOperatorMerkl_multipleOperators() external {
        assertEq(merklDistributor.operators(address(almProxy), operator1), 0);
        assertEq(merklDistributor.operators(address(almProxy), operator2), 0);

        vm.prank(relayer);
        mainnetController.toggleOperatorMerkl(operator1);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 1);
        assertEq(merklDistributor.operators(address(almProxy), operator2), 0);

        vm.prank(relayer);
        mainnetController.toggleOperatorMerkl(operator1);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 0);
        assertEq(merklDistributor.operators(address(almProxy), operator2), 0);

        vm.prank(relayer);
        mainnetController.toggleOperatorMerkl(operator1);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 1);
        assertEq(merklDistributor.operators(address(almProxy), operator2), 0);

        vm.prank(relayer);
        mainnetController.toggleOperatorMerkl(operator2);

        assertEq(merklDistributor.operators(address(almProxy), operator1), 1);
        assertEq(merklDistributor.operators(address(almProxy), operator2), 1);

    }

}
