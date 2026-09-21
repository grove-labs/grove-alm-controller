// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { IERC4626 } from "forge-std/interfaces/IERC4626.sol";

import "./ForkTestBase.t.sol";

import { ICurvePoolLike } from "../../src/libraries/CurveLib.sol";

contract CurveTestBase is ForkTestBase {

    address constant CURVE_POOL = 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85;

    IERC20 curveLp = IERC20(CURVE_POOL);

    ICurvePoolLike curvePool = ICurvePoolLike(CURVE_POOL);

    bytes32 curveDepositKey;
    bytes32 curveWithdrawKey;

    bytes32 curveUsdcSwapKey;
    bytes32 curveUsdtSwapKey;
    bytes32 curveUsdcDepositKey;
    bytes32 curveUsdtDepositKey;
    bytes32 curveUsdcWithdrawKey;
    bytes32 curveUsdtWithdrawKey;

    bytes32 curveLegacySwapKey;

    function setUp() public virtual override  {
        super.setUp();

        curveDepositKey  = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_CURVE_DEPOSIT(),  CURVE_POOL);
        curveWithdrawKey = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_CURVE_WITHDRAW(), CURVE_POOL);

        curveUsdcSwapKey     = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_SWAP(),     address(usdc), CURVE_POOL);
        curveUsdtSwapKey     = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_SWAP(),     address(usdt), CURVE_POOL);
        curveUsdcDepositKey  = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_DEPOSIT(),  address(usdc), CURVE_POOL);
        curveUsdtDepositKey  = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_DEPOSIT(),  address(usdt), CURVE_POOL);
        curveUsdcWithdrawKey = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_WITHDRAW(), address(usdc), CURVE_POOL);
        curveUsdtWithdrawKey = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_WITHDRAW(), address(usdt), CURVE_POOL);

        curveLegacySwapKey = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_CURVE_SWAP(), CURVE_POOL);

        // Skewed pool: a balanced 1m/1m deposit is worth slightly more than 2m pro-rata, hence the headroom.
        vm.startPrank(GROVE_PROXY);
        rateLimits.setRateLimitData(curveDepositKey,  2_100_000e18, uint256(2_100_000e18) / 1 days);
        rateLimits.setRateLimitData(curveWithdrawKey, 3_000_000e18, uint256(3_000_000e18) / 1 days);

        rateLimits.setRateLimitData(curveUsdcSwapKey,     1_000_000e6, uint256(1_000_000e6) / 1 days);
        rateLimits.setRateLimitData(curveUsdtSwapKey,     1_000_000e6, uint256(1_000_000e6) / 1 days);
        rateLimits.setRateLimitData(curveUsdcDepositKey,  2_000_000e6, uint256(2_000_000e6) / 1 days);
        rateLimits.setRateLimitData(curveUsdtDepositKey,  2_000_000e6, uint256(2_000_000e6) / 1 days);
        rateLimits.setRateLimitData(curveUsdcWithdrawKey, 3_000_000e6, uint256(3_000_000e6) / 1 days);
        rateLimits.setRateLimitData(curveUsdtWithdrawKey, 3_000_000e6, uint256(3_000_000e6) / 1 days);
        vm.stopPrank();

        // Set a higher slippage to allow for successes
        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(CURVE_POOL, 0.98e18);
    }

    function _setUnlimitedCurveRateLimits() internal {
        vm.startPrank(GROVE_PROXY);
        rateLimits.setUnlimitedRateLimitData(curveDepositKey);
        rateLimits.setUnlimitedRateLimitData(curveWithdrawKey);
        rateLimits.setUnlimitedRateLimitData(curveUsdcSwapKey);
        rateLimits.setUnlimitedRateLimitData(curveUsdtSwapKey);
        rateLimits.setUnlimitedRateLimitData(curveUsdcDepositKey);
        rateLimits.setUnlimitedRateLimitData(curveUsdtDepositKey);
        rateLimits.setUnlimitedRateLimitData(curveUsdcWithdrawKey);
        rateLimits.setUnlimitedRateLimitData(curveUsdtWithdrawKey);
        vm.stopPrank();
    }

    function _proRataBalances(uint256 lpTokens) internal view returns (uint256[] memory amounts) {
        uint256 totalSupply = curveLp.totalSupply();
        amounts = new uint256[](2);
        for (uint256 i = 0; i < 2; i++) {
            amounts[i] = curvePool.balances(i) * lpTokens / totalSupply;
        }
    }

    function _toValue(uint256[] memory amounts) internal view returns (uint256 value) {
        uint256[] memory rates = curvePool.stored_rates();
        for (uint256 i = 0; i < amounts.length; i++) {
            value += amounts[i] * rates[i];
        }
        value /= 1e18;
    }

    function _swappedIn(uint256 input, uint256 deposited) internal pure returns (uint256) {
        return input > deposited ? input - deposited : 0;
    }

    function _addLiquidity(uint256 usdcAmount, uint256 usdtAmount)
        internal returns (uint256 lpTokensReceived)
    {
        deal(address(usdc), address(almProxy), usdcAmount);
        deal(address(usdt), address(almProxy), usdtAmount);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = usdtAmount;

        uint256 minLpAmount = (usdcAmount + usdtAmount) * 1e12 * 98/100;

        vm.prank(relayer);
        return mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);
    }

    function _addLiquidity() internal returns (uint256 lpTokensReceived) {
        return _addLiquidity(1_000_000e6, 1_000_000e6);
    }

    function _getBlock() internal pure override returns (uint256) {
        return 22225000;  // April 8, 2025
    }

}

contract MainnetControllerAddLiquidityCurveFailureTests is CurveTestBase {

    function test_addLiquidityCurve_notRelayer() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_000_000e6;
        amounts[1] = 1_000_000e6;

        uint256 minLpAmount = 1_950_000e18;

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);
    }

    function test_addLiquidityCurve_slippageNotSet() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_000_000e6;
        amounts[1] = 1_000_000e6;

        uint256 minLpAmount = 1_950_000e18;

        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(CURVE_POOL, 0);

        vm.prank(relayer);
        vm.expectRevert("CurveLib/max-slippage-not-set");
        mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);
    }

    function test_addLiquidityCurve_invalidDepositAmountsLength() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1_000_000e6;
        amounts[1] = 1_000_000e6;
        amounts[2] = 1_000_000e6;

        uint256 minLpAmount = 0;

        vm.startPrank(relayer);

        vm.expectRevert("CurveLib/invalid-deposit-amounts");
        mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);

        uint256[] memory amounts2 = new uint256[](1);
        amounts[0] = 1_000_000e6;

        vm.expectRevert("CurveLib/invalid-deposit-amounts");
        mainnetController.addLiquidityCurve(CURVE_POOL, amounts2, minLpAmount);
    }

    function test_addLiquidityCurve_underAllowableSlippageBoundary() public {
        deal(address(usdc), address(almProxy), 1_000_000e6);
        deal(address(usdt), address(almProxy), 1_000_000e6);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_000_000e6;
        amounts[1] = 1_000_000e6;

        uint256 boundaryAmount = 2_000_000e18 * 0.98e18 / curvePool.get_virtual_price();

        assertApproxEqAbs(boundaryAmount, 1_950_000e18, 50_000e18);  // Sanity check on precision

        uint256 minLpAmount = boundaryAmount - 1;

        vm.startPrank(relayer);
        vm.expectRevert("CurveLib/min-amount-not-met");
        mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);

        minLpAmount = boundaryAmount;

        mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);
    }

    function _defaultAddLiquidityParams() internal pure returns (uint256[] memory amounts, uint256 minLpAmount) {
        amounts = new uint256[](2);
        amounts[0] = 1_000_000e6;
        amounts[1] = 1_000_000e6;

        minLpAmount = 1_950_000e18;
    }

    function _assertAddLiquidityZeroMaxAmount(bytes32 key) internal {
        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(key, 0, 0);

        (uint256[] memory amounts, uint256 minLpAmount) = _defaultAddLiquidityParams();

        deal(address(usdc), address(almProxy), amounts[0]);
        deal(address(usdt), address(almProxy), amounts[1]);

        vm.prank(relayer);
        vm.expectRevert("RateLimits/zero-maxAmount");
        mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);
    }

    function test_addLiquidityCurve_zeroMaxAmount() public {
        _assertAddLiquidityZeroMaxAmount(curveDepositKey);
    }

    function test_addLiquidityCurve_zeroMaxAmount_asset0Deposit() public {
        _assertAddLiquidityZeroMaxAmount(curveUsdcDepositKey);
    }

    function test_addLiquidityCurve_zeroMaxAmount_asset1Deposit() public {
        _assertAddLiquidityZeroMaxAmount(curveUsdtDepositKey);
    }

    // Swap limits are charged even when nothing was swapped in, so both keys must be configured
    function test_addLiquidityCurve_zeroMaxAmount_asset0Swap() public {
        _assertAddLiquidityZeroMaxAmount(curveUsdcSwapKey);
    }

    function test_addLiquidityCurve_zeroMaxAmount_asset1Swap() public {
        _assertAddLiquidityZeroMaxAmount(curveUsdtSwapKey);
    }

    function test_addLiquidityCurve_legacySwapKeyNotHonoured() public {
        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(curveLegacySwapKey, 0, 0);

        (uint256[] memory amounts, uint256 minLpAmount) = _defaultAddLiquidityParams();

        deal(address(usdc), address(almProxy), amounts[0]);
        deal(address(usdt), address(almProxy), amounts[1]);

        vm.prank(relayer);
        mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);
    }

    function _assertAddLiquidityRateLimitBoundary(bytes32 key, uint256[] memory amounts, uint256 minLpAmount) internal {
        deal(address(usdc), address(almProxy), amounts[0]);
        deal(address(usdt), address(almProxy), amounts[1]);

        uint256 id = vm.snapshotState();

        uint256 limitBefore = rateLimits.getCurrentRateLimit(key);

        vm.prank(relayer);
        mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);

        uint256 charged = limitBefore - rateLimits.getCurrentRateLimit(key);

        assertGt(charged, 0, "nothing charged");

        vm.revertToState(id);

        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(key, charged - 1, 0);

        vm.prank(relayer);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);

        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(key, charged, 0);

        vm.prank(relayer);
        mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);

        assertEq(rateLimits.getCurrentRateLimit(key), 0);
    }

    function _assertAddLiquidityRateLimitBoundary(bytes32 key) internal {
        (uint256[] memory amounts, uint256 minLpAmount) = _defaultAddLiquidityParams();
        _assertAddLiquidityRateLimitBoundary(key, amounts, minLpAmount);
    }

    function test_addLiquidityCurve_rateLimitBoundary_aggregateDeposit() public {
        _assertAddLiquidityRateLimitBoundary(curveDepositKey);
    }

    function test_addLiquidityCurve_rateLimitBoundary_asset0Deposit() public {
        _assertAddLiquidityRateLimitBoundary(curveUsdcDepositKey);
    }

    function test_addLiquidityCurve_rateLimitBoundary_asset1Deposit() public {
        _assertAddLiquidityRateLimitBoundary(curveUsdtDepositKey);
    }

    function test_addLiquidityCurve_rateLimitBoundary_asset0Swap() public {
        _assertAddLiquidityRateLimitBoundary(curveUsdcSwapKey);
    }

    function test_addLiquidityCurve_rateLimitBoundary_asset1Swap() public {
        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(CURVE_POOL, 0.7e18);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 1_000_000e6;

        _assertAddLiquidityRateLimitBoundary(curveUsdtSwapKey, amounts, 800_000e18);
    }

}

contract MainnetControllerAddLiquiditySuccessTests is CurveTestBase {

    function test_addLiquidityCurve() public {
        deal(address(usdc), address(almProxy), 1_000_000e6);
        deal(address(usdt), address(almProxy), 1_000_000e6);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_000_000e6;
        amounts[1] = 1_000_000e6;

        uint256 minLpAmount = 1_950_000e18;

        uint256 startingUsdtBalance = usdt.balanceOf(CURVE_POOL);
        uint256 startingUsdcBalance = usdc.balanceOf(CURVE_POOL);
        uint256 startingTotalSupply = curveLp.totalSupply();

        assertEq(usdc.allowance(address(almProxy), CURVE_POOL), 0);
        assertEq(usdt.allowance(address(almProxy), CURVE_POOL), 0);

        assertEq(usdc.balanceOf(address(almProxy)), 1_000_000e6);
        assertEq(usdc.balanceOf(CURVE_POOL),        startingUsdcBalance);

        assertEq(usdt.balanceOf(address(almProxy)), 1_000_000e6);
        assertEq(usdt.balanceOf(CURVE_POOL),        startingUsdtBalance);

        assertEq(curveLp.balanceOf(address(almProxy)), 0);
        assertEq(curveLp.totalSupply(),                startingTotalSupply);

        assertEq(rateLimits.getCurrentRateLimit(curveDepositKey),     2_100_000e18);
        assertEq(rateLimits.getCurrentRateLimit(curveUsdcDepositKey), 2_000_000e6);
        assertEq(rateLimits.getCurrentRateLimit(curveUsdtDepositKey), 2_000_000e6);
        assertEq(rateLimits.getCurrentRateLimit(curveUsdcSwapKey),    1_000_000e6);
        assertEq(rateLimits.getCurrentRateLimit(curveUsdtSwapKey),    1_000_000e6);

        vm.prank(relayer);
        uint256 lpTokensReceived = mainnetController.addLiquidityCurve(
            CURVE_POOL,
            amounts,
            minLpAmount
        );

        assertEq(lpTokensReceived, 1_987_199.361495730708108741e18);

        assertEq(usdc.allowance(address(almProxy), CURVE_POOL), 0);
        assertEq(usdt.allowance(address(almProxy), CURVE_POOL), 0);

        assertEq(usdc.balanceOf(address(almProxy)), 0);
        assertEq(usdc.balanceOf(CURVE_POOL),        startingUsdcBalance + 1_000_000e6);

        assertEq(usdt.balanceOf(address(almProxy)), 0);
        assertEq(usdt.balanceOf(CURVE_POOL),        startingUsdtBalance + 1_000_000e6);

        assertEq(curveLp.balanceOf(address(almProxy)), lpTokensReceived);
        assertEq(curveLp.totalSupply(),                startingTotalSupply + lpTokensReceived);

        uint256[] memory deposited = _proRataBalances(lpTokensReceived);

        // NOTE: A large swap happened because of the balances in the pool being skewed towards USDT.
        assertEq(deposited[0], 465_059.586753e6);
        assertEq(deposited[1], 1_535_013.847298e6);

        assertEq(_toValue(deposited), 2_000_073.434051e18);

        assertEq(rateLimits.getCurrentRateLimit(curveDepositKey),     2_100_000e18 - _toValue(deposited));
        assertEq(rateLimits.getCurrentRateLimit(curveUsdcDepositKey), 2_000_000e6  - deposited[0]);
        assertEq(rateLimits.getCurrentRateLimit(curveUsdtDepositKey), 2_000_000e6  - deposited[1]);
        assertEq(rateLimits.getCurrentRateLimit(curveUsdcSwapKey),    1_000_000e6  - (1_000_000e6 - deposited[0]));
        assertEq(rateLimits.getCurrentRateLimit(curveUsdtSwapKey),    1_000_000e6);  // USDT share exceeds input, nothing swapped in

        assertEq(rateLimits.getCurrentRateLimit(curveUsdcSwapKey), 465_059.586753e6);
    }

    function test_addLiquidityCurve_swapRateLimit() public {
        // Set a higher slippage to allow for successes
        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(CURVE_POOL, 0.7e18);

        deal(address(usdc), address(almProxy), 1_000_000e6);

        // Step 1: Add liquidity, check how much the rate limits were reduced

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_000_000e6;
        amounts[1] = 0;

        uint256 minLpAmount = 800_000e18;

        uint256 startingUsdcSwapLimit = rateLimits.getCurrentRateLimit(curveUsdcSwapKey);
        uint256 startingUsdtSwapLimit = rateLimits.getCurrentRateLimit(curveUsdtSwapKey);

        vm.startPrank(relayer);

        uint256 lpTokens = mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);

        uint256 derivedUsdcSwapped = startingUsdcSwapLimit - rateLimits.getCurrentRateLimit(curveUsdcSwapKey);
        uint256 derivedUsdtSwapped = startingUsdtSwapLimit - rateLimits.getCurrentRateLimit(curveUsdtSwapKey);

        // Step 2: Withdraw full balance of LP tokens, withdrawing proportional amounts from the pool

        // NOTE: These values are skewed because pool balance is skewed.
        uint256[] memory minWithdrawnAmounts = new uint256[](2);
        minWithdrawnAmounts[0] = 260_000e6;
        minWithdrawnAmounts[1] = 730_000e6;

        uint256[] memory withdrawnAmounts = mainnetController.removeLiquidityCurve(CURVE_POOL, lpTokens, minWithdrawnAmounts);

        // Step 3: The USDC put in on top of the pro-rata USDC share was swapped into USDT

        assertEq(withdrawnAmounts[0], 265_480.996766e6);
        assertEq(withdrawnAmounts[1], 734_605.036920e6);

        // Difference is accurate to within 1 unit of USDC (pro-rata rounding)
        assertApproxEqAbs(derivedUsdcSwapped, 1_000_000e6 - withdrawnAmounts[0], 1);

        assertEq(derivedUsdcSwapped, 734_519.003234e6);
        assertEq(derivedUsdtSwapped, 0);
    }

    function testFuzz_addLiquidityCurve_swapRateLimit(uint256 usdcAmount, uint256 usdtAmount) public {
        // Set slippage to be zero and unlimited rate limits for purposes of this test
        // Not using actual unlimited rate limit because need to get swap amount to be reduced.
        _setUnlimitedCurveRateLimits();
        vm.startPrank(GROVE_PROXY);
        mainnetController.setMaxSlippage(CURVE_POOL, 1);  // 1e-16%
        rateLimits.setRateLimitData(curveUsdcSwapKey, type(uint256).max - 1, type(uint256).max - 1);
        rateLimits.setRateLimitData(curveUsdtSwapKey, type(uint256).max - 1, type(uint256).max - 1);
        vm.stopPrank();

        usdcAmount = _bound(usdcAmount, 1_000_000e6, 10_000_000_000e6);
        usdtAmount = _bound(usdtAmount, 1_000_000e6, 10_000_000_000e6);

        deal(address(usdc), address(almProxy), usdcAmount);
        deal(address(usdt), address(almProxy), usdtAmount);

        // Step 1: Add liquidity with fuzzed inputs, check how much the rate limits were reduced

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = usdtAmount;

        uint256 startingUsdcSwapLimit = rateLimits.getCurrentRateLimit(curveUsdcSwapKey);
        uint256 startingUsdtSwapLimit = rateLimits.getCurrentRateLimit(curveUsdtSwapKey);

        vm.startPrank(relayer);

        uint256 lpTokens = mainnetController.addLiquidityCurve(CURVE_POOL, amounts, 1e18);

        uint256 derivedUsdcSwapped = startingUsdcSwapLimit - rateLimits.getCurrentRateLimit(curveUsdcSwapKey);
        uint256 derivedUsdtSwapped = startingUsdtSwapLimit - rateLimits.getCurrentRateLimit(curveUsdtSwapKey);

        // Step 2: Withdraw full balance of LP tokens, withdrawing proportional amounts from the pool

        uint256[] memory minWithdrawnAmounts = new uint256[](2);
        minWithdrawnAmounts[0] = 1e6;
        minWithdrawnAmounts[1] = 1e6;

        uint256[] memory withdrawnAmounts = mainnetController.removeLiquidityCurve(CURVE_POOL, lpTokens, minWithdrawnAmounts);

        // Step 3: Whatever was deposited above the proportional withdrawal is the amount swapped in per token

        // Difference is accurate to within 1 unit of each token (pro-rata rounding)
        assertApproxEqAbs(derivedUsdcSwapped, _swappedIn(amounts[0], withdrawnAmounts[0]), 1);
        assertApproxEqAbs(derivedUsdtSwapped, _swappedIn(amounts[1], withdrawnAmounts[1]), 1);
    }

}

contract MainnetControllerRemoveLiquidityCurveFailureTests is CurveTestBase {

    function test_removeLiquidityCurve_notRelayer() public {
        uint256[] memory minWithdrawAmounts = new uint256[](2);
        minWithdrawAmounts[0] = 1_000_000e6;
        minWithdrawAmounts[1] = 1_000_000e6;

        uint256 lpReturn = 1_980_000e18;

        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        mainnetController.removeLiquidityCurve(CURVE_POOL, lpReturn, minWithdrawAmounts);
    }

    function test_removeLiquidityCurve_slippageNotSet() public {
        uint256[] memory minWithdrawAmounts = new uint256[](2);
        minWithdrawAmounts[0] = 1_000_000e6;
        minWithdrawAmounts[1] = 1_000_000e6;

        uint256 lpReturn = 1_980_000e18;

        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(CURVE_POOL, 0);

        vm.prank(relayer);
        vm.expectRevert("CurveLib/max-slippage-not-set");
        mainnetController.removeLiquidityCurve(CURVE_POOL, lpReturn, minWithdrawAmounts);
    }

    function test_removeLiquidityCurve_invalidDepositAmountsLength() public {
        uint256[] memory minWithdrawAmounts = new uint256[](3);
        minWithdrawAmounts[0] = 1_000_000e6;
        minWithdrawAmounts[1] = 1_000_000e6;
        minWithdrawAmounts[2] = 1_000_000e6;

        uint256 lpReturn = 1_980_000e18;

        vm.startPrank(relayer);

        vm.expectRevert("CurveLib/invalid-min-withdraw-amounts");
        mainnetController.removeLiquidityCurve(CURVE_POOL, lpReturn, minWithdrawAmounts);

        uint256[] memory minWithdrawAmounts2 = new uint256[](1);
        minWithdrawAmounts[0] = 1_000_000e6;

        vm.expectRevert("CurveLib/invalid-min-withdraw-amounts");
        mainnetController.removeLiquidityCurve(CURVE_POOL, lpReturn, minWithdrawAmounts2);
    }

    function test_removeLiquidityCurve_underAllowableSlippageBoundary() public {
        uint256 lpTokensReceived = _addLiquidity(1_000_000e6, 1_000_000e6);

        uint256 minTotalReturned = lpTokensReceived * curvePool.get_virtual_price() * 98/100 / 1e18;

        assertApproxEqAbs(minTotalReturned, 1_960_000e18, 50_000e18);  // Sanity check on precision

        // Skewed pool, using 465k as anchor point because USDC balance of pool is low
        uint256[] memory minWithdrawAmounts = new uint256[](2);
        minWithdrawAmounts[0] = 465_000e6;
        minWithdrawAmounts[1] = minTotalReturned / 1e12 - 465_000e6;

        vm.startPrank(relayer);
        vm.expectRevert("CurveLib/min-amount-not-met");
        mainnetController.removeLiquidityCurve(CURVE_POOL, lpTokensReceived, minWithdrawAmounts);

        // Add one to get over the boundary
        minWithdrawAmounts[1] += 1;

        mainnetController.removeLiquidityCurve(CURVE_POOL, lpTokensReceived, minWithdrawAmounts);
    }

    function _defaultMinWithdrawAmounts() internal pure returns (uint256[] memory minWithdrawAmounts) {
        minWithdrawAmounts = new uint256[](2);
        minWithdrawAmounts[0] = 465_000e6;
        minWithdrawAmounts[1] = 1_535_000e6;
    }

    function _assertRemoveLiquidityZeroMaxAmount(bytes32 key) internal {
        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(key, 0, 0);

        uint256 lpTokensReceived = _addLiquidity(1_000_000e6, 1_000_000e6);

        uint256[] memory minWithdrawAmounts = _defaultMinWithdrawAmounts();

        vm.prank(relayer);
        vm.expectRevert("RateLimits/zero-maxAmount");
        mainnetController.removeLiquidityCurve(CURVE_POOL, lpTokensReceived, minWithdrawAmounts);
    }

    function test_removeLiquidityCurve_zeroMaxAmount() public {
        _assertRemoveLiquidityZeroMaxAmount(curveWithdrawKey);
    }

    function test_removeLiquidityCurve_zeroMaxAmount_asset0() public {
        _assertRemoveLiquidityZeroMaxAmount(curveUsdcWithdrawKey);
    }

    function test_removeLiquidityCurve_zeroMaxAmount_asset1() public {
        _assertRemoveLiquidityZeroMaxAmount(curveUsdtWithdrawKey);
    }

    function _assertRemoveLiquidityRateLimitBoundary(bytes32 key) internal {
        uint256 lpTokensReceived = _addLiquidity(1_000_000e6, 1_000_000e6);

        uint256[] memory minWithdrawAmounts = _defaultMinWithdrawAmounts();

        uint256 id = vm.snapshotState();

        uint256 limitBefore = rateLimits.getCurrentRateLimit(key);

        vm.prank(relayer);
        mainnetController.removeLiquidityCurve(CURVE_POOL, lpTokensReceived, minWithdrawAmounts);

        uint256 charged = limitBefore - rateLimits.getCurrentRateLimit(key);

        assertGt(charged, 0, "nothing charged");

        vm.revertToState(id);

        // Set to below boundary
        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(key, charged - 1, charged / 1 days);

        vm.prank(relayer);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        mainnetController.removeLiquidityCurve(CURVE_POOL, lpTokensReceived, minWithdrawAmounts);

        // Set to boundary
        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(key, charged, charged / 1 days);

        vm.prank(relayer);
        mainnetController.removeLiquidityCurve(CURVE_POOL, lpTokensReceived, minWithdrawAmounts);

        assertEq(rateLimits.getCurrentRateLimit(key), 0);
    }

    function test_removeLiquidityCurve_rateLimitBoundary() public {
        _assertRemoveLiquidityRateLimitBoundary(curveWithdrawKey);
    }

    function test_removeLiquidityCurve_rateLimitBoundary_asset0() public {
        _assertRemoveLiquidityRateLimitBoundary(curveUsdcWithdrawKey);
    }

    function test_removeLiquidityCurve_rateLimitBoundary_asset1() public {
        _assertRemoveLiquidityRateLimitBoundary(curveUsdtWithdrawKey);
    }

    function test_removeLiquidityCurve_minAmountOutNotMet() public {
        uint256 lpTokensReceived = _addLiquidity(1_000_000e6, 1_000_000e6);

        uint256[] memory minWithdrawAmounts = _defaultMinWithdrawAmounts();

        vm.mockCall(
            CURVE_POOL,
            abi.encodeWithSelector(ICurvePoolLike.remove_liquidity.selector),
            ""
        );

        vm.prank(relayer);
        vm.expectRevert("CurveLib/min-amount-out-not-met");
        mainnetController.removeLiquidityCurve(CURVE_POOL, lpTokensReceived, minWithdrawAmounts);

        vm.clearMockedCalls();
    }

}

contract MainnetControllerRemoveLiquiditySuccessTests is CurveTestBase {

    function test_removeLiquidityCurve() public {
        uint256 lpTokensReceived = _addLiquidity(1_000_000e6, 1_000_000e6);

        uint256 startingUsdtBalance = usdt.balanceOf(CURVE_POOL);
        uint256 startingUsdcBalance = usdc.balanceOf(CURVE_POOL);
        uint256 startingTotalSupply = curveLp.totalSupply();

        assertEq(lpTokensReceived, 1_987_199.361495730708108741e18);

        assertEq(curveLp.allowance(address(almProxy), CURVE_POOL), 0);

        assertEq(usdt.balanceOf(address(almProxy)), 0);
        assertEq(usdt.balanceOf(CURVE_POOL),        startingUsdtBalance);

        assertEq(usdc.balanceOf(address(almProxy)), 0);
        assertEq(usdc.balanceOf(CURVE_POOL),        startingUsdcBalance);

        assertEq(curveLp.balanceOf(address(almProxy)), lpTokensReceived);
        assertEq(curveLp.totalSupply(),                startingTotalSupply);

        assertEq(rateLimits.getCurrentRateLimit(curveWithdrawKey),     3_000_000e18);
        assertEq(rateLimits.getCurrentRateLimit(curveUsdcWithdrawKey), 3_000_000e6);
        assertEq(rateLimits.getCurrentRateLimit(curveUsdtWithdrawKey), 3_000_000e6);

        uint256[] memory minWithdrawAmounts = new uint256[](2);
        minWithdrawAmounts[0] = 465_000e6;
        minWithdrawAmounts[1] = 1_535_000e6;

        vm.prank(relayer);
        uint256[] memory assetsReceived = mainnetController.removeLiquidityCurve(
            CURVE_POOL,
            lpTokensReceived,
            minWithdrawAmounts
        );

        assertEq(assetsReceived[0], 465_059.586753e6);
        assertEq(assetsReceived[1], 1_535_013.847298e6);

        uint256 sumAssetsReceived = (assetsReceived[0] + assetsReceived[1]) * 1e12;

        assertApproxEqAbs(sumAssetsReceived, 2_000_000e18, 100e18);

        assertGe(sumAssetsReceived, 2_000_000e18);  // Pool is skewed so more value can be removed after balancing

        assertEq(curveLp.allowance(address(almProxy), CURVE_POOL), 0);

        assertEq(usdc.balanceOf(address(almProxy)), assetsReceived[0]);

        assertApproxEqAbs(usdc.balanceOf(CURVE_POOL), startingUsdcBalance - assetsReceived[0], 100e6);  // Fees from other deposits

        assertEq(usdt.balanceOf(address(almProxy)), assetsReceived[1]);

        assertApproxEqAbs(usdt.balanceOf(CURVE_POOL), startingUsdtBalance - assetsReceived[1], 100e6);  // Fees from other deposits

        assertEq(curveLp.balanceOf(address(almProxy)), 0);
        assertEq(curveLp.totalSupply(),                startingTotalSupply - lpTokensReceived);

        assertEq(rateLimits.getCurrentRateLimit(curveWithdrawKey),     3_000_000e18 - sumAssetsReceived);
        assertEq(rateLimits.getCurrentRateLimit(curveUsdcWithdrawKey), 3_000_000e6  - assetsReceived[0]);
        assertEq(rateLimits.getCurrentRateLimit(curveUsdtWithdrawKey), 3_000_000e6  - assetsReceived[1]);
    }

}

contract MainnetControllerSwapCurveFailureTests is CurveTestBase {

    function test_swapCurve_notRelayer() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        mainnetController.swapCurve(CURVE_POOL, 1, 0, 1_000_000e6, 980_000e6);
    }

    function test_swapCurve_sameIndex() public {
        vm.prank(relayer);
        vm.expectRevert("CurveLib/invalid-indices");
        mainnetController.swapCurve(CURVE_POOL, 1, 1, 1_000_000e6, 980_000e6);
    }

    function test_swapCurve_firstIndexTooHighBoundary() public {
        _addLiquidity();
        skip(1 days);  // Recharge swap rate limit from deposit

        deal(address(usdt), address(almProxy), 1_000_000e6);

        vm.prank(relayer);
        vm.expectRevert("CurveLib/index-too-high");
        mainnetController.swapCurve(CURVE_POOL, 2, 0, 1_000_000e6, 980_000e6);

        vm.prank(relayer);
        mainnetController.swapCurve(CURVE_POOL, 1, 0, 1_000_000e6, 980_000e6);
    }

    function test_swapCurve_secondIndexTooHighBoundary() public {
        _addLiquidity();
        skip(1 days);  // Recharge swap rate limit from deposit

        deal(address(usdc), address(almProxy), 1_000_000e6);

        vm.prank(relayer);
        vm.expectRevert("CurveLib/index-too-high");
        mainnetController.swapCurve(CURVE_POOL, 0, 2, 1_000_000e6, 980_000e6);

        vm.prank(relayer);
        mainnetController.swapCurve(CURVE_POOL, 0, 1, 1_000_000e6, 980_000e6);
    }

    function test_swapCurve_slippageNotSet() public {
        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(CURVE_POOL, 0);

        vm.prank(relayer);
        vm.expectRevert("CurveLib/max-slippage-not-set");
        mainnetController.swapCurve(CURVE_POOL, 1, 0, 1_000_000e6, 980_000e6);
    }

    function test_swapCurve_underAllowableSlippageBoundaryAsset0To1() public {
        _addLiquidity();
        skip(1 days);  // Recharge swap rate limit from deposit

        deal(address(usdc), address(almProxy), 1_000_000e6);

        vm.startPrank(relayer);
        vm.expectRevert("CurveLib/min-amount-not-met");
        mainnetController.swapCurve(CURVE_POOL, 0, 1, 1_000_000e6, 980_000e6 - 1);

        mainnetController.swapCurve(CURVE_POOL, 0, 1, 1_000_000e6, 980_000e6);
    }

    function test_swapCurve_underAllowableSlippageBoundaryAsset1To0() public {
        _addLiquidity();
        skip(1 days);  // Recharge swap rate limit from deposit

        deal(address(usdt), address(almProxy), 1_000_000e6);

        vm.startPrank(relayer);
        vm.expectRevert("CurveLib/min-amount-not-met");
        mainnetController.swapCurve(CURVE_POOL, 1, 0, 1_000_000e6, 980_000e6 - 1);

        mainnetController.swapCurve(CURVE_POOL, 1, 0, 1_000_000e6, 980_000e6);
    }

    function test_swapCurve_zeroMaxAmount() public {
        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(curveUsdtSwapKey, 0, 0);

        vm.prank(relayer);
        vm.expectRevert("RateLimits/zero-maxAmount");
        mainnetController.swapCurve(CURVE_POOL, 1, 0, 1_000_000e6, 980_000e6);
    }

    function test_swapCurve_otherTokenKeyNotHonoured() public {
        _addLiquidity();
        skip(1 days);  // Recharge swap rate limit from deposit

        deal(address(usdt), address(almProxy), 1_000_000e6);

        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(curveUsdcSwapKey, 0, 0);

        vm.prank(relayer);
        mainnetController.swapCurve(CURVE_POOL, 1, 0, 1_000_000e6, 980_000e6);
    }

    function test_swapCurve_legacyKeyNotHonoured() public {
        _addLiquidity();
        skip(1 days);  // Recharge swap rate limit from deposit

        deal(address(usdt), address(almProxy), 1_000_000e6);

        vm.prank(GROVE_PROXY);
        rateLimits.setRateLimitData(curveLegacySwapKey, 0, 0);

        vm.prank(relayer);
        mainnetController.swapCurve(CURVE_POOL, 1, 0, 1_000_000e6, 980_000e6);
    }

    function test_swapCurve_minAmountOutNotMet() public {
        deal(address(usdt), address(almProxy), 1_000_000e6);

        vm.mockCall(
            CURVE_POOL,
            abi.encodeWithSelector(ICurvePoolLike.exchange.selector),
            abi.encode(uint256(980_000e6))
        );

        vm.prank(relayer);
        vm.expectRevert("CurveLib/min-amount-out-not-met");
        mainnetController.swapCurve(CURVE_POOL, 1, 0, 1_000_000e6, 980_000e6);

        vm.clearMockedCalls();
    }

    function test_swapCurve_rateLimitBoundary() public {
        _addLiquidity();
        skip(1 days);  // Recharge swap rate limit from deposit

        deal(address(usdt), address(almProxy), 1_000_000e6 + 1);

        vm.startPrank(relayer);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        mainnetController.swapCurve(CURVE_POOL, 1, 0, 1_000_000e6 + 1, 998_000e6);

        mainnetController.swapCurve(CURVE_POOL, 1, 0, 1_000_000e6, 998_000e6);
    }

}

contract MainnetControllerSwapCurveSuccessTests is CurveTestBase {

    function test_swapCurve() public {
        _addLiquidity(1_000_000e6, 1_000_000e6);
        skip(1 days);  // Recharge swap rate limit from deposit

        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(CURVE_POOL, 0.999e18);  // 0.1%

        uint256 startingUsdtBalance = usdt.balanceOf(CURVE_POOL);
        uint256 startingUsdcBalance = usdc.balanceOf(CURVE_POOL);

        deal(address(usdt), address(almProxy), 1_000_000e6);

        assertEq(usdt.balanceOf(address(almProxy)), 1_000_000e6);
        assertEq(usdt.balanceOf(CURVE_POOL),        startingUsdtBalance);

        assertEq(usdc.balanceOf(address(almProxy)), 0);
        assertEq(usdc.balanceOf(CURVE_POOL),        startingUsdcBalance);

        assertEq(rateLimits.getCurrentRateLimit(curveUsdtSwapKey), 1_000_000e6);
        assertEq(rateLimits.getCurrentRateLimit(curveUsdcSwapKey), 1_000_000e6);

        assertEq(usdc.allowance(address(almProxy), CURVE_POOL), 0);
        assertEq(usdt.allowance(address(almProxy), CURVE_POOL), 0);

        vm.prank(relayer);
        uint256 amountOut = mainnetController.swapCurve(CURVE_POOL, 1, 0, 1_000_000e6, 999_500e6);

        assertEq(amountOut, 999_712.1851680e6);

        assertEq(usdc.allowance(address(almProxy), CURVE_POOL), 0);
        assertEq(usdt.allowance(address(almProxy), CURVE_POOL), 0);

        assertEq(usdt.balanceOf(address(almProxy)), 0);
        assertEq(usdt.balanceOf(CURVE_POOL),        startingUsdtBalance + 1_000_000e6);

        assertEq(usdc.balanceOf(address(almProxy)), amountOut);
        assertEq(usdc.balanceOf(CURVE_POOL),        startingUsdcBalance - amountOut);

        assertEq(rateLimits.getCurrentRateLimit(curveUsdtSwapKey), 0);
        assertEq(rateLimits.getCurrentRateLimit(curveUsdcSwapKey), 1_000_000e6);
    }

}

contract MainnetControllerGetVirtualPriceStressTests is CurveTestBase {

    function test_getVirtualPrice_stressTest() public {
        _setUnlimitedCurveRateLimits();

        _addLiquidity(100_000_000e6, 100_000_000e6);

        uint256 virtualPrice1 = curvePool.get_virtual_price();

        assertEq(virtualPrice1, 1.006472121147810626e18);

        deal(address(usdc), address(almProxy), 100_000_000e6);

        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(CURVE_POOL, 1);  // 1e-16%

        // Perform a massive swap to stress the virtual price
        vm.prank(relayer);
        uint256 amountOut = mainnetController.swapCurve(CURVE_POOL, 0, 1, 100_000_000e6, 1000e6);

        assertEq(amountOut, 99_949_401.825058e6);

        // Assert price rises
        uint256 virtualPrice2 = curvePool.get_virtual_price();

        assertEq(virtualPrice2, 1.006481289896618067e18);
        assertGt(virtualPrice2, virtualPrice1);

        // Add one sided liquidity to stress the virtual price
        _addLiquidity(0, 100_000_000e6);

        // Assert price rises
        uint256 virtualPrice3 = curvePool.get_virtual_price();

        assertEq(virtualPrice3, 1.006486607243912047e18);
        assertGt(virtualPrice3, virtualPrice2);

        // Remove liquidity
        uint256[] memory minWithdrawAmounts = new uint256[](2);
        minWithdrawAmounts[0] = 1000e6;
        minWithdrawAmounts[1] = 1000e6;

        vm.startPrank(relayer);
        mainnetController.removeLiquidityCurve(
            CURVE_POOL,
            curveLp.balanceOf(address(almProxy)),
            minWithdrawAmounts
        );
        vm.stopPrank();

        // Assert price rises
        uint256 virtualPrice4 = curvePool.get_virtual_price();

        assertEq(virtualPrice4, 1.006486607244205989e18);
        assertGt(virtualPrice4, virtualPrice3);
    }

}

contract MainnetController3PoolSwapRateLimitTest is ForkTestBase {

    // Working in BTC terms because only high TVL active NG three asset pool is BTC
    address CURVE_POOL = 0xabaf76590478F2fE0b396996f55F0b61101e9502;

    IERC20 ebtc = IERC20(0x657e8C867D8B37dCC18fA4Caead9C45EB088C642);
    IERC20 lbtc = IERC20(0x8236a87084f8B84306f72007F36F2618A5634494);
    IERC20 wbtc = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);

    address[3] tokens = [address(ebtc), address(lbtc), address(wbtc)];

    bytes32 curveDepositKey;
    bytes32 curveWithdrawKey;

    bytes32[3] curveSwapKeys;
    bytes32[3] curveDepositKeys;
    bytes32[3] curveWithdrawKeys;

    function setUp() public virtual override  {
        super.setUp();

        curveDepositKey  = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_CURVE_DEPOSIT(),  CURVE_POOL);
        curveWithdrawKey = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_CURVE_WITHDRAW(), CURVE_POOL);

        vm.startPrank(GROVE_PROXY);
        rateLimits.setRateLimitData(curveDepositKey,  5_000_000e18, uint256(5_000_000e18) / 1 days);
        rateLimits.setRateLimitData(curveWithdrawKey, 5_000_000e18, uint256(5_000_000e18) / 1 days);

        for (uint256 i = 0; i < 3; i++) {
            curveSwapKeys[i]     = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_SWAP(),     tokens[i], CURVE_POOL);
            curveDepositKeys[i]  = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_DEPOSIT(),  tokens[i], CURVE_POOL);
            curveWithdrawKeys[i] = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_WITHDRAW(), tokens[i], CURVE_POOL);

            rateLimits.setRateLimitData(curveSwapKeys[i],     5_000e8, uint256(5_000e8) / 1 days);
            rateLimits.setRateLimitData(curveDepositKeys[i],  5_000e8, uint256(5_000e8) / 1 days);
            rateLimits.setRateLimitData(curveWithdrawKeys[i], 5_000e8, uint256(5_000e8) / 1 days);
        }
        vm.stopPrank();

        // Set a higher slippage to allow for successes
        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(CURVE_POOL, 0.001e18);
    }

    function _getBlock() internal pure override returns (uint256) {
        return 22000000;  // March 8, 2025
    }

    function test_addLiquidityCurve_swapRateLimit() public {
        deal(address(ebtc), address(almProxy), 2_000e8);

        // Step 1: Add liquidity, check how much the rate limits were reduced

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e8;
        amounts[1] = 0;
        amounts[2] = 0;

        uint256 minLpAmount = 0.1e18;

        uint256[3] memory startingSwapLimits;
        for (uint256 i = 0; i < 3; i++) {
            startingSwapLimits[i] = rateLimits.getCurrentRateLimit(curveSwapKeys[i]);
        }

        vm.startPrank(relayer);

        uint256 lpTokens = mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);

        uint256[3] memory derivedSwapped;
        for (uint256 i = 0; i < 3; i++) {
            derivedSwapped[i] = startingSwapLimits[i] - rateLimits.getCurrentRateLimit(curveSwapKeys[i]);
        }

        // Step 2: Withdraw full balance of LP tokens, withdrawing proportional amounts from the pool

        uint256[] memory minWithdrawnAmounts = new uint256[](3);
        minWithdrawnAmounts[0] = 0.01e8;
        minWithdrawnAmounts[1] = 0.01e8;
        minWithdrawnAmounts[2] = 0.01e8;

        uint256[] memory withdrawnAmounts = mainnetController.removeLiquidityCurve(CURVE_POOL, lpTokens, minWithdrawnAmounts);

        // Step 3: Show "swapped" asset results, demonstrate that only the eBTC swap rate limit was reduced,
        //         by the amount of eBTC swapped in: 1e8 deposited - ~0.35e8 withdrawn = ~0.65e8 swapped

        assertEq(withdrawnAmounts[0], 0.35689723e8);
        assertEq(withdrawnAmounts[1], 0.22809783e8);
        assertEq(withdrawnAmounts[2], 0.41478858e8);

        // Difference is accurate to within 1 unit of eBTC (pro-rata rounding)
        assertApproxEqAbs(derivedSwapped[0], 1e8 - withdrawnAmounts[0], 1);

        assertEq(derivedSwapped[0], 0.64310277e8);
        assertEq(derivedSwapped[1], 0);
        assertEq(derivedSwapped[2], 0);

        for (uint256 i = 0; i < 3; i++) {
            assertApproxEqAbs(rateLimits.getCurrentRateLimit(curveDepositKeys[i]), 5_000e8 - withdrawnAmounts[i], 1);
            assertEq(rateLimits.getCurrentRateLimit(curveWithdrawKeys[i]),         5_000e8 - withdrawnAmounts[i]);
        }
    }

}

contract MainnetControllerSUsdsUsdtSwapRateLimitTest is ForkTestBase {

    address constant CURVE_POOL = 0x00836Fe54625BE242BcFA286207795405ca4fD10;

    IERC20 curveLp = IERC20(CURVE_POOL);

    bytes32 curveDepositKey;
    bytes32 curveWithdrawKey;

    bytes32 curveSUsdsSwapKey;
    bytes32 curveUsdtSwapKey;
    bytes32 curveSUsdsDepositKey;
    bytes32 curveUsdtDepositKey;
    bytes32 curveSUsdsWithdrawKey;
    bytes32 curveUsdtWithdrawKey;

    function setUp() public virtual override  {
        super.setUp();

        curveDepositKey  = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_CURVE_DEPOSIT(),  CURVE_POOL);
        curveWithdrawKey = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_CURVE_WITHDRAW(), CURVE_POOL);

        curveSUsdsSwapKey     = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_SWAP(),     address(susds), CURVE_POOL);
        curveUsdtSwapKey      = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_SWAP(),     address(usdt),  CURVE_POOL);
        curveSUsdsDepositKey  = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_DEPOSIT(),  address(susds), CURVE_POOL);
        curveUsdtDepositKey   = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_DEPOSIT(),  address(usdt),  CURVE_POOL);
        curveSUsdsWithdrawKey = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_WITHDRAW(), address(susds), CURVE_POOL);
        curveUsdtWithdrawKey  = RateLimitHelpers.makeAssetDestinationKey(mainnetController.LIMIT_CURVE_WITHDRAW(), address(usdt),  CURVE_POOL);

        vm.startPrank(GROVE_PROXY);
        rateLimits.setRateLimitData(curveDepositKey,  5_000_000e18, uint256(5_000_000e18) / 1 days);
        rateLimits.setRateLimitData(curveWithdrawKey, 5_000_000e18, uint256(5_000_000e18) / 1 days);

        rateLimits.setRateLimitData(curveSUsdsSwapKey,     5_000_000e18, uint256(5_000_000e18) / 1 days);
        rateLimits.setRateLimitData(curveUsdtSwapKey,      5_000_000e6,  uint256(5_000_000e6)  / 1 days);
        rateLimits.setRateLimitData(curveSUsdsDepositKey,  5_000_000e18, uint256(5_000_000e18) / 1 days);
        rateLimits.setRateLimitData(curveUsdtDepositKey,   5_000_000e6,  uint256(5_000_000e6)  / 1 days);
        rateLimits.setRateLimitData(curveSUsdsWithdrawKey, 5_000_000e18, uint256(5_000_000e18) / 1 days);
        rateLimits.setRateLimitData(curveUsdtWithdrawKey,  5_000_000e6,  uint256(5_000_000e6)  / 1 days);
        vm.stopPrank();

        // Set a higher slippage to allow for successes
        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(CURVE_POOL, 0.01e18);

        // Seed the pool with some liquidity to be able to perform the swap

        uint256 susdsAmount = susds.convertToShares(1_000_000e18);

        deal(address(susds), address(almProxy), susdsAmount);
        deal(address(usdt),  address(almProxy), 1_000_000e6);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = susdsAmount;
        amounts[1] = 1_000_000e6;

        uint256 minLpAmount = 100_000e18;

        vm.prank(relayer);
        mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);
    }

    function _getBlock() internal pure override returns (uint256) {
        return 22225000;  // April 8, 2025
    }

    function test_addLiquidityCurve_swapRateLimit() public {
        uint256 susdsAmount = susds.convertToShares(1_000_000e18);

        deal(address(susds), address(almProxy), susdsAmount);

        // Step 1: Add liquidity, check how much the rate limit was reduced

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = susdsAmount;
        amounts[1] = 0;

        uint256 minLpAmount = 100_000e18;

        uint256 startingSUsdsSwapLimit = rateLimits.getCurrentRateLimit(curveSUsdsSwapKey);
        uint256 startingUsdtSwapLimit  = rateLimits.getCurrentRateLimit(curveUsdtSwapKey);

        vm.startPrank(relayer);

        uint256 lpTokens = mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);

        uint256 derivedSUsdsSwapped = startingSUsdsSwapLimit - rateLimits.getCurrentRateLimit(curveSUsdsSwapKey);
        uint256 derivedUsdtSwapped  = startingUsdtSwapLimit  - rateLimits.getCurrentRateLimit(curveUsdtSwapKey);

        // Step 2: Withdraw full balance of LP tokens, withdrawing proportional amounts from the pool

        uint256[] memory minWithdrawnAmounts = new uint256[](2);
        minWithdrawnAmounts[0] = 100_000e18;
        minWithdrawnAmounts[1] = 100_000e6;

        uint256[] memory withdrawnAmounts = mainnetController.removeLiquidityCurve(CURVE_POOL, lpTokens, minWithdrawnAmounts);

        // Step 3: Show "swapped" asset results, demonstrate that the sUSDS swap rate limit was reduced by the
        //         amount of sUSDS swapped in (in sUSDS units): 1m deposited - ~666k withdrawn = ~333k swapped

        assertEq(susds.convertToAssets(withdrawnAmounts[0]), 666_655.261741191232680640e18);
        assertEq(withdrawnAmounts[1],                        333_327.974363e6);

        // Difference is accurate to within 1 unit of sUSDS (pro-rata rounding)
        assertApproxEqAbs(derivedSUsdsSwapped, susdsAmount - withdrawnAmounts[0], 1);

        assertEq(susds.convertToAssets(derivedSUsdsSwapped), 333_344.738258808767319358e18);
        assertEq(derivedUsdtSwapped,                         0);
    }

}

contract MainnetControllerE2ECurveUsdtUsdcPoolTest is CurveTestBase {

    function test_e2e_addSwapAndRemoveLiquidityCurve() public {
        // Set a higher slippage to allow for successes
        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(CURVE_POOL, 0.95e18);

        deal(address(usdc), address(almProxy), 1_000_000e6);
        deal(address(usdt), address(almProxy), 1_000_000e6);

        uint256 usdcBalance = usdc.balanceOf(CURVE_POOL);
        uint256 usdtBalance = usdt.balanceOf(CURVE_POOL);

        // Step 1: Add liquidity

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_000_000e6;
        amounts[1] = 1_000_000e6;

        uint256 minLpAmount = 1_950_000e18;

        assertEq(curveLp.balanceOf(address(almProxy)), 0);

        assertEq(usdc.balanceOf(address(almProxy)), 1_000_000e6);
        assertEq(usdt.balanceOf(address(almProxy)), 1_000_000e6);

        vm.prank(relayer);
        uint256 lpTokensReceived = mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);

        assertEq(curveLp.balanceOf(address(almProxy)), lpTokensReceived);

        assertEq(usdc.balanceOf(address(almProxy)), 0);
        assertEq(usdt.balanceOf(address(almProxy)), 0);

        assertEq(usdc.balanceOf(CURVE_POOL), usdcBalance + 1_000_000e6);
        assertEq(usdt.balanceOf(CURVE_POOL), usdtBalance + 1_000_000e6);

        // Step 2: Swap USDT for USDC

        deal(address(usdt), address(almProxy), 100_000e6);

        assertEq(usdt.balanceOf(address(almProxy)), 100_000e6);
        assertEq(usdc.balanceOf(address(almProxy)), 0);

        vm.prank(relayer);
        uint256 usdcReturned = mainnetController.swapCurve(CURVE_POOL, 1, 0, 100_000e6, 99_900e6);

        assertEq(usdcReturned, 99_984.727700e6);

        assertEq(usdc.balanceOf(address(almProxy)), usdcReturned);
        assertEq(usdt.balanceOf(address(almProxy)), 0);

        // Step 3: Swap USDT for USDC again (ensure no issues with USDT approval)

        deal(address(usdt), address(almProxy), 100_000e6);

        assertEq(usdc.balanceOf(address(almProxy)), usdcReturned);
        assertEq(usdt.balanceOf(address(almProxy)), 100_000e6);

        vm.prank(relayer);
        usdcReturned += mainnetController.swapCurve(CURVE_POOL, 1, 0, 100_000e6, 99_900e6);

        assertEq(usdcReturned, 199_967.818973e6);

        assertEq(usdc.balanceOf(address(almProxy)), usdcReturned);  // Incremented
        assertEq(usdt.balanceOf(address(almProxy)), 0);

        // Step 4: Swap USDC for USDT

        deal(address(usdc), address(almProxy), 100_000e6);  // NOTE: Overwrites balance

        assertEq(usdc.balanceOf(address(almProxy)), 100_000e6);
        assertEq(usdt.balanceOf(address(almProxy)), 0);

        vm.prank(relayer);
        uint256 usdtReturned = mainnetController.swapCurve(CURVE_POOL, 0, 1, 100_000e6, 99_900e6);

        assertEq(usdtReturned, 100_008.403841e6);

        assertEq(usdc.balanceOf(address(almProxy)), 0);
        assertEq(usdt.balanceOf(address(almProxy)), usdtReturned);

        // Step 5: Remove liquidity

        usdcBalance = usdc.balanceOf(CURVE_POOL);
        usdtBalance = usdt.balanceOf(CURVE_POOL);

        // NOTE: Asserting to demonstrate that balances are very skewed, so min withdraw amounts have to be as well
        assertEq(usdcBalance, 1_774_134.212373e6);
        assertEq(usdtBalance, 6_285_626.822871e6);

        uint256[] memory minWithdrawAmounts = new uint256[](2);
        minWithdrawAmounts[0] = 440_000e6;
        minWithdrawAmounts[1] = 1_550_000e6;

        vm.prank(relayer);
        uint256[] memory assetsReceived = mainnetController.removeLiquidityCurve(
            CURVE_POOL,
            lpTokensReceived,
            minWithdrawAmounts
        );

        assertEq(assetsReceived[0], 440_250.439766e6);
        assertEq(assetsReceived[1], 1_559_827.329765e6);

        uint256 sumAssetsReceived = assetsReceived[0] + assetsReceived[1];

        assertEq(sumAssetsReceived, 2_000_077.769531e6);

        assertEq(usdc.balanceOf(address(almProxy)), assetsReceived[0]);
        assertEq(usdt.balanceOf(address(almProxy)), assetsReceived[1] + usdtReturned);

        assertEq(curveLp.balanceOf(address(almProxy)), 0);

        // Approximate because of fees
        assertApproxEqAbs(usdc.balanceOf(CURVE_POOL), usdcBalance - assetsReceived[0], 100e6);
        assertApproxEqAbs(usdt.balanceOf(CURVE_POOL), usdtBalance - assetsReceived[1], 100e6);
    }

}

contract MainnetControllerE2ECurveSUsdsUsdtPoolTest is ForkTestBase {

    address constant CURVE_POOL = 0x00836Fe54625BE242BcFA286207795405ca4fD10;

    IERC20 curveLp = IERC20(CURVE_POOL);

    bytes32 curveDepositKey;
    bytes32 curveWithdrawKey;

    function setUp() public virtual override  {
        super.setUp();

        curveDepositKey  = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_CURVE_DEPOSIT(),  CURVE_POOL);
        curveWithdrawKey = RateLimitHelpers.makeAssetKey(mainnetController.LIMIT_CURVE_WITHDRAW(), CURVE_POOL);

        bytes32 swapId     = mainnetController.LIMIT_CURVE_SWAP();
        bytes32 depositId  = mainnetController.LIMIT_CURVE_DEPOSIT();
        bytes32 withdrawId = mainnetController.LIMIT_CURVE_WITHDRAW();

        // Skewed pool: a balancing deposit is worth more than the value put in, hence the headroom.
        vm.startPrank(GROVE_PROXY);
        rateLimits.setRateLimitData(curveDepositKey,  2_100_000e18, uint256(2_100_000e18) / 1 days);
        rateLimits.setRateLimitData(curveWithdrawKey, 3_000_000e18, uint256(3_000_000e18) / 1 days);

        rateLimits.setRateLimitData(RateLimitHelpers.makeAssetDestinationKey(swapId,     address(susds), CURVE_POOL), 1_000_000e18, uint256(1_000_000e18) / 1 days);
        rateLimits.setRateLimitData(RateLimitHelpers.makeAssetDestinationKey(swapId,     address(usdt),  CURVE_POOL), 1_000_000e6,  uint256(1_000_000e6)  / 1 days);
        rateLimits.setRateLimitData(RateLimitHelpers.makeAssetDestinationKey(depositId,  address(susds), CURVE_POOL), 2_000_000e18, uint256(2_000_000e18) / 1 days);
        rateLimits.setRateLimitData(RateLimitHelpers.makeAssetDestinationKey(depositId,  address(usdt),  CURVE_POOL), 2_000_000e6,  uint256(2_000_000e6)  / 1 days);
        rateLimits.setRateLimitData(RateLimitHelpers.makeAssetDestinationKey(withdrawId, address(susds), CURVE_POOL), 3_000_000e18, uint256(3_000_000e18) / 1 days);
        rateLimits.setRateLimitData(RateLimitHelpers.makeAssetDestinationKey(withdrawId, address(usdt),  CURVE_POOL), 3_000_000e6,  uint256(3_000_000e6)  / 1 days);
        vm.stopPrank();

        // Set a higher slippage to allow for successes
        vm.prank(GROVE_PROXY);
        mainnetController.setMaxSlippage(CURVE_POOL, 0.95e18);
    }

    function _getBlock() internal pure override returns (uint256) {
        return 22225000;  // April 8, 2025
    }

    function test_e2e_addSwapAndRemoveLiquidityCurve() public {
        uint256 susdsAmount = susds.convertToShares(1_000_000e18);

        deal(address(susds), address(almProxy), susdsAmount);
        deal(address(usdt),  address(almProxy), 1_000_000e6);

        uint256 susdsBalance = susds.balanceOf(CURVE_POOL);
        uint256 usdtBalance  = usdt.balanceOf(CURVE_POOL);

        // Step 1: Add liquidity

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = susdsAmount;
        amounts[1] = 1_000_000e6;

        uint256 minLpAmount = 1_950_000e18;

        assertEq(curveLp.balanceOf(address(almProxy)), 0);

        assertEq(susds.allowance(address(almProxy), CURVE_POOL), 0);
        assertEq(usdt.allowance(address(almProxy),  CURVE_POOL), 0);

        assertEq(susds.balanceOf(address(almProxy)), susdsAmount);
        assertEq(usdt.balanceOf(address(almProxy)),  1_000_000e6);

        vm.prank(relayer);
        uint256 lpTokensReceived = mainnetController.addLiquidityCurve(CURVE_POOL, amounts, minLpAmount);

        assertEq(curveLp.balanceOf(address(almProxy)), lpTokensReceived);

        assertEq(susds.allowance(address(almProxy), CURVE_POOL), 0);
        assertEq(usdt.allowance(address(almProxy),  CURVE_POOL), 0);

        assertEq(susds.balanceOf(address(almProxy)), 0);
        assertEq(usdt.balanceOf(address(almProxy)),  0);

        assertEq(susds.balanceOf(CURVE_POOL), susdsBalance + susdsAmount);
        assertEq(usdt.balanceOf(CURVE_POOL),  usdtBalance + 1_000_000e6);

        // Step 2: Swap USDT for sUSDS

        deal(address(usdt), address(almProxy), 100_000e6);

        uint256 minSUsdsAmount = susds.convertToShares(99_500e18);

        assertEq(susds.balanceOf(address(almProxy)), 0);
        assertEq(usdt.balanceOf(address(almProxy)),  100_000e6);

        vm.prank(relayer);
        uint256 susdsReturned = mainnetController.swapCurve(CURVE_POOL, 1, 0, 100_000e6, minSUsdsAmount);

        assertEq(susds.convertToAssets(susdsReturned), 99_996.989363188047296502e18);

        assertEq(susds.allowance(address(almProxy), CURVE_POOL), 0);
        assertEq(usdt.allowance(address(almProxy),  CURVE_POOL), 0);

        assertEq(susds.balanceOf(address(almProxy)), susdsReturned);
        assertEq(usdt.balanceOf(address(almProxy)),  0);

        // Step 3: Swap USDT for sUSDS again (ensure no issue with approval)

        deal(address(usdt), address(almProxy), 100_000e6);

        minSUsdsAmount = susds.convertToShares(99_500e18);

        assertEq(susds.balanceOf(address(almProxy)), susdsReturned);
        assertEq(usdt.balanceOf(address(almProxy)),  100_000e6);

        vm.prank(relayer);
        susdsReturned += mainnetController.swapCurve(CURVE_POOL, 1, 0, 100_000e6, minSUsdsAmount);

        assertEq(susds.convertToAssets(susdsReturned), 199_992.859585323329126373e18);

        assertEq(susds.allowance(address(almProxy), CURVE_POOL), 0);
        assertEq(usdt.allowance(address(almProxy),  CURVE_POOL), 0);

        assertEq(susds.balanceOf(address(almProxy)), susdsReturned);  // Incremented
        assertEq(usdt.balanceOf(address(almProxy)),  0);

        // Step 4: Swap sUSDS for USDT

        uint256 susdsSwapAmount = susds.convertToShares(100_000e18);

        deal(address(susds), address(almProxy), susdsSwapAmount);  // NOTE: Overwrites balance

        assertEq(susds.balanceOf(address(almProxy)), susdsSwapAmount);
        assertEq(usdt.balanceOf(address(almProxy)),  0);

        vm.prank(relayer);
        uint256 usdtReturned = mainnetController.swapCurve(CURVE_POOL, 0, 1, susdsSwapAmount, 99_500e6);

        assertEq(usdtReturned, 99_999.026465e6);

        assertEq(susds.allowance(address(almProxy), CURVE_POOL), 0);
        assertEq(usdt.allowance(address(almProxy),  CURVE_POOL), 0);

        assertEq(susds.balanceOf(address(almProxy)), 0);
        assertEq(usdt.balanceOf(address(almProxy)),  usdtReturned);

        // Step 5: Remove liquidity

        uint256[] memory minWithdrawAmounts = new uint256[](2);
        minWithdrawAmounts[0] = susds.convertToShares(900_000e18);
        minWithdrawAmounts[1] = 1_090_000e6;

        vm.prank(relayer);
        uint256[] memory assetsReceived = mainnetController.removeLiquidityCurve(
            CURVE_POOL,
            lpTokensReceived,
            minWithdrawAmounts
        );

        assertEq(susds.convertToAssets(assetsReceived[0]), 900_005.135097519857743801e18);
        assertEq(assetsReceived[1],                        1_099_999.173746e6);

        assertEq(
            susds.convertToAssets(assetsReceived[0]) + assetsReceived[1] * 1e12,
            2_000_004.308843519857743801e18
        );

        assertEq(susds.balanceOf(address(almProxy)), assetsReceived[0]);
        assertEq(usdt.balanceOf(address(almProxy)),  assetsReceived[1] + usdtReturned);

        assertEq(curveLp.balanceOf(address(almProxy)), 0);
    }

}
