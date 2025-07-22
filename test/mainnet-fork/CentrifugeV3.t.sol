// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import "./ForkTestBase.t.sol";

import { AsyncVault } from "centrifuge-v3/vaults/AsyncVault.sol";

contract CentrifugeTestBase is ForkTestBase {

    address constant CENTRIFUGE_VAULT = 0x1121F4e21eD8B9BC1BB9A2952cDD8639aC897784; // DEJAAA_VAULT_USDC
    uint16  constant DESTINATION_CENTRIFUGE_ID = 5; // Avalanche Centrifuge ID
    
    AsyncVault centrifugeVault;

    address ROOT;
    address SPOKE;
    address VAULT_TOKEN;

    uint64 POOL_ID;
    bytes16 SC_ID;

    function setUp() public override {
        super.setUp();

        centrifugeVault = AsyncVault(CENTRIFUGE_VAULT);
        
        ROOT = address(centrifugeVault.root());
        SPOKE = address(centrifugeVault.asyncRedeemManager().spoke());
        VAULT_TOKEN = centrifugeVault.share();

        POOL_ID = centrifugeVault.poolId().raw();
        SC_ID = centrifugeVault.scId().raw();
    }

    function _getBlock() internal pure override returns (uint256) {
        return 22968402;  // Jul 21, 2025
    }

}

contract MainnetControllerTransferSharesCentrifugeFailureTests is CentrifugeTestBase {

    function test_transferSharesCentrifuge_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        )); 
        mainnetController.transferSharesCentrifuge(SPOKE, POOL_ID, SC_ID, 1_000_000e6, DESTINATION_CENTRIFUGE_ID, 200_000);
    }

    function test_transferSharesCentrifuge_zeroMaxAmount() external {
        vm.prank(relayer);
        vm.expectRevert("RateLimits/zero-maxAmount");
        mainnetController.transferSharesCentrifuge(SPOKE, POOL_ID, SC_ID, 1_000_000e6, DESTINATION_CENTRIFUGE_ID, 200_000);
    }

    function test_transferSharesCentrifuge_rateLimitedBoundary() external {
        vm.startPrank(SPARK_PROXY);

        bytes32 target = bytes32(uint256(uint160(makeAddr("centrifugeRecipient"))));

        rateLimits.setRateLimitData(
            keccak256(abi.encode(
                mainnetController.LIMIT_CENTRIFUGE_TRANSFER(),
                SPOKE,
                POOL_ID,
                SC_ID,
                DESTINATION_CENTRIFUGE_ID
            )),
            10_000_000e6,
            0
        );

        mainnetController.setCentrifugeRecipient(DESTINATION_CENTRIFUGE_ID, target);

        vm.stopPrank();

        // Setup token balances
        deal(VAULT_TOKEN, address(almProxy), 10_000_000e6);
        deal(relayer, 1 ether);  // Gas cost for Centrifuge

        vm.startPrank(relayer);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        mainnetController.transferSharesCentrifuge{value: 0.1 ether}(
            SPOKE,
            POOL_ID,
            SC_ID,
            10_000_000e6 + 1,
            DESTINATION_CENTRIFUGE_ID,
            200_000
        );

        mainnetController.transferSharesCentrifuge{value: 0.1 ether}(
            SPOKE,
            POOL_ID,
            SC_ID,
            10_000_000e6,
            DESTINATION_CENTRIFUGE_ID,
            200_000
        );
    }

        function test_transferSharesCentrifuge_invalidCentrifugeId() external {
        vm.startPrank(SPARK_PROXY);

        rateLimits.setRateLimitData(
            keccak256(abi.encode(
                mainnetController.LIMIT_CENTRIFUGE_TRANSFER(),
                SPOKE,
                POOL_ID,
                SC_ID,
                DESTINATION_CENTRIFUGE_ID
            )),
            10_000_000e6,
            0
        );

        vm.stopPrank();

        // Setup token balances
        deal(VAULT_TOKEN, address(almProxy), 10_000_000e6);
        deal(relayer, 1 ether);  // Gas cost for Centrifuge

        vm.startPrank(relayer);
        vm.expectRevert("MainnetController/centrifuge-id-not-configured");
        mainnetController.transferSharesCentrifuge{value: 0.1 ether}(
            SPOKE,
            POOL_ID,
            SC_ID,
            10_000_000e6,
            DESTINATION_CENTRIFUGE_ID,
            200_000
        );
    }

}