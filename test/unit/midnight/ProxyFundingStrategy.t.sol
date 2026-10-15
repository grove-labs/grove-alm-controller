// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import "forge-std/Test.sol";

import { IERC20 }    from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import { ERC20Mock } from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

import { ProxyFundingStrategy } from "../../../src/ProxyFundingStrategy.sol";

import { CollateralParams, Market } from "../../../src/interfaces/MidnightInterfaces.sol";

contract MockSettlementVenue {

    bytes internal _market;

    function setMarket(Market memory newMarket) external {
        _market = abi.encode(newMarket);
    }

    function market() public view returns (Market memory) {
        return abi.decode(_market, (Market));
    }

    function settle(
        address strategy,
        bytes32 marketId,
        uint256 buyerAssets,
        uint256 units,
        uint256 pendingFeeIncrease,
        address buyer,
        bytes   memory data
    )
        external returns (bytes32 ret)
    {
        Market memory m = market();

        ret = ProxyFundingStrategy(strategy).onBuy(
            marketId, m, buyerAssets, units, pendingFeeIncrease, buyer, data
        );

        if (buyerAssets != 0) {
            IERC20(m.loanToken).transferFrom(strategy, address(this), buyerAssets);
        }
    }

    function poke(address strategy, bytes32 marketId, uint256 buyerAssets, uint256 units, address buyer)
        external returns (bytes32)
    {
        return ProxyFundingStrategy(strategy).onBuy(
            marketId, market(), buyerAssets, units, 0, buyer, ""
        );
    }

}

contract MockFundingController {

    ERC20Mock public token;

    uint256 public calls;
    bytes32 public lastMarketId;
    uint256 public lastAssets;
    uint256 public lastUnits;

    address public reenterVenue;
    address public reenterStrategy;
    address public reenterBuyer;

    constructor(ERC20Mock token_) {
        token = token_;
    }

    function setReentry(address venue_, address strategy_, address buyer_) external {
        reenterVenue    = venue_;
        reenterStrategy = strategy_;
        reenterBuyer    = buyer_;
    }

    function fundMidnightFill(bytes32 marketId, uint256 assets, uint256 units) external {
        calls++;
        lastMarketId = marketId;
        lastAssets   = assets;
        lastUnits    = units;

        if (reenterVenue != address(0)) {
            MockSettlementVenue(reenterVenue).poke(reenterStrategy, marketId, assets, units, reenterBuyer);
        }

        token.mint(msg.sender, assets);
    }

}

contract ProxyFundingStrategyTestBase is Test {

    event Skimmed(address indexed token, uint256 amount);

    bytes32 constant MARKET_ID = keccak256("market");

    uint256 constant ASSETS = 500e18;
    uint256 constant UNITS  = 1_000e18;

    address proxy = makeAddr("proxy");

    ERC20Mock             loanToken;
    MockSettlementVenue   venue;
    MockFundingController controller;
    ProxyFundingStrategy  strategy;

    function setUp() public virtual {
        loanToken  = new ERC20Mock();
        venue      = new MockSettlementVenue();
        controller = new MockFundingController(loanToken);

        strategy = new ProxyFundingStrategy(address(venue), proxy, address(controller));

        venue.setMarket(_market());
    }

    function _market() internal view returns (Market memory) {
        return Market({
            chainId          : block.chainid,
            midnight         : address(venue),
            loanToken        : address(loanToken),
            collateralParams : new CollateralParams[](0),
            maturity         : block.timestamp + 365 days,
            rcfThreshold     : 0,
            enterGate        : address(0),
            liquidatorGate   : address(0)
        });
    }

    function _settle(uint256 assets, uint256 units) internal returns (bytes32) {
        return venue.settle(address(strategy), MARKET_ID, assets, units, 0, proxy, "");
    }

}

contract ConstructorTests is ProxyFundingStrategyTestBase {

    function test_constructor() public view {
        assertEq(strategy.midnight(),   address(venue));
        assertEq(strategy.proxy(),      proxy);
        assertEq(strategy.controller(), address(controller));
    }

    function test_constructor_callbackSuccessMatchesProtocol() public view {
        assertEq(strategy.CALLBACK_SUCCESS(), keccak256("morpho.midnight.callbackSuccess"));
        assertEq(
            strategy.CALLBACK_SUCCESS(),
            0x7f87788ea698181ea4d28d1576d0ba4fc92c0dbe5bf75b43692af2ce91dbaea2
        );
    }

    function test_constructor_invalidMidnight() public {
        vm.expectRevert("ProxyFundingStrategy/invalid-midnight");
        new ProxyFundingStrategy(address(0), proxy, address(controller));
    }

    function test_constructor_invalidProxy() public {
        vm.expectRevert("ProxyFundingStrategy/invalid-proxy");
        new ProxyFundingStrategy(address(venue), address(0), address(controller));
    }

    function test_constructor_invalidController() public {
        vm.expectRevert("ProxyFundingStrategy/invalid-controller");
        new ProxyFundingStrategy(address(venue), proxy, address(0));
    }

}

contract OnBuyGuardTests is ProxyFundingStrategyTestBase {

    function test_onBuy_callerNotMidnight() public {
        vm.expectRevert("ProxyFundingStrategy/caller-not-midnight");
        strategy.onBuy(MARKET_ID, _market(), ASSETS, UNITS, 0, proxy, "");
    }

    function test_onBuy_callerNotMidnight_evenForTheProxy() public {
        vm.prank(proxy);
        vm.expectRevert("ProxyFundingStrategy/caller-not-midnight");
        strategy.onBuy(MARKET_ID, _market(), ASSETS, UNITS, 0, proxy, "");
    }

    function test_onBuy_buyerNotProxy() public {
        vm.expectRevert("ProxyFundingStrategy/buyer-not-proxy");
        venue.settle(address(strategy), MARKET_ID, ASSETS, UNITS, 0, makeAddr("attacker"), "");

        assertEq(controller.calls(), 0);
    }

    function test_onBuy_buyerNotProxy_zeroBuyerStillRejected() public {
        vm.expectRevert("ProxyFundingStrategy/buyer-not-proxy");
        venue.settle(address(strategy), MARKET_ID, ASSETS, UNITS, 0, address(0), "");
    }

    function test_onBuy_reentrancyLocked() public {
        controller.setReentry(address(venue), address(strategy), proxy);

        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        _settle(ASSETS, UNITS);
    }

    function test_onSell_isNotImplemented() public {
        ( bool success, ) = address(strategy).call(
            abi.encodeWithSelector(
                bytes4(0x6cf21842),
                MARKET_ID, _market(), ASSETS, UNITS, uint256(0), proxy, proxy, bytes("")
            )
        );

        assertFalse(success);
    }

}

contract OnBuyFundingTests is ProxyFundingStrategyTestBase {

    function test_onBuy_fundsAndApprovesExactly() public {
        assertEq(controller.calls(),                                     0);
        assertEq(loanToken.allowance(address(strategy), address(venue)), 0);

        bytes32 ret = _settle(ASSETS, UNITS);

        assertEq(ret, strategy.CALLBACK_SUCCESS());

        assertEq(controller.calls(),       1);
        assertEq(controller.lastMarketId(), MARKET_ID);
        assertEq(controller.lastAssets(),   ASSETS);
        assertEq(controller.lastUnits(),    UNITS);

        assertEq(loanToken.allowance(address(strategy), address(venue)), 0);
        assertEq(loanToken.balanceOf(address(strategy)),                 0);
        assertEq(loanToken.balanceOf(address(venue)),                    ASSETS);
    }

    function test_onBuy_relaysAssetsAndUnitsVerbatim() public {
        _settle(ASSETS, UNITS);

        assertEq(controller.lastAssets(), ASSETS);
        assertEq(controller.lastUnits(),  UNITS);
        assertTrue(controller.lastAssets() != controller.lastUnits());
    }

    function test_onBuy_approvalIsExactNotUnlimited() public {
        // Stop the venue short of pulling, to observe the approval the callback actually left.
        vm.prank(address(venue));
        strategy.onBuy(MARKET_ID, _market(), ASSETS, UNITS, 0, proxy, "");

        assertEq(loanToken.allowance(address(strategy), address(venue)), ASSETS);
    }

    function test_onBuy_zeroAssetsIsAHarmlessSuccess() public {
        bytes32 ret = _settle(0, UNITS);

        assertEq(ret, strategy.CALLBACK_SUCCESS());

        assertEq(controller.calls(),                                     0);
        assertEq(loanToken.allowance(address(strategy), address(venue)), 0);
    }

    function test_onBuy_ignoredArgsDoNotChangeBehaviour() public {
        bytes32 ret = venue.settle(
            address(strategy), MARKET_ID, ASSETS, UNITS, type(uint256).max, proxy, hex"deadbeef"
        );

        assertEq(ret,                     strategy.CALLBACK_SUCCESS());
        assertEq(controller.lastAssets(), ASSETS);
        assertEq(controller.lastUnits(),  UNITS);
    }

    function test_onBuy_consecutiveFillsEachSettleClean() public {
        _settle(ASSETS, UNITS);
        _settle(ASSETS, UNITS);

        assertEq(controller.calls(),                                     2);
        assertEq(loanToken.allowance(address(strategy), address(venue)), 0);
        assertEq(loanToken.balanceOf(address(strategy)),                 0);
        assertEq(loanToken.balanceOf(address(venue)),                    ASSETS * 2);
    }

    function testFuzz_onBuy_settlementAlwaysConsumesTheApproval(uint256 assets, uint256 units)
        public
    {
        assets = bound(assets, 1, 1e36);
        units  = bound(units,  1, 1e36);

        _settle(assets, units);

        assertEq(loanToken.allowance(address(strategy), address(venue)), 0);
        assertEq(loanToken.balanceOf(address(strategy)),                 0);
    }

}

contract SkimTests is ProxyFundingStrategyTestBase {

    function test_skim() public {
        loanToken.mint(address(strategy), 123e18);

        assertEq(loanToken.balanceOf(address(strategy)), 123e18);
        assertEq(loanToken.balanceOf(proxy),             0);

        vm.expectEmit(address(strategy));
        emit Skimmed(address(loanToken), 123e18);
        strategy.skim(address(loanToken));

        assertEq(loanToken.balanceOf(address(strategy)), 0);
        assertEq(loanToken.balanceOf(proxy),             123e18);
    }

    function test_skim_isPermissionless() public {
        loanToken.mint(address(strategy), 1e18);

        vm.prank(makeAddr("anyone"));
        strategy.skim(address(loanToken));

        assertEq(loanToken.balanceOf(proxy), 1e18);
    }

    function test_skim_canOnlySendToTheProxy() public {
        loanToken.mint(address(strategy), 1e18);

        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        strategy.skim(address(loanToken));

        assertEq(loanToken.balanceOf(attacker), 0);
        assertEq(loanToken.balanceOf(proxy),    1e18);
    }

    function test_skim_zeroBalanceIsANoOp() public {
        strategy.skim(address(loanToken));

        assertEq(loanToken.balanceOf(proxy), 0);
    }

    function test_skim_sweepsAnyToken() public {
        ERC20Mock other = new ERC20Mock();

        other.mint(address(strategy), 7e18);

        strategy.skim(address(other));

        assertEq(other.balanceOf(address(strategy)), 0);
        assertEq(other.balanceOf(proxy),             7e18);
    }

}
