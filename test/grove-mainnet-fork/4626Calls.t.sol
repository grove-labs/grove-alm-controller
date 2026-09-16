// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import "./ForkTestBase.t.sol";

contract SUSDSTestBase is ForkTestBase {

    uint256 SUSDS_CONVERTED_ASSETS;
    uint256 SUSDS_CONVERTED_SHARES;

    uint256 SUSDS_TOTAL_ASSETS;
    uint256 SUSDS_TOTAL_SUPPLY;

    uint256 SUSDS_DRIP_AMOUNT;

    bytes32 depositKey;
    bytes32 withdrawKey;

    function setUp() override public {
        super.setUp();

        depositKey  = RateLimitHelpers.makeAddressAddressKey(mainnetController.LIMIT_4626_DEPOSIT(), Ethereum.USDS, Ethereum.SUSDS);
        withdrawKey = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_4626_WITHDRAW(), Ethereum.SUSDS);

        vm.startPrank(Ethereum.GROVE_PROXY);
        rateLimits.setRateLimitData(mainnetController.LIMIT_USDS_MINT(), 10_000_000e18, uint256(10_000_000e18) / 4 hours);
        rateLimits.setRateLimitData(depositKey,  5_000_000e18, uint256(1_000_000e18) / 4 hours);
        rateLimits.setRateLimitData(withdrawKey, 5_000_000e18, uint256(1_000_000e18) / 4 hours);
        mainnetController.setMaxExchangeRate(address(susds), susds.convertToShares(1e18), 1.2e18);
        vm.stopPrank();

        SUSDS_CONVERTED_ASSETS = susds.convertToAssets(1e18);
        SUSDS_CONVERTED_SHARES = susds.convertToShares(1e18);

        SUSDS_TOTAL_ASSETS = susds.totalAssets();
        SUSDS_TOTAL_SUPPLY = susds.totalSupply();

        // Setting this value directly because susds.drip() fails in setUp with
        // StateChangeDuringStaticCall and it is unclear why, something related to foundry.
        SUSDS_DRIP_AMOUNT = 51.87160523081084142e18;

        assertEq(SUSDS_CONVERTED_ASSETS, 1.073777980370121329e18);
        assertEq(SUSDS_CONVERTED_SHARES, 0.931291215019430047e18);

        assertEq(SUSDS_TOTAL_ASSETS, 3_096_961_050.229935401970647802e18);
        assertEq(SUSDS_TOTAL_SUPPLY, 2_884_172_619.336486671521984122e18);
    }

}

contract MainnetControllerDepositERC4626FailureTests is SUSDSTestBase {

    function test_depositERC4626_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        mainnetController.depositERC4626(address(susds), 1e18, 0);
    }

    function test_depositERC4626_zeroMaxAmount() external {
        vm.prank(Ethereum.GROVE_PROXY);
        rateLimits.setRateLimitData(depositKey, 0, 0);

        vm.prank(relayer);
        vm.expectRevert("RateLimits/zero-maxAmount");
        mainnetController.depositERC4626(address(susds), 1e18, 0);
    }

    function test_depositERC4626_tokenOnlyKeyNotHonoured() external {
        // A limit under the pre-facet (rateLimitId, token) key does not authorize deposits.
        vm.startPrank(Ethereum.GROVE_PROXY);
        rateLimits.setRateLimitData(depositKey, 0, 0);
        rateLimits.setRateLimitData(
            RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_4626_DEPOSIT(), Ethereum.SUSDS),
            5_000_000e18,
            uint256(1_000_000e18) / 4 hours
        );
        vm.stopPrank();

        vm.prank(relayer);
        vm.expectRevert("RateLimits/zero-maxAmount");
        mainnetController.depositERC4626(address(susds), 1e18, 0);
    }

    function test_depositERC4626_minSharesOutNotMetBoundary() external {
        vm.startPrank(relayer);
        mainnetController.mintUSDS(5_000_000e18);

        uint256 overBoundaryShares = susds.convertToShares(5_000_000e18) + 1;
        uint256 atBoundaryShares   = susds.convertToShares(5_000_000e18);

        vm.expectRevert("ERC4626Lib/min-shares-out-not-met");
        mainnetController.depositERC4626(address(susds), 5_000_000e18, overBoundaryShares);

        mainnetController.depositERC4626(address(susds), 5_000_000e18, atBoundaryShares);
    }

    function test_depositERC4626_rateLimitBoundary() external {
        vm.startPrank(relayer);

        mainnetController.mintUSDS(5_000_000e18);

        // Warp to get back above rate limit
        skip(1 minutes);
        mainnetController.mintUSDS(100e18);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        mainnetController.depositERC4626(address(susds), 5_000_000e18 + 1, 0);

        mainnetController.depositERC4626(address(susds), 5_000_000e18, 0);

        vm.stopPrank();
    }

    function test_depositERC4626_exchangeRateBoundary() external {
        vm.prank(relayer);
        mainnetController.mintUSDS(5_000_000e18);

        vm.startPrank(Ethereum.GROVE_PROXY);
        mainnetController.setMaxExchangeRate(address(susds), susds.convertToShares(5_000_000e18), 5_000_000e18 - 1);
        vm.stopPrank();

        vm.prank(relayer);
        vm.expectRevert("ERC4626Lib/exchange-rate-too-high");
        mainnetController.depositERC4626(address(susds), 5_000_000e18, 0);

        vm.startPrank(Ethereum.GROVE_PROXY);
        mainnetController.setMaxExchangeRate(address(susds), susds.convertToShares(5_000_000e18), 5_000_000e18);
        vm.stopPrank();

        vm.prank(relayer);
        mainnetController.depositERC4626(address(susds), 5_000_000e18, 0);
    }

    function test_depositERC4626_zeroExchangeRate() external {
        vm.prank(relayer);
        mainnetController.mintUSDS(5_000_000e18);

        vm.prank(Ethereum.GROVE_PROXY);
        mainnetController.setMaxExchangeRate(address(susds), 0, 0);

        vm.prank(relayer);
        vm.expectRevert("ERC4626Lib/exchange-rate-too-high");
        mainnetController.depositERC4626(address(susds), 5_000_000e18, 0);
    }

}

contract MainnetControllerDepositERC4626Tests is SUSDSTestBase {

    function test_depositERC4626() external {
        vm.prank(relayer);
        mainnetController.mintUSDS(1e18);

        assertEq(usds.balanceOf(address(almProxy)),          1e18);
        assertEq(usds.balanceOf(address(mainnetController)), 0);
        assertEq(usds.balanceOf(address(susds)),             USDS_BAL_SUSDS);

        assertEq(usds.allowance(address(buffer),   address(vault)),  type(uint256).max);
        assertEq(usds.allowance(address(almProxy), address(susds)),  0);

        assertEq(susds.totalSupply(),                SUSDS_TOTAL_SUPPLY);
        assertEq(susds.totalAssets(),                SUSDS_TOTAL_ASSETS);
        assertEq(susds.balanceOf(address(almProxy)), 0);

        vm.prank(relayer);
        uint256 shares = mainnetController.depositERC4626(address(susds), 1e18, 0);

        assertEq(shares, SUSDS_CONVERTED_SHARES);

        assertEq(usds.balanceOf(address(almProxy)),          0);
        assertEq(usds.balanceOf(address(mainnetController)), 0);
        assertEq(usds.balanceOf(address(susds)),             USDS_BAL_SUSDS + SUSDS_DRIP_AMOUNT + 1e18);

        assertEq(usds.allowance(address(buffer),   address(vault)), type(uint256).max);
        assertEq(usds.allowance(address(almProxy), address(susds)), 0);

        assertEq(susds.totalSupply(),                SUSDS_TOTAL_SUPPLY + shares);
        assertEq(susds.totalAssets(),                SUSDS_TOTAL_ASSETS + 1e18 - 1);  // Rounding
        assertEq(susds.balanceOf(address(almProxy)), SUSDS_CONVERTED_SHARES);
    }

}

contract MainnetControllerWithdrawERC4626FailureTests is SUSDSTestBase {

    function test_withdrawERC4626_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        mainnetController.withdrawERC4626(address(susds), 1e18, type(uint256).max);
    }

    function test_withdrawERC4626_zeroMaxAmount() external {
        // Longer setup because rate limit revert is at the end of the function
        vm.prank(Ethereum.GROVE_PROXY);
        rateLimits.setRateLimitData(withdrawKey, 0, 0);

        vm.startPrank(relayer);
        mainnetController.mintUSDS(100e18);
        mainnetController.depositERC4626(address(susds), 100e18, 0);

        vm.expectRevert("RateLimits/zero-maxAmount");
        mainnetController.withdrawERC4626(address(susds), 1e18, type(uint256).max);
    }

    function test_withdrawERC4626_maxSharesInBoundary() external {
        vm.startPrank(relayer);
        mainnetController.mintUSDS(1_000_000e18);
        mainnetController.depositERC4626(address(susds), 1_000_000e18, 0);

        uint256 underBoundaryShares = susds.previewWithdraw(500_000e18) - 1;
        uint256 atBoundaryShares    = susds.previewWithdraw(500_000e18);

        vm.expectRevert("ERC4626Lib/shares-burned-too-high");
        mainnetController.withdrawERC4626(address(susds), 500_000e18, underBoundaryShares);

        mainnetController.withdrawERC4626(address(susds), 500_000e18, atBoundaryShares);
    }

    function test_withdrawERC4626_rateLimitBoundary() external {
        vm.startPrank(Ethereum.GROVE_PROXY);
        rateLimits.setRateLimitData(depositKey, 10_000_000e18, uint256(1_000_000e18) / 4 hours);
        vm.stopPrank();

        vm.startPrank(relayer);

        mainnetController.mintUSDS(10_000_000e18);
        mainnetController.depositERC4626(address(susds), 10_000_000e18, 0);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        mainnetController.withdrawERC4626(address(susds), 5_000_000e18 + 1, type(uint256).max);

        mainnetController.withdrawERC4626(address(susds), 5_000_000e18, type(uint256).max);

        vm.stopPrank();
    }

}

contract MainnetControllerWithdrawERC4626Tests is SUSDSTestBase {

    function test_withdrawERC4626() external {
        vm.startPrank(relayer);
        mainnetController.mintUSDS(1e18);
        mainnetController.depositERC4626(address(susds), 1e18, 0);
        vm.stopPrank();

        assertEq(usds.balanceOf(address(almProxy)),          0);
        assertEq(usds.balanceOf(address(mainnetController)), 0);
        assertEq(usds.balanceOf(address(susds)),             USDS_BAL_SUSDS + SUSDS_DRIP_AMOUNT + 1e18);

        assertEq(usds.allowance(address(buffer),   address(vault)), type(uint256).max);
        assertEq(usds.allowance(address(almProxy), address(susds)),  0);

        assertEq(susds.totalSupply(),                SUSDS_TOTAL_SUPPLY + SUSDS_CONVERTED_SHARES);
        assertEq(susds.totalAssets(),                SUSDS_TOTAL_ASSETS + 1e18 - 1);  // Rounding
        assertEq(susds.balanceOf(address(almProxy)), SUSDS_CONVERTED_SHARES);

        // Max available with rounding
        vm.prank(relayer);
        uint256 shares = mainnetController.withdrawERC4626(address(susds), 1e18 - 2, type(uint256).max);  // Rounding

        assertEq(shares, SUSDS_CONVERTED_SHARES);

        assertEq(usds.balanceOf(address(almProxy)),          1e18 - 2);
        assertEq(usds.balanceOf(address(mainnetController)), 0);
        assertEq(usds.balanceOf(address(susds)),             USDS_BAL_SUSDS + SUSDS_DRIP_AMOUNT + 2);  // Rounding

        assertEq(usds.allowance(address(buffer),   address(vault)), type(uint256).max);
        assertEq(usds.allowance(address(almProxy), address(susds)),  0);

        assertEq(susds.totalSupply(),                SUSDS_TOTAL_SUPPLY);
        assertEq(susds.totalAssets(),                SUSDS_TOTAL_ASSETS);
        assertEq(susds.balanceOf(address(almProxy)), 0);
    }

}

contract MainnetControllerRedeemERC4626FailureTests is SUSDSTestBase {

    function test_redeemERC4626_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        mainnetController.redeemERC4626(address(susds), 1e18, 0);
    }

    function test_redeemERC4626_zeroMaxAmount() external {
        // Longer setup because rate limit revert is at the end of the function
        vm.prank(Ethereum.GROVE_PROXY);
        rateLimits.setRateLimitData(withdrawKey, 0, 0);

        vm.startPrank(relayer);
        mainnetController.mintUSDS(100e18);
        mainnetController.depositERC4626(address(susds), 100e18, 0);
        vm.stopPrank();

        vm.prank(relayer);
        vm.expectRevert("RateLimits/zero-maxAmount");
        mainnetController.redeemERC4626(address(susds), 1e18, 0);
    }

    function test_redeemERC4626_rateLimitBoundary() external {
        vm.startPrank(Ethereum.GROVE_PROXY);
        rateLimits.setRateLimitData(depositKey, 10_000_000e18, uint256(1_000_000e18) / 4 hours);
        vm.stopPrank();

        vm.startPrank(relayer);

        mainnetController.mintUSDS(10_000_000e18);
        mainnetController.depositERC4626(address(susds), 10_000_000e18, 0);

        uint256 overBoundaryShares = susds.convertToShares(5_000_000e18 + 2);
        uint256 atBoundaryShares   = susds.convertToShares(5_000_000e18 + 1);  // Still rounds down

        assertEq(susds.previewRedeem(overBoundaryShares), 5_000_000e18 + 1);
        assertEq(susds.previewRedeem(atBoundaryShares),   5_000_000e18);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        mainnetController.redeemERC4626(address(susds), overBoundaryShares, 0);

        mainnetController.redeemERC4626(address(susds), atBoundaryShares, 0);

        vm.stopPrank();
    }

}

contract MainnetControllerRedeemERC4626Tests is SUSDSTestBase {

    function test_redeemERC4626() external {
        vm.startPrank(relayer);
        mainnetController.mintUSDS(1e18);
        mainnetController.depositERC4626(address(susds), 1e18, 0);
        vm.stopPrank();

        assertEq(usds.balanceOf(address(almProxy)),          0);
        assertEq(usds.balanceOf(address(mainnetController)), 0);
        assertEq(usds.balanceOf(address(susds)),             USDS_BAL_SUSDS + SUSDS_DRIP_AMOUNT + 1e18);

        assertEq(usds.allowance(address(buffer),   address(vault)), type(uint256).max);
        assertEq(usds.allowance(address(almProxy), address(susds)),  0);

        assertEq(susds.totalSupply(),                SUSDS_TOTAL_SUPPLY + SUSDS_CONVERTED_SHARES);
        assertEq(susds.totalAssets(),                SUSDS_TOTAL_ASSETS + 1e18 - 1);  // Rounding
        assertEq(susds.balanceOf(address(almProxy)), SUSDS_CONVERTED_SHARES);

        vm.prank(relayer);
        uint256 assets = mainnetController.redeemERC4626(address(susds), SUSDS_CONVERTED_SHARES, 0);

        assertEq(assets, 1e18 - 2);  // Rounding

        assertEq(usds.balanceOf(address(almProxy)),          1e18 - 2);  // Rounding
        assertEq(usds.balanceOf(address(mainnetController)), 0);
        assertEq(usds.balanceOf(address(susds)),             USDS_BAL_SUSDS + SUSDS_DRIP_AMOUNT + 2);  // Rounding

        assertEq(usds.allowance(address(buffer),   address(vault)), type(uint256).max);
        assertEq(usds.allowance(address(almProxy), address(susds)), 0);

        assertEq(susds.totalSupply(),                SUSDS_TOTAL_SUPPLY);
        assertEq(susds.totalAssets(),                SUSDS_TOTAL_ASSETS);
        assertEq(susds.balanceOf(address(almProxy)), 0);
    }

}
