// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { IPendleMarket, ISY } from "../../src/interfaces/PendleInterfaces.sol";

import "./ForkTestBase.t.sol";

contract PendleTestBase is ForkTestBase {

    // sUSDe 25 Sep 2025 market
    IPendleMarket constant pendleMarket = IPendleMarket(0xA36b60A14A1A5247912584768C6e53E1a269a9F7);

    address PT_WHALE = 0x8C0824fFccBE9A3CDda4c3d409A0b7447320F364;

    bytes32 redeemKey;

    function setUp() public virtual override {
        super.setUp();

        redeemKey = RateLimitHelpers.makeAssetKey(
            mainnetController.LIMIT_PENDLE_PT_REDEEM(),
            address(pendleMarket)
        );

        vm.startPrank(GROVE_PROXY);
        rateLimits.setRateLimitData(redeemKey, 10_000_000e18, uint256(10_000_000e18) / 1 days);
        vm.stopPrank();
    }

    function _getBlock() internal pure override returns (uint256) {
        return 23319550;  // 8 Sep 2025
    }

}

contract MainnetControllerRedeemSuccessPendleTests is PendleTestBase {

    function test_redeemPendlePT() public {
        (address sy, address pt,) = pendleMarket.readTokens();
        IERC20 yieldToken = IERC20(ISY(sy).yieldToken());

        vm.startPrank(PT_WHALE);
        IERC20(pt).transfer((address(almProxy)), 1_000_000e18);
        vm.stopPrank();

        console.log('isExpired ', pendleMarket.isExpired());
        console.log('exchangeRate ', ISY(sy).exchangeRate());

        vm.warp(block.timestamp + 1 days);
        console.log('isExpired ', pendleMarket.isExpired());
        console.log('exchangeRate ', ISY(sy).exchangeRate());

        vm.warp(block.timestamp + 1 days);
        console.log('isExpired ', pendleMarket.isExpired());
        console.log('exchangeRate ', ISY(sy).exchangeRate());

        vm.warp(block.timestamp + 1 days);

        console.log('isExpired ', pendleMarket.isExpired());
        console.log('exchangeRate ', ISY(sy).exchangeRate());

        vm.warp(block.timestamp + 180 days);

        console.log('isExpired ', pendleMarket.isExpired());
        console.log('exchangeRate ', ISY(sy).exchangeRate());

        console.log('        pt', IERC20(pt).balanceOf((address(almProxy))));
        console.log('yieldToken', yieldToken.balanceOf((address(almProxy))));

        console.log('isExpired ', pendleMarket.isExpired());
        console.log('exchangeRate ', ISY(sy).exchangeRate());

        vm.prank(relayer);
        mainnetController.redeemPendlePT(address(pendleMarket), 500_000e18);

        console.log('        pt', IERC20(pt).balanceOf((address(almProxy))));
        console.log('yieldToken', yieldToken.balanceOf((address(almProxy))));

        console.log('isExpired ', pendleMarket.isExpired());
        console.log('exchangeRate ', ISY(sy).exchangeRate());

        vm.warp(block.timestamp + 18 days);
        vm.prank(relayer);
        mainnetController.redeemPendlePT(address(pendleMarket), 500_000e18);

        console.log('        pt', IERC20(pt).balanceOf((address(almProxy))));
        console.log('yieldToken', yieldToken.balanceOf((address(almProxy))));

        console.log('isExpired ', pendleMarket.isExpired());
        console.log('exchangeRate ', ISY(sy).exchangeRate());
    }

}
