// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { IAaveV4Spoke } from "../../src/libraries/AaveV4Lib.sol";

import "./ForkTestBase.t.sol";

interface IAaveV4Hub {
    function getAssetLiquidity(uint256 assetId) external view returns (uint256);
    function getAddedAssets(uint256 assetId)    external view returns (uint256);
    function getAddedShares(uint256 assetId)    external view returns (uint256);
}

contract AaveV4MainSpokeBaseTest is ForkTestBase {

    // Aave v4 Main Spoke on Avalanche (liquidity custodied by the Core Hub).
    // USDC = reserveId 2 (6 decimals); WAVAX = reserveId 0 (18 decimals).
    address constant MAIN_SPOKE = 0x435272CefF93a1E657E8ABfdf0A13e95900A3a56;
    address constant CORE_HUB   = 0xd07369fAE4A5BB13c9Ce446B052c7867B1AbDf6e;
    address constant WAVAX      = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    uint256 constant USDC_RESERVE_ID  = 2;
    uint256 constant WAVAX_RESERVE_ID = 0;

    // Deposit rate limits are controller config only and never bind here: Aave v4's on-chain
    // supply ("add") caps are far lower (USDC 5,000,000; WAVAX 500,000). The WAVAX limit is the
    // USD target converted at the fork-block Chainlink AVAX/USD price ($6.58383/AVAX).
    uint256 constant USDC_DEPOSIT_LIMIT  = 50_000_000e6;   // $50M
    uint256 constant WAVAX_DEPOSIT_LIMIT = 3_500_000e18;   // ~$23M @ $6.58383/AVAX ($25M target, rounded)

    // Actual deposit sizes exercised below, kept under Aave's supply caps.
    uint256 constant USDC_DEPOSIT_AMOUNT  = 4_000_000e6;   // $4M     (cap headroom ~$4.98M)
    uint256 constant WAVAX_DEPOSIT_AMOUNT = 400_000e18;    // ~$2.63M (cap headroom ~492k WAVAX)

    IERC20 wavax = IERC20(WAVAX);

    bytes32 usdcDepositKey;
    bytes32 usdcWithdrawKey;
    bytes32 wavaxDepositKey;
    bytes32 wavaxWithdrawKey;

    uint256 startingHubBalanceUsdc;
    uint256 startingHubBalanceWavax;

    function _getBlock() internal pure override returns (uint256) {
        return 90450000;  // July 16, 2026
    }

    function setUp() public virtual override {
        super.setUp();

        usdcDepositKey   = RateLimitHelpers.makeSpokeReserveAssetKey(foreignController.LIMIT_AAVE_V4_DEPOSIT(),  MAIN_SPOKE, USDC_RESERVE_ID,  address(usdcAvalanche));
        usdcWithdrawKey  = RateLimitHelpers.makeSpokeReserveKey(foreignController.LIMIT_AAVE_V4_WITHDRAW(),      MAIN_SPOKE, USDC_RESERVE_ID);
        wavaxDepositKey  = RateLimitHelpers.makeSpokeReserveAssetKey(foreignController.LIMIT_AAVE_V4_DEPOSIT(),  MAIN_SPOKE, WAVAX_RESERVE_ID, WAVAX);
        wavaxWithdrawKey = RateLimitHelpers.makeSpokeReserveKey(foreignController.LIMIT_AAVE_V4_WITHDRAW(),      MAIN_SPOKE, WAVAX_RESERVE_ID);

        vm.startPrank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(usdcDepositKey,  USDC_DEPOSIT_LIMIT,  USDC_DEPOSIT_LIMIT  / 1 days);
        rateLimits.setRateLimitData(wavaxDepositKey, WAVAX_DEPOSIT_LIMIT, WAVAX_DEPOSIT_LIMIT / 1 days);
        rateLimits.setUnlimitedRateLimitData(usdcWithdrawKey);
        rateLimits.setUnlimitedRateLimitData(wavaxWithdrawKey);
        foreignController.setMaxSlippage(MAIN_SPOKE, 1e18 - 1e4);  // Rounding slippage
        vm.stopPrank();

        startingHubBalanceUsdc  = usdcAvalanche.balanceOf(CORE_HUB);
        startingHubBalanceWavax = wavax.balanceOf(CORE_HUB);
    }

    function _suppliedAssets(uint256 reserveId) internal view returns (uint256) {
        return IAaveV4Spoke(MAIN_SPOKE).getUserSuppliedAssets(reserveId, address(almProxy));
    }

}

// NOTE: Non-rate-limit failures only test USDC as the revert path is asset-agnostic.

contract AaveV4MainSpokeDepositFailureTests is AaveV4MainSpokeBaseTest {

    function test_depositAaveV4_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, 1_000e6);
    }

    function test_depositAaveV4_zeroMaxAmount() external {
        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.depositAaveV4(MAIN_SPOKE, 1, 1e6);
    }

    function test_depositAaveV4_zeroMaxSlippage() external {
        vm.prank(GROVE_EXECUTOR);
        foreignController.setMaxSlippage(MAIN_SPOKE, 0);

        deal(address(usdcAvalanche), address(almProxy), 1_000e6);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("AaveV4Lib/max-slippage-not-set");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, 1_000e6);
    }

    function test_depositAaveV4_usdcSlippageBoundary() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);

        // Strictest tolerance (1e18) still admits the exact 1:1 USDC deposit.
        vm.prank(GROVE_EXECUTOR);
        foreignController.setMaxSlippage(MAIN_SPOKE, 1e18);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, USDC_DEPOSIT_AMOUNT);

        assertApproxEqAbs(_suppliedAssets(USDC_RESERVE_ID), USDC_DEPOSIT_AMOUNT, 1);
    }

    // Mirror image of the USDC boundary: WAVAX's share price is above 1:1, so the credited position
    // rounds just below the supplied amount and the strictest tolerance (1e18) trips the guard.
    function test_depositAaveV4_wavaxSlippageBoundary() external {
        deal(WAVAX, address(almProxy), WAVAX_DEPOSIT_AMOUNT);

        vm.prank(GROVE_EXECUTOR);
        foreignController.setMaxSlippage(MAIN_SPOKE, 1e18);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("AaveV4Lib/slippage-too-high");
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, WAVAX_DEPOSIT_AMOUNT);
    }

    // The deposit limit ($50M) far exceeds Aave's supply cap, so only the over-limit revert is
    // asserted (the rate-limit check runs before the Aave supply call); a cap-safe deposit then
    // confirms the limit admits a legitimate large deposit and decrements as expected.
    function test_depositAaveV4_usdcRateLimitedBoundary() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_LIMIT + 1);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, USDC_DEPOSIT_LIMIT + 1);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, USDC_DEPOSIT_AMOUNT);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey), USDC_DEPOSIT_LIMIT - USDC_DEPOSIT_AMOUNT);
    }

    function test_depositAaveV4_wavaxRateLimitedBoundary() external {
        deal(WAVAX, address(almProxy), WAVAX_DEPOSIT_LIMIT + 1);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, WAVAX_DEPOSIT_LIMIT + 1);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, WAVAX_DEPOSIT_AMOUNT);

        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), WAVAX_DEPOSIT_LIMIT - WAVAX_DEPOSIT_AMOUNT);
    }

}

contract AaveV4MainSpokeDepositSuccessTests is AaveV4MainSpokeBaseTest {

    // Guards the IAaveV4Spoke.Reserve layout assumed by the partial interface.
    function test_aaveV4_reserveLayout() external view {
        IAaveV4Spoke.Reserve memory usdcReserve = IAaveV4Spoke(MAIN_SPOKE).getReserve(USDC_RESERVE_ID);

        assertEq(usdcReserve.underlying, address(usdcAvalanche));
        assertEq(usdcReserve.hub,        CORE_HUB);
        assertEq(usdcReserve.assetId,    2);
        assertEq(usdcReserve.decimals,   6);

        IAaveV4Spoke.Reserve memory wavaxReserve = IAaveV4Spoke(MAIN_SPOKE).getReserve(WAVAX_RESERVE_ID);

        assertEq(wavaxReserve.underlying, WAVAX);
        assertEq(wavaxReserve.hub,        CORE_HUB);
        assertEq(wavaxReserve.assetId,    0);
        assertEq(wavaxReserve.decimals,   18);
    }

    function test_depositAaveV4_usdc() public {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);

        assertEq(usdcAvalanche.allowance(address(almProxy), MAIN_SPOKE), 0);
        assertEq(_suppliedAssets(USDC_RESERVE_ID),                       0);
        assertEq(usdcAvalanche.balanceOf(address(almProxy)),            USDC_DEPOSIT_AMOUNT);
        assertEq(usdcAvalanche.balanceOf(CORE_HUB),                     startingHubBalanceUsdc);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey), USDC_DEPOSIT_LIMIT);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, USDC_DEPOSIT_AMOUNT);

        assertEq(usdcAvalanche.allowance(address(almProxy), MAIN_SPOKE), 0);
        assertApproxEqAbs(_suppliedAssets(USDC_RESERVE_ID),  USDC_DEPOSIT_AMOUNT, 1);
        assertEq(usdcAvalanche.balanceOf(address(almProxy)), 0);
        assertEq(usdcAvalanche.balanceOf(CORE_HUB),          startingHubBalanceUsdc + USDC_DEPOSIT_AMOUNT);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey), USDC_DEPOSIT_LIMIT - USDC_DEPOSIT_AMOUNT);
    }

    function test_depositAaveV4_wavax() public {
        uint256 amount = WAVAX_DEPOSIT_AMOUNT;

        // WAVAX share price is above 1:1 (accrued interest).
        uint256 assetId = IAaveV4Spoke(MAIN_SPOKE).getReserve(WAVAX_RESERVE_ID).assetId;
        assertGt(IAaveV4Hub(CORE_HUB).getAddedAssets(assetId), IAaveV4Hub(CORE_HUB).getAddedShares(assetId));

        deal(WAVAX, address(almProxy), amount);

        assertEq(wavax.allowance(address(almProxy), MAIN_SPOKE), 0);
        assertEq(_suppliedAssets(WAVAX_RESERVE_ID),             0);
        assertEq(wavax.balanceOf(address(almProxy)),            amount);
        assertEq(wavax.balanceOf(CORE_HUB),                     startingHubBalanceWavax);

        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), WAVAX_DEPOSIT_LIMIT);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, amount);

        assertEq(wavax.allowance(address(almProxy), MAIN_SPOKE), 0);
        // Supplied tracks the deposit within share-conversion rounding (share price > 1:1).
        assertApproxEqAbs(_suppliedAssets(WAVAX_RESERVE_ID), amount, 10);
        assertEq(wavax.balanceOf(address(almProxy)),         0);
        assertEq(wavax.balanceOf(CORE_HUB),                  startingHubBalanceWavax + amount);

        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), WAVAX_DEPOSIT_LIMIT - amount);
    }

}

// NOTE: Non-rate-limit failures only test USDC as the revert path is asset-agnostic.

contract AaveV4MainSpokeWithdrawFailureTests is AaveV4MainSpokeBaseTest {

    function test_withdrawAaveV4_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.withdrawAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, 1_000e6);
    }

    function test_withdrawAaveV4_zeroMaxAmount() external {
        // Longer setup because rate limit revert is at the end of the function
        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(usdcWithdrawKey, 0, 0);

        deal(address(usdcAvalanche), address(almProxy), 1_000e6);

        vm.startPrank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, 1_000e6);

        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.withdrawAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, 1_000e6);
        vm.stopPrank();
    }

    // Withdrawals are globally unlimited, so a finite withdraw limit is installed locally to
    // exercise the withdraw rate-limit boundary.
    function test_withdrawAaveV4_usdcRateLimitedBoundary() external {
        uint256 withdrawLimit = 1_000_000e6;

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(usdcWithdrawKey, withdrawLimit, withdrawLimit / 1 days);

        // Supply more than the withdraw limit so the rate limit binds first
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);

        vm.startPrank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, USDC_DEPOSIT_AMOUNT);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.withdrawAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, withdrawLimit + 1);

        foreignController.withdrawAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, withdrawLimit);
        vm.stopPrank();

        assertEq(rateLimits.getCurrentRateLimit(usdcWithdrawKey), 0);
    }

    function test_withdrawAaveV4_wavaxRateLimitedBoundary() external {
        uint256 withdrawLimit = 100_000e18;

        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(wavaxWithdrawKey, withdrawLimit, withdrawLimit / 1 days);

        // Supply more than the withdraw limit so the rate limit binds first
        deal(WAVAX, address(almProxy), WAVAX_DEPOSIT_AMOUNT);

        vm.startPrank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, WAVAX_DEPOSIT_AMOUNT);

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.withdrawAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, withdrawLimit + 1);

        foreignController.withdrawAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, withdrawLimit);
        vm.stopPrank();

        assertApproxEqAbs(rateLimits.getCurrentRateLimit(wavaxWithdrawKey), 0, 10);
    }

}

contract AaveV4MainSpokeWithdrawSuccessTests is AaveV4MainSpokeBaseTest {

    function test_withdrawAaveV4_usdc() public {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);
        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, USDC_DEPOSIT_AMOUNT);

        uint256 supplied = _suppliedAssets(USDC_RESERVE_ID);
        assertApproxEqAbs(supplied, USDC_DEPOSIT_AMOUNT, 1);

        assertEq(usdcAvalanche.balanceOf(address(almProxy)),                     0);
        assertEq(usdcAvalanche.balanceOf(CORE_HUB),                              startingHubBalanceUsdc + USDC_DEPOSIT_AMOUNT);
        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),   USDC_DEPOSIT_LIMIT - USDC_DEPOSIT_AMOUNT);
        assertEq(rateLimits.getCurrentRateLimit(usdcWithdrawKey),  type(uint256).max);

        // Partial withdraw
        uint256 partialAmount = 1_500_000e6;
        vm.prank(ALM_RELAYER);
        assertEq(foreignController.withdrawAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, partialAmount), partialAmount);

        assertEq(usdcAvalanche.balanceOf(address(almProxy)),                     partialAmount);
        assertEq(usdcAvalanche.balanceOf(CORE_HUB),                              startingHubBalanceUsdc + USDC_DEPOSIT_AMOUNT - partialAmount);
        assertApproxEqAbs(_suppliedAssets(USDC_RESERVE_ID),                      supplied - partialAmount, 1);
        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),   USDC_DEPOSIT_LIMIT - USDC_DEPOSIT_AMOUNT + partialAmount);
        assertEq(rateLimits.getCurrentRateLimit(usdcWithdrawKey),  type(uint256).max);

        // Withdraw all
        vm.prank(ALM_RELAYER);
        uint256 remaining = foreignController.withdrawAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, type(uint256).max);

        assertApproxEqAbs(remaining,                                  supplied - partialAmount, 1);
        assertEq(_suppliedAssets(USDC_RESERVE_ID),                   0);
        assertApproxEqAbs(usdcAvalanche.balanceOf(address(almProxy)), supplied,               1);
        assertApproxEqAbs(usdcAvalanche.balanceOf(CORE_HUB),          startingHubBalanceUsdc, 1);

        // Deposit capacity restored, withdraw capacity untouched (unlimited)
        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),   USDC_DEPOSIT_LIMIT);
        assertEq(rateLimits.getCurrentRateLimit(usdcWithdrawKey),  type(uint256).max);
    }

    function test_withdrawAaveV4_usdc_zeroDepositRateLimit() public {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  USDC_DEPOSIT_LIMIT);
        assertEq(rateLimits.getCurrentRateLimit(usdcWithdrawKey), type(uint256).max);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, USDC_DEPOSIT_AMOUNT);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  USDC_DEPOSIT_LIMIT - USDC_DEPOSIT_AMOUNT);
        assertEq(rateLimits.getCurrentRateLimit(usdcWithdrawKey), type(uint256).max);

        // Partial withdraw restores deposit capacity
        vm.prank(ALM_RELAYER);
        assertEq(foreignController.withdrawAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, 1_000_000e6), 1_000_000e6);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  USDC_DEPOSIT_LIMIT - USDC_DEPOSIT_AMOUNT + 1_000_000e6);
        assertEq(rateLimits.getCurrentRateLimit(usdcWithdrawKey), type(uint256).max);

        // Disable the deposit rate limit
        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(usdcDepositKey, 0, 0);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey), 0);

        // Withdraw still works; deposit restore is skipped
        vm.prank(ALM_RELAYER);
        assertEq(foreignController.withdrawAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, 1_000_000e6), 1_000_000e6);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  0);  // Stays at 0
        assertEq(rateLimits.getCurrentRateLimit(usdcWithdrawKey), type(uint256).max);
    }

    function test_withdrawAaveV4_wavax() public {
        uint256 amount = WAVAX_DEPOSIT_AMOUNT;

        deal(WAVAX, address(almProxy), amount);
        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, amount);

        uint256 supplied = _suppliedAssets(WAVAX_RESERVE_ID);
        assertApproxEqAbs(supplied, amount, 10);

        assertEq(wavax.balanceOf(address(almProxy)),                            0);
        assertEq(wavax.balanceOf(CORE_HUB),                                     startingHubBalanceWavax + amount);
        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey),  WAVAX_DEPOSIT_LIMIT - amount);
        assertEq(rateLimits.getCurrentRateLimit(wavaxWithdrawKey), type(uint256).max);

        // Withdraw all
        vm.prank(ALM_RELAYER);
        uint256 withdrawn = foreignController.withdrawAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, type(uint256).max);

        assertApproxEqAbs(withdrawn,                          amount, 10);
        assertEq(_suppliedAssets(WAVAX_RESERVE_ID),           0);
        assertApproxEqAbs(wavax.balanceOf(address(almProxy)), amount,                  10);
        assertApproxEqAbs(wavax.balanceOf(CORE_HUB),          startingHubBalanceWavax, 10);

        assertApproxEqAbs(rateLimits.getCurrentRateLimit(wavaxDepositKey),  WAVAX_DEPOSIT_LIMIT, 10);
        assertEq(rateLimits.getCurrentRateLimit(wavaxWithdrawKey),          type(uint256).max);
    }

}

contract AaveV4MainSpokeInflationAttackTests is AaveV4MainSpokeBaseTest {

    // Aave v3 lets an attacker inflate the share price by donating underlying to the aToken, whose
    // accounting derives from balanceOf. Aave v4's Hub tracks liquidity internally (asset.liquidity),
    // so a raw donation is inert. See AaveV4-REVIEW.md section 3 for the full analysis.
    function test_depositAaveV4_donationDoesNotInflateSharePrice() external {
        IAaveV4Hub hub     = IAaveV4Hub(CORE_HUB);
        uint256    assetId = IAaveV4Spoke(MAIN_SPOKE).getReserve(USDC_RESERVE_ID).assetId;

        uint256 liquidityBefore = hub.getAssetLiquidity(assetId);
        uint256 assetsBefore    = hub.getAddedAssets(assetId);
        uint256 sharesBefore    = hub.getAddedShares(assetId);

        // Share price starts at exactly 1:1.
        assertEq(assetsBefore, sharesBefore);

        // Donate underlying straight to the Hub (the v3 inflation vector).
        uint256 donation = 10_000_000e6;
        deal(address(usdcAvalanche), address(this), donation);
        usdcAvalanche.transfer(CORE_HUB, donation);

        // Raw balance grew, but the Hub's internal accounting is untouched: share price stays 1:1.
        assertEq(usdcAvalanche.balanceOf(CORE_HUB), startingHubBalanceUsdc + donation);
        assertEq(hub.getAssetLiquidity(assetId),    liquidityBefore);
        assertEq(hub.getAddedAssets(assetId),       assetsBefore);
        assertEq(hub.getAddedShares(assetId),       sharesBefore);

        // Honest deposit still receives ~1:1 and passes the slippage guard.
        deal(address(usdcAvalanche), address(almProxy), 1_000e6);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, 1_000e6);

        assertApproxEqAbs(_suppliedAssets(USDC_RESERVE_ID), 1_000e6, 1);

        // Shares minted 1:1 against the deposit; the donation conferred no benefit.
        assertEq(hub.getAddedShares(assetId), sharesBefore + 1_000e6);
    }

}

contract AaveV4MainSpokeMultiAssetScenarioTests is AaveV4MainSpokeBaseTest {

    // End-to-end flow across both reserves on the shared Main Spoke, interleaving successful and
    // failing deposits/withdrawals. Core invariant under test: rate limits are keyed per
    // (spoke, reserveId), so USDC and WAVAX capacity move fully independently, and a withdraw only
    // restores the deposit capacity of the asset withdrawn. Deposit limits are tightened to
    // cap-safe sizes so the controller rate limit (not Aave's supply cap) is the binding constraint.
    function test_aaveV4_multiAssetInterleavedScenario() external {
        uint256 usdcLimit  = 3_000_000e6;
        uint256 wavaxLimit = 300_000e18;

        vm.startPrank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(usdcDepositKey,  usdcLimit,  usdcLimit  / 1 days);
        rateLimits.setRateLimitData(wavaxDepositKey, wavaxLimit, wavaxLimit / 1 days);
        vm.stopPrank();

        deal(address(usdcAvalanche), address(almProxy), 5_000_000e6);
        deal(WAVAX,                  address(almProxy), 500_000e18);

        // Baseline: full deposit capacity, empty positions.
        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  usdcLimit);
        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), wavaxLimit);
        assertEq(_suppliedAssets(USDC_RESERVE_ID),  0);
        assertEq(_suppliedAssets(WAVAX_RESERVE_ID), 0);

        // Stage 1: USDC deposit consumes USDC capacity only; WAVAX untouched.
        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, 2_000_000e6);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  1_000_000e6);
        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), wavaxLimit);
        assertApproxEqAbs(_suppliedAssets(USDC_RESERVE_ID), 2_000_000e6, 1);

        // Stage 2: WAVAX deposit consumes WAVAX capacity only; USDC untouched.
        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, 200_000e18);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  1_000_000e6);
        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), 100_000e18);
        assertApproxEqAbs(_suppliedAssets(WAVAX_RESERVE_ID), 200_000e18, 10);

        // Stage 3: USDC deposit above its remaining limit reverts and mutates nothing on either asset.
        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, 1_000_000e6 + 1);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  1_000_000e6);
        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), 100_000e18);

        // Stage 4: WAVAX deposit up to its own remaining limit still succeeds and exhausts it.
        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, 100_000e18);

        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), 0);
        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  1_000_000e6);
        assertApproxEqAbs(_suppliedAssets(WAVAX_RESERVE_ID), 300_000e18, 10);

        // Stage 5: WAVAX is now blocked, yet USDC deposits still work: one exhausted asset does not
        // freeze the other.
        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, 1);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, 1_000_000e6);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  0);
        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), 0);
        assertApproxEqAbs(_suppliedAssets(USDC_RESERVE_ID), 3_000_000e6, 1);

        // Stage 6: withdrawing USDC restores USDC deposit capacity only; WAVAX stays exhausted.
        vm.prank(ALM_RELAYER);
        assertEq(foreignController.withdrawAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, 1_500_000e6), 1_500_000e6);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  1_500_000e6);
        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), 0);
        assertApproxEqAbs(_suppliedAssets(USDC_RESERVE_ID), 1_500_000e6, 1);

        // Stage 7: full WAVAX withdraw restores WAVAX deposit capacity only; USDC capacity unchanged.
        vm.prank(ALM_RELAYER);
        uint256 wavaxWithdrawn = foreignController.withdrawAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, type(uint256).max);
        assertApproxEqAbs(wavaxWithdrawn, 300_000e18, 10);

        assertApproxEqAbs(rateLimits.getCurrentRateLimit(wavaxDepositKey), 300_000e18, 10);
        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey), 1_500_000e6);
        assertEq(_suppliedAssets(WAVAX_RESERVE_ID), 0);

        // Final integrity: net USDC still supplied is custodied by the Hub; WAVAX fully unwound;
        // withdraw limits were never consumed by any of the above (still unlimited).
        assertApproxEqAbs(usdcAvalanche.balanceOf(CORE_HUB), startingHubBalanceUsdc + 1_500_000e6, 1);
        assertApproxEqAbs(wavax.balanceOf(CORE_HUB),         startingHubBalanceWavax,              10);
        assertEq(rateLimits.getCurrentRateLimit(usdcWithdrawKey),  type(uint256).max);
        assertEq(rateLimits.getCurrentRateLimit(wavaxWithdrawKey), type(uint256).max);
    }

}
