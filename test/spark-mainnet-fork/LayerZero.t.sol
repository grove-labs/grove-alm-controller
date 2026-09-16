// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import { IERC20 } from "forge-std/interfaces/IERC20.sol";

import "./ForkTestBase.t.sol";

import { ERC20Mock } from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import { Arbitrum } from "spark-address-registry/Arbitrum.sol";

import { PSM3Deploy } from "spark-psm/deploy/PSM3Deploy.sol";
import { IPSM3 }      from "spark-psm/src/PSM3.sol";

import { ForeignControllerDeploy } from "../../deploy/ControllerDeploy.sol";
import { ControllerInstance }      from "../../deploy/ControllerInstance.sol";

import { ForeignControllerInit } from "../../deploy/ForeignControllerInit.sol";

import { OptionsBuilder } from "layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import { ALMProxy }                from "../../src/ALMProxy.sol";
import { ForeignController }       from "../../src/ForeignController.sol";
import { IRateLimits, RateLimits } from "../../src/RateLimits.sol";
import { RateLimitHelpers }        from "../../src/RateLimitHelpers.sol";

import "src/interfaces/ILayerZero.sol";

import { CCTPv2Forwarder as CCTPForwarder } from "xchain-helpers/forwarders/CCTPv2Forwarder.sol";

contract MainnetControllerLayerZeroTestBase is ForkTestBase {

    using OptionsBuilder for bytes;

    uint32 constant destinationEndpointId = 30110;  // Arbitrum EID

    address constant USDT_OFT = 0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee;

    bytes32 key;
    bytes32 target;

    function setUp() public override virtual {
        super.setUp();

        key = RateLimitHelpers.makeAddressAddressBytes32Uint32Key(
            mainnetController.LIMIT_LAYERZERO_TRANSFER(),
            ILayerZero(USDT_OFT).token(),
            USDT_OFT,
            ILayerZero(USDT_OFT).peers(destinationEndpointId),
            destinationEndpointId
        );

        target = bytes32(uint256(uint160(makeAddr("layerZeroRecipient"))));
    }

    function _getBlock() internal pure override returns (uint256) {
        return 22468758;  // May 12, 2025
    }

    function _configure(uint256 maxAmount) internal {
        vm.startPrank(SPARK_PROXY);
        rateLimits.setRateLimitData(key, maxAmount, 0);
        mainnetController.setLayerZeroRecipient(destinationEndpointId, target);
        vm.stopPrank();
    }

    function _fee(uint256 amount) internal view returns (uint256) {
        return mainnetController.quoteTransferLayerZero(USDT_OFT, amount, destinationEndpointId).nativeFee;
    }

    function _expectedSendParams(uint256 amount) internal view returns (SendParam memory) {
        return SendParam({
            dstEid       : destinationEndpointId,
            to           : target,
            amountLD     : amount,
            minAmountLD  : amount,
            extraOptions : OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0),
            composeMsg   : "",
            oftCmd       : ""
        });
    }

}

contract MainnetControllerQuoteTransferLayerZeroTests is MainnetControllerLayerZeroTestBase {

    function test_quoteTransferLayerZero_recipientNotSet() external {
        vm.expectRevert("LayerZeroLib/recipient-not-set");
        mainnetController.quoteTransferLayerZero(USDT_OFT, 1e6, destinationEndpointId);
    }

    function test_quoteTransferLayerZero_zeroMinAmount() external {
        _configure(10_000_000e6);

        vm.expectRevert("LayerZeroLib/zero-min-amount");
        mainnetController.quoteTransferLayerZero(USDT_OFT, 0, destinationEndpointId);
    }

    function test_quoteTransferLayerZero_quoteSendFailed() external {
        _configure(10_000_000e6);

        vm.mockCallRevert(USDT_OFT, ILayerZero.quoteSend.selector, "");

        vm.expectRevert("LayerZeroLib/quote-send-failed");
        mainnetController.quoteTransferLayerZero(USDT_OFT, 1e6, destinationEndpointId);
    }

    function test_quoteTransferLayerZero() external {
        _configure(10_000_000e6);

        MessagingFee memory expected = ILayerZero(USDT_OFT).quoteSend(_expectedSendParams(1e6), false);
        MessagingFee memory fee      = mainnetController.quoteTransferLayerZero(USDT_OFT, 1e6, destinationEndpointId);

        assertGt(fee.nativeFee, 0);
        assertEq(fee.nativeFee,  expected.nativeFee);
        assertEq(fee.lzTokenFee, expected.lzTokenFee);
    }

}

contract MainnetControllerTransferLayerZeroFailureTests is MainnetControllerLayerZeroTestBase {

    function test_transferTokenLayerZero_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        mainnetController.transferTokenLayerZero(USDT_OFT, 1e6, destinationEndpointId);
    }

    function test_transferTokenLayerZero_recipientNotSet() external {
        vm.prank(SPARK_PROXY);
        rateLimits.setRateLimitData(key, 10_000_000e6, 0);

        vm.expectRevert("LayerZeroLib/recipient-not-set");
        vm.prank(relayer);
        mainnetController.transferTokenLayerZero(USDT_OFT, 1e6, destinationEndpointId);
    }

    function test_transferTokenLayerZero_zeroMinAmount() external {
        _configure(10_000_000e6);

        vm.expectRevert("LayerZeroLib/zero-min-amount");
        vm.prank(relayer);
        mainnetController.transferTokenLayerZero(USDT_OFT, 0, destinationEndpointId);
    }

    function test_transferTokenLayerZero_zeroMaxAmount() external {
        _configure(0);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(relayer);
        mainnetController.transferTokenLayerZero(USDT_OFT, 1e6, destinationEndpointId);
    }

    function test_transferTokenLayerZero_legacyKeyNotHonoured() external {
        // A limit under the pre-facet (rateLimitId, oft, eid) key does not authorize transfers.
        _configure(0);

        bytes32 legacyKey =
            keccak256(abi.encode(mainnetController.LIMIT_LAYERZERO_TRANSFER(), USDT_OFT, destinationEndpointId));

        vm.prank(SPARK_PROXY);
        rateLimits.setRateLimitData(legacyKey, 10_000_000e6, 0);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(relayer);
        mainnetController.transferTokenLayerZero(USDT_OFT, 1e6, destinationEndpointId);
    }

    function test_transferTokenLayerZero_insufficientFee() external {
        _configure(10_000_000e6);

        deal(address(usdt), address(almProxy), 10_000_000e6);
        deal(relayer, 1 ether);

        uint256 fee = _fee(10_000_000e6);

        vm.prank(relayer);
        vm.expectRevert();
        mainnetController.transferTokenLayerZero{value: fee - 1}(
            USDT_OFT,
            10_000_000e6,
            destinationEndpointId
        );
    }

    function test_transferTokenLayerZero_rateLimitedBoundary() external {
        _configure(10_000_000e6);

        deal(address(usdt), address(almProxy), 10_000_000e6);
        deal(relayer, 1 ether);  // Gas cost for LayerZero

        uint256 fee = _fee(10_000_000e6 + 1);

        vm.startPrank(relayer);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        mainnetController.transferTokenLayerZero{value: fee}(
            USDT_OFT,
            10_000_000e6 + 1,
            destinationEndpointId
        );

        fee = _fee(10_000_000e6);

        mainnetController.transferTokenLayerZero{value: fee}(
            USDT_OFT,
            10_000_000e6,
            destinationEndpointId
        );
    }

}

contract MainnetControllerTransferLayerZeroSuccessTests is MainnetControllerLayerZeroTestBase {

    event OFTSent(
        bytes32 indexed guid, // GUID of the OFT message.
        uint32  dstEid, // Destination Endpoint ID.
        address indexed fromAddress, // Address of the sender on the src chain.
        uint256 amountSentLD, // Amount of tokens sent in local decimals.
        uint256 amountReceivedLD // Amount of tokens received in local decimals.
    );

    function setUp() public override {
        super.setUp();

        _configure(10_000_000e6);

        deal(address(usdt), address(almProxy), 10_000_000e6);
        deal(relayer, 1 ether);  // Gas cost for LayerZero
    }

    function test_transferTokenLayerZero() external {
        uint256 fee = _fee(10_000_000e6);

        uint256 oftBalanceBefore = IERC20(usdt).balanceOf(USDT_OFT);

        assertEq(relayer.balance,                           1 ether);
        assertEq(rateLimits.getCurrentRateLimit(key),       10_000_000e6);
        assertEq(IERC20(usdt).balanceOf(address(almProxy)), 10_000_000e6);

        vm.expectEmit(USDT_OFT);
        emit OFTSent(
            bytes32(0xb6ebf135f758657b482818d84091e50f1af1cb378bd6f4e013f45dfa6f860cd6),
            destinationEndpointId,
            address(almProxy),
            10_000_000e6,
            10_000_000e6
        );
        vm.prank(relayer);
        mainnetController.transferTokenLayerZero{value: fee}(
            USDT_OFT,
            10_000_000e6,
            destinationEndpointId
        );

        assertEq(relayer.balance,                           1 ether - fee);
        assertEq(address(mainnetController).balance,        0);
        assertEq(address(almProxy).balance,                 0);
        assertEq(rateLimits.getCurrentRateLimit(key),       0);
        assertEq(IERC20(usdt).balanceOf(USDT_OFT),          oftBalanceBefore + 10_000_000e6);
        assertEq(IERC20(usdt).balanceOf(address(almProxy)), 0);
        assertEq(IERC20(usdt).allowance(address(almProxy), USDT_OFT), 0);
    }

    function test_transferTokenLayerZero_excessFeeSweptToProxy() external {
        uint256 fee = _fee(10_000_000e6);

        assertEq(address(mainnetController).balance, 0);
        assertEq(address(almProxy).balance,          0);

        vm.prank(relayer);
        mainnetController.transferTokenLayerZero{value: fee + 0.1 ether}(
            USDT_OFT,
            10_000_000e6,
            destinationEndpointId
        );

        assertEq(relayer.balance,                    1 ether - fee - 0.1 ether);
        assertEq(address(mainnetController).balance, 0);
        assertEq(address(almProxy).balance,          0.1 ether);
    }

    function test_transferTokenLayerZero_controllerBalanceSweptToProxy() external {
        // Any ETH already sitting in the controller is swept too, not only this call's excess.
        deal(address(mainnetController), 0.5 ether);

        uint256 fee = _fee(10_000_000e6);

        vm.prank(relayer);
        mainnetController.transferTokenLayerZero{value: fee}(
            USDT_OFT,
            10_000_000e6,
            destinationEndpointId
        );

        assertEq(address(mainnetController).balance, 0);
        assertEq(address(almProxy).balance,          0.5 ether);
    }

}

contract ArbitrumChainLayerZeroTestBase is ForkTestBase {

    using DomainHelpers for *;

    /**********************************************************************************************/
    /*** Constants/state variables                                                              ***/
    /**********************************************************************************************/

    address pocket = makeAddr("pocket");

    /**********************************************************************************************/
    /*** Arbtirum addresses                                                                     ***/
    /**********************************************************************************************/

    address constant CCTP_MESSENGER_ARB = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address constant SPARK_EXECUTOR     = Arbitrum.SPARK_EXECUTOR;
    address constant SSR_ORACLE         = Arbitrum.SSR_AUTH_ORACLE;
    address constant USDC_ARB           = Arbitrum.USDC;
    address constant USDT_OFT           = 0x14E4A1B13bf7F943c8ff7C51fb60FA964A298D92;
    address constant USDT0              = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant PENDLE_ROUTER_ARB  = 0x888888888889758F76e7103c6CbF23ABbF58F946;

    /**********************************************************************************************/
    /*** ALM system deployments                                                                 ***/
    /**********************************************************************************************/

    ALMProxy          foreignAlmProxy;
    RateLimits        foreignRateLimits;
    ForeignController foreignController;

    /**********************************************************************************************/
    /*** Casted addresses for testing                                                           ***/
    /**********************************************************************************************/

    IERC20 usdsArb;
    IERC20 susdsArb;
    IERC20 usdcArb;

    IPSM3 psmArb;

    uint32 constant destinationEndpointId = 30101;  // Ethereum EID

    function setUp() public override virtual {
        super.setUp();

        /*** Step 1: Set up environment and deploy mocks ***/

        destination = getChain("arbitrum_one").createSelectFork(341038130);  // May 27, 2025

        usdsArb  = IERC20(address(new ERC20Mock()));
        susdsArb = IERC20(address(new ERC20Mock()));
        usdcArb  = IERC20(USDC_ARB);

        /*** Step 2: Deploy and configure PSM with a pocket ***/

        deal(address(usdsArb), address(this), 1e18);  // For seeding PSM during deployment

        psmArb = IPSM3(PSM3Deploy.deploy(
            SPARK_EXECUTOR, USDC_ARB, address(usdsArb), address(susdsArb), SSR_ORACLE
        ));

        vm.prank(SPARK_EXECUTOR);
        psmArb.setPocket(pocket);

        vm.prank(pocket);
        usdcArb.approve(address(psmArb), type(uint256).max);

        /*** Step 3: Deploy and configure ALM system ***/

        ControllerInstance memory controllerInst = ForeignControllerDeploy.deployFull({
            admin        : SPARK_EXECUTOR,
            psm                      : address(psmArb),
            usdc                     : USDC_ARB,
            cctp                     : CCTP_MESSENGER_ARB,
            pendleRouter             : PENDLE_ROUTER_ARB,
            uniswapV3Router          : address(0xdeadbeef),
            uniswapV3PositionManager : address(0xdeadbeef)
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
            admin                    : SPARK_EXECUTOR,
            psm                      : address(psmArb),
            cctp                     : CCTP_MESSENGER_ARB,
            usdc                     : address(usdcArb),
            pendleRouter             : PENDLE_ROUTER_ARB,
            uniswapV3Router          : address(0xdeadbeef),
            uniswapV3PositionManager : address(0xdeadbeef)
        });

        ForeignControllerInit.MintRecipient[] memory mintRecipients = new ForeignControllerInit.MintRecipient[](1);

        mintRecipients[0] = ForeignControllerInit.MintRecipient({
            domain        : CCTPForwarder.DOMAIN_ID_CIRCLE_ETHEREUM,
            mintRecipient : bytes32(uint256(uint160(address(almProxy))))
        });

        ForeignControllerInit.LayerZeroRecipient[] memory layerZeroRecipients = new ForeignControllerInit.LayerZeroRecipient[](0);

        ForeignControllerInit.CentrifugeRecipient[] memory centrifugeRecipients = new ForeignControllerInit.CentrifugeRecipient[](0);

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

    function _getBlock() internal pure override returns (uint256) {
        return 22468758;  // May 12, 2025
    }

}

contract ForeignControllerLayerZeroTestBase is ArbitrumChainLayerZeroTestBase {

    using DomainHelpers  for *;
    using OptionsBuilder for bytes;

    bytes32 key;
    bytes32 target;

    function setUp() public override virtual {
        super.setUp();
        destination.selectFork();

        key = RateLimitHelpers.makeAddressAddressBytes32Uint32Key(
            foreignController.LIMIT_LAYERZERO_TRANSFER(),
            ILayerZero(USDT_OFT).token(),
            USDT_OFT,
            ILayerZero(USDT_OFT).peers(destinationEndpointId),
            destinationEndpointId
        );

        target = bytes32(uint256(uint160(makeAddr("layerZeroRecipient"))));
    }

    function _configure(uint256 maxAmount) internal {
        vm.startPrank(SPARK_EXECUTOR);
        foreignRateLimits.setRateLimitData(key, maxAmount, 0);
        foreignController.setLayerZeroRecipient(destinationEndpointId, target);
        vm.stopPrank();
    }

    function _fee(uint256 amount) internal view returns (uint256) {
        return foreignController.quoteTransferLayerZero(USDT_OFT, amount, destinationEndpointId).nativeFee;
    }

    function _expectedSendParams(uint256 amount) internal view returns (SendParam memory) {
        return SendParam({
            dstEid       : destinationEndpointId,
            to           : target,
            amountLD     : amount,
            minAmountLD  : amount,
            extraOptions : OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0),
            composeMsg   : "",
            oftCmd       : ""
        });
    }

}

contract ForeignControllerQuoteTransferLayerZeroTests is ForeignControllerLayerZeroTestBase {

    function test_quoteTransferLayerZero_recipientNotSet() external {
        vm.expectRevert("LayerZeroLib/recipient-not-set");
        foreignController.quoteTransferLayerZero(USDT_OFT, 1e6, destinationEndpointId);
    }

    function test_quoteTransferLayerZero_zeroMinAmount() external {
        _configure(10_000_000e6);

        vm.expectRevert("LayerZeroLib/zero-min-amount");
        foreignController.quoteTransferLayerZero(USDT_OFT, 0, destinationEndpointId);
    }

    function test_quoteTransferLayerZero_quoteSendFailed() external {
        _configure(10_000_000e6);

        vm.mockCallRevert(USDT_OFT, ILayerZero.quoteSend.selector, "");

        vm.expectRevert("LayerZeroLib/quote-send-failed");
        foreignController.quoteTransferLayerZero(USDT_OFT, 1e6, destinationEndpointId);
    }

    function test_quoteTransferLayerZero() external {
        _configure(10_000_000e6);

        MessagingFee memory expected = ILayerZero(USDT_OFT).quoteSend(_expectedSendParams(1e6), false);
        MessagingFee memory fee      = foreignController.quoteTransferLayerZero(USDT_OFT, 1e6, destinationEndpointId);

        assertGt(fee.nativeFee, 0);
        assertEq(fee.nativeFee,  expected.nativeFee);
        assertEq(fee.lzTokenFee, expected.lzTokenFee);
    }

}

contract ForeignControllerTransferLayerZeroFailureTests is ForeignControllerLayerZeroTestBase {

    function test_transferTokenLayerZero_notRelayer() external {
        vm.expectRevert(abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            RELAYER
        ));
        foreignController.transferTokenLayerZero(USDT_OFT, 1e6, destinationEndpointId);
    }

    function test_transferTokenLayerZero_recipientNotSet() external {
        vm.prank(SPARK_EXECUTOR);
        foreignRateLimits.setRateLimitData(key, 10_000_000e6, 0);

        vm.expectRevert("LayerZeroLib/recipient-not-set");
        vm.prank(relayer);
        foreignController.transferTokenLayerZero(USDT_OFT, 1e6, destinationEndpointId);
    }

    function test_transferTokenLayerZero_zeroMinAmount() external {
        _configure(10_000_000e6);

        vm.expectRevert("LayerZeroLib/zero-min-amount");
        vm.prank(relayer);
        foreignController.transferTokenLayerZero(USDT_OFT, 0, destinationEndpointId);
    }

    function test_transferTokenLayerZero_zeroMaxAmount() external {
        _configure(0);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(relayer);
        foreignController.transferTokenLayerZero(USDT_OFT, 1e6, destinationEndpointId);
    }

    function test_transferTokenLayerZero_legacyKeyNotHonoured() external {
        // A limit under the pre-facet (rateLimitId, oft, eid) key does not authorize transfers.
        _configure(0);

        bytes32 legacyKey =
            keccak256(abi.encode(foreignController.LIMIT_LAYERZERO_TRANSFER(), USDT_OFT, destinationEndpointId));

        vm.prank(SPARK_EXECUTOR);
        foreignRateLimits.setRateLimitData(legacyKey, 10_000_000e6, 0);

        vm.expectRevert("RateLimits/zero-maxAmount");
        vm.prank(relayer);
        foreignController.transferTokenLayerZero(USDT_OFT, 1e6, destinationEndpointId);
    }

    function test_transferTokenLayerZero_insufficientFee() external {
        _configure(10_000_000e6);

        deal(USDT0, address(foreignAlmProxy), 10_000_000e6);
        deal(relayer, 1 ether);

        uint256 fee = _fee(10_000_000e6);

        vm.prank(relayer);
        vm.expectRevert();
        foreignController.transferTokenLayerZero{value: fee - 1}(
            USDT_OFT,
            10_000_000e6,
            destinationEndpointId
        );
    }

    function test_transferTokenLayerZero_rateLimitedBoundary() external {
        _configure(10_000_000e6);

        deal(USDT0, address(foreignAlmProxy), 10_000_000e6);
        deal(relayer, 1 ether);  // Gas cost for LayerZero

        uint256 fee = _fee(10_000_000e6 + 1);

        vm.startPrank(relayer);
        vm.expectRevert("RateLimits/rate-limit-exceeded");
        foreignController.transferTokenLayerZero{value: fee}(
            USDT_OFT,
            10_000_000e6 + 1,
            destinationEndpointId
        );

        fee = _fee(10_000_000e6);

        foreignController.transferTokenLayerZero{value: fee}(
            USDT_OFT,
            10_000_000e6,
            destinationEndpointId
        );
    }

}

contract ForeignControllerTransferLayerZeroSuccessTests is ForeignControllerLayerZeroTestBase {

    event OFTSent(
        bytes32 indexed guid, // GUID of the OFT message.
        uint32  dstEid, // Destination Endpoint ID.
        address indexed fromAddress, // Address of the sender on the src chain.
        uint256 amountSentLD, // Amount of tokens sent in local decimals.
        uint256 amountReceivedLD // Amount of tokens received in local decimals.
    );

    function setUp() public override {
        super.setUp();

        _configure(10_000_000e6);

        deal(USDT0, address(foreignAlmProxy), 10_000_000e6);
        deal(relayer, 1 ether);  // Gas cost for LayerZero
    }

    function test_transferTokenLayerZero() external {
        uint256 fee = _fee(10_000_000e6);

        assertEq(relayer.balance,                                   1 ether);
        assertEq(foreignRateLimits.getCurrentRateLimit(key),        10_000_000e6);
        assertEq(IERC20(USDT0).balanceOf(address(foreignAlmProxy)), 10_000_000e6);

        vm.expectEmit(USDT_OFT);
        emit OFTSent(
            bytes32(0xce4454206df6ee6a9cab360f7d76fd11ae258f65a9e8cc88faf1110c0bb36864),
            destinationEndpointId,
            address(foreignAlmProxy),
            10_000_000e6,
            10_000_000e6
        );
        vm.prank(relayer);
        foreignController.transferTokenLayerZero{value: fee}(
            USDT_OFT,
            10_000_000e6,
            destinationEndpointId
        );

        assertEq(relayer.balance,                                    1 ether - fee);
        assertEq(address(foreignController).balance,                 0);
        assertEq(address(foreignAlmProxy).balance,                   0);
        assertEq(foreignRateLimits.getCurrentRateLimit(key),         0);
        assertEq(IERC20(USDT0).balanceOf(address(foreignAlmProxy)),  0);
        assertEq(IERC20(USDT0).allowance(address(foreignAlmProxy), USDT_OFT), 0);
    }

    function test_transferTokenLayerZero_excessFeeSweptToProxy() external {
        uint256 fee = _fee(10_000_000e6);

        assertEq(address(foreignController).balance, 0);
        assertEq(address(foreignAlmProxy).balance,   0);

        vm.prank(relayer);
        foreignController.transferTokenLayerZero{value: fee + 0.1 ether}(
            USDT_OFT,
            10_000_000e6,
            destinationEndpointId
        );

        assertEq(relayer.balance,                    1 ether - fee - 0.1 ether);
        assertEq(address(foreignController).balance, 0);
        assertEq(address(foreignAlmProxy).balance,   0.1 ether);
    }

    function test_transferTokenLayerZero_controllerBalanceSweptToProxy() external {
        // Any ETH already sitting in the controller is swept too, not only this call's excess.
        deal(address(foreignController), 0.5 ether);

        uint256 fee = _fee(10_000_000e6);

        vm.prank(relayer);
        foreignController.transferTokenLayerZero{value: fee}(
            USDT_OFT,
            10_000_000e6,
            destinationEndpointId
        );

        assertEq(address(foreignController).balance, 0);
        assertEq(address(foreignAlmProxy).balance,   0.5 ether);
    }

}
