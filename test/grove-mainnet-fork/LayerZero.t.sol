// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";

import { ERC20Mock } from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

// import { Base } from "grove-address-registry/Base.sol";

import { PSM3Deploy }       from "spark-psm/deploy/PSM3Deploy.sol";
import { IPSM3 }            from "spark-psm/src/PSM3.sol";
import { MockRateProvider } from "spark-psm/test/mocks/MockRateProvider.sol";

// import { CCTPBridgeTesting } from "xchain-helpers/testing/bridges/CCTPBridgeTesting.sol";
// import { CCTPForwarder }     from "xchain-helpers/forwarders/CCTPForwarder.sol";

import {LZBridgeTesting} from "xchain-helpers/testing/bridges/LZBridgeTesting.sol";
import {LZForwarder} from "xchain-helpers/forwarders/LZForwarder.sol";

import { ForeignControllerDeploy } from "../../deploy/ControllerDeploy.sol";
import { ControllerInstance }      from "../../deploy/ControllerInstance.sol";

import { ForeignControllerInit } from "../../deploy/ForeignControllerInit.sol";

import { ALMProxy }          from "../../src/ALMProxy.sol";
import { ForeignController } from "../../src/ForeignController.sol";
import { RateLimits }        from "../../src/RateLimits.sol";
import { RateLimitHelpers }  from "../../src/RateLimitHelpers.sol";

import "./ForkTestBase.t.sol";

// TODO: Figure out finalized structure for this repo/testing structure wise
contract PlasmaChainUSDTToLayerZeroTestBase is ForkTestBase {
    using DomainHelpers for *;

    /**********************************************************************************************/
    /*** Constants/state variables                                                              ***/
    /**********************************************************************************************/

    address pocket = makeAddr("pocket");

    /**********************************************************************************************/
    /*** Plasma addresses                                                                     ***/
    /**********************************************************************************************/
    
    // TODO revisit
    address constant CCTP_MESSENGER_ARB = address(0xDeadBeef);
    address constant SPARK_EXECUTOR     = address(0xDeadBeef);
    address constant SSR_ORACLE         = address(0xDeadBeef);
    
    // Plasma OUpgradeable USDT OFT
    address constant USDT_OFT           = 0x02ca37966753bDdDf11216B73B16C1dE756A7CF9;
    // Plasma USDT0
    address constant USDT0              = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    /**********************************************************************************************/
    /*** ALM system deployments                                                                 ***/
    /**********************************************************************************************/

    ALMProxy          foreignAlmProxy;
    RateLimits        foreignRateLimits;
    ForeignController foreignController;

    /**********************************************************************************************/
    /*** Casted addresses for testing                                                           ***/
    /**********************************************************************************************/
    IERC20 usdsPlasma;
    IERC20 susdsPlasma;
    IERC20 usdt0Plasma;
    IPSM3 psmPlasma;

    uint256 USDT0_PLASMA_SUPPLY;

    uint32 constant destinationEndpointId = 30383;  // Plasma EID

    function setUp() public override virtual {
        super.setUp();

        /*** Step 1: Set up environment and deploy mocks ***/

        destination = getChain(1).createSelectFork(23591129);  // Oct 16, 2025

        usdsPlasma  = IERC20(address(new ERC20Mock()));
        susdsPlasma = IERC20(address(new ERC20Mock()));
        usdt0Plasma = IERC20(USDT0);

        /*** Step 2: Deploy and configure PSM with a pocket ***/

        psmPlasma = IPSM3(PSM3Deploy.deploy(
            SPARK_EXECUTOR, address(usdt0Plasma), address(usdsPlasma), address(susdsPlasma), SSR_ORACLE
        ));

        vm.prank(SPARK_EXECUTOR);
        psmPlasma.setPocket(pocket);

        vm.prank(pocket);
        usdt0Plasma.approve(address(psmPlasma), type(uint256).max);

        /*** Step 3: Deploy and configure ALM system ***/

        ControllerInstance memory controllerInst = ForeignControllerDeploy.deployFull({
            admin : SPARK_EXECUTOR,
            psm   : address(psmPlasma),
            usdc  : address(usdt0Plasma),
            cctp  : CCTP_MESSENGER_ARB
        });

        foreignAlmProxy   = ALMProxy(payable(controllerInst.almProxy));
        foreignRateLimits = RateLimits(controllerInst.rateLimits);
        foreignController = ForeignController(controllerInst.controller);

        address[] memory relayers = new address[](1);
        relayers[0] = relayer;

        ForeignControllerInit.ConfigAddressParams memory configAddresses = ForeignControllerInit.ConfigAddressParams({
            freezer       : freezer,
            relayers      : relayers,
            oldController : address(0)
        });

        ForeignControllerInit.CheckAddressParams memory checkAddresses = ForeignControllerInit.CheckAddressParams({
            admin : SPARK_EXECUTOR,
            psm   : address(psmPlasma),
            cctp  : CCTP_MESSENGER_ARB,
            usdc  : address(usdt0Plasma)
        });

        ForeignControllerInit.MintRecipient[] memory mintRecipients = new ForeignControllerInit.MintRecipient[](1);

        mintRecipients[0] = ForeignControllerInit.MintRecipient({
            domain        : CCTPForwarder.DOMAIN_ID_CIRCLE_ETHEREUM,
            mintRecipient : bytes32(uint256(uint160(address(almProxy))))
        });

        ForeignControllerInit.LayerZeroRecipient[] memory layerZeroRecipients = new ForeignControllerInit.LayerZeroRecipient[](0);

        ForeignControllerInit.CentrifugeRecipient[] memory centrifugeRecipients = new ForeignControllerInit.CentrifugeRecipient[](0);

        USDT0_PLASMA_SUPPLY = usdt0Plasma.totalSupply();

        vm.startPrank(SPARK_EXECUTOR);

        ForeignControllerInit.initAlmSystem(
            controllerInst,
            configAddresses,
            checkAddresses,
            mintRecipients,
            layerZeroRecipients,
            centrifugeRecipients
        );

        vm.stopPrank();
    }

}

contract USDTToLayerZeroIntegrationTests is PlasmaChainUSDTToLayerZeroTestBase {
    using DomainHelpers     for *;
    using LZBridgeTesting for Bridge;

    // event CCTPTransferInitiated(
    //     uint64  indexed nonce,
    //     uint32  indexed destinationDomain,
    //     bytes32 indexed mintRecipient,
    //     uint256 usdcAmount
    // );

    // event DepositForBurn(
    //     uint64  indexed nonce,
    //     address indexed burnToken,
    //     uint256 amount,
    //     address indexed depositor,
    //     bytes32 mintRecipient,
    //     uint32  destinationDomain,
    //     bytes32 destinationTokenMessenger,
    //     bytes32 destinationCaller
    // );

    function test_transferUSDTToLZ_sourceToDestination() external {
        deal(address(usdt), address(almProxy), 1e6);

        assertEq(usdt.balanceOf(address(almProxy)),          1e6);
        assertEq(usdt.balanceOf(address(mainnetController)), 0);
        assertEq(usdt.totalSupply(),                         USDT_SUPPLY);

        // assertEq(usds.allowance(address(almProxy), CCTP_MESSENGER),  0);

        // _expectEthereumCCTPEmit(114_803, 1e6);

        vm.prank(relayer);
        mainnetController.transferTokenLayerZero(address(usdt), 1e6, CCTPForwarder.DOMAIN_ID_CIRCLE_BASE);

        assertEq(usdc.balanceOf(address(almProxy)),          0);
        assertEq(usdc.balanceOf(address(mainnetController)), 0);
        assertEq(usdc.totalSupply(),                         USDT_SUPPLY - 1e6);

        assertEq(usds.allowance(address(almProxy), CCTP_MESSENGER),  0);

        destination.selectFork();

        assertEq(usdt0Plasma.balanceOf(address(foreignAlmProxy)),   0);
        assertEq(usdt0Plasma.balanceOf(address(foreignController)), 0);
        assertEq(usdt0Plasma.totalSupply(),                         USDT0_PLASMA_SUPPLY);

        bridge.relayMessagesToDestination(true, address(almProxy), address(foreignAlmProxy));

        assertEq(usdt0Plasma.balanceOf(address(foreignAlmProxy)),   1e6);
        assertEq(usdt0Plasma.balanceOf(address(foreignController)), 0);
        assertEq(usdt0Plasma.totalSupply(),                         USDT0_PLASMA_SUPPLY + 1e6);
    }

    // function test_transferUSDTToLZ_sourceToDestination_bigTransfer() external {
    //     deal(address(usdc), address(almProxy), 2_900_000e6);

    //     assertEq(usdc.balanceOf(address(almProxy)),          2_900_000e6);
    //     assertEq(usdc.balanceOf(address(mainnetController)), 0);
    //     assertEq(usdc.totalSupply(),                         USDT_SUPPLY);

    //     assertEq(usds.allowance(address(almProxy), CCTP_MESSENGER),  0);

    //     // Will split into 3 separate transactions at max 1m each
    //     // _expectEthereumCCTPEmit(114_803, 1_000_000e6);
    //     // _expectEthereumCCTPEmit(114_804, 1_000_000e6);
    //     // _expectEthereumCCTPEmit(114_805, 900_000e6);

    //     vm.prank(relayer);
    //     mainnetController.transferUSDCToCCTP(2_900_000e6, CCTPForwarder.DOMAIN_ID_CIRCLE_BASE);

    //     assertEq(usdc.balanceOf(address(almProxy)),          0);
    //     assertEq(usdc.balanceOf(address(mainnetController)), 0);
    //     assertEq(usdc.totalSupply(),                         USDT_SUPPLY - 2_900_000e6);

    //     assertEq(usds.allowance(address(almProxy), CCTP_MESSENGER),  0);

    //     destination.selectFork();

    //     assertEq(usdcBase.balanceOf(address(foreignAlmProxy)),   0);
    //     assertEq(usdcBase.balanceOf(address(foreignController)), 0);
    //     assertEq(usdcBase.totalSupply(),                         USDC_BASE_SUPPLY);

    //     bridge.relayMessagesToDestination(true);

    //     assertEq(usdcBase.balanceOf(address(foreignAlmProxy)),   2_900_000e6);
    //     assertEq(usdcBase.balanceOf(address(foreignController)), 0);
    //     assertEq(usdcBase.totalSupply(),                         USDC_BASE_SUPPLY + 2_900_000e6);
    // }

    // function test_transferUSDTToLZ_sourceToDestination_rateLimited() external {
    //     bytes32 key = mainnetController.LIMIT_USDC_TO_CCTP();
    //     deal(address(usdc), address(almProxy), 9_000_000e6);

    //     vm.startPrank(relayer);

    //     assertEq(usdc.balanceOf(address(almProxy)),   9_000_000e6);
    //     assertEq(rateLimits.getCurrentRateLimit(key), 5_000_000e6);

    //     mainnetController.transferUSDCToCCTP(2_000_000e6, CCTPForwarder.DOMAIN_ID_CIRCLE_BASE);

    //     assertEq(usdc.balanceOf(address(almProxy)),   7_000_000e6);
    //     assertEq(rateLimits.getCurrentRateLimit(key), 3_000_000e6);

    //     vm.expectRevert("RateLimits/rate-limit-exceeded");
    //     mainnetController.transferUSDCToCCTP(3_000_001e6, CCTPForwarder.DOMAIN_ID_CIRCLE_BASE);

    //     mainnetController.transferUSDCToCCTP(3_000_000e6, CCTPForwarder.DOMAIN_ID_CIRCLE_BASE);

    //     assertEq(usdc.balanceOf(address(almProxy)),   4_000_000e6);
    //     assertEq(rateLimits.getCurrentRateLimit(key), 0);

    //     skip(4 hours);

    //     assertEq(usdc.balanceOf(address(almProxy)),   4_000_000e6);
    //     assertEq(rateLimits.getCurrentRateLimit(key), 999_999.9936e6);

    //     mainnetController.transferUSDCToCCTP(999_999.9936e6, CCTPForwarder.DOMAIN_ID_CIRCLE_BASE);

    //     assertEq(usdc.balanceOf(address(almProxy)),   3_000_000.0064e6);
    //     assertEq(rateLimits.getCurrentRateLimit(key), 0);

    //     vm.stopPrank();
    // }

    // function test_transferUSDTToLZ_destinationToSource() external {
    //     destination.selectFork();

    //     deal(address(usdcBase), address(foreignAlmProxy), 1e6);

    //     assertEq(usdcBase.balanceOf(address(foreignAlmProxy)),   1e6);
    //     assertEq(usdcBase.balanceOf(address(foreignController)), 0);
    //     assertEq(usdcBase.totalSupply(),                         USDC_BASE_SUPPLY);

    //     assertEq(usdsBase.allowance(address(foreignAlmProxy), CCTP_MESSENGER_BASE),  0);

    //     // _expectBaseCCTPEmit(296_114, 1e6);

    //     vm.prank(relayer);
    //     foreignController.transferUSDCToCCTP(1e6, CCTPForwarder.DOMAIN_ID_CIRCLE_ETHEREUM);

    //     assertEq(usdcBase.balanceOf(address(foreignAlmProxy)),   0);
    //     assertEq(usdcBase.balanceOf(address(foreignController)), 0);
    //     assertEq(usdcBase.totalSupply(),                         USDC_BASE_SUPPLY - 1e6);

    //     assertEq(usdsBase.allowance(address(foreignAlmProxy), CCTP_MESSENGER_BASE),  0);

    //     source.selectFork();

    //     assertEq(usdc.balanceOf(address(almProxy)),          0);
    //     assertEq(usdc.balanceOf(address(mainnetController)), 0);
    //     assertEq(usdc.totalSupply(),                         USDT_SUPPLY);

    //     bridge.relayMessagesToSource(true);

    //     assertEq(usdc.balanceOf(address(almProxy)),          1e6);
    //     assertEq(usdc.balanceOf(address(mainnetController)), 0);
    //     assertEq(usdc.totalSupply(),                         USDT_SUPPLY + 1e6);
    // }

    // function test_transferUSDTToLZ_destinationToSource_bigTransfer() external {
    //     destination.selectFork();

    //     deal(address(usdcBase), address(foreignAlmProxy), 2_600_000e6);

    //     assertEq(usdcBase.balanceOf(address(foreignAlmProxy)),   2_600_000e6);
    //     assertEq(usdcBase.balanceOf(address(foreignController)), 0);
    //     assertEq(usdcBase.totalSupply(),                         USDC_BASE_SUPPLY);

    //     assertEq(usdsBase.allowance(address(foreignAlmProxy), CCTP_MESSENGER_BASE),  0);

    //     // Will split into three separate transactions at max 1m each
    //     // _expectBaseCCTPEmit(296_114, 1_000_000e6);
    //     // _expectBaseCCTPEmit(296_115, 1_000_000e6);
    //     // _expectBaseCCTPEmit(296_116, 600_000e6);

    //     vm.prank(relayer);
    //     foreignController.transferUSDCToCCTP(2_600_000e6, CCTPForwarder.DOMAIN_ID_CIRCLE_ETHEREUM);

    //     assertEq(usdcBase.balanceOf(address(foreignAlmProxy)),   0);
    //     assertEq(usdcBase.balanceOf(address(foreignController)), 0);
    //     assertEq(usdcBase.totalSupply(),                         USDC_BASE_SUPPLY - 2_600_000e6);

    //     assertEq(usdsBase.allowance(address(foreignAlmProxy), CCTP_MESSENGER_BASE),  0);

    //     source.selectFork();

    //     assertEq(usdc.balanceOf(address(almProxy)),          0);
    //     assertEq(usdc.balanceOf(address(mainnetController)), 0);
    //     assertEq(usdc.totalSupply(),                         USDT_SUPPLY);

    //     bridge.relayMessagesToSource(true);

    //     assertEq(usdc.balanceOf(address(almProxy)),          2_600_000e6);
    //     assertEq(usdc.balanceOf(address(mainnetController)), 0);
    //     assertEq(usdc.totalSupply(),                         USDT_SUPPLY + 2_600_000e6);
    // }

    // function test_transferUSDTToLZ_destinationToSource_rateLimited() external {
    //     destination.selectFork();

    //     bytes32 key = foreignController.LIMIT_USDC_TO_CCTP();
    //     deal(address(usdcBase), address(foreignAlmProxy), 9_000_000e6);

    //     vm.startPrank(relayer);

    //     assertEq(usdcBase.balanceOf(address(foreignAlmProxy)), 9_000_000e6);
    //     assertEq(foreignRateLimits.getCurrentRateLimit(key),   5_000_000e6);

    //     foreignController.transferUSDCToCCTP(2_000_000e6, CCTPForwarder.DOMAIN_ID_CIRCLE_ETHEREUM);

    //     assertEq(usdcBase.balanceOf(address(foreignAlmProxy)), 7_000_000e6);
    //     assertEq(foreignRateLimits.getCurrentRateLimit(key),   3_000_000e6);

    //     vm.expectRevert("RateLimits/rate-limit-exceeded");
    //     foreignController.transferUSDCToCCTP(3_000_001e6, CCTPForwarder.DOMAIN_ID_CIRCLE_ETHEREUM);

    //     foreignController.transferUSDCToCCTP(3_000_000e6, CCTPForwarder.DOMAIN_ID_CIRCLE_ETHEREUM);

    //     assertEq(usdcBase.balanceOf(address(foreignAlmProxy)), 4_000_000e6);
    //     assertEq(foreignRateLimits.getCurrentRateLimit(key),   0);

    //     skip(4 hours);

    //     assertEq(usdcBase.balanceOf(address(foreignAlmProxy)), 4_000_000e6);
    //     assertEq(foreignRateLimits.getCurrentRateLimit(key),   999_999.9936e6);

    //     foreignController.transferUSDCToCCTP(999_999.9936e6, CCTPForwarder.DOMAIN_ID_CIRCLE_ETHEREUM);

    //     assertEq(usdcBase.balanceOf(address(foreignAlmProxy)), 3_000_000.0064e6);
    //     assertEq(foreignRateLimits.getCurrentRateLimit(key),   0);

    //     vm.stopPrank();
    // }

    // function _expectEthereumCCTPEmit(uint64 nonce, uint256 amount) internal {
    //     // NOTE: Focusing on burnToken, amount, depositor, mintRecipient, and destinationDomain
    //     //       for assertions
    //     vm.expectEmit(CCTP_MESSENGER);
    //     emit DepositForBurn(
    //         nonce,
    //         address(usdc),
    //         amount,
    //         address(almProxy),
    //         mainnetController.mintRecipients(CCTPForwarder.DOMAIN_ID_CIRCLE_BASE),
    //         CCTPForwarder.DOMAIN_ID_CIRCLE_BASE,
    //         bytes32(0x0000000000000000000000001682ae6375c4e4a97e4b583bc394c861a46d8962),
    //         bytes32(0x0000000000000000000000000000000000000000000000000000000000000000)
    //     );

    //     vm.expectEmit(address(mainnetController));
    //     emit CCTPTransferInitiated(
    //         nonce,
    //         CCTPForwarder.DOMAIN_ID_CIRCLE_BASE,
    //         mainnetController.mintRecipients(CCTPForwarder.DOMAIN_ID_CIRCLE_BASE),
    //         amount
    //     );
    // }

    // function _expectBaseCCTPEmit(uint64 nonce, uint256 amount) internal {
    //     // NOTE: Focusing on burnToken, amount, depositor, mintRecipient, and destinationDomain
    //     //       for assertions
    //     vm.expectEmit(CCTP_MESSENGER_BASE);
    //     emit DepositForBurn(
    //         nonce,
    //         address(usdcBase),
    //         amount,
    //         address(foreignAlmProxy),
    //         foreignController.mintRecipients(CCTPForwarder.DOMAIN_ID_CIRCLE_ETHEREUM),
    //         CCTPForwarder.DOMAIN_ID_CIRCLE_ETHEREUM,
    //         bytes32(0x000000000000000000000000bd3fa81b58ba92a82136038b25adec7066af3155),
    //         bytes32(0x0000000000000000000000000000000000000000000000000000000000000000)
    //     );

    //     vm.expectEmit(address(foreignController));
    //     emit CCTPTransferInitiated(
    //         nonce,
    //         CCTPForwarder.DOMAIN_ID_CIRCLE_ETHEREUM,
    //         foreignController.mintRecipients(CCTPForwarder.DOMAIN_ID_CIRCLE_ETHEREUM),
    //         amount
    //     );
    // }

}
