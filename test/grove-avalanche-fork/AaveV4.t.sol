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

    // Hub asset ids, folded into the deposit rate limit key alongside the Hub and underlying.
    uint16 constant USDC_ASSET_ID  = 2;
    uint16 constant WAVAX_ASSET_ID = 0;

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

        usdcDepositKey   = _depositKey(USDC_RESERVE_ID,  USDC_ASSET_ID,  address(usdcAvalanche));
        usdcWithdrawKey  = RateLimitHelpers.makeAddressUint256Key(foreignController.LIMIT_AAVE_V4_WITHDRAW(), MAIN_SPOKE, USDC_RESERVE_ID);
        wavaxDepositKey  = _depositKey(WAVAX_RESERVE_ID, WAVAX_ASSET_ID, WAVAX);
        wavaxWithdrawKey = RateLimitHelpers.makeAddressUint256Key(foreignController.LIMIT_AAVE_V4_WITHDRAW(), MAIN_SPOKE, WAVAX_RESERVE_ID);

        vm.startPrank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(usdcDepositKey,  USDC_DEPOSIT_LIMIT,  USDC_DEPOSIT_LIMIT  / 1 days);
        rateLimits.setRateLimitData(wavaxDepositKey, WAVAX_DEPOSIT_LIMIT, WAVAX_DEPOSIT_LIMIT / 1 days);
        rateLimits.setUnlimitedRateLimitData(usdcWithdrawKey);
        rateLimits.setUnlimitedRateLimitData(wavaxWithdrawKey);
        // Rounding slippage, set per market now that one spoke hosts many reserves.
        foreignController.setMaxAaveV4Slippage(MAIN_SPOKE, USDC_RESERVE_ID,  1e18 - 1e4);
        foreignController.setMaxAaveV4Slippage(MAIN_SPOKE, WAVAX_RESERVE_ID, 1e18 - 1e4);
        vm.stopPrank();

        startingHubBalanceUsdc  = usdcAvalanche.balanceOf(CORE_HUB);
        startingHubBalanceWavax = wavax.balanceOf(CORE_HUB);
    }

    function _suppliedAssets(uint256 reserveId) internal view returns (uint256) {
        return IAaveV4Spoke(MAIN_SPOKE).getUserSuppliedAssets(reserveId, address(almProxy));
    }

    // Simulates governance remapping a live reserveId onto a different Hub asset. No remap has
    // happened on-chain, so the real reserve is read back and re-encoded with a new assetId.
    function _remapUsdcReserveToAsset(uint16 assetId) internal {
        IAaveV4Spoke.Reserve memory reserve = IAaveV4Spoke(MAIN_SPOKE).getReserve(USDC_RESERVE_ID);

        reserve.assetId = assetId;

        vm.mockCall(
            MAIN_SPOKE,
            abi.encodeCall(IAaveV4Spoke.getReserve, (USDC_RESERVE_ID)),
            abi.encode(reserve)
        );
    }

    // Components are hardcoded rather than read from the spoke; the resulting key bytes are pinned
    // against literals in test_aaveV4_depositKeyDerivation, since this helper shares the production
    // key builder and so cannot detect a change to it on its own.
    function _depositKey(uint256 reserveId, uint16 assetId, address underlying)
        internal view returns (bytes32)
    {
        return RateLimitHelpers.makeAddressUint256AddressUint16AddressKey(
            foreignController.LIMIT_AAVE_V4_DEPOSIT(),
            MAIN_SPOKE,
            reserveId,
            CORE_HUB,
            assetId,
            underlying
        );
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
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, 1_000e6);
    }

    // Reserve 1 (BTC.b) has a slippage tolerance but no deposit limit configured.
    function test_depositAaveV4_zeroMaxAmount() external {
        vm.prank(GROVE_EXECUTOR);
        foreignController.setMaxAaveV4Slippage(MAIN_SPOKE, 1, 1e18 - 1e4);

        uint16 assetId = IAaveV4Spoke(MAIN_SPOKE).getReserve(1).assetId;

        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.depositAaveV4(MAIN_SPOKE, 1, CORE_HUB, assetId, 1e6);
    }

    // The deposit key binds the reserve's Hub and asset id, so a budget configured against any
    // other Hub asset is unreachable even for the right (spoke, reserveId).
    function test_depositAaveV4_depositKeyBindsHubAndAsset() external {
        bytes32 wrongHubKey = RateLimitHelpers.makeAddressUint256AddressUint16AddressKey(
            foreignController.LIMIT_AAVE_V4_DEPOSIT(),
            MAIN_SPOKE,
            USDC_RESERVE_ID,
            makeAddr("otherHub"),
            USDC_ASSET_ID,
            address(usdcAvalanche)
        );
        bytes32 wrongAssetIdKey = _depositKey(USDC_RESERVE_ID, USDC_ASSET_ID + 1, address(usdcAvalanche));

        vm.startPrank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(usdcDepositKey, 0, 0);
        rateLimits.setUnlimitedRateLimitData(wrongHubKey);
        rateLimits.setUnlimitedRateLimitData(wrongAssetIdKey);
        vm.stopPrank();

        deal(address(usdcAvalanche), address(almProxy), 1_000e6);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, 1_000e6);
    }

    function test_depositAaveV4_zeroMaxSlippage() external {
        vm.prank(GROVE_EXECUTOR);
        foreignController.setMaxAaveV4Slippage(MAIN_SPOKE, USDC_RESERVE_ID, 0);

        deal(address(usdcAvalanche), address(almProxy), 1_000e6);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("AaveV4Lib/max-slippage-not-set");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, 1_000e6);
    }

    // The relayer declares (hub, assetId) so the controller can resolve the bad debt tolerance
    // before the reserve is read. A declaration the Spoke does not confirm is rejected outright.
    function test_depositAaveV4_wrongHub() external {
        deal(address(usdcAvalanche), address(almProxy), 1_000e6);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("AaveV4Lib/invalid-hub-asset");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, makeAddr("otherHub"), USDC_ASSET_ID, 1_000e6);
    }

    function test_depositAaveV4_usdcSlippageBoundary() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);

        // Strictest tolerance (1e18) still admits the exact 1:1 USDC deposit.
        vm.prank(GROVE_EXECUTOR);
        foreignController.setMaxAaveV4Slippage(MAIN_SPOKE, USDC_RESERVE_ID, 1e18);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

        assertApproxEqAbs(_suppliedAssets(USDC_RESERVE_ID), USDC_DEPOSIT_AMOUNT, 1);
    }

    // Mirror image of the USDC boundary: WAVAX's share price is above 1:1, so the credited position
    // rounds just below the supplied amount and the strictest tolerance (1e18) trips the guard.
    // Per-market tolerances mean tightening WAVAX cannot loosen or break USDC, asserted below.
    function test_depositAaveV4_wavaxSlippageBoundary() external {
        deal(WAVAX,                  address(almProxy), WAVAX_DEPOSIT_AMOUNT);
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);

        vm.prank(GROVE_EXECUTOR);
        foreignController.setMaxAaveV4Slippage(MAIN_SPOKE, WAVAX_RESERVE_ID, 1e18);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("AaveV4Lib/slippage-too-high");
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, CORE_HUB, WAVAX_ASSET_ID, WAVAX_DEPOSIT_AMOUNT);

        // USDC keeps its own tolerance and still deposits.
        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

        assertApproxEqAbs(_suppliedAssets(USDC_RESERVE_ID), USDC_DEPOSIT_AMOUNT, 1);
    }

    // The deposit limit ($50M) far exceeds Aave's supply cap, so only the over-limit revert is
    // asserted (the rate-limit check runs before the Aave supply call); a cap-safe deposit then
    // confirms the limit admits a legitimate large deposit and decrements as expected.
    function test_depositAaveV4_usdcRateLimitedBoundary() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_LIMIT + 1);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_LIMIT + 1);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey), USDC_DEPOSIT_LIMIT - USDC_DEPOSIT_AMOUNT);
    }

    function test_depositAaveV4_wavaxRateLimitedBoundary() external {
        deal(WAVAX, address(almProxy), WAVAX_DEPOSIT_LIMIT + 1);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, CORE_HUB, WAVAX_ASSET_ID, WAVAX_DEPOSIT_LIMIT + 1);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, CORE_HUB, WAVAX_ASSET_ID, WAVAX_DEPOSIT_AMOUNT);

        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), WAVAX_DEPOSIT_LIMIT - WAVAX_DEPOSIT_AMOUNT);
    }

}

contract AaveV4MainSpokeDepositDeficitGuardTests is AaveV4MainSpokeBaseTest {

    // getAssetDeficitRay is denominated in the asset's own units scaled by RAY, so $1,000 of USDC
    // (6 decimals) is 1_000e6 * 1e27. Every reserve on the Core Hub reads zero at the fork block.
    uint256 constant USDC_DEFICIT_TOLERANCE = 1_000e6 * 1e27;

    function _setUsdcDeficitTolerance(uint256 maxDeficit) internal {
        vm.prank(GROVE_EXECUTOR);
        foreignController.setMaxAaveV4Deficit(CORE_HUB, USDC_ASSET_ID, maxDeficit);
    }

    function _mockDeficit(uint16 assetId, uint256 deficitRay) internal {
        vm.mockCall(
            CORE_HUB,
            abi.encodeWithSignature("getAssetDeficitRay(uint256)", uint256(assetId)),
            abi.encode(deficitRay)
        );
    }

    // The tolerance defaults to zero, so any deficit blocks the deposit until governance opts in.
    function test_depositAaveV4_deficitAboveDefaultTolerance() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);
        _mockDeficit(USDC_ASSET_ID, 1);

        assertEq(foreignController.maxAaveV4Deficits(CORE_HUB, USDC_ASSET_ID), 0);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("AaveV4Lib/deficit-too-high");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);
    }

    // A reserve carrying no deficit deposits normally.
    function test_depositAaveV4_noDeficit() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);
        _mockDeficit(USDC_ASSET_ID, 0);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

        assertApproxEqAbs(_suppliedAssets(USDC_RESERVE_ID), USDC_DEPOSIT_AMOUNT, 1);
    }

    function test_depositAaveV4_deficitToleranceBoundary() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT * 2);

        _setUsdcDeficitTolerance(USDC_DEFICIT_TOLERANCE);

        // One RAY-wei above the tolerance blocks the deposit.
        _mockDeficit(USDC_ASSET_ID, USDC_DEFICIT_TOLERANCE + 1);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("AaveV4Lib/deficit-too-high");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

        // Exactly at the tolerance is admitted.
        _mockDeficit(USDC_ASSET_ID, USDC_DEFICIT_TOLERANCE);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

        assertApproxEqAbs(_suppliedAssets(USDC_RESERVE_ID), USDC_DEPOSIT_AMOUNT, 1);
    }

    // The tolerance is scoped to one Hub asset, so raising it for USDC leaves every other asset at
    // zero, whichever spoke or reserve fronts it.
    function test_depositAaveV4_deficitToleranceIsPerHubAsset() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);
        deal(WAVAX,                  address(almProxy), WAVAX_DEPOSIT_AMOUNT);

        _setUsdcDeficitTolerance(USDC_DEFICIT_TOLERANCE);

        _mockDeficit(USDC_ASSET_ID,  USDC_DEFICIT_TOLERANCE);
        _mockDeficit(WAVAX_ASSET_ID, 1);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("AaveV4Lib/deficit-too-high");
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, CORE_HUB, WAVAX_ASSET_ID, WAVAX_DEPOSIT_AMOUNT);
    }

    // The tolerance follows the Hub asset the reserve points at, not the market used to reach it.
    // Remapping the USDC reserve onto the WAVAX asset forces the relayer to declare WAVAX, so the
    // deposit reads WAVAX's tolerance and USDC's own stops applying however permissive it is.
    function test_depositAaveV4_deficitToleranceFollowsHubAsset() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);

        _mockDeficit(WAVAX_ASSET_ID, USDC_DEFICIT_TOLERANCE);
        _remapUsdcReserveToAsset(WAVAX_ASSET_ID);
        _setUsdcDeficitTolerance(type(uint256).max);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("AaveV4Lib/deficit-too-high");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, WAVAX_ASSET_ID, USDC_DEPOSIT_AMOUNT);

        // Configuring the asset the reserve now points at clears the guard, leaving the deposit to
        // fail on the remapped (and so unconfigured) rate limit key instead.
        vm.prank(GROVE_EXECUTOR);
        foreignController.setMaxAaveV4Deficit(CORE_HUB, WAVAX_ASSET_ID, USDC_DEFICIT_TOLERANCE);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, WAVAX_ASSET_ID, USDC_DEPOSIT_AMOUNT);
    }

    // The declaration cannot be aimed at a more tolerant asset to sneak a deposit through: it is
    // checked against the Spoke, so the reserve's own asset is the only tolerance that can apply.
    function test_depositAaveV4_declaredAssetCannotBorrowTolerance() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);

        _mockDeficit(USDC_ASSET_ID, USDC_DEFICIT_TOLERANCE);

        vm.prank(GROVE_EXECUTOR);
        foreignController.setMaxAaveV4Deficit(CORE_HUB, WAVAX_ASSET_ID, type(uint256).max);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("AaveV4Lib/invalid-hub-asset");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, WAVAX_ASSET_ID, USDC_DEPOSIT_AMOUNT);

        // Declaring honestly leaves USDC's own (zero) tolerance in force.
        vm.prank(ALM_RELAYER);
        vm.expectRevert("AaveV4Lib/deficit-too-high");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);
    }

    // Exiting an impaired pool is never gated: only deposits read the deficit.
    function test_withdrawAaveV4_unaffectedByDeficit() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

        _mockDeficit(USDC_ASSET_ID, USDC_DEFICIT_TOLERANCE);

        vm.prank(ALM_RELAYER);
        uint256 withdrawn = foreignController.withdrawAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, type(uint256).max);

        assertApproxEqAbs(withdrawn, USDC_DEPOSIT_AMOUNT, 1);
        assertEq(_suppliedAssets(USDC_RESERVE_ID), 0);

        // The restore is keyed on the same deposit key, so capacity comes back despite the deficit.
        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey), USDC_DEPOSIT_LIMIT);
    }

}

contract AaveV4MainSpokeDepositSuccessTests is AaveV4MainSpokeBaseTest {

    // Guards the IAaveV4Spoke.Reserve layout assumed by the partial interface.
    function test_aaveV4_reserveLayout() external view {
        IAaveV4Spoke.Reserve memory usdcReserve = IAaveV4Spoke(MAIN_SPOKE).getReserve(USDC_RESERVE_ID);

        assertEq(usdcReserve.underlying, address(usdcAvalanche));
        assertEq(usdcReserve.hub,        CORE_HUB);
        assertEq(usdcReserve.assetId,    USDC_ASSET_ID);
        assertEq(usdcReserve.decimals,   6);

        IAaveV4Spoke.Reserve memory wavaxReserve = IAaveV4Spoke(MAIN_SPOKE).getReserve(WAVAX_RESERVE_ID);

        assertEq(wavaxReserve.underlying, WAVAX);
        assertEq(wavaxReserve.hub,        CORE_HUB);
        assertEq(wavaxReserve.assetId,    WAVAX_ASSET_ID);
        assertEq(wavaxReserve.decimals,   18);
    }

    // Literals computed outside Solidity as
    // keccak256(abi.encode(keccak256("LIMIT_AAVE_V4_DEPOSIT"), spoke, reserveId, hub, assetId, underlying)).
    // Pinning the bytes means a change to the key's components, their order or their types fails
    // here, rather than silently re-pointing every configured market at an unfunded key.
    function test_aaveV4_depositKeyDerivation() external view {
        assertEq(usdcDepositKey,  0xdd0ecb82a84c89ed5146cfd9c39e4ce7355790e3f317e639a28b8db8d7b52489);
        assertEq(wavaxDepositKey, 0x324d1fe3d06c4ac7e9e27b2923e8b5e4a8aab8e1e72a114e8f87250d58f5ce7a);

        // The withdraw key deliberately omits the reserve's Hub data.
        assertEq(
            usdcWithdrawKey,
            keccak256(abi.encode(foreignController.LIMIT_AAVE_V4_WITHDRAW(), MAIN_SPOKE, USDC_RESERVE_ID))
        );
    }

    function test_depositAaveV4_usdc() public {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);

        assertEq(usdcAvalanche.allowance(address(almProxy), MAIN_SPOKE), 0);
        assertEq(_suppliedAssets(USDC_RESERVE_ID),                       0);
        assertEq(usdcAvalanche.balanceOf(address(almProxy)),            USDC_DEPOSIT_AMOUNT);
        assertEq(usdcAvalanche.balanceOf(CORE_HUB),                     startingHubBalanceUsdc);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey), USDC_DEPOSIT_LIMIT);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

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
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, CORE_HUB, WAVAX_ASSET_ID, amount);

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
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, 1_000e6);

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
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

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
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, CORE_HUB, WAVAX_ASSET_ID, WAVAX_DEPOSIT_AMOUNT);

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
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

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
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

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

    // A withdraw restores deposit capacity only up to the configured maxAmount: after the deposit
    // limit is tightened below the withdrawn amount, the restore clamps at the new cap instead of
    // minting excess capacity.
    function test_withdrawAaveV4_usdc_depositRestoreCappedAtMaxAmount() public {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);
        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

        // Tighten the deposit limit below the withdrawn amount, with no remaining capacity.
        uint256 tightenedLimit = 1_000_000e6;
        vm.prank(GROVE_EXECUTOR);
        rateLimits.setRateLimitData(usdcDepositKey, tightenedLimit, 0, 0, block.timestamp);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey), 0);

        // Withdraw ~4M; the restore credits only up to the 1M cap.
        vm.prank(ALM_RELAYER);
        foreignController.withdrawAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, type(uint256).max);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey), tightenedLimit);
    }

    function test_withdrawAaveV4_wavax() public {
        uint256 amount = WAVAX_DEPOSIT_AMOUNT;

        deal(WAVAX, address(almProxy), amount);
        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, CORE_HUB, WAVAX_ASSET_ID, amount);

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

// The deposit key binds (hub, assetId, underlying), so remapping a live reserve onto a different
// Hub asset moves it to a fresh, unconfigured key. The withdraw key binds only (spoke, reserveId),
// which is what keeps the exit reachable. Simulated with vm.mockCall on getReserve, since no
// remapping has happened on-chain.
contract AaveV4MainSpokeReserveRemapTests is AaveV4MainSpokeBaseTest {

    // A different asset that exists on the Core Hub, so the deficit read still resolves.
    uint16 constant REMAPPED_ASSET_ID = 3;

    // A relayer still declaring the pre-remap asset is turned away before anything else is read.
    function test_depositAaveV4_remappedReserveRejectsStaleDeclaration() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);

        _remapUsdcReserveToAsset(REMAPPED_ASSET_ID);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("AaveV4Lib/invalid-hub-asset");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);
    }

    // Declaring the new asset gets past the check, but lands on a fresh, unconfigured deposit key.
    function test_depositAaveV4_remappedReserveHasNoBudget() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);

        _remapUsdcReserveToAsset(REMAPPED_ASSET_ID);

        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, REMAPPED_ASSET_ID, USDC_DEPOSIT_AMOUNT);
    }

    function test_withdrawAaveV4_remappedReserveSkipsRestore() external {
        deal(address(usdcAvalanche), address(almProxy), USDC_DEPOSIT_AMOUNT);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, USDC_DEPOSIT_AMOUNT);

        uint256 remainingBeforeRemap = rateLimits.getCurrentRateLimit(usdcDepositKey);

        assertEq(remainingBeforeRemap, USDC_DEPOSIT_LIMIT - USDC_DEPOSIT_AMOUNT);

        _remapUsdcReserveToAsset(REMAPPED_ASSET_ID);

        vm.prank(ALM_RELAYER);
        uint256 withdrawn = foreignController.withdrawAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, type(uint256).max);

        // The exit succeeds and the funds come back...
        assertApproxEqAbs(withdrawn,                          USDC_DEPOSIT_AMOUNT, 1);
        assertApproxEqAbs(usdcAvalanche.balanceOf(address(almProxy)), USDC_DEPOSIT_AMOUNT, 1);
        assertEq(_suppliedAssets(USDC_RESERVE_ID), 0);

        // ...but the restore targets the new, unconfigured key, so the original market's consumed
        // capacity is not returned. Failing this way keeps funds recoverable, which is the point.
        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey), remainingBeforeRemap);
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
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, 2_000_000e6);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  1_000_000e6);
        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), wavaxLimit);
        assertApproxEqAbs(_suppliedAssets(USDC_RESERVE_ID), 2_000_000e6, 1);

        // Stage 2: WAVAX deposit consumes WAVAX capacity only; USDC untouched.
        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, CORE_HUB, WAVAX_ASSET_ID, 200_000e18);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  1_000_000e6);
        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), 100_000e18);
        assertApproxEqAbs(_suppliedAssets(WAVAX_RESERVE_ID), 200_000e18, 10);

        // Stage 3: USDC deposit above its remaining limit reverts and mutates nothing on either asset.
        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, 1_000_000e6 + 1);

        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  1_000_000e6);
        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), 100_000e18);

        // Stage 4: WAVAX deposit up to its own remaining limit still succeeds and exhausts it.
        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, CORE_HUB, WAVAX_ASSET_ID, 100_000e18);

        assertEq(rateLimits.getCurrentRateLimit(wavaxDepositKey), 0);
        assertEq(rateLimits.getCurrentRateLimit(usdcDepositKey),  1_000_000e6);
        assertApproxEqAbs(_suppliedAssets(WAVAX_RESERVE_ID), 300_000e18, 10);

        // Stage 5: WAVAX is now blocked, yet USDC deposits still work: one exhausted asset does not
        // freeze the other.
        vm.prank(ALM_RELAYER);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.depositAaveV4(MAIN_SPOKE, WAVAX_RESERVE_ID, CORE_HUB, WAVAX_ASSET_ID, 1);

        vm.prank(ALM_RELAYER);
        foreignController.depositAaveV4(MAIN_SPOKE, USDC_RESERVE_ID, CORE_HUB, USDC_ASSET_ID, 1_000_000e6);

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
