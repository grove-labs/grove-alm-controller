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

import {OFTMock} from "@layerzerolabs/oft-evm/test/mocks/OFTMock.sol";
import {OFTAdapterMock} from "@layerzerolabs/oft-evm/test/mocks/OFTAdapterMock.sol";

import "./ForkTestBase.t.sol";

/**********************************************************************************************/
/*** Abstract base: shared setUp for all LayerZero call tests                               ***/
/**********************************************************************************************/

abstract contract LayerZeroCallsTestBase is ForkTestBase {
    using DomainHelpers for *;
    using LZBridgeTesting for Bridge;

    /**********************************************************************************************/
    /*** Constants/state variables                                                              ***/
    /**********************************************************************************************/

    address pocket = makeAddr("pocket");

    /**********************************************************************************************/
    /*** ALM system deployments                                                                 ***/
    /**********************************************************************************************/

    ALMProxy          foreignAlmProxy;
    RateLimits        foreignRateLimits;
    ForeignController foreignController;

    /**********************************************************************************************/
    /*** Casted addresses for testing                                                           ***/
    /**********************************************************************************************/

    IERC20 usdsAvalanche;
    IERC20 susdsAvalanche;

    IPSM3 psmAvalanche;

    uint32 constant sourceEndpointId      = 30101; // Ethereum EID
    uint32 constant destinationEndpointId = 30106; // Avalanche EID

    bytes32 sourceRateLimitKey;
    bytes32 destinationRateLimitKey;

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**********************************************************************************************/
    /*** Abstract hooks                                                                         ***/
    /**********************************************************************************************/

    function _getDestinationBlock() internal pure virtual returns (uint256);
    function _setupDestinationTokens() internal virtual;
    function _getDestinationToken() internal view virtual returns (address);
    function _getDestinationOftAddress() internal view virtual returns (address);
    function _setupSourceTokens() internal virtual;
    function _getSourceOftAddress() internal view virtual returns (address);
    function _afterSetUp() internal virtual {}
    function _labelAddresses() internal virtual;

    /**********************************************************************************************/
    /*** Setup                                                                                  ***/
    /**********************************************************************************************/

    function setUp() public virtual override {
        super.setUp();

        /**
         * Step 1: Set up Avalanche environment **
         */
        destination = getChain("avalanche").createSelectFork(_getDestinationBlock());

        usdsAvalanche  = IERC20(address(new ERC20Mock()));
        susdsAvalanche = IERC20(address(new ERC20Mock()));

        _setupDestinationTokens();

        /**
         * Step 2: Deploy and configure PSM with a pocket **
         */
        address destinationToken = _getDestinationToken();

        MockRateProvider mockRateProvider = new MockRateProvider();
        mockRateProvider.__setConversionRate(1.25e27);

        IRateProviderLike rateProvider = IRateProviderLike(address(mockRateProvider));

        deal(address(usdsAvalanche), address(this), 1e18); // For seeding PSM during deployment

        psmAvalanche = IPSM3(
            PSM3Deploy.deploy(
                Avalanche.GROVE_EXECUTOR,
                destinationToken,
                address(usdsAvalanche),
                address(susdsAvalanche),
                address(rateProvider)
            )
        );

        vm.prank(Avalanche.GROVE_EXECUTOR);
        psmAvalanche.setPocket(pocket);

        vm.prank(pocket);
        IERC20(destinationToken).approve(address(psmAvalanche), type(uint256).max);

        /**
         * Step 3: Deploy and configure ALM system **
         */
        ControllerInstance memory controllerInst = ForeignControllerDeploy.deployFull({
            admin                    : Avalanche.GROVE_EXECUTOR,
            psm                      : address(psmAvalanche),
            usdc                     : destinationToken,
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
            usdc                     : destinationToken,
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

        destinationRateLimitKey = keccak256(
            abi.encode(foreignController.LIMIT_LAYERZERO_TRANSFER(), _getDestinationOftAddress(), sourceEndpointId)
        );

        uint256 maxAmount = 5_000_000e18;
        uint256 slope     = uint256(1_000_000e18) / 4 hours;

        foreignRateLimits.setRateLimitData(destinationRateLimitKey, maxAmount, slope);
        vm.stopPrank();

        /**
         * Step 4: Set up mainnet **
         */
        source.selectFork();

        deal(address(mainnetController), 1 ether); // Gas cost for LZ

        _setupSourceTokens();

        bridge = LZBridgeTesting.createLZBridge(source, destination);

        vm.startPrank(Ethereum.GROVE_PROXY);

        sourceRateLimitKey = keccak256(
            abi.encode(mainnetController.LIMIT_LAYERZERO_TRANSFER(), _getSourceOftAddress(), destinationEndpointId)
        );

        rateLimits.setRateLimitData(sourceRateLimitKey, maxAmount, slope);

        // Add foreign ALM Proxy as recipient
        mainnetController.setLayerZeroRecipient(
            destinationEndpointId, bytes32(uint256(uint160(address(foreignAlmProxy))))
        );

        vm.stopPrank();

        /**
         * Step 5: Final setup and labels **
         */
        _afterSetUp();
        _labelAddresses();
    }
}

/**********************************************************************************************/
/***                                                                                        ***/
/***                        USDe tests (real forked OFTs with relay)                        ***/
/***                                                                                        ***/
/**********************************************************************************************/

contract AvalancheChainUSDeToLayerZeroTestBase is LayerZeroCallsTestBase {
    using DomainHelpers for *;
    using LZBridgeTesting for Bridge;

    /**********************************************************************************************/
    /*** Avalanche addresses                                                                    ***/
    /**********************************************************************************************/

    // USDe OFT on Avalanche (ENAOFT - the OFT IS the token on Avalanche)
    address constant USDE_OFT_AVALANCHE_ADDRESS = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;

    /**********************************************************************************************/
    /*** Casted addresses for testing                                                           ***/
    /**********************************************************************************************/

    // Mainnet OFTs
    IERC20 usdeOft;

    // Avalanche Tokens
    IERC20 usdeAvalanche;

    uint256 USDE_AVALANCHE_SUPPLY;
    uint256 USDE_MAINNET_BALANCE_BEFORE;

    /**********************************************************************************************/
    /*** Hook implementations                                                                   ***/
    /**********************************************************************************************/

    function _getDestinationBlock() internal pure override returns (uint256) {
        return 82400000; // April 2026
    }

    function _setupDestinationTokens() internal override {
        usdeAvalanche = IERC20(USDE_OFT_AVALANCHE_ADDRESS);
        USDE_AVALANCHE_SUPPLY = usdeAvalanche.totalSupply();
    }

    function _getDestinationToken() internal view override returns (address) {
        return address(usdeAvalanche);
    }

    function _getDestinationOftAddress() internal view override returns (address) {
        return address(usdeAvalanche);
    }

    function _setupSourceTokens() internal override {
        usdeOft = IERC20(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34);
    }

    function _getSourceOftAddress() internal view override returns (address) {
        return address(usdeOft);
    }

    function _afterSetUp() internal override {
        USDE_MAINNET_BALANCE_BEFORE = usde.balanceOf(address(usdeOft));
    }

    function _labelAddresses() internal override {
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

// NOTE: Failure tests (notRelayer, rateLimitExceeded, zeroMaxAmount, rateLimitedBoundary) are
// covered in spark-mainnet-fork/LayerZero.t.sol for both MainnetController and ForeignController.
// These paths are token-agnostic — they revert before reaching any OFT-specific logic.

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

        // approvalRequired == true: expect Approval from almProxy to OFT for USDe
        vm.expectEmit(true, true, true, true, address(usde));
        emit Approval(address(almProxy), address(usdeOft), 1e18);

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

    // NOTE: bigTransfer and rateLimited tests are covered by grove-mainnet-fork/LayerZero.t.sol
    // (USDT/Plasma). The code paths are identical — only the token and chain differ.
    // Rate limit enforcement + recovery is token-agnostic.

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

        // approvalRequired == false: no approval should be set
        assertEq(
            usdeAvalanche.allowance(address(foreignAlmProxy), address(usdeAvalanche)),
            0,
            "No allowance should exist before transfer (approvalRequired == false)"
        );

        _expectAvalancheOftEmit(1e18);

        vm.prank(relayer);
        foreignController.transferTokenLayerZero(address(usdeAvalanche), 1e18, sourceEndpointId);

        // approvalRequired == false: allowance should still be zero (no approval was made)
        assertEq(
            usdeAvalanche.allowance(address(foreignAlmProxy), address(usdeAvalanche)),
            0,
            "No allowance should exist after transfer (approvalRequired == false)"
        );

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

    function _expectEthereumOftEmit(uint256 amount) internal {
        vm.expectEmit(false, true, true, true, address(usdeOft));
        emit OFTSent(bytes32(0), destinationEndpointId, address(almProxy), amount, amount);
    }

    function _expectAvalancheOftEmit(uint256 amount) internal {
        vm.expectEmit(false, true, true, true, address(usdeAvalanche));
        emit OFTSent(bytes32(0), sourceEndpointId, address(foreignAlmProxy), amount, amount);
    }
}

/**********************************************************************************************/
/***                                                                                        ***/
/***    ETH/WETH tests (deployed OFTMock/OFTAdapterMock with full relay)                    ***/
/***                                                                                        ***/
/**********************************************************************************************/

contract AvalancheChainETHToLayerZeroTestBase is LayerZeroCallsTestBase {
    using DomainHelpers for *;
    using LZBridgeTesting for Bridge;

    /**********************************************************************************************/
    /*** Avalanche addresses                                                                    ***/
    /**********************************************************************************************/

    // WETH.e on Avalanche
    address constant WETH_AVALANCHE = 0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB;

    /**********************************************************************************************/
    /*** OFT deployments                                                                        ***/
    /**********************************************************************************************/

    // Source: OFTMock on mainnet (approvalRequired == false, burns/mints)
    OFTMock oftMockMainnet;

    // Destination: OFTAdapterMock wrapping WETH on Avalanche (approvalRequired == true, locks/unlocks)
    OFTAdapterMock oftAdapterAvalanche;

    /**********************************************************************************************/
    /*** Casted addresses for testing                                                           ***/
    /**********************************************************************************************/

    IERC20 wethAvalanche;

    uint256 WETH_ADAPTER_BALANCE;

    /**********************************************************************************************/
    /*** Hook implementations                                                                   ***/
    /**********************************************************************************************/

    function _getDestinationBlock() internal pure override returns (uint256) {
        return 82400000; // April 2026
    }

    function _setupDestinationTokens() internal override {
        wethAvalanche = IERC20(WETH_AVALANCHE);

        // Deploy OFTAdapterMock wrapping WETH (approvalRequired == true)
        oftAdapterAvalanche = new OFTAdapterMock(
            address(wethAvalanche),
            LZForwarder.ENDPOINT_AVALANCHE,
            address(this)
        );
    }

    function _getDestinationToken() internal view override returns (address) {
        return address(wethAvalanche);
    }

    function _getDestinationOftAddress() internal view override returns (address) {
        return address(oftAdapterAvalanche);
    }

    function _setupSourceTokens() internal override {
        // Deploy OFTMock on mainnet (the OFT IS the token, approvalRequired == false)
        oftMockMainnet = new OFTMock(
            "Mock ETH OFT",
            "mETH",
            LZForwarder.ENDPOINT_ETHEREUM,
            address(this)
        );

        // Configure peer: mainnet OFT -> Avalanche adapter
        oftMockMainnet.setPeer(destinationEndpointId, bytes32(uint256(uint160(address(oftAdapterAvalanche)))));
    }

    function _getSourceOftAddress() internal view override returns (address) {
        return address(oftMockMainnet);
    }

    function _afterSetUp() internal override {
        // Configure peer: Avalanche adapter -> mainnet OFT
        destination.selectFork();
        oftAdapterAvalanche.setPeer(sourceEndpointId, bytes32(uint256(uint160(address(oftMockMainnet)))));

        // Seed OFTAdapterMock with WETH (simulates prior bridge deposits for unlocking)
        WETH_ADAPTER_BALANCE = 10_000_000e18;
        deal(address(wethAvalanche), address(oftAdapterAvalanche), WETH_ADAPTER_BALANCE);

        source.selectFork();
    }

    function _labelAddresses() internal override {
        vm.label(address(oftMockMainnet),          "oftMockMainnet");
        vm.label(address(oftAdapterAvalanche),  "oftAdapterAvalanche");
        vm.label(address(wethAvalanche),          "wethAvalanche");
        vm.label(address(mainnetController),    "mainnetController");
        vm.label(address(foreignAlmProxy),        "foreignAlmProxy");
        vm.label(address(foreignRateLimits),    "foreignRateLimits");
        vm.label(address(foreignController),    "foreignController");
        vm.label(address(rateLimits),                "rateLimits");
        vm.label(address(almProxy),                    "almProxy");
    }
}

/**********************************************************************************************/
/*** Source to Destination tests (approvalRequired == false on MainnetController)            ***/
/**********************************************************************************************/

contract ETHToLayerZeroSourceToDestinationTests is AvalancheChainETHToLayerZeroTestBase {
    using DomainHelpers for *;
    using LZBridgeTesting for Bridge;

    event OFTSent(
        bytes32 indexed guid, uint32 dstEid, address indexed fromAddress, uint256 amountSentLD, uint256 amountReceivedLD
    );

    function test_transferETHToLZ_sourceToDestination() external {
        oftMockMainnet.mint(address(almProxy), 1e18);

        assertEq(oftMockMainnet.balanceOf(address(almProxy)), 1e18, "ALM Proxy balance should be 1e18 before transfer");
        assertEq(
            oftMockMainnet.balanceOf(address(mainnetController)),
            0,
            "Mainnet Controller balance should be 0 before transfer"
        );
        assertEq(oftMockMainnet.totalSupply(), 1e18, "OFT total supply should be 1e18 before transfer");

        // approvalRequired == false: no approval should be set
        assertEq(
            oftMockMainnet.allowance(address(almProxy), address(oftMockMainnet)),
            0,
            "No allowance should exist before transfer (approvalRequired == false)"
        );

        _expectEthereumOftEmit(1e18);

        vm.prank(relayer);
        mainnetController.transferTokenLayerZero(address(oftMockMainnet), 1e18, destinationEndpointId);

        // approvalRequired == false: allowance should still be zero (no approval was made)
        assertEq(
            oftMockMainnet.allowance(address(almProxy), address(oftMockMainnet)),
            0,
            "No allowance should exist after transfer (approvalRequired == false)"
        );

        // OFT tokens burned from almProxy (approvalRequired == false path: no approval needed)
        assertEq(oftMockMainnet.balanceOf(address(almProxy)), 0, "ALM Proxy balance should be 0 after transfer");
        assertEq(
            oftMockMainnet.balanceOf(address(mainnetController)),
            0,
            "Mainnet Controller balance should be 0 after transfer"
        );
        assertEq(oftMockMainnet.totalSupply(), 0, "OFT total supply should be 0 after transfer (burned)");

        destination.selectFork();

        assertEq(
            wethAvalanche.balanceOf(address(foreignAlmProxy)),
            0,
            "Foreign ALM Proxy WETH balance should be 0 before message relay"
        );
        assertEq(
            wethAvalanche.balanceOf(address(oftAdapterAvalanche)),
            WETH_ADAPTER_BALANCE,
            "OFT Adapter WETH balance should be WETH_ADAPTER_BALANCE before message relay"
        );

        bridge.relayMessagesToDestination(true, address(oftMockMainnet), address(oftAdapterAvalanche));

        // WETH unlocked from adapter to foreignAlmProxy
        assertEq(
            wethAvalanche.balanceOf(address(foreignAlmProxy)),
            1e18,
            "Foreign ALM Proxy WETH balance should be 1e18 after message relay"
        );
        assertEq(
            wethAvalanche.balanceOf(address(oftAdapterAvalanche)),
            WETH_ADAPTER_BALANCE - 1e18,
            "OFT Adapter WETH balance should decrease by 1e18 after message relay"
        );
    }

    function test_transferETHToLZ_sourceToDestination_bigTransfer() external {
        oftMockMainnet.mint(address(almProxy), 2_900_000e18);

        assertEq(
            oftMockMainnet.balanceOf(address(almProxy)),
            2_900_000e18,
            "ALM Proxy balance should be 2_900_000e18 before transfer"
        );
        assertEq(oftMockMainnet.totalSupply(), 2_900_000e18, "OFT total supply should be 2_900_000e18 before transfer");

        _expectEthereumOftEmit(2_900_000e18);

        vm.prank(relayer);
        mainnetController.transferTokenLayerZero(address(oftMockMainnet), 2_900_000e18, destinationEndpointId);

        assertEq(oftMockMainnet.balanceOf(address(almProxy)), 0, "ALM Proxy balance should be 0 after transfer");
        assertEq(oftMockMainnet.totalSupply(), 0, "OFT total supply should be 0 after transfer (burned)");

        destination.selectFork();

        assertEq(
            wethAvalanche.balanceOf(address(foreignAlmProxy)),
            0,
            "Foreign ALM Proxy WETH balance should be 0 before message relay"
        );

        bridge.relayMessagesToDestination(true, address(oftMockMainnet), address(oftAdapterAvalanche));

        assertEq(
            wethAvalanche.balanceOf(address(foreignAlmProxy)),
            2_900_000e18,
            "Foreign ALM Proxy WETH balance should be 2_900_000e18 after message relay"
        );
        assertEq(
            wethAvalanche.balanceOf(address(oftAdapterAvalanche)),
            WETH_ADAPTER_BALANCE - 2_900_000e18,
            "OFT Adapter WETH balance should decrease by 2_900_000e18 after message relay"
        );
    }

    function _expectEthereumOftEmit(uint256 amount) internal {
        vm.expectEmit(false, true, true, true, address(oftMockMainnet));
        emit OFTSent(bytes32(0), destinationEndpointId, address(almProxy), amount, amount);
    }
}

/**********************************************************************************************/
/*** Destination to Source tests (approvalRequired == true on ForeignController)             ***/
/**********************************************************************************************/

contract ETHToLayerZeroDestinationToSourceTests is AvalancheChainETHToLayerZeroTestBase {
    using DomainHelpers for *;
    using LZBridgeTesting for Bridge;

    event OFTSent(
        bytes32 indexed guid, uint32 dstEid, address indexed fromAddress, uint256 amountSentLD, uint256 amountReceivedLD
    );

    function test_transferETHToLZ_destinationToSource() external {
        destination.selectFork();

        deal(address(wethAvalanche), address(foreignAlmProxy), 1e18);

        assertEq(
            wethAvalanche.balanceOf(address(foreignAlmProxy)),
            1e18,
            "Foreign ALM Proxy WETH balance should be 1e18 before transfer"
        );
        assertEq(
            wethAvalanche.balanceOf(address(foreignController)),
            0,
            "Foreign Controller WETH balance should be 0 before transfer"
        );
        assertEq(
            wethAvalanche.balanceOf(address(oftAdapterAvalanche)),
            WETH_ADAPTER_BALANCE,
            "OFT Adapter WETH balance should be WETH_ADAPTER_BALANCE before transfer"
        );

        // approvalRequired == true: expect Approval from foreignAlmProxy to adapter for WETH
        vm.expectEmit(true, true, true, true, address(wethAvalanche));
        emit Approval(address(foreignAlmProxy), address(oftAdapterAvalanche), 1e18);

        _expectAvalancheOftEmit(1e18);

        vm.prank(relayer);
        foreignController.transferTokenLayerZero(address(oftAdapterAvalanche), 1e18, sourceEndpointId);

        // WETH locked in adapter (approvalRequired == true path: controller approved WETH for adapter)
        assertEq(
            wethAvalanche.balanceOf(address(foreignAlmProxy)),
            0,
            "Foreign ALM Proxy WETH balance should be 0 after transfer"
        );
        assertEq(
            wethAvalanche.balanceOf(address(foreignController)),
            0,
            "Foreign Controller WETH balance should be 0 after transfer"
        );
        assertEq(
            wethAvalanche.balanceOf(address(oftAdapterAvalanche)),
            WETH_ADAPTER_BALANCE + 1e18,
            "OFT Adapter WETH balance should increase by 1e18 after transfer (locked)"
        );

        source.selectFork();

        assertEq(oftMockMainnet.balanceOf(address(almProxy)), 0, "ALM Proxy balance should be 0 before relay");
        assertEq(
            oftMockMainnet.balanceOf(address(mainnetController)), 0, "Mainnet Controller balance should be 0 before relay"
        );
        assertEq(oftMockMainnet.totalSupply(), 0, "OFT total supply should be 0 before relay");

        bridge.relayMessagesToSource(true, address(oftAdapterAvalanche), address(oftMockMainnet));

        // OFT tokens minted to almProxy
        assertEq(oftMockMainnet.balanceOf(address(almProxy)), 1e18, "ALM Proxy balance should be 1e18 after relay");
        assertEq(
            oftMockMainnet.balanceOf(address(mainnetController)), 0, "Mainnet Controller balance should be 0 after relay"
        );
        assertEq(oftMockMainnet.totalSupply(), 1e18, "OFT total supply should be 1e18 after relay (minted)");
    }

    function test_transferETHToLZ_destinationToSource_bigTransfer() external {
        destination.selectFork();

        deal(address(wethAvalanche), address(foreignAlmProxy), 2_600_000e18);

        assertEq(
            wethAvalanche.balanceOf(address(foreignAlmProxy)),
            2_600_000e18,
            "Foreign ALM Proxy WETH balance should be 2_600_000e18 before transfer"
        );
        assertEq(
            wethAvalanche.balanceOf(address(oftAdapterAvalanche)),
            WETH_ADAPTER_BALANCE,
            "OFT Adapter WETH balance should be WETH_ADAPTER_BALANCE before transfer"
        );

        // approvalRequired == true: expect Approval from foreignAlmProxy to adapter for WETH
        vm.expectEmit(true, true, true, true, address(wethAvalanche));
        emit Approval(address(foreignAlmProxy), address(oftAdapterAvalanche), 2_600_000e18);

        _expectAvalancheOftEmit(2_600_000e18);

        vm.prank(relayer);
        foreignController.transferTokenLayerZero(address(oftAdapterAvalanche), 2_600_000e18, sourceEndpointId);

        assertEq(
            wethAvalanche.balanceOf(address(foreignAlmProxy)),
            0,
            "Foreign ALM Proxy WETH balance should be 0 after transfer"
        );
        assertEq(
            wethAvalanche.balanceOf(address(oftAdapterAvalanche)),
            WETH_ADAPTER_BALANCE + 2_600_000e18,
            "OFT Adapter WETH balance should increase by 2_600_000e18 after transfer (locked)"
        );

        source.selectFork();

        assertEq(oftMockMainnet.balanceOf(address(almProxy)), 0, "ALM Proxy balance should be 0 before relay");
        assertEq(oftMockMainnet.totalSupply(), 0, "OFT total supply should be 0 before relay");

        bridge.relayMessagesToSource(true, address(oftAdapterAvalanche), address(oftMockMainnet));

        assertEq(
            oftMockMainnet.balanceOf(address(almProxy)), 2_600_000e18, "ALM Proxy balance should be 2_600_000e18 after relay"
        );
        assertEq(
            oftMockMainnet.balanceOf(address(mainnetController)), 0, "Mainnet Controller balance should be 0 after relay"
        );
        assertEq(
            oftMockMainnet.totalSupply(), 2_600_000e18, "OFT total supply should be 2_600_000e18 after relay (minted)"
        );
    }

    function _expectAvalancheOftEmit(uint256 amount) internal {
        vm.expectEmit(false, true, true, true, address(oftAdapterAvalanche));
        emit OFTSent(bytes32(0), sourceEndpointId, address(foreignAlmProxy), amount, amount);
    }
}
