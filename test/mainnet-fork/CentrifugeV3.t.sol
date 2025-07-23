// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { IERC7540 } from "forge-std/interfaces/IERC7540.sol";

import "./ForkTestBase.t.sol";

interface ICentrifugeV3Vault is IERC7540 {
    function asset()        external view returns (address);
    function share()        external view returns (address);
    function manager()      external view returns (address);
    function poolId()       external view returns (uint64);
    function scId()         external view returns (bytes16);
    function root()         external view returns (address);

    function claimableCancelDepositRequest(uint256 requestId, address controller)
        external view returns (uint256 claimableAssets);
    function claimableCancelRedeemRequest(uint256 requestId, address controller)
        external view returns (uint256 claimableShares);
    function pendingCancelDepositRequest(uint256 requestId, address controller)
        external view returns (bool isPending);
    function pendingCancelRedeemRequest(uint256 requestId, address controller)
        external view returns (bool isPending);
}

interface IAsyncRedeemManagerLike {
    function issuedShares(
        uint64  poolId,
        bytes16 scId,
        uint128 shareAmount,
        uint128 pricePoolPerShare) external;
    function revokedShares(
        uint64  poolId,
        bytes16 scId,
        uint128 assetId,
        uint128 assetAmount,
        uint128 shareAmount,
        uint128 pricePoolPerShare) external;
    function approvedDeposits(
        uint64  poolId,
        bytes16 scId,
        uint128 assetId,
        uint128 assetAmount,
        uint128 pricePoolPerAsset
    ) external;
    function fulfillDepositRequest(
        uint64  poolId,
        bytes16 scId,
        address user,
        uint128 assetId,
        uint128 fulfilledAssets,
        uint128 fulfilledShares,
        uint128 cancelledAssets
    ) external;
    function fulfillRedeemRequest(
        uint64  poolId,
        bytes16 scId,
        address user,
        uint128 assetId,
        uint128 fulfilledAssets,
        uint128 fulfilledShares,
        uint128 cancelledShares
    ) external;
    function balanceSheet()            external view returns (address);
    function spoke()                   external view returns (address);
    function poolEscrow(uint64 poolId) external view returns (address);
    function globalEscrow()            external view returns (address);
}

contract CentrifugeTestBase is ForkTestBase {

    address constant CENTRIFUGE_VAULT = 0x1121F4e21eD8B9BC1BB9A2952cDD8639aC897784; // DEJAAA_VAULT_USDC
    uint16  constant DESTINATION_CENTRIFUGE_ID = 5; // Avalanche Centrifuge ID

    ICentrifugeV3Vault centrifugeVault = ICentrifugeV3Vault(CENTRIFUGE_VAULT);

    IAsyncRedeemManagerLike manager;

    address root;
    address spoke;
    address vaultToken;

    uint64  poolId;
    bytes16 scId;

    function setUp() public override {
        super.setUp();

        root       = centrifugeVault.root();
        vaultToken = centrifugeVault.share();
        manager    = IAsyncRedeemManagerLike(centrifugeVault.manager());
        spoke      = manager.spoke();

        poolId = centrifugeVault.poolId();
        scId   = centrifugeVault.scId();
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
        mainnetController.transferSharesCentrifuge(CENTRIFUGE_VAULT, 1_000_000e6, DESTINATION_CENTRIFUGE_ID, 200_000);
    }

    function test_transferSharesCentrifuge_zeroMaxAmount() external {
        vm.prank(relayer);
        vm.expectRevert("RateLimits/zero-maxAmount");
        mainnetController.transferSharesCentrifuge(CENTRIFUGE_VAULT, 1_000_000e6, DESTINATION_CENTRIFUGE_ID, 200_000);
    }

    function test_transferSharesCentrifuge_rateLimitedBoundary() external {
        vm.startPrank(SPARK_PROXY);

        bytes32 target = bytes32(uint256(uint160(makeAddr("centrifugeRecipient"))));

        rateLimits.setRateLimitData(
            keccak256(abi.encode(
                mainnetController.LIMIT_CENTRIFUGE_TRANSFER(),
                CENTRIFUGE_VAULT,
                DESTINATION_CENTRIFUGE_ID
            )),
            10_000_000e6,
            0
        );

        mainnetController.setCentrifugeRecipient(DESTINATION_CENTRIFUGE_ID, target);

        vm.stopPrank();

        // Setup token balances
        deal(vaultToken, address(almProxy), 10_000_000e6);
        deal(relayer, 1 ether);  // Gas cost for Centrifuge

        vm.startPrank(relayer);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        mainnetController.transferSharesCentrifuge{value: 0.1 ether}(
            CENTRIFUGE_VAULT,
            10_000_000e6 + 1,
            DESTINATION_CENTRIFUGE_ID,
            200_000
        );

        mainnetController.transferSharesCentrifuge{value: 0.1 ether}(
            CENTRIFUGE_VAULT,
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
                CENTRIFUGE_VAULT,
                DESTINATION_CENTRIFUGE_ID
            )),
            10_000_000e6,
            0
        );

        vm.stopPrank();

        // Setup token balances
        deal(vaultToken, address(almProxy), 10_000_000e6);
        deal(relayer, 1 ether);  // Gas cost for Centrifuge

        vm.startPrank(relayer);
        vm.expectRevert("MainnetController/centrifuge-id-not-configured");
        mainnetController.transferSharesCentrifuge{value: 0.1 ether}(
            CENTRIFUGE_VAULT,
            10_000_000e6,
            DESTINATION_CENTRIFUGE_ID,
            200_000
        );
    }

}
