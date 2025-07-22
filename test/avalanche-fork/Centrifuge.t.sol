// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import "./ForkTestBase.t.sol";

import {IERC7540} from "forge-std/interfaces/IERC7540.sol";

interface IRestrictionManager {
    function updateMember(address token, address user, uint64 validUntil) external;
}

interface IInvestmentManager {
    function fulfillCancelDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 fulfillment
    ) external;
    function fulfillCancelRedeemRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 shares
    ) external;
    function fulfillDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) external;
    function fulfillRedeemRequest(
        uint64 poolId,
        bytes16 trancheId,
        address user,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) external;
    function poolManager() external view returns (address);

}

interface IPoolManager {
    function assetToId(address asset) external view returns (uint128);
}

interface IERC20Mintable is IERC20 {
    function mint(address to, uint256 amount) external;
}

interface ICentrifugeVault is IERC7540 {
    function asset()              external view returns (address);
    function manager()            external view returns (address);
    // function restrictionManager() external view returns (address);
    function root()               external view returns (address);
    function share()              external view returns (address);
    function trancheId()          external view returns (bytes16);
    function poolId()             external view returns (uint64);

    function claimableCancelDepositRequest(uint256 requestId, address controller)
        external view returns (uint256 claimableAssets);
    function claimableCancelRedeemRequest(uint256 requestId, address controller)
        external view returns (uint256 claimableShares);
    function pendingCancelDepositRequest(uint256 requestId, address controller)
        external view returns (bool isPending);
    function pendingCancelRedeemRequest(uint256 requestId, address controller)
        external view returns (bool isPending);
}

contract CentrifugeTestBase is ForkTestBase {

    // TODO: Change to Avalanche addresses after switching to Avalanche fork
    address constant JTREASURY_VAULT_USDC = 0x04157759a9fe406d82a16BdEB20F9BeB9bBEb958;

    // Requests for Centrifuge pools are non-fungible and all have ID = 0
    uint256 constant REQUEST_ID = 0;

    ICentrifugeVault jtrsyVault = ICentrifugeVault(JTREASURY_VAULT_USDC);

    // IInvestmentManager  investmentManager;
    // IRestrictionManager restrictionManager;
    // IERC20Mintable      jtrsyToken;

    // address escrow;
    // address root;

    // uint64  jtrsyPoolId;
    // bytes16 jtrsyTrancheId;
    // uint128 usdcAssetId;


    function _getBlock() internal pure override returns (uint256) {
        return 4074609;  // July 21, 2025
    }

    function setUp() public virtual override {
        super.setUp();

        // investmentManager  = IInvestmentManager(jtrsyVault.manager());
        // restrictionManager = IRestrictionManager(jtrsyVault.restrictionManager());
        // restrictionManager = IRestrictionManager(0x04157759a9fe406d82a16BdEB20F9BeB9bBEb958); // TODO: Change to Avalanche addresses after switching to Avalanche fork
        // jtrsyToken         = IERC20Mintable(jtrsyVault.share());
        // escrow             = investmentManager.poolEscrow();
        // root               = jtrsyVault.root();
        // jtrsyPoolId        = jtrsyVault.poolId();
        // jtrsyTrancheId     = jtrsyVault.trancheId();
        // usdcAssetId        = IPoolManager(investmentManager.poolManager()).assetToId(jtrsyVault.asset());
    }
}

contract ForeignControllerRequestDepositERC7540FailureTests is CentrifugeTestBase {

    function test_requestDepositERC7540_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.requestDepositERC7540(address(jtrsyVault), 1_000_000e6);
    }

    function test_requestDepositERC7540_zeroMaxAmount() external {
        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.requestDepositERC7540(address(jtrsyVault), 1_000_000e6);
    }

    function test_requestDepositERC7540_rateLimitBoundary() external {
        vm.startPrank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(
            RateLimitHelpers.makeAssetKey(
                foreignController.LIMIT_7540_DEPOSIT(),
                address(jtrsyVault)
            ),
            1_000_000e6,
            uint256(1_000_000e6) / 1 days
        );
        vm.stopPrank();

        deal(address(usdcAvalanche), address(almProxy), 1_000_000e6);

        vm.prank(root);
        restrictionManager.updateMember(address(jtrsyToken), address(almProxy), type(uint64).max);

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.requestDepositERC7540(address(jtrsyVault), 1_000_000e6 + 1);

        foreignController.requestDepositERC7540(address(jtrsyVault), 1_000_000e6);
    }
}

contract ForeignControllerRequestDepositERC7540SuccessTests is CentrifugeTestBase {

    bytes32 key;

    function setUp() public override {
        super.setUp();

        vm.prank(root);
        restrictionManager.updateMember(address(jtrsyToken), address(almProxy), type(uint64).max);

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_DEPOSIT(),
            address(jtrsyVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_000_000e6, uint256(1_000_000e6) / 1 days);
    }

    function test_requestDepositERC7540() external {
        deal(address(usdcAvalanche), address(almProxy), 1_000_000e6);

        assertEq(rateLimits.getCurrentRateLimit(key), 1_000_000e6);

        assertEq(usdcAvalanche.allowance(address(almProxy), address(jtrsyVault)), 0);

        uint256 initialEscrowBal = usdcAvalanche.balanceOf(escrow);

        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 1_000_000e6);
        assertEq(usdcAvalanche.balanceOf(escrow),            initialEscrowBal);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)), 0);

        vm.prank(ALM_RELAYER);
        foreignController.requestDepositERC7540(address(jtrsyVault), 1_000_000e6);

        assertEq(rateLimits.getCurrentRateLimit(key), 0);

        assertEq(usdcAvalanche.allowance(address(almProxy), address(jtrsyVault)), 0);

        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 0);
        assertEq(usdcAvalanche.balanceOf(escrow),            initialEscrowBal + 1_000_000e6);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)), 1_000_000e6);
    }

}

contract ForeignControllerClaimDepositERC7540FailureTests is CentrifugeTestBase {

    function test_claimDepositERC7540_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.claimDepositERC7540(address(jtrsyVault));
    }

    function test_claimDepositERC7540_invalidVault() external {
        vm.prank(ALM_RELAYER);
        vm.expectRevert("ForeignController/invalid-action");
        foreignController.claimDepositERC7540(makeAddr("fake-vault"));
    }

}

contract ForeignControllerClaimDepositERC7540SuccessTests is CentrifugeTestBase {

    bytes32 key;

    function setUp() public override {
        super.setUp();

        vm.prank(root);
        restrictionManager.updateMember(address(jtrsyToken), address(almProxy), type(uint64).max);

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_DEPOSIT(),
            address(jtrsyVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_500_000e6, uint256(1_500_000e6) / 1 days);
    }

    function test_claimDepositERC7540_singleRequest() external {
        deal(address(usdcAvalanche), address(almProxy), 1_000_000e6);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jtrsyVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);

        // Request deposit into JTRSY by supplying USDC
        vm.prank(ALM_RELAYER);
        foreignController.requestDepositERC7540(address(jtrsyVault), 1_000_000e6);

        uint256 totalSupply = jtrsyToken.totalSupply();

        uint256 initialEscrowBal = jtrsyToken.balanceOf(escrow);

        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal);
        assertEq(jtrsyToken.balanceOf(address(almProxy)), 0);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   1_000_000e6);
        assertEq(jtrsyVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);

        // Fulfill request at price 2.0
        vm.prank(root);
        investmentManager.fulfillDepositRequest(
            jtrsyPoolId,
            jtrsyTrancheId,
            address(almProxy),
            usdcAssetId,
            1_000_000e6,
            500_000e6
        );

        assertEq(jtrsyToken.totalSupply(),                totalSupply + 500_000e6);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal + 500_000e6);
        assertEq(jtrsyToken.balanceOf(address(almProxy)), 0);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jtrsyVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 1_000_000e6);

        // Claim shares
        vm.prank(ALM_RELAYER);
        foreignController.claimDepositERC7540(address(jtrsyVault));

        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal);
        assertEq(jtrsyToken.balanceOf(address(almProxy)), 500_000e6);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jtrsyVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);
    }


    function test_claimDepositERC7540_multipleRequests() external {
        deal(address(usdcAvalanche), address(almProxy), 1_500_000e6);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jtrsyVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);

        // Request deposit into JTRSY by supplying USDC
        vm.prank(ALM_RELAYER);
        foreignController.requestDepositERC7540(address(jtrsyVault), 1_000_000e6);

        uint256 totalSupply = jtrsyToken.totalSupply();

        uint256 initialEscrowBal = jtrsyToken.balanceOf(escrow);

        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal);
        assertEq(jtrsyToken.balanceOf(address(almProxy)), 0);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   1_000_000e6);
        assertEq(jtrsyVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);

        // Request another deposit into JTRSY by supplying more USDC
        vm.prank(ALM_RELAYER);
        foreignController.requestDepositERC7540(address(jtrsyVault), 500_000e6);

        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal);
        assertEq(jtrsyToken.balanceOf(address(almProxy)), 0);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   1_500_000e6);
        assertEq(jtrsyVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);

        // Fulfill both requests at price 2.0
        vm.prank(root);
        investmentManager.fulfillDepositRequest(
            jtrsyPoolId,
            jtrsyTrancheId,
            address(almProxy),
            usdcAssetId,
            1_500_000e6,
            750_000e6
        );

        assertEq(jtrsyToken.totalSupply(),                totalSupply + 750_000e6);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal + 750_000e6);
        assertEq(jtrsyToken.balanceOf(address(almProxy)), 0);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jtrsyVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 1_500_000e6);

        // Claim shares
        vm.prank(ALM_RELAYER);
        foreignController.claimDepositERC7540(address(jtrsyVault));

        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal);
        assertEq(jtrsyToken.balanceOf(address(almProxy)), 750_000e6);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jtrsyVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);
    }

}

contract ForeignControllerCancelCentrifugeDepositFailureTests is CentrifugeTestBase {

    function test_cancelCentrifugeDepositRequest_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.cancelCentrifugeDepositRequest(address(jtrsyVault));
    }

    function test_cancelCentrifugeDepositRequest_invalidVault() external {
        vm.prank(ALM_RELAYER);
        vm.expectRevert("ForeignController/invalid-action");
        foreignController.cancelCentrifugeDepositRequest(makeAddr("fake-vault"));
    }

}

contract ForeignControllerCancelCentrifugeDepositSuccessTests is CentrifugeTestBase {

    bytes32 key;

    function setUp() public override {
        super.setUp();

        vm.prank(root);
        restrictionManager.updateMember(address(jtrsyToken), address(almProxy), type(uint64).max);

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_DEPOSIT(),
            address(jtrsyVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_000_000e6, uint256(1_000_000e6) / 1 days);
    }

    function test_cancelCentrifugeDepositRequest() external {
        deal(address(usdcAvalanche), address(almProxy), 1_000_000e6);

        vm.prank(ALM_RELAYER);
        foreignController.requestDepositERC7540(address(jtrsyVault), 1_000_000e6);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),       1_000_000e6);
        assertEq(jtrsyVault.pendingCancelDepositRequest(REQUEST_ID, address(almProxy)), false);

        vm.prank(ALM_RELAYER);
        foreignController.cancelCentrifugeDepositRequest(address(jtrsyVault));

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),       1_000_000e6);
        assertEq(jtrsyVault.pendingCancelDepositRequest(REQUEST_ID, address(almProxy)), true);
    }

}

contract ForeignControllerClaimCentrifugeCancelDepositFailureTests is CentrifugeTestBase {

    function test_claimCentrifugeCancelDepositRequest_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.claimCentrifugeCancelDepositRequest(address(jtrsyVault));
    }

    function test_claimCentrifugeCancelDepositRequest_invalidVault() external {
        vm.prank(ALM_RELAYER);
        vm.expectRevert("ForeignController/invalid-action");
        foreignController.claimCentrifugeCancelDepositRequest(makeAddr("fake-vault"));
    }

}

contract ForeignControllerClaimCentrifugeCancelDepositSuccessTests is CentrifugeTestBase {

    bytes32 key;

    function setUp() public override {
        super.setUp();

        vm.prank(root);
        restrictionManager.updateMember(address(jtrsyToken), address(almProxy), type(uint64).max);

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_DEPOSIT(),
            address(jtrsyVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_000_000e6, uint256(1_000_000e6) / 1 days);
    }

    function test_claimCentrifugeCancelDepositRequest() external {
        deal(address(usdcAvalanche), address(almProxy), 1_000_000e6);

        uint256 initialEscrowBal = usdcAvalanche.balanceOf(escrow);

        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 1_000_000e6);
        assertEq(usdcAvalanche.balanceOf(escrow),            initialEscrowBal);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),         0);
        assertEq(jtrsyVault.pendingCancelDepositRequest(REQUEST_ID, address(almProxy)),   false);
        assertEq(jtrsyVault.claimableCancelDepositRequest(REQUEST_ID, address(almProxy)), 0);

        vm.startPrank(ALM_RELAYER);
        foreignController.requestDepositERC7540(address(jtrsyVault), 1_000_000e6);
        foreignController.cancelCentrifugeDepositRequest(address(jtrsyVault));
        vm.stopPrank();

        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 0);
        assertEq(usdcAvalanche.balanceOf(escrow),            initialEscrowBal + 1_000_000e6);

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),         1_000_000e6);
        assertEq(jtrsyVault.pendingCancelDepositRequest(REQUEST_ID, address(almProxy)),   true);
        assertEq(jtrsyVault.claimableCancelDepositRequest(REQUEST_ID, address(almProxy)), 0);

        // Fulfill cancelation request
        vm.prank(root);
        investmentManager.fulfillCancelDepositRequest(
            jtrsyPoolId,
            jtrsyTrancheId,
            address(almProxy),
            usdcAssetId,
            1_000_000e6,
            1_000_000e6
        );

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),         0);
        assertEq(jtrsyVault.pendingCancelDepositRequest(REQUEST_ID, address(almProxy)),   false);
        assertEq(jtrsyVault.claimableCancelDepositRequest(REQUEST_ID, address(almProxy)), 1_000_000e6);

        vm.prank(ALM_RELAYER);
        foreignController.claimCentrifugeCancelDepositRequest(address(jtrsyVault));

        assertEq(jtrsyVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),         0);
        assertEq(jtrsyVault.pendingCancelDepositRequest(REQUEST_ID, address(almProxy)),   false);
        assertEq(jtrsyVault.claimableCancelDepositRequest(REQUEST_ID, address(almProxy)), 0);

        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 1_000_000e6);
        assertEq(usdcAvalanche.balanceOf(escrow),            initialEscrowBal);
    }

}

contract ForeignControllerRequestRedeemERC7540FailureTests is CentrifugeTestBase {

    function test_requestRedeemERC7540_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.requestRedeemERC7540(address(jtrsyVault), 1_000_000e6);
    }

    function test_requestRedeemERC7540_zeroMaxAmount() external {
        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.requestRedeemERC7540(address(jtrsyVault), 1_000_000e6);
    }

    function test_requestRedeemERC7540_rateLimitsBoundary() external {
        vm.startPrank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(
            RateLimitHelpers.makeAssetKey(
                foreignController.LIMIT_7540_REDEEM(),
                address(jtrsyVault)
            ),
            1_000_000e6,
            uint256(1_000_000e6) / 1 days
        );
        vm.stopPrank();

        vm.startPrank(root);
        restrictionManager.updateMember(address(jtrsyToken), address(almProxy), type(uint64).max);
        jtrsyToken.mint(address(almProxy), 1_000_000e6);
        vm.stopPrank();

        uint256 overBoundaryShares = jtrsyVault.convertToShares(1_000_000e6 + 3);
        uint256 atBoundaryShares   = jtrsyVault.convertToShares(1_000_000e6 + 1);

        assertEq(jtrsyVault.convertToAssets(overBoundaryShares), 1_000_000e6 + 2);
        assertEq(jtrsyVault.convertToAssets(atBoundaryShares),   1_000_000e6);

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.requestRedeemERC7540(address(jtrsyVault), overBoundaryShares);

        foreignController.requestRedeemERC7540(address(jtrsyVault), atBoundaryShares);
    }
}

contract ForeignControllerRequestRedeemERC7540SuccessTests is CentrifugeTestBase {

    bytes32 key;

    function setUp() public override {
        super.setUp();

        vm.startPrank(root);
        restrictionManager.updateMember(address(jtrsyToken), address(almProxy), type(uint64).max);
        vm.stopPrank();

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_REDEEM(),
            address(jtrsyVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_000_000e6, uint256(1_000_000e6) / 1 days);
    }

    function test_requestRedeemERC7540() external {
        uint256 shares = jtrsyVault.convertToShares(1_000_000e6);

        assertEq(shares, 948_558.832635e6);

        vm.prank(root);
        jtrsyToken.mint(address(almProxy), shares);

        assertEq(rateLimits.getCurrentRateLimit(key), 1_000_000e6);

        uint256 initialEscrowBal = jtrsyToken.balanceOf(escrow);

        assertEq(jtrsyToken.balanceOf(address(almProxy)), shares);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        vm.prank(ALM_RELAYER);
        foreignController.requestRedeemERC7540(address(jtrsyVault), shares);

        assertEq(rateLimits.getCurrentRateLimit(key), 1);  // Rounding

        assertEq(jtrsyToken.balanceOf(address(almProxy)), 0);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal + shares);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)), shares);
    }

}

contract ForeignControllerClaimRedeemERC7540FailureTests is CentrifugeTestBase {

    function test_claimRedeemERC7540_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.claimRedeemERC7540(address(jtrsyVault));
    }

    function test_claimRedeemERC7540_invalidVault() external {
        vm.prank(ALM_RELAYER);
        vm.expectRevert("ForeignController/invalid-action");
        foreignController.claimRedeemERC7540(makeAddr("fake-vault"));
    }

}

contract ForeignControllerClaimRedeemERC7540SuccessTests is CentrifugeTestBase {

    bytes32 key;

    function setUp() public override {
        super.setUp();

        vm.startPrank(root);
        restrictionManager.updateMember(address(jtrsyToken), address(almProxy), type(uint64).max);
        vm.stopPrank();

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_REDEEM(),
            address(jtrsyVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 2_000_000e6, uint256(2_000_000e6) / 1 days);
    }

    function test_claimRedeemERC7540_singleRequest() external {
        vm.prank(root);
        jtrsyToken.mint(address(almProxy), 1_000_000e6);

        uint256 initialEscrowBal = jtrsyToken.balanceOf(escrow);

        assertEq(jtrsyToken.balanceOf(address(almProxy)), 1_000_000e6);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jtrsyVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        // Request JTRSY redemption
        vm.prank(ALM_RELAYER);
        foreignController.requestRedeemERC7540(address(jtrsyVault), 1_000_000e6);

        uint256 totalSupply = jtrsyToken.totalSupply();

        assertEq(jtrsyToken.balanceOf(address(almProxy)), 0);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal + 1_000_000e6);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   1_000_000e6);
        assertEq(jtrsyVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        // Fulfill request at price 2.0
        deal(address(usdcAvalanche), escrow, 2_000_000e6);
        vm.prank(root);
        investmentManager.fulfillRedeemRequest(
            jtrsyPoolId,
            jtrsyTrancheId,
            address(almProxy),
            usdcAssetId,
            2_000_000e6,
            1_000_000e6
        );

        assertEq(jtrsyToken.totalSupply(),                totalSupply - 1_000_000e6);
        assertEq(jtrsyToken.balanceOf(address(almProxy)), 0);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal);

        assertEq(usdcAvalanche.balanceOf(escrow),            2_000_000e6);
        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 0);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jtrsyVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 1_000_000e6);

        // Claim assets
        vm.prank(ALM_RELAYER);
        foreignController.claimRedeemERC7540(address(jtrsyVault));

        assertEq(usdcAvalanche.balanceOf(escrow),            0);
        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 2_000_000e6);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jtrsyVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);
    }

    function test_claimRedeemERC7540_multipleRequests() external {
        vm.prank(root);
        jtrsyToken.mint(address(almProxy), 1_500_000e6);

        uint256 initialEscrowBal = jtrsyToken.balanceOf(escrow);

        assertEq(jtrsyToken.balanceOf(address(almProxy)), 1_500_000e6);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jtrsyVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        // Request JTRSY redemption
        vm.prank(ALM_RELAYER);
        foreignController.requestRedeemERC7540(address(jtrsyVault), 1_000_000e6);

        uint256 totalSupply = jtrsyToken.totalSupply();

        assertEq(jtrsyToken.balanceOf(address(almProxy)), 500_000e6);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal + 1_000_000e6);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   1_000_000e6);
        assertEq(jtrsyVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        // Request another JTRSY redemption
        vm.prank(ALM_RELAYER);
        foreignController.requestRedeemERC7540(address(jtrsyVault), 500_000e6);

        assertEq(jtrsyToken.balanceOf(address(almProxy)), 0);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal + 1_500_000e6);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   1_500_000e6);
        assertEq(jtrsyVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        // Fulfill both requests at price 2.0
        deal(address(usdcAvalanche), escrow, 3_000_000e6);
        vm.prank(root);
        investmentManager.fulfillRedeemRequest(
            jtrsyPoolId,
            jtrsyTrancheId,
            address(almProxy),
            usdcAssetId,
            3_000_000e6,
            1_500_000e6
        );

        assertEq(jtrsyToken.totalSupply(),                totalSupply - 1_500_000e6);
        assertEq(jtrsyToken.balanceOf(address(almProxy)), 0);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal);

        assertEq(usdcAvalanche.balanceOf(escrow),            3_000_000e6);
        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 0);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jtrsyVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 1_500_000e6);

        // Claim assets
        vm.prank(ALM_RELAYER);
        foreignController.claimRedeemERC7540(address(jtrsyVault));

        assertEq(usdcAvalanche.balanceOf(escrow),            0);
        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 3_000_000e6);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jtrsyVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);
    }

}

contract ForeignControllerCancelCentrifugeRedeemRequestFailureTests is CentrifugeTestBase {

    function test_cancelCentrifugeRedeemRequest_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.cancelCentrifugeRedeemRequest(address(jtrsyVault));
    }

    function test_cancelCentrifugeRedeemRequest_invalidVault() external {
        vm.prank(ALM_RELAYER);
        vm.expectRevert("ForeignController/invalid-action");
        foreignController.cancelCentrifugeRedeemRequest(makeAddr("fake-vault"));
    }

}

contract ForeignControllerCancelCentrifugeRedeemRequestSuccessTests is CentrifugeTestBase {

    bytes32 key;

    function setUp() public override {
        super.setUp();

        vm.startPrank(root);
        restrictionManager.updateMember(address(jtrsyToken), address(almProxy), type(uint64).max);
        vm.stopPrank();

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_REDEEM(),
            address(jtrsyVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_000_000e6, uint256(1_000_000e6) / 1 days);
    }

    function test_cancelCentrifugeRedeemRequest() external {
        uint256 shares = jtrsyVault.convertToShares(1_000_000e6);

        vm.prank(root);
        jtrsyToken.mint(address(almProxy), shares);

        vm.prank(ALM_RELAYER);
        foreignController.requestRedeemERC7540(address(jtrsyVault), shares);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),       shares);
        assertEq(jtrsyVault.pendingCancelRedeemRequest(REQUEST_ID, address(almProxy)), false);

        vm.prank(ALM_RELAYER);
        foreignController.cancelCentrifugeRedeemRequest(address(jtrsyVault));

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),       shares);
        assertEq(jtrsyVault.pendingCancelRedeemRequest(REQUEST_ID, address(almProxy)), true);
    }

}

contract ForeignControllerClaimCentrifugeCancelRedeemRequestFailureTests is CentrifugeTestBase {

    function test_claimCentrifugeCancelRedeemRequest_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.claimCentrifugeCancelRedeemRequest(address(jtrsyVault));
    }

    function test_claimCentrifugeCancelRedeemRequest_invalidVault() external {
        vm.prank(ALM_RELAYER);
        vm.expectRevert("ForeignController/invalid-action");
        foreignController.claimCentrifugeCancelRedeemRequest(makeAddr("fake-vault"));
    }

}

contract ForeignControllerClaimCentrifugeCancelRedeemRequestSuccessTests is CentrifugeTestBase {

    bytes32 key;

    function setUp() public override {
        super.setUp();

        vm.startPrank(root);
        restrictionManager.updateMember(address(jtrsyToken), address(almProxy), type(uint64).max);
        vm.stopPrank();

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_REDEEM(),
            address(jtrsyVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_000_000e6, uint256(1_000_000e6) / 1 days);
    }

    function test_claimCentrifugeCancelRedeemRequest() external {
        uint256 shares = jtrsyVault.convertToShares(1_000_000e6);

        vm.prank(root);
        jtrsyToken.mint(address(almProxy), shares);

        uint256 initialEscrowBal = jtrsyToken.balanceOf(escrow);

        assertEq(jtrsyToken.balanceOf(address(almProxy)), shares);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),         0);
        assertEq(jtrsyVault.pendingCancelRedeemRequest(REQUEST_ID, address(almProxy)),   false);
        assertEq(jtrsyVault.claimableCancelRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        vm.startPrank(ALM_RELAYER);
        foreignController.requestRedeemERC7540(address(jtrsyVault), shares);
        foreignController.cancelCentrifugeRedeemRequest(address(jtrsyVault));
        vm.stopPrank();

        assertEq(jtrsyToken.balanceOf(address(almProxy)), 0);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal + shares);

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),         shares);
        assertEq(jtrsyVault.pendingCancelRedeemRequest(REQUEST_ID, address(almProxy)),   true);
        assertEq(jtrsyVault.claimableCancelRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        // Fulfill cancelation request
        vm.prank(root);
        investmentManager.fulfillCancelRedeemRequest(
            jtrsyPoolId,
            jtrsyTrancheId,
            address(almProxy),
            usdcAssetId,
            uint128(shares)
        );

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),         0);
        assertEq(jtrsyVault.pendingCancelRedeemRequest(REQUEST_ID, address(almProxy)),   false);
        assertEq(jtrsyVault.claimableCancelRedeemRequest(REQUEST_ID, address(almProxy)), shares);

        vm.prank(ALM_RELAYER);
        foreignController.claimCentrifugeCancelRedeemRequest(address(jtrsyVault));

        assertEq(jtrsyVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),         0);
        assertEq(jtrsyVault.pendingCancelRedeemRequest(REQUEST_ID, address(almProxy)),   false);
        assertEq(jtrsyVault.claimableCancelRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        assertEq(jtrsyToken.balanceOf(address(almProxy)), shares);
        assertEq(jtrsyToken.balanceOf(escrow),            initialEscrowBal);
    }

}
