// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import "./ForkTestBase.t.sol";

import { IERC7540 } from "forge-std/interfaces/IERC7540.sol";

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

interface ICentrifugeV3ShareLike is IERC20 {
    function mint(address to, uint256 value) external;
    function hook() external view returns (address);
}

interface IFreelyTransferableHookLike {
    function updateMember(address token, address user, uint64 validUntil) external;
}

interface IAsyncRedeemManagerLike {
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
    function spoke()                   external view returns (address);
    function poolEscrow(uint64 poolId) external view returns (address);
    function globalEscrow()            external view returns (address);
}

interface ISpokeLike {
    function assetToId(address asset, uint256 tokenId) external view returns (uint128);
}

contract CentrifugeTestBase is ForkTestBase {

    address constant JAAA_VAULT = 0xCF4C60066aAB54b3f750F94c2a06046d5466Ccf9;

    // Requests for Centrifuge pools are non-fungible and all have ID = 0
    uint256 constant REQUEST_ID = 0;

    ICentrifugeV3Vault jaaaVault = ICentrifugeV3Vault(JAAA_VAULT);

    ICentrifugeV3ShareLike      jaaaToken;
    IFreelyTransferableHookLike jaaaTokenHook;
    IAsyncRedeemManagerLike     manager;
    ISpokeLike                  spoke;

    address globalEscrow;
    address poolEscrow;
    address root;

    uint64  jaaaPoolId;
    bytes16 jaaaScId;
    uint128 usdcAssetId;


    function _getBlock() internal pure override returns (uint256) {
        return 65896755;  // July 22, 2025
    }

    function setUp() public virtual override {
        super.setUp();

        jaaaToken     = ICentrifugeV3ShareLike(jaaaVault.share());
        jaaaTokenHook = IFreelyTransferableHookLike(jaaaToken.hook());
        manager       = IAsyncRedeemManagerLike(jaaaVault.manager());
        spoke         = ISpokeLike(manager.spoke());


        root        = jaaaVault.root();
        jaaaPoolId  = jaaaVault.poolId();
        jaaaScId    = jaaaVault.scId();
        usdcAssetId = spoke.assetToId(jaaaVault.asset(), 0);

        globalEscrow = manager.globalEscrow();
        poolEscrow   = manager.poolEscrow(jaaaPoolId);
    }
}

contract ForeignControllerRequestDepositERC7540FailureTests is CentrifugeTestBase {

    function test_requestDepositERC7540_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.requestDepositERC7540(address(jaaaVault), 1_000_000e6);
    }

    function test_requestDepositERC7540_zeroMaxAmount() external {
        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.requestDepositERC7540(address(jaaaVault), 1_000_000e6);
    }

    function test_requestDepositERC7540_rateLimitBoundary() external {
        vm.startPrank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(
            RateLimitHelpers.makeAssetKey(
                foreignController.LIMIT_7540_DEPOSIT(),
                address(jaaaVault)
            ),
            1_000_000e6,
            uint256(1_000_000e6) / 1 days
        );
        vm.stopPrank();

        deal(address(usdcAvalanche), address(almProxy), 1_000_000e6);

        vm.prank(root);
        jaaaTokenHook.updateMember(address(jaaaToken), address(almProxy), type(uint64).max);

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.requestDepositERC7540(address(jaaaVault), 1_000_000e6 + 1);

        foreignController.requestDepositERC7540(address(jaaaVault), 1_000_000e6);
    }
}

contract ForeignControllerRequestDepositERC7540SuccessTests is CentrifugeTestBase {

    bytes32 key;

    function setUp() public override {
        super.setUp();

        vm.prank(root);
        jaaaTokenHook.updateMember(address(jaaaToken), address(almProxy), type(uint64).max);

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_DEPOSIT(),
            address(jaaaVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_000_000e6, uint256(1_000_000e6) / 1 days);
    }

    function test_requestDepositERC7540() external {
        deal(address(usdcAvalanche), address(almProxy), 1_000_000e6);

        assertEq(rateLimits.getCurrentRateLimit(key), 1_000_000e6);

        assertEq(usdcAvalanche.allowance(address(almProxy), address(jaaaVault)), 0);

        uint256 initialEscrowBal = usdcAvalanche.balanceOf(poolEscrow);

        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 1_000_000e6);
        assertEq(usdcAvalanche.balanceOf(poolEscrow),            initialEscrowBal);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)), 0);

        vm.prank(ALM_RELAYER);
        foreignController.requestDepositERC7540(address(jaaaVault), 1_000_000e6);

        assertEq(rateLimits.getCurrentRateLimit(key), 0);

        assertEq(usdcAvalanche.allowance(address(almProxy), address(jaaaVault)), 0);

        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 0);
        assertEq(usdcAvalanche.balanceOf(poolEscrow),            initialEscrowBal + 1_000_000e6);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)), 1_000_000e6);
    }

}

contract ForeignControllerClaimDepositERC7540FailureTests is CentrifugeTestBase {

    function test_claimDepositERC7540_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.claimDepositERC7540(address(jaaaVault));
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
        jaaaTokenHook.updateMember(address(jaaaToken), address(almProxy), type(uint64).max);

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_DEPOSIT(),
            address(jaaaVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_500_000e6, uint256(1_500_000e6) / 1 days);
    }

    function test_claimDepositERC7540_singleRequest() external {
        deal(address(usdcAvalanche), address(almProxy), 1_000_000e6);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jaaaVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);

        // Request deposit into JTRSY by supplying USDC
        vm.prank(ALM_RELAYER);
        foreignController.requestDepositERC7540(address(jaaaVault), 1_000_000e6);

        uint256 totalSupply = jaaaToken.totalSupply();

        uint256 initialEscrowBal = jaaaToken.balanceOf(poolEscrow);

        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal);
        assertEq(jaaaToken.balanceOf(address(almProxy)), 0);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   1_000_000e6);
        assertEq(jaaaVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);

        // Fulfill request at price 2.0
        vm.prank(root);
        manager.fulfillDepositRequest(
            jaaaPoolId,
            jaaaScId,
            address(almProxy),
            usdcAssetId,
            1_000_000e6,
            500_000e6,
            0
        );

        assertEq(jaaaToken.totalSupply(),                totalSupply + 500_000e6);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal + 500_000e6);
        assertEq(jaaaToken.balanceOf(address(almProxy)), 0);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jaaaVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 1_000_000e6);

        // Claim shares
        vm.prank(ALM_RELAYER);
        foreignController.claimDepositERC7540(address(jaaaVault));

        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal);
        assertEq(jaaaToken.balanceOf(address(almProxy)), 500_000e6);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jaaaVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);
    }


    function test_claimDepositERC7540_multipleRequests() external {
        deal(address(usdcAvalanche), address(almProxy), 1_500_000e6);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jaaaVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);

        // Request deposit into JTRSY by supplying USDC
        vm.prank(ALM_RELAYER);
        foreignController.requestDepositERC7540(address(jaaaVault), 1_000_000e6);

        uint256 totalSupply = jaaaToken.totalSupply();

        uint256 initialEscrowBal = jaaaToken.balanceOf(poolEscrow);

        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal);
        assertEq(jaaaToken.balanceOf(address(almProxy)), 0);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   1_000_000e6);
        assertEq(jaaaVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);

        // Request another deposit into JTRSY by supplying more USDC
        vm.prank(ALM_RELAYER);
        foreignController.requestDepositERC7540(address(jaaaVault), 500_000e6);

        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal);
        assertEq(jaaaToken.balanceOf(address(almProxy)), 0);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   1_500_000e6);
        assertEq(jaaaVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);

        // Fulfill both requests at price 2.0
        vm.prank(root);
        manager.fulfillDepositRequest(
            jaaaPoolId,
            jaaaScId,
            address(almProxy),
            usdcAssetId,
            1_500_000e6,
            750_000e6,
            0
        );

        assertEq(jaaaToken.totalSupply(),                totalSupply + 750_000e6);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal + 750_000e6);
        assertEq(jaaaToken.balanceOf(address(almProxy)), 0);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jaaaVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 1_500_000e6);

        // Claim shares
        vm.prank(ALM_RELAYER);
        foreignController.claimDepositERC7540(address(jaaaVault));

        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal);
        assertEq(jaaaToken.balanceOf(address(almProxy)), 750_000e6);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jaaaVault.claimableDepositRequest(REQUEST_ID, address(almProxy)), 0);
    }

}

contract ForeignControllerCancelCentrifugeDepositFailureTests is CentrifugeTestBase {

    function test_cancelCentrifugeDepositRequest_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.cancelCentrifugeDepositRequest(address(jaaaVault));
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
        jaaaTokenHook.updateMember(address(jaaaToken), address(almProxy), type(uint64).max);

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_DEPOSIT(),
            address(jaaaVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_000_000e6, uint256(1_000_000e6) / 1 days);
    }

    function test_cancelCentrifugeDepositRequest() external {
        deal(address(usdcAvalanche), address(almProxy), 1_000_000e6);

        vm.prank(ALM_RELAYER);
        foreignController.requestDepositERC7540(address(jaaaVault), 1_000_000e6);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),       1_000_000e6);
        assertEq(jaaaVault.pendingCancelDepositRequest(REQUEST_ID, address(almProxy)), false);

        vm.prank(ALM_RELAYER);
        foreignController.cancelCentrifugeDepositRequest(address(jaaaVault));

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),       1_000_000e6);
        assertEq(jaaaVault.pendingCancelDepositRequest(REQUEST_ID, address(almProxy)), true);
    }

}

contract ForeignControllerClaimCentrifugeCancelDepositFailureTests is CentrifugeTestBase {

    function test_claimCentrifugeCancelDepositRequest_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.claimCentrifugeCancelDepositRequest(address(jaaaVault));
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
        jaaaTokenHook.updateMember(address(jaaaToken), address(almProxy), type(uint64).max);

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_DEPOSIT(),
            address(jaaaVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_000_000e6, uint256(1_000_000e6) / 1 days);
    }

    function test_claimCentrifugeCancelDepositRequest() external {
        deal(address(usdcAvalanche), address(almProxy), 1_000_000e6);

        uint256 initialEscrowBal = usdcAvalanche.balanceOf(poolEscrow);

        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 1_000_000e6);
        assertEq(usdcAvalanche.balanceOf(poolEscrow),            initialEscrowBal);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),         0);
        assertEq(jaaaVault.pendingCancelDepositRequest(REQUEST_ID, address(almProxy)),   false);
        assertEq(jaaaVault.claimableCancelDepositRequest(REQUEST_ID, address(almProxy)), 0);

        vm.startPrank(ALM_RELAYER);
        foreignController.requestDepositERC7540(address(jaaaVault), 1_000_000e6);
        foreignController.cancelCentrifugeDepositRequest(address(jaaaVault));
        vm.stopPrank();

        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 0);
        assertEq(usdcAvalanche.balanceOf(poolEscrow),            initialEscrowBal + 1_000_000e6);

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),         1_000_000e6);
        assertEq(jaaaVault.pendingCancelDepositRequest(REQUEST_ID, address(almProxy)),   true);
        assertEq(jaaaVault.claimableCancelDepositRequest(REQUEST_ID, address(almProxy)), 0);

        // Fulfill cancelation request
        vm.prank(root);
        manager.fulfillDepositRequest(
            jaaaPoolId,
            jaaaScId,
            address(almProxy),
            usdcAssetId,
            1_000_000e6,
            0,
            1_000_000e6
        );

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),         0);
        assertEq(jaaaVault.pendingCancelDepositRequest(REQUEST_ID, address(almProxy)),   false);
        assertEq(jaaaVault.claimableCancelDepositRequest(REQUEST_ID, address(almProxy)), 1_000_000e6);

        vm.prank(ALM_RELAYER);
        foreignController.claimCentrifugeCancelDepositRequest(address(jaaaVault));

        assertEq(jaaaVault.pendingDepositRequest(REQUEST_ID, address(almProxy)),         0);
        assertEq(jaaaVault.pendingCancelDepositRequest(REQUEST_ID, address(almProxy)),   false);
        assertEq(jaaaVault.claimableCancelDepositRequest(REQUEST_ID, address(almProxy)), 0);

        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 1_000_000e6);
        assertEq(usdcAvalanche.balanceOf(poolEscrow),            initialEscrowBal);
    }

}

contract ForeignControllerRequestRedeemERC7540FailureTests is CentrifugeTestBase {

    function test_requestRedeemERC7540_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.requestRedeemERC7540(address(jaaaVault), 1_000_000e6);
    }

    function test_requestRedeemERC7540_zeroMaxAmount() external {
        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.requestRedeemERC7540(address(jaaaVault), 1_000_000e6);
    }

    function test_requestRedeemERC7540_rateLimitsBoundary() external {
        vm.startPrank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(
            RateLimitHelpers.makeAssetKey(
                foreignController.LIMIT_7540_REDEEM(),
                address(jaaaVault)
            ),
            1_000_000e6,
            uint256(1_000_000e6) / 1 days
        );
        vm.stopPrank();

        vm.startPrank(root);
        jaaaTokenHook.updateMember(address(jaaaToken), address(almProxy), type(uint64).max);
        jaaaToken.mint(address(almProxy), 1_000_000e6);
        vm.stopPrank();

        uint256 overBoundaryShares = jaaaVault.convertToShares(1_000_000e6 + 3);
        uint256 atBoundaryShares   = jaaaVault.convertToShares(1_000_000e6 + 1);

        assertEq(jaaaVault.convertToAssets(overBoundaryShares), 1_000_000e6 + 2);
        assertEq(jaaaVault.convertToAssets(atBoundaryShares),   1_000_000e6);

        vm.startPrank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.requestRedeemERC7540(address(jaaaVault), overBoundaryShares);

        foreignController.requestRedeemERC7540(address(jaaaVault), atBoundaryShares);
    }
}

contract ForeignControllerRequestRedeemERC7540SuccessTests is CentrifugeTestBase {

    bytes32 key;

    function setUp() public override {
        super.setUp();

        vm.startPrank(root);
        jaaaTokenHook.updateMember(address(jaaaToken), address(almProxy), type(uint64).max);
        vm.stopPrank();

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_REDEEM(),
            address(jaaaVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_000_000e6, uint256(1_000_000e6) / 1 days);
    }

    function test_requestRedeemERC7540() external {
        uint256 shares = jaaaVault.convertToShares(1_000_000e6);

        assertEq(shares, 948_558.832635e6);

        vm.prank(root);
        jaaaToken.mint(address(almProxy), shares);

        assertEq(rateLimits.getCurrentRateLimit(key), 1_000_000e6);

        uint256 initialEscrowBal = jaaaToken.balanceOf(poolEscrow);

        assertEq(jaaaToken.balanceOf(address(almProxy)), shares);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        vm.prank(ALM_RELAYER);
        foreignController.requestRedeemERC7540(address(jaaaVault), shares);

        assertEq(rateLimits.getCurrentRateLimit(key), 1);  // Rounding

        assertEq(jaaaToken.balanceOf(address(almProxy)), 0);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal + shares);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)), shares);
    }

}

contract ForeignControllerClaimRedeemERC7540FailureTests is CentrifugeTestBase {

    function test_claimRedeemERC7540_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.claimRedeemERC7540(address(jaaaVault));
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
        jaaaTokenHook.updateMember(address(jaaaToken), address(almProxy), type(uint64).max);
        vm.stopPrank();

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_REDEEM(),
            address(jaaaVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 2_000_000e6, uint256(2_000_000e6) / 1 days);
    }

    function test_claimRedeemERC7540_singleRequest() external {
        vm.prank(root);
        jaaaToken.mint(address(almProxy), 1_000_000e6);

        uint256 initialEscrowBal = jaaaToken.balanceOf(poolEscrow);

        assertEq(jaaaToken.balanceOf(address(almProxy)), 1_000_000e6);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jaaaVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        // Request JTRSY redemption
        vm.prank(ALM_RELAYER);
        foreignController.requestRedeemERC7540(address(jaaaVault), 1_000_000e6);

        uint256 totalSupply = jaaaToken.totalSupply();

        assertEq(jaaaToken.balanceOf(address(almProxy)), 0);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal + 1_000_000e6);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   1_000_000e6);
        assertEq(jaaaVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        // Fulfill request at price 2.0
        deal(address(usdcAvalanche), poolEscrow, 2_000_000e6);
        vm.prank(root);
        manager.fulfillRedeemRequest(
            jaaaPoolId,
            jaaaScId,
            address(almProxy),
            usdcAssetId,
            2_000_000e6,
            1_000_000e6,
            0
        );

        assertEq(jaaaToken.totalSupply(),                totalSupply - 1_000_000e6);
        assertEq(jaaaToken.balanceOf(address(almProxy)), 0);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal);

        assertEq(usdcAvalanche.balanceOf(poolEscrow),            2_000_000e6);
        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 0);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jaaaVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 1_000_000e6);

        // Claim assets
        vm.prank(ALM_RELAYER);
        foreignController.claimRedeemERC7540(address(jaaaVault));

        assertEq(usdcAvalanche.balanceOf(poolEscrow),            0);
        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 2_000_000e6);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jaaaVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);
    }

    function test_claimRedeemERC7540_multipleRequests() external {
        vm.prank(root);
        jaaaToken.mint(address(almProxy), 1_500_000e6);

        uint256 initialEscrowBal = jaaaToken.balanceOf(poolEscrow);

        assertEq(jaaaToken.balanceOf(address(almProxy)), 1_500_000e6);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jaaaVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        // Request JTRSY redemption
        vm.prank(ALM_RELAYER);
        foreignController.requestRedeemERC7540(address(jaaaVault), 1_000_000e6);

        uint256 totalSupply = jaaaToken.totalSupply();

        assertEq(jaaaToken.balanceOf(address(almProxy)), 500_000e6);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal + 1_000_000e6);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   1_000_000e6);
        assertEq(jaaaVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        // Request another JTRSY redemption
        vm.prank(ALM_RELAYER);
        foreignController.requestRedeemERC7540(address(jaaaVault), 500_000e6);

        assertEq(jaaaToken.balanceOf(address(almProxy)), 0);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal + 1_500_000e6);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   1_500_000e6);
        assertEq(jaaaVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        // Fulfill both requests at price 2.0
        deal(address(usdcAvalanche), poolEscrow, 3_000_000e6);
        vm.prank(root);
        manager.fulfillRedeemRequest(
            jaaaPoolId,
            jaaaScId,
            address(almProxy),
            usdcAssetId,
            3_000_000e6,
            1_500_000e6,
            0
        );

        assertEq(jaaaToken.totalSupply(),                totalSupply - 1_500_000e6);
        assertEq(jaaaToken.balanceOf(address(almProxy)), 0);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal);

        assertEq(usdcAvalanche.balanceOf(poolEscrow),            3_000_000e6);
        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 0);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jaaaVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 1_500_000e6);

        // Claim assets
        vm.prank(ALM_RELAYER);
        foreignController.claimRedeemERC7540(address(jaaaVault));

        assertEq(usdcAvalanche.balanceOf(poolEscrow),            0);
        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 3_000_000e6);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),   0);
        assertEq(jaaaVault.claimableRedeemRequest(REQUEST_ID, address(almProxy)), 0);
    }

}

contract ForeignControllerCancelCentrifugeRedeemRequestFailureTests is CentrifugeTestBase {

    function test_cancelCentrifugeRedeemRequest_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.cancelCentrifugeRedeemRequest(address(jaaaVault));
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
        jaaaTokenHook.updateMember(address(jaaaToken), address(almProxy), type(uint64).max);
        vm.stopPrank();

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_REDEEM(),
            address(jaaaVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_000_000e6, uint256(1_000_000e6) / 1 days);
    }

    function test_cancelCentrifugeRedeemRequest() external {
        uint256 shares = jaaaVault.convertToShares(1_000_000e6);

        vm.prank(root);
        jaaaToken.mint(address(almProxy), shares);

        vm.prank(ALM_RELAYER);
        foreignController.requestRedeemERC7540(address(jaaaVault), shares);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),       shares);
        assertEq(jaaaVault.pendingCancelRedeemRequest(REQUEST_ID, address(almProxy)), false);

        vm.prank(ALM_RELAYER);
        foreignController.cancelCentrifugeRedeemRequest(address(jaaaVault));

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),       shares);
        assertEq(jaaaVault.pendingCancelRedeemRequest(REQUEST_ID, address(almProxy)), true);
    }

}

contract ForeignControllerClaimCentrifugeCancelRedeemRequestFailureTests is CentrifugeTestBase {

    function test_claimCentrifugeCancelRedeemRequest_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.claimCentrifugeCancelRedeemRequest(address(jaaaVault));
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
        jaaaTokenHook.updateMember(address(jaaaToken), address(almProxy), type(uint64).max);
        vm.stopPrank();

        key = RateLimitHelpers.makeAssetKey(
            foreignController.LIMIT_7540_REDEEM(),
            address(jaaaVault)
        );

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(key, 1_000_000e6, uint256(1_000_000e6) / 1 days);
    }

    function test_claimCentrifugeCancelRedeemRequest() external {
        uint256 shares = jaaaVault.convertToShares(1_000_000e6);

        vm.prank(root);
        jaaaToken.mint(address(almProxy), shares);

        uint256 initialEscrowBal = jaaaToken.balanceOf(poolEscrow);

        assertEq(jaaaToken.balanceOf(address(almProxy)), shares);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),         0);
        assertEq(jaaaVault.pendingCancelRedeemRequest(REQUEST_ID, address(almProxy)),   false);
        assertEq(jaaaVault.claimableCancelRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        vm.startPrank(ALM_RELAYER);
        foreignController.requestRedeemERC7540(address(jaaaVault), shares);
        foreignController.cancelCentrifugeRedeemRequest(address(jaaaVault));
        vm.stopPrank();

        assertEq(jaaaToken.balanceOf(address(almProxy)), 0);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal + shares);

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),         shares);
        assertEq(jaaaVault.pendingCancelRedeemRequest(REQUEST_ID, address(almProxy)),   true);
        assertEq(jaaaVault.claimableCancelRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        // Fulfill cancelation request
        vm.prank(root);
        manager.fulfillRedeemRequest(
            jaaaPoolId,
            jaaaScId,
            address(almProxy),
            usdcAssetId,
            0,
            0,
            uint128(shares)
        );

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),         0);
        assertEq(jaaaVault.pendingCancelRedeemRequest(REQUEST_ID, address(almProxy)),   false);
        assertEq(jaaaVault.claimableCancelRedeemRequest(REQUEST_ID, address(almProxy)), shares);

        vm.prank(ALM_RELAYER);
        foreignController.claimCentrifugeCancelRedeemRequest(address(jaaaVault));

        assertEq(jaaaVault.pendingRedeemRequest(REQUEST_ID, address(almProxy)),         0);
        assertEq(jaaaVault.pendingCancelRedeemRequest(REQUEST_ID, address(almProxy)),   false);
        assertEq(jaaaVault.claimableCancelRedeemRequest(REQUEST_ID, address(almProxy)), 0);

        assertEq(jaaaToken.balanceOf(address(almProxy)), shares);
        assertEq(jaaaToken.balanceOf(poolEscrow),            initialEscrowBal);
    }

}
