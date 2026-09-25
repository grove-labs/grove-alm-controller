// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { ForeignController } from "../../../src/ForeignController.sol";
import { MainnetController } from "../../../src/MainnetController.sol";
import { MidnightLib }       from "../../../src/libraries/MidnightLib.sol";
import { UniswapV3Lib }      from "../../../src/libraries/UniswapV3Lib.sol";

import { MAX_TICK as MIDNIGHT_MAX_TICK } from "../../../src/libraries/midnight/MidnightTickLib.sol";

import { MockDaiUsds } from "../mocks/MockDaiUsds.sol";
import { MockPSM }     from "../mocks/MockPSM.sol";
import { MockVault }   from "../mocks/MockVault.sol";

import "../UnitTestBase.t.sol";

contract MainnetControllerAdminTestBase is UnitTestBase {

    event LayerZeroRecipientSet(uint32 indexed destinationDomain, bytes32 layerZeroRecipient);
    event MaxSlippageSet(address indexed pool, uint256 maxSlippage);
    event MintRecipientSet(uint32 indexed destinationDomain, bytes32 mintRecipient);
    event UniswapV3PoolMaxTickDeltaSet(address indexed pool, uint24 maxTickDelta);
    event UniswapV3PoolLowerTickUpdated(address indexed pool, int24 lowerTick);
    event UniswapV3PoolUpperTickUpdated(address indexed pool, int24 upperTick);
    event UniswapV3PoolTwapSecondsAgoUpdated(address indexed pool, uint32 twapSecondsAgo);

    bytes32 layerZeroRecipient1 = bytes32(uint256(uint160(makeAddr("layerZeroRecipient1"))));
    bytes32 layerZeroRecipient2 = bytes32(uint256(uint160(makeAddr("layerZeroRecipient2"))));
    bytes32 mintRecipient1      = bytes32(uint256(uint160(makeAddr("mintRecipient1"))));
    bytes32 mintRecipient2      = bytes32(uint256(uint160(makeAddr("mintRecipient2"))));

    MainnetController mainnetController;

    function setUp() public {
        MockDaiUsds daiUsds = new MockDaiUsds(makeAddr("dai"));
        MockPSM     psm     = new MockPSM(makeAddr("usdc"));
        MockVault   vault   = new MockVault(makeAddr("buffer"));

        mainnetController = new MainnetController(
            admin,
            makeAddr("almProxy"),
            makeAddr("rateLimits"),
            address(vault),
            address(psm),
            address(daiUsds),
            makeAddr("cctp"),
            makeAddr("uniswapV3Router"),
            makeAddr("uniswapV3PositionManager")
        );
    }

}

contract MainnetControllerSetMintRecipientTests is MainnetControllerAdminTestBase {

    function test_setMintRecipient_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setMintRecipient(1, mintRecipient1);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setMintRecipient(1, mintRecipient1);
    }

    function test_setMintRecipient() public {
        assertEq(mainnetController.mintRecipients(1), bytes32(0));
        assertEq(mainnetController.mintRecipients(2), bytes32(0));

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit MintRecipientSet(1, mintRecipient1);
        mainnetController.setMintRecipient(1, mintRecipient1);

        assertEq(mainnetController.mintRecipients(1), mintRecipient1);

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit MintRecipientSet(2, mintRecipient2);
        mainnetController.setMintRecipient(2, mintRecipient2);

        assertEq(mainnetController.mintRecipients(2), mintRecipient2);

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit MintRecipientSet(1, mintRecipient2);
        mainnetController.setMintRecipient(1, mintRecipient2);

        assertEq(mainnetController.mintRecipients(1), mintRecipient2);
    }

}

contract MainnetControllerSetCentrifugeRecipientTests is MainnetControllerAdminTestBase {

    event CentrifugeRecipientSet(uint16 indexed centrifugeId, bytes32 recipient);

    function test_setCentrifugeRecipient_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setCentrifugeRecipient(1, bytes32(uint256(1)));
    }

    function test_setCentrifugeRecipient_zeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert("MC/zero-recipient");
        mainnetController.setCentrifugeRecipient(1, bytes32(0));
    }

    function test_setCentrifugeRecipient() public {
        assertEq(mainnetController.centrifugeRecipients(1), bytes32(0));

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit CentrifugeRecipientSet(1, bytes32(uint256(1)));
        mainnetController.setCentrifugeRecipient(1, bytes32(uint256(1)));

        assertEq(mainnetController.centrifugeRecipients(1), bytes32(uint256(1)));
    }

}

contract MainnetControllerSetLayerZeroRecipientTests is MainnetControllerAdminTestBase {

    function test_setLayerZeroRecipient_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setLayerZeroRecipient(1, layerZeroRecipient1);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setMintRecipient(1, mintRecipient1);
    }

    function test_setLayerZeroRecipient() public {
        assertEq(mainnetController.layerZeroRecipients(1), bytes32(0));
        assertEq(mainnetController.layerZeroRecipients(2), bytes32(0));

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit LayerZeroRecipientSet(1, layerZeroRecipient1);
        mainnetController.setLayerZeroRecipient(1, layerZeroRecipient1);

        assertEq(mainnetController.layerZeroRecipients(1), layerZeroRecipient1);

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit LayerZeroRecipientSet(2, layerZeroRecipient2);
        mainnetController.setLayerZeroRecipient(2, layerZeroRecipient2);

        assertEq(mainnetController.layerZeroRecipients(2), layerZeroRecipient2);

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit LayerZeroRecipientSet(1, layerZeroRecipient2);
        mainnetController.setLayerZeroRecipient(1, layerZeroRecipient2);

        assertEq(mainnetController.layerZeroRecipients(1), layerZeroRecipient2);
    }

}

contract MainnetControllerSetMaxSlippageTests is MainnetControllerAdminTestBase {

    function test_setMaxSlippage_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setMaxSlippage(makeAddr("pool"), 0.01e18);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setMaxSlippage(makeAddr("pool"), 0.01e18);
    }

    function test_setMaxSlippage() public {
        address pool = makeAddr("pool");

        assertEq(mainnetController.maxSlippages(pool), 0);

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit MaxSlippageSet(pool, 0.01e18);
        mainnetController.setMaxSlippage(pool, 0.01e18);

        assertEq(mainnetController.maxSlippages(pool), 0.01e18);

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit MaxSlippageSet(pool, 0.02e18);
        mainnetController.setMaxSlippage(pool, 0.02e18);

        assertEq(mainnetController.maxSlippages(pool), 0.02e18);
    }

    function test_setMaxSlippage_outOfBounds() public {
        vm.prank(admin);
        vm.expectRevert("MC/max-slippage-oob");
        mainnetController.setMaxSlippage(makeAddr("pool"), 1e18 + 1);
    }
}

contract MainnetControllerSetUniswapV3PoolMaxTickDeltaTests is MainnetControllerAdminTestBase {

    function test_setUniswapV3PoolMaxTickDelta_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setUniswapV3PoolMaxTickDelta(makeAddr("pool"), 1000);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setUniswapV3PoolMaxTickDelta(makeAddr("pool"), 1000);
    }

    function test_setUniswapV3PoolMaxTickDelta_zeroMaxTickDelta() public {
        vm.prank(admin);
        vm.expectRevert("MC/max-tick-delta-oob");
        mainnetController.setUniswapV3PoolMaxTickDelta(makeAddr("pool"), 0);
    }

    function test_setUniswapV3PoolMaxTickDelta_exceedsMaxTickDelta() public {
        vm.prank(admin);
        vm.expectRevert("MC/max-tick-delta-oob");
        mainnetController.setUniswapV3PoolMaxTickDelta(makeAddr("pool"), 887273); // MAX_TICK_DELTA + 1
    }

    function test_setUniswapV3PoolMaxTickDelta() public {
        address pool = makeAddr("pool");

        ( uint24 maxTickDelta,, ) = mainnetController.uniswapV3PoolParams(pool);
        assertEq(maxTickDelta, 0);

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit UniswapV3PoolMaxTickDeltaSet(pool, 1000);
        mainnetController.setUniswapV3PoolMaxTickDelta(pool, 1000);

        ( maxTickDelta,, ) = mainnetController.uniswapV3PoolParams(pool);
        assertEq(maxTickDelta, 1000);

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit UniswapV3PoolMaxTickDeltaSet(pool, 887272); // MAX_TICK_DELTA
        mainnetController.setUniswapV3PoolMaxTickDelta(pool, 887272);

        ( maxTickDelta,, ) = mainnetController.uniswapV3PoolParams(pool);
        assertEq(maxTickDelta, 887272);
    }

}

contract MainnetControllerSetUniswapV3AddLiquidityLowerTickBoundTests is MainnetControllerAdminTestBase {

    function test_setUniswapV3AddLiquidityLowerTickBound_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setUniswapV3AddLiquidityLowerTickBound(makeAddr("pool"), -1000);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setUniswapV3AddLiquidityLowerTickBound(makeAddr("pool"), -1000);
    }

    function test_setUniswapV3AddLiquidityLowerTickBound_belowMinTick() public {
        vm.prank(admin);
        vm.expectRevert("MC/lower-tick-oob");
        mainnetController.setUniswapV3AddLiquidityLowerTickBound(makeAddr("pool"), -887273); // MIN_TICK - 1
    }

    function test_setUniswapV3AddLiquidityLowerTickBound_atOrAboveUpperTick() public {
        address pool = makeAddr("pool");

        // First set an upper tick bound
        vm.prank(admin);
        mainnetController.setUniswapV3AddLiquidityUpperTickBound(pool, 1000);

        // Try to set lower tick at or above the upper tick
        vm.prank(admin);
        vm.expectRevert("MC/lower-tick-oob");
        mainnetController.setUniswapV3AddLiquidityLowerTickBound(pool, 1000);

        vm.prank(admin);
        vm.expectRevert("MC/lower-tick-oob");
        mainnetController.setUniswapV3AddLiquidityLowerTickBound(pool, 1001);
    }

    function test_setUniswapV3AddLiquidityLowerTickBound() public {
        address pool = makeAddr("pool");

        // First set an upper tick bound so we have room to set lower
        vm.prank(admin);
        mainnetController.setUniswapV3AddLiquidityUpperTickBound(pool, 5000);

        (, UniswapV3Lib.Tick memory tickBounds, ) = mainnetController.uniswapV3PoolParams(pool);
        assertEq(tickBounds.lower, 0);
        assertEq(tickBounds.upper, 5000);

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit UniswapV3PoolLowerTickUpdated(pool, -1000);
        mainnetController.setUniswapV3AddLiquidityLowerTickBound(pool, -1000);

        (, tickBounds, ) = mainnetController.uniswapV3PoolParams(pool);
        assertEq(tickBounds.lower, -1000);

        // Can set at MIN_TICK
        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit UniswapV3PoolLowerTickUpdated(pool, -887272);
        mainnetController.setUniswapV3AddLiquidityLowerTickBound(pool, -887272);

        (, tickBounds, ) = mainnetController.uniswapV3PoolParams(pool);
        assertEq(tickBounds.lower, -887272);
    }

}

contract MainnetControllerSetUniswapV3AddLiquidityUpperTickBoundTests is MainnetControllerAdminTestBase {

    function test_setUniswapV3AddLiquidityUpperTickBound_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setUniswapV3AddLiquidityUpperTickBound(makeAddr("pool"), 1000);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setUniswapV3AddLiquidityUpperTickBound(makeAddr("pool"), 1000);
    }

    function test_setUniswapV3AddLiquidityUpperTickBound_aboveMaxTick() public {
        vm.prank(admin);
        vm.expectRevert("MC/upper-tick-oob");
        mainnetController.setUniswapV3AddLiquidityUpperTickBound(makeAddr("pool"), 887273); // MAX_TICK + 1
    }

    function test_setUniswapV3AddLiquidityUpperTickBound_atOrBelowLowerTick() public {
        address pool = makeAddr("pool");

        // First set a lower tick bound
        vm.prank(admin);
        mainnetController.setUniswapV3AddLiquidityUpperTickBound(pool, 2000);
        vm.prank(admin);
        mainnetController.setUniswapV3AddLiquidityLowerTickBound(pool, 1000);

        // Try to set upper tick at or below the lower tick
        vm.prank(admin);
        vm.expectRevert("MC/upper-tick-oob");
        mainnetController.setUniswapV3AddLiquidityUpperTickBound(pool, 1000);

        vm.prank(admin);
        vm.expectRevert("MC/upper-tick-oob");
        mainnetController.setUniswapV3AddLiquidityUpperTickBound(pool, 999);
    }

    function test_setUniswapV3AddLiquidityUpperTickBound() public {
        address pool = makeAddr("pool");

        (, UniswapV3Lib.Tick memory tickBounds, ) = mainnetController.uniswapV3PoolParams(pool);
        assertEq(tickBounds.lower, 0);
        assertEq(tickBounds.upper, 0);

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit UniswapV3PoolUpperTickUpdated(pool, 1000);
        mainnetController.setUniswapV3AddLiquidityUpperTickBound(pool, 1000);

        (, tickBounds, ) = mainnetController.uniswapV3PoolParams(pool);
        assertEq(tickBounds.lower, 0);
        assertEq(tickBounds.upper, 1000);

        // Can set at MAX_TICK
        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit UniswapV3PoolUpperTickUpdated(pool, 887272);
        mainnetController.setUniswapV3AddLiquidityUpperTickBound(pool, 887272);

        (, tickBounds, ) = mainnetController.uniswapV3PoolParams(pool);
        assertEq(tickBounds.upper, 887272);
    }

}

contract MainnetControllerSetUniswapV3TwapSecondsAgoTests is MainnetControllerAdminTestBase {

    function test_setUniswapV3TwapSecondsAgo_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setUniswapV3TwapSecondsAgo(makeAddr("pool"), 300);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        mainnetController.setUniswapV3TwapSecondsAgo(makeAddr("pool"), 300);
    }

    function test_setUniswapV3TwapSecondsAgo_outOfBounds() public {
        vm.startPrank(admin);

        vm.expectRevert("MC/twap-seconds-ago-oob");
        mainnetController.setUniswapV3TwapSecondsAgo(makeAddr("pool"), uint32(type(int32).max));

        vm.expectRevert("MC/twap-seconds-ago-oob");
        mainnetController.setUniswapV3TwapSecondsAgo(makeAddr("pool"), type(uint32).max);

        vm.stopPrank();
    }

    function test_setUniswapV3TwapSecondsAgo() public {
        address pool = makeAddr("pool");

        (,, uint32 twapSecondsAgo ) = mainnetController.uniswapV3PoolParams(pool);
        assertEq(twapSecondsAgo, 0);

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit UniswapV3PoolTwapSecondsAgoUpdated(pool, 300);
        mainnetController.setUniswapV3TwapSecondsAgo(pool, 300);

        (,, twapSecondsAgo ) = mainnetController.uniswapV3PoolParams(pool);
        assertEq(twapSecondsAgo, 300);

        vm.prank(admin);
        vm.expectEmit(address(mainnetController));
        emit UniswapV3PoolTwapSecondsAgoUpdated(pool, 1800);
        mainnetController.setUniswapV3TwapSecondsAgo(pool, 1800);

        (,, twapSecondsAgo ) = mainnetController.uniswapV3PoolParams(pool);
        assertEq(twapSecondsAgo, 1800);
    }

}

contract ForeignControllerAdminTestBase is UnitTestBase {

    event MaxAaveV4DeficitSet(address indexed hub, uint16 indexed assetId, uint256 maxDeficit);
    event MaxAaveV4SlippageSet(address indexed spoke, uint256 indexed reserveId, uint256 maxSlippage);
    event MaxSlippageSet(address indexed pool, uint256 maxSlippage);
    event LayerZeroRecipientSet(uint32 indexed destinationDomain, bytes32 layerZeroRecipient);
    event MintRecipientSet(uint32 indexed destinationDomain, bytes32 mintRecipient);
    event UniswapV3PoolMaxTickDeltaSet(address indexed pool, uint24 maxTickDelta);
    event UniswapV3PoolLowerTickUpdated(address indexed pool, int24 lowerTick);
    event UniswapV3PoolUpperTickUpdated(address indexed pool, int24 upperTick);
    event UniswapV3PoolTwapSecondsAgoUpdated(address indexed pool, uint32 twapSecondsAgo);

    ForeignController foreignController;

    bytes32 layerZeroRecipient1 = bytes32(uint256(uint160(makeAddr("layerZeroRecipient1"))));
    bytes32 layerZeroRecipient2 = bytes32(uint256(uint160(makeAddr("layerZeroRecipient2"))));
    bytes32 mintRecipient1      = bytes32(uint256(uint160(makeAddr("mintRecipient1"))));
    bytes32 mintRecipient2      = bytes32(uint256(uint160(makeAddr("mintRecipient2"))));

    function setUp() public virtual {
        foreignController = new ForeignController(
            admin,
            makeAddr("almProxy"),
            makeAddr("rateLimits"),
            makeAddr("psm"),
            makeAddr("usdc"),
            makeAddr("cctp"),
            makeAddr("pendleRouter"),
            makeAddr("uniswapV3Router"),
            makeAddr("uniswapV3PositionManager"),
            makeAddr("midnight")
        );
    }
}

contract ForeignControllerSetMintRecipientTests is ForeignControllerAdminTestBase {

    function test_setMintRecipient_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setMintRecipient(1, mintRecipient1);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setMintRecipient(1, mintRecipient1);
    }

    function test_setMintRecipient() public {
        assertEq(foreignController.mintRecipients(1), bytes32(0));
        assertEq(foreignController.mintRecipients(2), bytes32(0));

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit MintRecipientSet(1, mintRecipient1);
        foreignController.setMintRecipient(1, mintRecipient1);

        assertEq(foreignController.mintRecipients(1), mintRecipient1);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit MintRecipientSet(2, mintRecipient2);
        foreignController.setMintRecipient(2, mintRecipient2);

        assertEq(foreignController.mintRecipients(2), mintRecipient2);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit MintRecipientSet(1, mintRecipient2);
        foreignController.setMintRecipient(1, mintRecipient2);

        assertEq(foreignController.mintRecipients(1), mintRecipient2);
    }
}

contract ForeignControllerSetCentrifugeRecipientTests is ForeignControllerAdminTestBase {

    event CentrifugeRecipientSet(uint16 indexed centrifugeId, bytes32 recipient);

    function test_setCentrifugeRecipient_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setCentrifugeRecipient(1, bytes32(uint256(1)));
    }

    function test_setCentrifugeRecipient_zeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert("FC/zero-recipient");
        foreignController.setCentrifugeRecipient(1, bytes32(0));
    }

    function test_setCentrifugeRecipient() public {
        assertEq(foreignController.centrifugeRecipients(1), bytes32(0));

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit CentrifugeRecipientSet(1, bytes32(uint256(1)));
        foreignController.setCentrifugeRecipient(1, bytes32(uint256(1)));

        assertEq(foreignController.centrifugeRecipients(1), bytes32(uint256(1)));
    }

}

contract ForeignControllerSetLayerZeroRecipientTests is ForeignControllerAdminTestBase {

    function test_setLayerZeroRecipient_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setLayerZeroRecipient(1, layerZeroRecipient1);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setLayerZeroRecipient(1, layerZeroRecipient1);
    }

    function test_setLayerZeroRecipient() public {
        assertEq(foreignController.layerZeroRecipients(1), bytes32(0));
        assertEq(foreignController.layerZeroRecipients(2), bytes32(0));

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit LayerZeroRecipientSet(1, layerZeroRecipient1);
        foreignController.setLayerZeroRecipient(1, layerZeroRecipient1);

        assertEq(foreignController.layerZeroRecipients(1), layerZeroRecipient1);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit LayerZeroRecipientSet(2, layerZeroRecipient2);
        foreignController.setLayerZeroRecipient(2, layerZeroRecipient2);

        assertEq(foreignController.layerZeroRecipients(2), layerZeroRecipient2);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit LayerZeroRecipientSet(1, layerZeroRecipient2);
        foreignController.setLayerZeroRecipient(1, layerZeroRecipient2);

        assertEq(foreignController.layerZeroRecipients(1), layerZeroRecipient2);
    }

}

contract ForeignControllerSetMaxSlippageTests is ForeignControllerAdminTestBase {

    function test_setMaxSlippage_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setMaxSlippage(makeAddr("pool"), 0.01e18);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setMaxSlippage(makeAddr("pool"), 0.01e18);
    }

    function test_setMaxSlippage() public {
        address pool = makeAddr("pool");

        assertEq(foreignController.maxSlippages(pool), 0);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit MaxSlippageSet(pool, 0.01e18);
        foreignController.setMaxSlippage(pool, 0.01e18);

        assertEq(foreignController.maxSlippages(pool), 0.01e18);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit MaxSlippageSet(pool, 0.02e18);
        foreignController.setMaxSlippage(pool, 0.02e18);

        assertEq(foreignController.maxSlippages(pool), 0.02e18);
    }

    function test_setMaxSlippage_outOfBounds() public {
        vm.prank(admin);
        vm.expectRevert("FC/max-slippage-oob");
        foreignController.setMaxSlippage(makeAddr("pool"), 1e18 + 1);
    }
}

contract ForeignControllerSetMaxAaveV4SlippageTests is ForeignControllerAdminTestBase {

    function test_setMaxAaveV4Slippage_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setMaxAaveV4Slippage(makeAddr("spoke"), 1, 0.01e18);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setMaxAaveV4Slippage(makeAddr("spoke"), 1, 0.01e18);
    }

    // Each reserve on a spoke carries its own tolerance, unlike the shared maxSlippages mapping.
    function test_setMaxAaveV4Slippage() public {
        address spoke      = makeAddr("spoke");
        address otherSpoke = makeAddr("otherSpoke");

        assertEq(foreignController.maxAaveV4Slippages(spoke, 1), 0);
        assertEq(foreignController.maxAaveV4Slippages(spoke, 2), 0);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit MaxAaveV4SlippageSet(spoke, 1, 0.01e18);
        foreignController.setMaxAaveV4Slippage(spoke, 1, 0.01e18);

        assertEq(foreignController.maxAaveV4Slippages(spoke, 1), 0.01e18);
        assertEq(foreignController.maxAaveV4Slippages(spoke, 2), 0);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit MaxAaveV4SlippageSet(spoke, 2, 0.02e18);
        foreignController.setMaxAaveV4Slippage(spoke, 2, 0.02e18);

        assertEq(foreignController.maxAaveV4Slippages(spoke, 1), 0.01e18);
        assertEq(foreignController.maxAaveV4Slippages(spoke, 2), 0.02e18);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit MaxAaveV4SlippageSet(spoke, 1, 1e18);
        foreignController.setMaxAaveV4Slippage(spoke, 1, 1e18);

        assertEq(foreignController.maxAaveV4Slippages(spoke, 1), 1e18);

        // The same reserveId on another spoke is a different market.
        assertEq(foreignController.maxAaveV4Slippages(otherSpoke, 1), 0);

        vm.prank(admin);
        foreignController.setMaxAaveV4Slippage(otherSpoke, 1, 0.5e18);

        assertEq(foreignController.maxAaveV4Slippages(otherSpoke, 1), 0.5e18);
        assertEq(foreignController.maxAaveV4Slippages(spoke,      1), 1e18);
    }

    function test_setMaxAaveV4Slippage_outOfBounds() public {
        vm.prank(admin);
        vm.expectRevert("FC/max-slippage-oob");
        foreignController.setMaxAaveV4Slippage(makeAddr("spoke"), 1, 1e18 + 1);
    }
}

contract ForeignControllerSetMaxAaveV4DeficitTests is ForeignControllerAdminTestBase {

    // RAY-denominated in the asset's own units, so this is $1,000 of a 6-decimal asset.
    uint256 constant TOLERANCE = 1_000e6 * 1e27;

    address hub      = makeAddr("hub");
    address otherHub = makeAddr("otherHub");

    function test_setMaxAaveV4Deficit_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setMaxAaveV4Deficit(hub, 2, TOLERANCE);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setMaxAaveV4Deficit(hub, 2, TOLERANCE);
    }

    // The tolerance is scoped to one asset on one Hub: neither another asset on the same Hub nor the
    // same asset id on another Hub inherits it.
    function test_setMaxAaveV4Deficit() public {
        assertEq(foreignController.maxAaveV4Deficits(hub,      2), 0);
        assertEq(foreignController.maxAaveV4Deficits(hub,      3), 0);
        assertEq(foreignController.maxAaveV4Deficits(otherHub, 2), 0);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit MaxAaveV4DeficitSet(hub, 2, TOLERANCE);
        foreignController.setMaxAaveV4Deficit(hub, 2, TOLERANCE);

        assertEq(foreignController.maxAaveV4Deficits(hub,      2), TOLERANCE);
        assertEq(foreignController.maxAaveV4Deficits(hub,      3), 0);
        assertEq(foreignController.maxAaveV4Deficits(otherHub, 2), 0);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit MaxAaveV4DeficitSet(hub, 2, 0);
        foreignController.setMaxAaveV4Deficit(hub, 2, 0);

        assertEq(foreignController.maxAaveV4Deficits(hub, 2), 0);
    }
}

contract ForeignControllerSetUniswapV3PoolMaxTickDeltaTests is ForeignControllerAdminTestBase {

    function test_setUniswapV3PoolMaxTickDelta_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setUniswapV3PoolMaxTickDelta(makeAddr("pool"), 1000);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setUniswapV3PoolMaxTickDelta(makeAddr("pool"), 1000);
    }

    function test_setUniswapV3PoolMaxTickDelta_zeroMaxTickDelta() public {
        vm.prank(admin);
        vm.expectRevert("FC/max-tick-delta-oob");
        foreignController.setUniswapV3PoolMaxTickDelta(makeAddr("pool"), 0);
    }

    function test_setUniswapV3PoolMaxTickDelta_exceedsMaxTickDelta() public {
        vm.prank(admin);
        vm.expectRevert("FC/max-tick-delta-oob");
        foreignController.setUniswapV3PoolMaxTickDelta(makeAddr("pool"), 887273); // MAX_TICK_DELTA + 1
    }

    function test_setUniswapV3PoolMaxTickDelta() public {
        address pool = makeAddr("pool");

        ( uint24 maxTickDelta,, ) = foreignController.uniswapV3PoolParams(pool);
        assertEq(uint256(maxTickDelta), 0);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit UniswapV3PoolMaxTickDeltaSet(pool, 1000);
        foreignController.setUniswapV3PoolMaxTickDelta(pool, 1000);

        ( maxTickDelta,, ) = foreignController.uniswapV3PoolParams(pool);
        assertEq(uint256(maxTickDelta), 1000);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit UniswapV3PoolMaxTickDeltaSet(pool, 887272); // MAX_TICK_DELTA
        foreignController.setUniswapV3PoolMaxTickDelta(pool, 887272);

        ( maxTickDelta,, ) = foreignController.uniswapV3PoolParams(pool);
        assertEq(uint256(maxTickDelta), 887272);
    }

}

contract ForeignControllerSetUniswapV3AddLiquidityLowerTickBoundTests is ForeignControllerAdminTestBase {

    function test_setUniswapV3AddLiquidityLowerTickBound_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setUniswapV3AddLiquidityLowerTickBound(makeAddr("pool"), -1000);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setUniswapV3AddLiquidityLowerTickBound(makeAddr("pool"), -1000);
    }

    function test_setUniswapV3AddLiquidityLowerTickBound_belowMinTick() public {
        vm.prank(admin);
        vm.expectRevert("FC/lower-tick-oob");
        foreignController.setUniswapV3AddLiquidityLowerTickBound(makeAddr("pool"), -887273); // MIN_TICK - 1
    }

    function test_setUniswapV3AddLiquidityLowerTickBound_atOrAboveUpperTick() public {
        address pool = makeAddr("pool");

        // First set an upper tick bound
        vm.prank(admin);
        foreignController.setUniswapV3AddLiquidityUpperTickBound(pool, 1000);

        // Try to set lower tick at or above the upper tick
        vm.prank(admin);
        vm.expectRevert("FC/lower-tick-oob");
        foreignController.setUniswapV3AddLiquidityLowerTickBound(pool, 1000);

        vm.prank(admin);
        vm.expectRevert("FC/lower-tick-oob");
        foreignController.setUniswapV3AddLiquidityLowerTickBound(pool, 1001);
    }

    function test_setUniswapV3AddLiquidityLowerTickBound() public {
        address pool = makeAddr("pool");

        // First set an upper tick bound so we have room to set lower
        vm.prank(admin);
        foreignController.setUniswapV3AddLiquidityUpperTickBound(pool, 5000);

        (, UniswapV3Lib.Tick memory tickBounds, ) = foreignController.uniswapV3PoolParams(pool);
        assertEq(tickBounds.lower, 0);
        assertEq(tickBounds.upper, 5000);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit UniswapV3PoolLowerTickUpdated(pool, -1000);
        foreignController.setUniswapV3AddLiquidityLowerTickBound(pool, -1000);

        (, tickBounds, ) = foreignController.uniswapV3PoolParams(pool);
        assertEq(tickBounds.lower, -1000);

        // Can set at MIN_TICK
        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit UniswapV3PoolLowerTickUpdated(pool, -887272);
        foreignController.setUniswapV3AddLiquidityLowerTickBound(pool, -887272);

        (, tickBounds, ) = foreignController.uniswapV3PoolParams(pool);
        assertEq(tickBounds.lower, -887272);
    }

}

contract ForeignControllerSetUniswapV3AddLiquidityUpperTickBoundTests is ForeignControllerAdminTestBase {

    function test_setUniswapV3AddLiquidityUpperTickBound_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setUniswapV3AddLiquidityUpperTickBound(makeAddr("pool"), 1000);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setUniswapV3AddLiquidityUpperTickBound(makeAddr("pool"), 1000);
    }

    function test_setUniswapV3AddLiquidityUpperTickBound_aboveMaxTick() public {
        vm.prank(admin);
        vm.expectRevert("FC/upper-tick-oob");
        foreignController.setUniswapV3AddLiquidityUpperTickBound(makeAddr("pool"), 887273); // MAX_TICK + 1
    }

    function test_setUniswapV3AddLiquidityUpperTickBound_atOrBelowLowerTick() public {
        address pool = makeAddr("pool");

        // First set a lower tick bound
        vm.prank(admin);
        foreignController.setUniswapV3AddLiquidityUpperTickBound(pool, 2000);
        vm.prank(admin);
        foreignController.setUniswapV3AddLiquidityLowerTickBound(pool, 1000);

        // Try to set upper tick at or below the lower tick
        vm.prank(admin);
        vm.expectRevert("FC/upper-tick-oob");
        foreignController.setUniswapV3AddLiquidityUpperTickBound(pool, 1000);

        vm.prank(admin);
        vm.expectRevert("FC/upper-tick-oob");
        foreignController.setUniswapV3AddLiquidityUpperTickBound(pool, 999);
    }

    function test_setUniswapV3AddLiquidityUpperTickBound() public {
        address pool = makeAddr("pool");

        (, UniswapV3Lib.Tick memory tickBounds, ) = foreignController.uniswapV3PoolParams(pool);
        assertEq(tickBounds.lower, 0);
        assertEq(tickBounds.upper, 0);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit UniswapV3PoolUpperTickUpdated(pool, 1000);
        foreignController.setUniswapV3AddLiquidityUpperTickBound(pool, 1000);

        (, tickBounds, ) = foreignController.uniswapV3PoolParams(pool);
        assertEq(tickBounds.lower, 0);
        assertEq(tickBounds.upper, 1000);

        // Can set at MAX_TICK
        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit UniswapV3PoolUpperTickUpdated(pool, 887272);
        foreignController.setUniswapV3AddLiquidityUpperTickBound(pool, 887272);

        (, tickBounds, ) = foreignController.uniswapV3PoolParams(pool);
        assertEq(tickBounds.upper, 887272);
    }

}

contract ForeignControllerSetUniswapV3TwapSecondsAgoTests is ForeignControllerAdminTestBase {

    function test_setUniswapV3TwapSecondsAgo_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setUniswapV3TwapSecondsAgo(makeAddr("pool"), 300);

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setUniswapV3TwapSecondsAgo(makeAddr("pool"), 300);
    }

    function test_setUniswapV3TwapSecondsAgo_outOfBounds() public {
        vm.startPrank(admin);

        vm.expectRevert("FC/twap-seconds-ago-oob");
        foreignController.setUniswapV3TwapSecondsAgo(makeAddr("pool"), uint32(type(int32).max));

        vm.expectRevert("FC/twap-seconds-ago-oob");
        foreignController.setUniswapV3TwapSecondsAgo(makeAddr("pool"), type(uint32).max);

        vm.stopPrank();
    }

    function test_setUniswapV3TwapSecondsAgo() public {
        address pool = makeAddr("pool");

        (,, uint32 twapSecondsAgo ) = foreignController.uniswapV3PoolParams(pool);
        assertEq(twapSecondsAgo, 0);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit UniswapV3PoolTwapSecondsAgoUpdated(pool, 300);
        foreignController.setUniswapV3TwapSecondsAgo(pool, 300);

        (,, twapSecondsAgo ) = foreignController.uniswapV3PoolParams(pool);
        assertEq(twapSecondsAgo, 300);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit UniswapV3PoolTwapSecondsAgoUpdated(pool, 1800);
        foreignController.setUniswapV3TwapSecondsAgo(pool, 1800);

        (,, twapSecondsAgo ) = foreignController.uniswapV3PoolParams(pool);
        assertEq(twapSecondsAgo, 1800);
    }

}

contract ForeignControllerSetMidnightMarketConfigTests is ForeignControllerAdminTestBase {

    event MidnightMarketConfigSet(
        bytes32 indexed marketId,
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  minBuyYield,
        uint16  maxSellYield,
        uint16  maxContinuousFee,
        uint128 maxLossFactor
    );

    // Midnight's own ceiling, as the annual rate the config now speaks in: percent_bp_cbp.
    uint16 constant MAX_CONTINUOUS_FEE_CBP = 1_00_00;

    uint16 constant MIN_BUY_YIELD  = 1_00;
    uint16 constant MAX_SELL_YIELD = 10_00;

    bytes32 marketId = keccak256("market");

    function _config(uint16 maxBuyTick, uint16 minSellTick, uint16 maxContinuousFee)
        internal pure returns (MidnightLib.MarketConfig memory)
    {
        return _config(maxBuyTick, minSellTick, maxContinuousFee, 0);
    }

    function _config(
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  maxContinuousFee,
        uint128 maxLossFactor
    )
        internal pure returns (MidnightLib.MarketConfig memory)
    {
        return _config(
            maxBuyTick, minSellTick, MIN_BUY_YIELD, MAX_SELL_YIELD, maxContinuousFee, maxLossFactor
        );
    }

    function _config(
        uint16  maxBuyTick,
        uint16  minSellTick,
        uint16  minBuyYield,
        uint16  maxSellYield,
        uint16  maxContinuousFee,
        uint128 maxLossFactor
    )
        internal pure returns (MidnightLib.MarketConfig memory)
    {
        return MidnightLib.MarketConfig({
            maxBuyTick       : maxBuyTick,
            minSellTick      : minSellTick,
            minBuyYield      : minBuyYield,
            maxSellYield     : maxSellYield,
            maxContinuousFee : maxContinuousFee,
            maxLossFactor    : maxLossFactor
        });
    }

    function test_setMidnightMarketConfig_unauthorizedAccount() public {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setMidnightMarketConfig(marketId, _config(4000, 3000, 0));

        vm.prank(freezer);
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            freezer,
            DEFAULT_ADMIN_ROLE
        ));
        foreignController.setMidnightMarketConfig(marketId, _config(4000, 3000, 0));
    }

    function test_setMidnightMarketConfig_maxBuyTickOutOfBounds() public {
        vm.prank(admin);
        vm.expectRevert("MidnightLib/max-buy-tick-oob");
        foreignController.setMidnightMarketConfig(
            marketId,
            _config(uint16(MIDNIGHT_MAX_TICK + 1), 3000, 0)
        );
    }

    function test_setMidnightMarketConfig_minSellTickOutOfBounds() public {
        vm.startPrank(admin);

        vm.expectRevert("MidnightLib/min-sell-tick-oob");
        foreignController.setMidnightMarketConfig(marketId, _config(4000, 0, 0));

        vm.expectRevert("MidnightLib/min-sell-tick-oob");
        foreignController.setMidnightMarketConfig(
            marketId,
            _config(4000, uint16(MIDNIGHT_MAX_TICK + 1), 0)
        );

        vm.stopPrank();
    }

    function test_setMidnightMarketConfig_maxContinuousFeeOutOfBounds() public {
        vm.prank(admin);
        vm.expectRevert("MidnightLib/max-continuous-fee-oob");
        foreignController.setMidnightMarketConfig(
            marketId,
            _config(4000, 3000, MAX_CONTINUOUS_FEE_CBP + 1)
        );

        assertEq(
            MidnightLib.continuousFeePerSecond(MAX_CONTINUOUS_FEE_CBP),
            MidnightLib.MAX_CONTINUOUS_FEE
        );

        vm.prank(admin);
        foreignController.setMidnightMarketConfig(
            marketId,
            _config(4000, 3000, MAX_CONTINUOUS_FEE_CBP)
        );
    }

    function test_setMidnightMarketConfig_maxSellYieldNotSet() public {
        vm.prank(admin);
        vm.expectRevert("MidnightLib/max-sell-yield-not-set");
        foreignController.setMidnightMarketConfig(
            marketId,
            _config(4000, 3000, MIN_BUY_YIELD, 0, MAX_CONTINUOUS_FEE_CBP, 0)
        );
    }

    function test_setMidnightMarketConfig() public {
        (
            uint16  maxBuyTick,
            uint16  minSellTick,
            uint16  minBuyYield,
            uint16  maxSellYield,
            uint16  maxContinuousFee,
            uint128 maxLossFactor
        ) = foreignController.midnightMarketConfigs(marketId);

        assertEq(maxBuyTick,       0);
        assertEq(minSellTick,      0);
        assertEq(minBuyYield,      0);
        assertEq(maxSellYield,     0);
        assertEq(maxContinuousFee, 0);
        assertEq(maxLossFactor,    0);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit MidnightMarketConfigSet(marketId, 4000, 3000, MIN_BUY_YIELD, MAX_SELL_YIELD, 100, 1e18);
        foreignController.setMidnightMarketConfig(marketId, _config(4000, 3000, 100, 1e18));

        ( maxBuyTick, minSellTick, minBuyYield, maxSellYield, maxContinuousFee, maxLossFactor )
            = foreignController.midnightMarketConfigs(marketId);

        assertEq(maxBuyTick,       4000);
        assertEq(minSellTick,      3000);
        assertEq(minBuyYield,      MIN_BUY_YIELD);
        assertEq(maxSellYield,     MAX_SELL_YIELD);
        assertEq(maxContinuousFee, 100);
        assertEq(maxLossFactor,    1e18);

        ( maxBuyTick, minSellTick, minBuyYield, maxSellYield, maxContinuousFee, maxLossFactor )
            = foreignController.midnightMarketConfigs(keccak256("otherMarket"));

        assertEq(maxBuyTick,       0);
        assertEq(minSellTick,      0);
        assertEq(minBuyYield,      0);
        assertEq(maxSellYield,     0);
        assertEq(maxContinuousFee, 0);
        assertEq(maxLossFactor,    0);

        vm.prank(admin);
        vm.expectEmit(address(foreignController));
        emit MidnightMarketConfigSet(
            marketId,
            0,
            uint16(MIDNIGHT_MAX_TICK),
            0,
            type(uint16).max,
            MAX_CONTINUOUS_FEE_CBP,
            type(uint128).max
        );
        foreignController.setMidnightMarketConfig(
            marketId,
            _config(
                0,
                uint16(MIDNIGHT_MAX_TICK),
                0,
                type(uint16).max,
                MAX_CONTINUOUS_FEE_CBP,
                type(uint128).max
            )
        );

        ( maxBuyTick, minSellTick, minBuyYield, maxSellYield, maxContinuousFee, maxLossFactor )
            = foreignController.midnightMarketConfigs(marketId);

        assertEq(maxBuyTick,       0);
        assertEq(minSellTick,      MIDNIGHT_MAX_TICK);
        assertEq(minBuyYield,      0);
        assertEq(maxSellYield,     type(uint16).max);
        assertEq(maxContinuousFee, MAX_CONTINUOUS_FEE_CBP);
        assertEq(maxLossFactor,    type(uint128).max);
    }

}
