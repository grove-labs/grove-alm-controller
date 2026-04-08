// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import {Avalanche} from "grove-address-registry/Avalanche.sol";

import {PSM3Deploy} from "spark-psm/deploy/PSM3Deploy.sol";
import {IPSM3} from "spark-psm/src/PSM3.sol";
import {MockRateProvider} from "spark-psm/test/mocks/MockRateProvider.sol";
import {IRateProviderLike} from "spark-psm/src/interfaces/IRateProviderLike.sol";

import {LZBridgeTesting} from "xchain-helpers/testing/bridges/LZBridgeTesting.sol";
import {LZForwarder} from "xchain-helpers/forwarders/LZForwarder.sol";

import {ForeignControllerDeploy} from "../../deploy/ControllerDeploy.sol";
import {ControllerInstance} from "../../deploy/ControllerInstance.sol";

import {ForeignControllerInit} from "../../deploy/ForeignControllerInit.sol";

import {ALMProxy} from "../../src/ALMProxy.sol";
import {ForeignController} from "../../src/ForeignController.sol";
import {RateLimits} from "../../src/RateLimits.sol";
import {RateLimitHelpers} from "../../src/RateLimitHelpers.sol";

import "./ForkTestBase.t.sol";

contract AvalancheChainUSDeToLayerZeroTestBase is ForkTestBase {
    using DomainHelpers for *;
    using LZBridgeTesting for Bridge;

    /**********************************************************************************************/
    /*** Constants/state variables                                                              ***/
    /**********************************************************************************************/

    address pocket = makeAddr("pocket");

    /**********************************************************************************************/
    /*** Avalanche addresses                                                                    ***/
    /**********************************************************************************************/

    // USDe OFT on Avalanche (ENAOFT - the OFT IS the token on Avalanche)
    address constant USDE_OFT_AVALANCHE_ADDRESS = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;

    /**********************************************************************************************/
    /*** ALM system deployments                                                                 ***/
    /**********************************************************************************************/

    ALMProxy          foreignAlmProxy;
    RateLimits        foreignRateLimits;
    ForeignController foreignController;

    /**********************************************************************************************/
    /*** Casted addresses for testing                                                           ***/
    /**********************************************************************************************/

    // Mainnet OFTs
    IERC20 usdeOft;

    // Avalanche Tokens
    IERC20 usdsAvalanche;
    IERC20 susdsAvalanche;
    IERC20 usdeAvalanche;

    IPSM3 psmAvalanche;

    uint256 USDE_AVALANCHE_SUPPLY;
    uint256 USDE_MAINNET_BALANCE_BEFORE;

    uint32 constant sourceEndpointId      = 30101; // Ethereum EID
    uint32 constant destinationEndpointId = 30106; // Avalanche EID

    bytes32 sourceRateLimitKey;
    bytes32 destinationRateLimitKey;

    function setUp() public virtual override {
        super.setUp();

        /**
         * Step 1: Set up environment and deploy mocks **
         */
        destination = getChain("avalanche").createSelectFork(_getDestinationBlock());

        usdsAvalanche  = IERC20(address(new ERC20Mock()));
        susdsAvalanche = IERC20(address(new ERC20Mock()));
        usdeAvalanche  = IERC20(USDE_OFT_AVALANCHE_ADDRESS);

        USDE_AVALANCHE_SUPPLY = usdeAvalanche.totalSupply();

        /**
         * Step 2: Deploy and configure PSM with a pocket **
         */
        MockRateProvider mockRateProvider = new MockRateProvider();
        mockRateProvider.__setConversionRate(1.25e27);

        IRateProviderLike rateProvider = IRateProviderLike(address(mockRateProvider));

        deal(address(usdsAvalanche), address(this), 1e18); // For seeding PSM during deployment

        psmAvalanche = IPSM3(
            PSM3Deploy.deploy(
                Avalanche.GROVE_EXECUTOR,
                address(usdeAvalanche),
                address(usdsAvalanche),
                address(susdsAvalanche),
                address(rateProvider)
            )
        );

        vm.prank(Avalanche.GROVE_EXECUTOR);
        psmAvalanche.setPocket(pocket);

        vm.prank(pocket);
        usdeAvalanche.approve(address(psmAvalanche), type(uint256).max);

        /**
         * Step 3: Deploy and configure ALM system **
         */
        ControllerInstance memory controllerInst = ForeignControllerDeploy.deployFull({
            admin                    : Avalanche.GROVE_EXECUTOR,
            psm                      : address(psmAvalanche),
            usdc                     : address(usdeAvalanche),
            cctp                     : address(0xDeadBeef), // unused
            pendleRouter             : address(0xDeadBeef), // unused
            uniswapV3Router          : address(0xDeadBeef), // unused
            uniswapV3PositionManager : address(0xDeadBeef)  // unused
        });

        foreignAlmProxy   = ALMProxy(payable(controllerInst.almProxy));
        foreignRateLimits = RateLimits(controllerInst.rateLimits);
        foreignController = ForeignController(controllerInst.controller);

        deal(address(foreignController), 100 ether); // LZ gas costs

        address[] memory relayers = new address[](1);
        relayers[0] = relayer;

        ForeignControllerInit.ConfigAddressParams memory configAddresses =
            ForeignControllerInit.ConfigAddressParams({freezer: freezer, relayers: relayers, oldController: address(0)});

        ForeignControllerInit.CheckAddressParams memory checkAddresses = ForeignControllerInit.CheckAddressParams({
            admin                    : Avalanche.GROVE_EXECUTOR,
            psm                      : address(psmAvalanche),
            cctp                     : address(0xDeadBeef), // unused
            usdc                     : address(usdeAvalanche),
            pendleRouter             : address(0xDeadBeef), // unused
            uniswapV3Router          : address(0xDeadBeef), // unused
            uniswapV3PositionManager : address(0xDeadBeef)  // unused
        });

        ForeignControllerInit.MintRecipient[] memory mintRecipients = new ForeignControllerInit.MintRecipient[](1);

        mintRecipients[0] = ForeignControllerInit.MintRecipient({
            domain:        CCTPForwarder.DOMAIN_ID_CIRCLE_ETHEREUM,
            mintRecipient: bytes32(uint256(uint160(address(almProxy))))
        });

        ForeignControllerInit.LayerZeroRecipient[] memory layerZeroRecipients =
            new ForeignControllerInit.LayerZeroRecipient[](1);
        layerZeroRecipients[0] = ForeignControllerInit.LayerZeroRecipient({
            destinationEndpointId: LZForwarder.ENDPOINT_ID_ETHEREUM,
            recipient:             bytes32(uint256(uint160(address(almProxy))))
        });

        ForeignControllerInit.CentrifugeRecipient[] memory centrifugeRecipients =
            new ForeignControllerInit.CentrifugeRecipient[](0);

        vm.startPrank(Avalanche.GROVE_EXECUTOR);

        ForeignControllerInit.initAlmSystem(
            controllerInst, configAddresses, checkAddresses, mintRecipients, layerZeroRecipients, centrifugeRecipients
        );

        destinationRateLimitKey =
            keccak256(abi.encode(foreignController.LIMIT_LAYERZERO_TRANSFER(), usdeAvalanche, sourceEndpointId));

        uint256 usdeAvalancheMaxAmount = 5_000_000e18;
        uint256 usdeAvalancheSlope     = uint256(1_000_000e18) / 4 hours;

        foreignRateLimits.setRateLimitData(destinationRateLimitKey, usdeAvalancheMaxAmount, usdeAvalancheSlope);
        vm.stopPrank();

        /**
         * Step 4: Set up mainnet **
         */
        source.selectFork();

        usdeOft = IERC20(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34);

        // Gas cost for LZ
        deal(address(mainnetController), 1 ether);

        bridge = LZBridgeTesting.createLZBridge(source, destination);

        vm.startPrank(Ethereum.GROVE_PROXY);
        sourceRateLimitKey =
            keccak256(abi.encode(mainnetController.LIMIT_LAYERZERO_TRANSFER(), usdeOft, destinationEndpointId));
        uint256 usdeMaxAmount = 5_000_000e18;
        uint256 usdeSlope     = uint256(1_000_000e18) / 4 hours;

        rateLimits.setRateLimitData(sourceRateLimitKey, usdeMaxAmount, usdeSlope);

        // Add foreign ALM Proxy as recipient
        mainnetController.setLayerZeroRecipient(
            destinationEndpointId, bytes32(uint256(uint160(address(foreignAlmProxy))))
        );

        USDE_MAINNET_BALANCE_BEFORE = usde.balanceOf(address(usdeOft));

        vm.stopPrank();

        /**
         * Step 5: Label addresses **
         */
        _labelAddresses();
    }

    function _getDestinationBlock() internal pure returns (uint256) {
        return 82400000; // April 2026
    }

    function _labelAddresses() internal {
        vm.label(address(usdsAvalanche),            "usdsAvalanche");
        vm.label(address(susdsAvalanche),          "susdsAvalanche");
        vm.label(address(usdeAvalanche),            "usdeAvalanche");
        vm.label(address(usdeOft),                       "usdeOft");
        vm.label(address(usde),                             "usde");
        vm.label(address(mainnetController),   "mainnetController");
        vm.label(address(foreignAlmProxy),       "foreignAlmProxy");
        vm.label(address(foreignRateLimits),   "foreignRateLimits");
        vm.label(address(foreignController),   "foreignController");
        vm.label(address(rateLimits),                 "rateLimits");
        vm.label(address(almProxy),                     "almProxy");
    }
}

contract MainnetControllerTransferUSDeToLayerZeroFailureTests is AvalancheChainUSDeToLayerZeroTestBase {
    using DomainHelpers for *;

    function test_transferUSDeToLZ_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        mainnetController.transferTokenLayerZero(address(usdeOft), 1e18, destinationEndpointId);
    }

    function test_transferUSDeToLZ_rateLimitExceeded() external {
        deal(address(usde), address(almProxy), 10_000_001e18);

        vm.prank(relayer);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        mainnetController.transferTokenLayerZero(address(usdeOft), 5_000_001e18, destinationEndpointId);
    }

    function test_transferUSDeToLZ_zeroMaxAmount() external {
        vm.prank(Ethereum.GROVE_PROXY);
        rateLimits.setRateLimitData(sourceRateLimitKey, 0, 0);

        vm.prank(relayer);
        vm.expectRevert("RateLimits/zero-maxAmount");
        mainnetController.transferTokenLayerZero(address(usdeOft), 1e18, destinationEndpointId);
    }
}

contract ForeignControllerTransferUSDeToLayerZeroFailureTests is AvalancheChainUSDeToLayerZeroTestBase {
    using DomainHelpers for *;

    function setUp() public override {
        super.setUp();
        destination.selectFork();
    }

    function test_transferUSDeToLZ_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.transferTokenLayerZero(address(usdeAvalanche), 1e18, sourceEndpointId);
    }

    function test_transferUSDeToLZ_rateLimitExceeded() external {
        deal(address(usdeAvalanche), address(foreignAlmProxy), 10_000_001e18, true);

        vm.prank(relayer);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.transferTokenLayerZero(address(usdeAvalanche), 5_000_001e18, sourceEndpointId);
    }

    function test_transferUSDeToLZ_zeroMaxAmount() external {
        vm.prank(Avalanche.GROVE_EXECUTOR);
        foreignRateLimits.setRateLimitData(destinationRateLimitKey, 0, 0);

        vm.prank(relayer);
        vm.expectRevert("RateLimits/zero-maxAmount");
        foreignController.transferTokenLayerZero(address(usdeAvalanche), 1e18, sourceEndpointId);
    }
}

contract USDeToLayerZeroIntegrationTests is AvalancheChainUSDeToLayerZeroTestBase {
    using DomainHelpers for *;
    using LZBridgeTesting for Bridge;

    event OFTSent(
        bytes32 indexed guid, uint32 dstEid, address indexed fromAddress, uint256 amountSentLD, uint256 amountReceivedLD
    );

    function test_transferUSDeToLZ_sourceToDestination() external {
        deal(address(usde), address(almProxy), 1e18);

        assertEq(usde.balanceOf(address(almProxy)), 1e18, "ALM Proxy balance should be 1e18 before transfer");
        assertEq(
            usde.balanceOf(address(mainnetController)), 0, "Mainnet Controller balance should be 0 before transfer"
        );
        assertEq(
            usde.balanceOf(address(usdeOft)), USDE_MAINNET_BALANCE_BEFORE, "OFT balance should match before transfer"
        );

        _expectEthereumOftEmit(1e18);

        vm.prank(relayer);
        mainnetController.transferTokenLayerZero(address(usdeOft), 1e18, destinationEndpointId);

        assertEq(usde.balanceOf(address(almProxy)), 0, "ALM Proxy balance should be 0 after transfer");
        assertEq(usde.balanceOf(address(mainnetController)), 0, "Mainnet Controller balance should be 0 after transfer");
        assertEq(
            usde.balanceOf(address(usdeOft)),
            USDE_MAINNET_BALANCE_BEFORE + 1e18,
            "OFT balance should be increased by 1e18 after transfer"
        );

        destination.selectFork();

        assertEq(
            usdeAvalanche.balanceOf(address(foreignAlmProxy)),
            0,
            "Foreign ALM Proxy balance should be 0 before message relay"
        );
        assertEq(
            usdeAvalanche.balanceOf(address(foreignController)),
            0,
            "Foreign Controller balance should be 0 before message relay"
        );
        assertEq(
            usdeAvalanche.totalSupply(),
            USDE_AVALANCHE_SUPPLY,
            "Total supply should be USDE_AVALANCHE_SUPPLY before message relay"
        );

        bridge.relayMessagesToDestination(true, address(usdeOft), address(usdeAvalanche));

        assertEq(
            usdeAvalanche.balanceOf(address(foreignAlmProxy)),
            1e18,
            "Foreign ALM Proxy balance should be 1e18 after message relay"
        );
        assertEq(
            usdeAvalanche.balanceOf(address(foreignController)),
            0,
            "Foreign Controller balance should be 0 after message relay"
        );
        assertEq(
            usdeAvalanche.totalSupply(),
            USDE_AVALANCHE_SUPPLY + 1e18,
            "Total supply should be increased by 1e18 after message relay"
        );
    }

    function test_transferUSDeToLZ_sourceToDestination_bigTransfer() external {
        deal(address(usde), address(almProxy), 2_900_000e18);

        assertEq(
            usde.balanceOf(address(almProxy)), 2_900_000e18, "ALM Proxy balance should be 2_900_000e18 before transfer"
        );
        assertEq(
            usde.balanceOf(address(mainnetController)), 0, "Mainnet Controller balance should be 0 before transfer"
        );
        assertEq(
            usde.balanceOf(address(usdeOft)), USDE_MAINNET_BALANCE_BEFORE, "OFT balance should match before transfer"
        );

        _expectEthereumOftEmit(2_900_000e18);

        vm.prank(relayer);
        mainnetController.transferTokenLayerZero(address(usdeOft), 2_900_000e18, destinationEndpointId);

        assertEq(usde.balanceOf(address(almProxy)), 0, "ALM Proxy balance should be 0 after transfer");
        assertEq(usde.balanceOf(address(mainnetController)), 0, "Mainnet Controller balance should be 0 after transfer");
        assertEq(
            usde.balanceOf(address(usdeOft)),
            USDE_MAINNET_BALANCE_BEFORE + 2_900_000e18,
            "OFT balance should be increased by 2_900_000e18 after transfer"
        );

        destination.selectFork();

        assertEq(
            usdeAvalanche.balanceOf(address(foreignAlmProxy)),
            0,
            "Foreign ALM Proxy balance should be 0 before message relay"
        );
        assertEq(
            usdeAvalanche.balanceOf(address(foreignController)),
            0,
            "Foreign Controller balance should be 0 before message relay"
        );
        assertEq(
            usdeAvalanche.totalSupply(),
            USDE_AVALANCHE_SUPPLY,
            "Total supply should be USDE_AVALANCHE_SUPPLY before message relay"
        );

        bridge.relayMessagesToDestination(true, address(usdeOft), address(usdeAvalanche));

        assertEq(
            usdeAvalanche.balanceOf(address(foreignAlmProxy)),
            2_900_000e18,
            "Foreign ALM Proxy balance should be 2_900_000e18 after message relay"
        );
        assertEq(
            usdeAvalanche.balanceOf(address(foreignController)),
            0,
            "Foreign Controller balance should be 0 after message relay"
        );
        assertEq(
            usdeAvalanche.totalSupply(),
            USDE_AVALANCHE_SUPPLY + 2_900_000e18,
            "Total supply should be increased by 2_900_000e18 after message relay"
        );
    }

    function test_transferUSDeToLZ_sourceToDestination_rateLimited() external {
        bytes32 key = sourceRateLimitKey;
        deal(address(usde), address(almProxy), 9_000_000e18);

        vm.startPrank(relayer);

        assertEq(
            usde.balanceOf(address(almProxy)), 9_000_000e18, "ALM Proxy balance should be 9_000_000e18 before transfer"
        );
        assertEq(rateLimits.getCurrentRateLimit(key), 5_000_000e18, "Rate limit should be 5_000_000e18 before transfer");

        mainnetController.transferTokenLayerZero(address(usdeOft), 2_000_000e18, destinationEndpointId);

        assertEq(
            usde.balanceOf(address(almProxy)), 7_000_000e18, "ALM Proxy balance should be 7_000_000e18 after transfer"
        );
        assertEq(rateLimits.getCurrentRateLimit(key), 3_000_000e18, "Rate limit should be 3_000_000e18 after transfer");

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        mainnetController.transferTokenLayerZero(address(usdeOft), 3_000_001e18, destinationEndpointId);

        mainnetController.transferTokenLayerZero(address(usdeOft), 3_000_000e18, destinationEndpointId);

        assertEq(
            usde.balanceOf(address(almProxy)), 4_000_000e18, "ALM Proxy balance should be 4_000_000e18 after transfer"
        );
        assertEq(rateLimits.getCurrentRateLimit(key), 0, "Rate limit should be 0 after transfer");

        skip(4 hours);

        assertEq(
            usde.balanceOf(address(almProxy)), 4_000_000e18, "ALM Proxy balance should be 4_000_000e18 after skipping"
        );
        assertEq(
            rateLimits.getCurrentRateLimit(key), 999_999999999999999993600, "Rate limit should replenish after skipping"
        );

        mainnetController.transferTokenLayerZero(address(usdeOft), 999_999999999999999993600, destinationEndpointId);

        // NOTE: OFT shared decimals truncation - the OFT adapter removes dust (rounds down to 1e12),
        // so 999_999_999_999_999_999_993_600 becomes 999_999_999_999_000_000_000_000 actual debit
        assertEq(
            usde.balanceOf(address(almProxy)),
            3_000_000_000_001_000_000_000_000,
            "ALM Proxy balance should decrease after transfer"
        );
        assertEq(rateLimits.getCurrentRateLimit(key), 0, "Rate limit should be 0 after transfer");

        vm.stopPrank();
    }

    function test_transferUSDeToLZ_destinationToSource() external {
        destination.selectFork();

        deal(address(usdeAvalanche), address(foreignAlmProxy), 1e18, true);

        assertEq(
            usdeAvalanche.balanceOf(address(foreignAlmProxy)),
            1e18,
            "Foreign ALM Proxy balance should be 1e18 before transfer"
        );
        assertEq(
            usdeAvalanche.balanceOf(address(foreignController)),
            0,
            "Foreign Controller balance should be 0 before transfer"
        );
        assertEq(
            usdeAvalanche.totalSupply(), USDE_AVALANCHE_SUPPLY + 1e18, "Total supply should be USDE_AVALANCHE_SUPPLY + 1e18 before transfer"
        );

        _expectAvalancheOftEmit(1e18);

        vm.prank(relayer);
        foreignController.transferTokenLayerZero(address(usdeAvalanche), 1e18, sourceEndpointId);

        assertEq(
            usdeAvalanche.balanceOf(address(foreignAlmProxy)), 0, "Foreign ALM Proxy balance should be 0 after transfer"
        );
        assertEq(
            usdeAvalanche.balanceOf(address(foreignController)),
            0,
            "Foreign Controller balance should be 0 after transfer"
        );
        assertEq(
            usdeAvalanche.totalSupply(),
            USDE_AVALANCHE_SUPPLY,
            "Total supply should be USDE_AVALANCHE_SUPPLY after transfer"
        );

        source.selectFork();

        assertEq(usde.balanceOf(address(almProxy)), 0, "ALM Proxy balance should be 0 before relay");
        assertEq(usde.balanceOf(address(mainnetController)), 0, "Mainnet Controller balance should be 0 before relay");
        assertEq(
            usde.balanceOf(address(usdeOft)),
            USDE_MAINNET_BALANCE_BEFORE,
            "OFT balance should be the same before relay"
        );

        bridge.relayMessagesToSource(true, address(usdeAvalanche), address(usdeOft));

        assertEq(usde.balanceOf(address(almProxy)), 1e18, "ALM Proxy balance should be 1e18 after relay");
        assertEq(usde.balanceOf(address(mainnetController)), 0, "Mainnet Controller balance should be 0 after relay");
        assertEq(
            usde.balanceOf(address(usdeOft)),
            USDE_MAINNET_BALANCE_BEFORE - 1e18,
            "OFT balance should be decreased by 1e18 after relay"
        );
    }

    function test_transferUSDeToLZ_destinationToSource_bigTransfer() external {
        destination.selectFork();

        deal(address(usdeAvalanche), address(foreignAlmProxy), 2_600_000e18, true);

        assertEq(
            usdeAvalanche.balanceOf(address(foreignAlmProxy)),
            2_600_000e18,
            "Foreign ALM Proxy balance should be 2_600_000e18 before transfer"
        );
        assertEq(
            usdeAvalanche.balanceOf(address(foreignController)),
            0,
            "Foreign Controller balance should be 0 before transfer"
        );
        assertEq(
            usdeAvalanche.totalSupply(), USDE_AVALANCHE_SUPPLY + 2_600_000e18, "Total supply should be increased before transfer"
        );

        _expectAvalancheOftEmit(2_600_000e18);

        vm.prank(relayer);
        foreignController.transferTokenLayerZero(address(usdeAvalanche), 2_600_000e18, sourceEndpointId);

        assertEq(
            usdeAvalanche.balanceOf(address(foreignAlmProxy)), 0, "Foreign ALM Proxy balance should be 0 after transfer"
        );
        assertEq(
            usdeAvalanche.balanceOf(address(foreignController)),
            0,
            "Foreign Controller balance should be 0 after transfer"
        );
        assertEq(
            usdeAvalanche.totalSupply(),
            USDE_AVALANCHE_SUPPLY,
            "Total supply should be USDE_AVALANCHE_SUPPLY after transfer"
        );

        source.selectFork();

        assertEq(usde.balanceOf(address(almProxy)), 0, "ALM Proxy balance should be 0 before relay");
        assertEq(usde.balanceOf(address(mainnetController)), 0, "Mainnet Controller balance should be 0 before relay");
        assertEq(
            usde.balanceOf(address(usdeOft)),
            USDE_MAINNET_BALANCE_BEFORE,
            "OFT balance should be the same before relay"
        );

        bridge.relayMessagesToSource(true, address(usdeAvalanche), address(usdeOft));

        assertEq(usde.balanceOf(address(almProxy)), 2_600_000e18, "ALM Proxy balance should be 2_600_000e18 after relay");
        assertEq(usde.balanceOf(address(mainnetController)), 0, "Mainnet Controller balance should be 0 after relay");
        assertEq(
            usde.balanceOf(address(usdeOft)),
            USDE_MAINNET_BALANCE_BEFORE - 2_600_000e18,
            "OFT balance should be decreased by 2_600_000e18 after relay"
        );
    }

    function test_transferUSDeToLZ_destinationToSource_rateLimited() external {
        destination.selectFork();

        bytes32 key = destinationRateLimitKey;
        deal(address(usdeAvalanche), address(foreignAlmProxy), 9_000_000e18, true);

        vm.startPrank(relayer);

        assertEq(usdeAvalanche.balanceOf(address(foreignAlmProxy)), 9_000_000e18, "Foreign ALM Proxy balance should be 9_000_000e18 before transfer");
        assertEq(foreignRateLimits.getCurrentRateLimit(key), 5_000_000e18, "Rate limit should be 5_000_000e18 before transfer");

        foreignController.transferTokenLayerZero(address(usdeAvalanche), 2_000_000e18, sourceEndpointId);

        assertEq(usdeAvalanche.balanceOf(address(foreignAlmProxy)), 7_000_000e18, "Foreign ALM Proxy balance should be 7_000_000e18 after transfer");
        assertEq(foreignRateLimits.getCurrentRateLimit(key), 3_000_000e18, "Rate limit should be 3_000_000e18 after transfer");

        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.transferTokenLayerZero(address(usdeAvalanche), 3_000_001e18, sourceEndpointId);

        foreignController.transferTokenLayerZero(address(usdeAvalanche), 3_000_000e18, sourceEndpointId);

        assertEq(usdeAvalanche.balanceOf(address(foreignAlmProxy)), 4_000_000e18, "Foreign ALM Proxy balance should be 4_000_000e18 after transfer");
        assertEq(foreignRateLimits.getCurrentRateLimit(key), 0, "Rate limit should be 0 after transfer");

        skip(4 hours);

        assertEq(usdeAvalanche.balanceOf(address(foreignAlmProxy)), 4_000_000e18, "Foreign ALM Proxy balance should be 4_000_000e18 after skipping");
        assertEq(foreignRateLimits.getCurrentRateLimit(key), 999_999999999999999993600, "Rate limit should replenish after skipping");

        foreignController.transferTokenLayerZero(address(usdeAvalanche), 999_999999999999999993600, sourceEndpointId);

        // NOTE: OFT shared decimals truncation - the OFT removes dust (rounds down to 1e12),
        // so 999_999_999_999_999_999_993_600 becomes 999_999_999_999_000_000_000_000 actual debit
        assertEq(usdeAvalanche.balanceOf(address(foreignAlmProxy)), 3_000_000_000_001_000_000_000_000, "Foreign ALM Proxy balance should decrease after transfer");
        assertEq(foreignRateLimits.getCurrentRateLimit(key), 0, "Rate limit should be 0 after transfer");

        vm.stopPrank();
    }

    function _expectEthereumOftEmit(uint256 amount) internal {
        vm.expectEmit(false, true, true, true, address(usdeOft));
        emit OFTSent(bytes32(0), destinationEndpointId, address(almProxy), amount, amount);
    }

    function _expectAvalancheOftEmit(uint256 amount) internal {
        vm.expectEmit(false, true, true, true, address(usdeAvalanche));
        emit OFTSent(bytes32(0), sourceEndpointId, address(foreignAlmProxy), amount, amount);
    }
}
