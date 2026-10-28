// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test-only mocks use simple ERC-20 calls and bounded uint128 fixtures.
// forge-lint: disable-start(erc20-unchecked-transfer,unsafe-typecast)

import { ZoneRouter } from "../src/ZoneRouter.sol";
import { ZoneRouterFactory } from "../src/ZoneRouterFactory.sol";
import { ISpendSettler } from "../src/interfaces/ISpendSettler.sol";
import { EarnRouterTestBase, IRouterPropAMMPool } from "earn-test/helpers/EarnRouterTestBase.sol";
import { MemoMockToken } from "earn-test/helpers/PropAMMEngineMocks.sol";
import { ZONE_MESSENGER_ADDRESS } from "tempo-earn/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "tempo-earn/router/SingleZoneEarnRouter.sol";

/// @dev A settler whose behavior each test picks. The router sends it `maxInput` up front: pay `use`
///      of it to `payee` and hand back the rest, optionally try to pull more from the router, hand back
///      extra, keep the rest of the input, or re-enter the router.
contract MockSettler is ISpendSettler {
    enum Behavior {
        Pay,
        PullMore,
        HandBackExtra,
        KeepInput,
        Reenter
    }

    Behavior public behavior;
    uint256 public use;
    address public payee;

    function configure(Behavior behavior_, uint256 use_, address payee_) external {
        behavior = behavior_;
        use = use_;
        payee = payee_;
    }

    function settle(address token, uint256 maxInput, bytes calldata) external {
        MemoMockToken input = MemoMockToken(token);
        if (behavior == Behavior.PullMore) {
            // The router grants no allowance, so this reverts.
            input.transferFrom(msg.sender, address(this), 1);
            return;
        }
        if (behavior == Behavior.Reenter) {
            ZoneRouter(msg.sender).onWithdrawalReceived(0, address(0), bytes32(0), token, 1, "");
            return;
        }
        input.transfer(payee, use);
        if (behavior == Behavior.KeepInput) return;
        uint256 back = maxInput - use;
        if (behavior == Behavior.HandBackExtra) back += 1;
        input.transfer(msg.sender, back);
    }
}

contract ZoneRouterTest is EarnRouterTestBase {
    ZoneRouterFactory internal factory;
    MockSettler internal settler;
    IRouterPropAMMPool internal pool;
    address internal payee = makeAddr("payee");

    /// @dev Earn owns the pinned DirectPropAMM fixture; this project reads it from there.
    function _propAMMArtifact() internal pure override returns (string memory) {
        return "../earn/test/fixtures/propamm/DirectPropAMM.json";
    }

    function setUp() public override {
        super.setUp();
        factory = new ZoneRouterFactory();
        settler = new MockSettler();
        pool = _routerPool(address(alternate), address(assetA));
        // Settlers hand back their unused input, so they hold some to return extra from.
        alternate.mint(address(settler), ONE);
    }

    // ---------------------------------------------------------------------------------------------
    // Modes and the factory
    // ---------------------------------------------------------------------------------------------

    function testEarnModeIsByteCompatibleWithSingleZoneEarnRouter() public {
        ZoneRouter zr = _earnRouter(false);
        alternate.mint(address(zr), ONE);
        // Callback data encoded with SingleZoneEarnRouter's own struct.
        bytes memory data = _callback(SingleZoneEarnRouter.Flow.Deposit, uint128(ONE), uint128(ONE), 0);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        zr.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), data);
        assertEq(earnA.balanceOf(address(portalA)), ONE);
        _assertEmpty(zr);

        portalA.release(address(earnA), address(zr), ONE);
        bytes memory redeem = _callback(SingleZoneEarnRouter.Flow.Redeem, uint128(ONE), 0, uint128(ONE));
        vm.prank(ZONE_MESSENGER_ADDRESS);
        zr.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), address(earnA), uint128(ONE), redeem);
        assertEq(alternate.balanceOf(address(portalA)), ONE);
        _assertEmpty(zr);
    }

    /// @notice The Earn preset reports the same views clients read from SingleZoneEarnRouter.
    function testEarnModeReportsTheSameViewsAsSingleZoneEarnRouter() public {
        ZoneRouter zr = _earnRouter(false);
        SingleZoneEarnRouter legacy = _admittedRouter(pool);
        assertEq(zr.parPrice(), legacy.parPrice());
        assertEq(zr.privateAssetIsBase(), legacy.privateAssetIsBase());
        (bool p1, bool a1, bool r1, uint256 d1, uint256 l1) = zr.liquidityStatus();
        (bool p2, bool a2, bool r2, uint256 d2, uint256 l2) = legacy.liquidityStatus();
        assertEq(abi.encode(p1, a1, r1, d1, l1), abi.encode(p2, a2, r2, d2, l2));
        assertTrue(a1, "admitted");
        for (uint8 flow = 0; flow < 2; flow++) {
            assertEq(zr.supportsFlow(flow), legacy.supportsFlow(flow));
        }
    }

    function testFactoryDeploysAtPredictedAddressOnce() public {
        ZoneRouter.Mode memory mode = _spendMode();
        address predicted = factory.predict(mode);
        assertFalse(factory.isRouter(predicted));

        vm.expectEmit(true, true, false, true, address(factory));
        emit ZoneRouterFactory.RouterDeployed(predicted, keccak256(abi.encode(mode)), mode);
        address router_ = factory.deploy(mode);
        assertEq(router_, predicted);
        assertTrue(factory.isRouter(router_));
        assertEq(factory.deploy(mode), router_);

        address[] memory listed = ZoneRouter(router_).settlers();
        assertEq(listed.length, 1);
        assertEq(listed[0], address(settler));
        assertEq(ZoneRouter(router_).enabledOps(), uint8(1 << 2));
        assertEq(ZoneRouter(router_).earnVault(), address(0));
    }

    function testSettlerOrderIsPartOfTheMode() public {
        MockSettler other = new MockSettler();
        ZoneRouter.Mode memory a = _spendMode();
        a.settlers = new address[](2);
        a.settlers[0] = address(settler);
        a.settlers[1] = address(other);
        ZoneRouter.Mode memory b = _spendMode();
        b.settlers = new address[](2);
        b.settlers[0] = address(other);
        b.settlers[1] = address(settler);
        assertTrue(factory.predict(a) != factory.predict(b));
    }

    function testConstructorRejectsInconsistentModes() public {
        ZoneRouter.Mode memory mode = _spendMode();
        mode.zoneId = 0;
        vm.expectRevert(ZoneRouter.WrongSourceZone.selector);
        new ZoneRouter(mode);

        mode = _spendMode();
        mode.enabledOps = 0;
        vm.expectRevert(ZoneRouter.InvalidOps.selector);
        new ZoneRouter(mode);

        mode.enabledOps = 1 << 3;
        vm.expectRevert(ZoneRouter.InvalidOps.selector);
        new ZoneRouter(mode);

        mode = _spendMode();
        mode.settlers = new address[](0);
        vm.expectRevert(ZoneRouter.InvalidSettlers.selector);
        new ZoneRouter(mode);

        mode = _spendMode();
        mode.settlers = new address[](2);
        mode.settlers[0] = address(settler);
        mode.settlers[1] = address(settler);
        vm.expectRevert(ZoneRouter.InvalidSettlers.selector);
        new ZoneRouter(mode);

        mode = _spendMode();
        mode.settlers[0] = makeAddr("eoa");
        vm.expectRevert(ZoneRouter.InvalidSettlers.selector);
        new ZoneRouter(mode);

        mode = _spendMode();
        mode.earnVault = address(earnVaultA);
        vm.expectRevert(ZoneRouter.InvalidEarnBinding.selector);
        new ZoneRouter(mode);

        mode = _earnMode(false);
        mode.settlers = new address[](1);
        mode.settlers[0] = address(settler);
        vm.expectRevert(ZoneRouter.InvalidSettlers.selector);
        new ZoneRouter(mode);
    }

    function testDisabledOpsRevert() public {
        ZoneRouter earnOnly = _earnRouter(false);
        alternate.mint(address(earnOnly), ONE);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.OpDisabled.selector);
        earnOnly.onWithdrawalReceived(
            ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), _spend(address(settler), ONE, 0)
        );

        ZoneRouter spendOnly = _spendRouter();
        alternate.mint(address(spendOnly), ONE);
        bytes memory deposit = _callback(SingleZoneEarnRouter.Flow.Deposit, uint128(ONE), uint128(ONE), 0);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.OpDisabled.selector);
        spendOnly.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), deposit);
        assertFalse(spendOnly.supportsFlow(0));
        assertTrue(spendOnly.supportsFlow(2));
        assertFalse(spendOnly.supportsFlow(3));
    }

    // ---------------------------------------------------------------------------------------------
    // Spend
    // ---------------------------------------------------------------------------------------------

    function testSpendPaysThroughSettlerAndReturnsChange() public {
        ZoneRouter zr = _spendRouter();
        settler.configure(MockSettler.Behavior.Pay, 5 * ONE, payee);
        alternate.mint(address(zr), 10 * ONE);

        vm.expectEmit(true, true, false, false, address(zr));
        emit ZoneRouter.Spent(address(settler), address(alternate), 5 * ONE, 5 * ONE, bytes32(0));
        _deliverSpend(zr, 10 * ONE, 6 * ONE, 0);

        assertEq(alternate.balanceOf(payee), 5 * ONE);
        assertEq(portalA.lastToken(), address(alternate));
        assertEq(portalA.lastAmount(), 5 * ONE);
        assertEq(portalA.lastRefundRecipient(), refundRecipient);
        _assertEmpty(zr);
        assertEq(alternate.allowance(address(zr), address(settler)), 0);
    }

    /// @notice The change's approval to the Portal stays standing, so a later spend sets no new slot,
    ///         and the Portal still takes exactly the change.
    function testSpendLeavesAStandingPortalApproval() public {
        ZoneRouter zr = _spendRouter();
        settler.configure(MockSettler.Behavior.Pay, 5 * ONE, payee);
        alternate.mint(address(zr), 10 * ONE);
        _deliverSpend(zr, 10 * ONE, 6 * ONE, 0);
        assertGt(alternate.allowance(address(zr), address(portalA)), type(uint128).max);

        alternate.mint(address(zr), 10 * ONE);
        _deliverSpend(zr, 10 * ONE, 6 * ONE, 0);
        assertEq(portalA.lastAmount(), 5 * ONE);
        assertEq(alternate.balanceOf(address(zr)), 0);
    }

    /// @notice Anyone may set the router's standing approval to its own Zone's Portal ahead of the
    ///         first spend.
    function testWarmApprovesTheZonePortal() public {
        ZoneRouter zr = _spendRouter();
        vm.prank(makeAddr("anyone"));
        zr.warm(address(alternate));
        assertEq(alternate.allowance(address(zr), address(portalA)), type(uint256).max);
    }

    /// @notice An Earn-only router cannot be warmed, so it never holds a standing Portal approval.
    function testWarmRefusesAnEarnOnlyRouter() public {
        ZoneRouter zr = _earnRouter(false);
        vm.expectRevert(ZoneRouter.OpDisabled.selector);
        zr.warm(address(alternate));
    }

    function testSpendUsingEverythingReturnsNothing() public {
        ZoneRouter zr = _spendRouter();
        settler.configure(MockSettler.Behavior.Pay, 3 * ONE, payee);
        alternate.mint(address(zr), 3 * ONE);
        uint256 depositsBefore = portalA.depositCount();
        _deliverSpend(zr, 3 * ONE, 3 * ONE, 0);
        assertEq(portalA.depositCount(), depositsBefore);
        _assertEmpty(zr);
    }

    /// @notice The cardholder's maxInput bounds what any settler, or a handler behind it, can take: the
    ///         router sends exactly maxInput and grants no allowance to pull more.
    function testSettlerCannotTakeMoreThanMaxInput() public {
        ZoneRouter zr = _spendRouter();
        settler.configure(MockSettler.Behavior.PullMore, 0, payee);
        _expectSpendRevert(zr, 10 * ONE, 4 * ONE, bytes(""));
    }

    function testSettlerThatKeepsInputCountsOnlyWithinMaxInput() public {
        // Keeping unused input is bounded by the transfer: the settler got maxInput and the rest returns.
        ZoneRouter zr = _spendRouter();
        settler.configure(MockSettler.Behavior.KeepInput, ONE, payee);
        alternate.mint(address(zr), 10 * ONE);
        _deliverSpend(zr, 10 * ONE, 4 * ONE, 0);
        assertEq(portalA.lastAmount(), 6 * ONE);
        _assertEmpty(zr);
    }

    function testSettlementThatUsesNothingOrHandsBackExtraReverts() public {
        ZoneRouter zr = _spendRouter();
        settler.configure(MockSettler.Behavior.Pay, 0, payee);
        _expectSpendRevert(zr, ONE, ONE, abi.encodeWithSelector(ZoneRouter.InvalidSettlement.selector));

        settler.configure(MockSettler.Behavior.HandBackExtra, 0, payee);
        _expectSpendRevert(zr, ONE, ONE, abi.encodeWithSelector(ZoneRouter.InvalidSettlement.selector));
    }

    function testSpendRejectsUnknownSettlerAndBadMaxInput() public {
        ZoneRouter zr = _spendRouter();
        MockSettler stranger = new MockSettler();
        alternate.mint(address(zr), ONE);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.UnknownSettler.selector);
        zr.onWithdrawalReceived(
            ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), _spend(address(stranger), ONE, 0)
        );

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.InvalidMaxInput.selector);
        zr.onWithdrawalReceived(
            ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), _spend(address(settler), 0, 0)
        );

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.InvalidMaxInput.selector);
        zr.onWithdrawalReceived(
            ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), _spend(address(settler), ONE + 1, 0)
        );
    }

    function testSpendCapsTheDepositFee() public {
        ZoneRouter zr = _spendRouter();
        settler.configure(MockSettler.Behavior.Pay, ONE, payee);
        portalA.setDepositFee(100);
        _expectSpendRevert(
            zr, 2 * ONE, ONE, abi.encodeWithSelector(ZoneRouter.DepositFeeTooHigh.selector, uint128(100))
        );
    }

    function testSpendRejectsReentryFromSettler() public {
        ZoneRouter zr = _spendRouter();
        settler.configure(MockSettler.Behavior.Reenter, 0, payee);
        _expectSpendRevert(zr, ONE, ONE, abi.encodeWithSelector(ZoneRouter.ReentrantCall.selector));
    }

    function testSpendOnlyFromMessengerZoneAndPortal() public {
        ZoneRouter zr = _spendRouter();
        alternate.mint(address(zr), ONE);
        bytes memory data = _spend(address(settler), ONE, 0);
        vm.expectRevert(ZoneRouter.NotZoneMessenger.selector);
        zr.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), data);

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.WrongSourceZone.selector);
        zr.onWithdrawalReceived(ZONE_B, address(portalB), bytes32(0), address(alternate), uint128(ONE), data);

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.InvalidSourcePortal.selector);
        zr.onWithdrawalReceived(ZONE_A, address(portalB), bytes32(0), address(alternate), uint128(ONE), data);
    }

    function testFuzzSpendNeverTakesMoreThanMaxInput(uint96 amount, uint96 maxInput, uint96 use) public {
        amount = uint96(bound(amount, 1, 1e12));
        maxInput = uint96(bound(maxInput, 1, amount));
        use = uint96(bound(use, 1, maxInput));
        ZoneRouter zr = _spendRouter();
        settler.configure(MockSettler.Behavior.Pay, use, payee);
        alternate.mint(address(zr), amount);
        _deliverSpend(zr, amount, maxInput, 0);
        assertEq(alternate.balanceOf(payee), use);
        assertEq(alternate.balanceOf(address(portalA)), amount - use);
        _assertEmpty(zr);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _earnMode(bool withSpend) internal view returns (ZoneRouter.Mode memory mode) {
        mode.zoneId = ZONE_A;
        mode.enabledOps = withSpend ? uint8(7) : uint8(3);
        mode.earnVault = address(earnVaultA);
        mode.privateAsset = address(alternate);
        mode.pool = address(pool);
        mode.customerId = CUSTOMER_ID;
        mode.settlers = new address[](withSpend ? 1 : 0);
        if (withSpend) mode.settlers[0] = address(settler);
    }

    function _spendMode() internal view returns (ZoneRouter.Mode memory mode) {
        mode.zoneId = ZONE_A;
        mode.enabledOps = uint8(1 << 2);
        mode.settlers = new address[](1);
        mode.settlers[0] = address(settler);
    }

    function _earnRouter(bool withSpend) internal returns (ZoneRouter zr) {
        zr = ZoneRouter(factory.deploy(_earnMode(withSpend)));
        pool.setTakerAllowed(address(zr), true);
        pool.setRecipientAllowed(address(zr), true);
    }

    function _spendRouter() internal returns (ZoneRouter) {
        return ZoneRouter(factory.deploy(_spendMode()));
    }

    function _spend(address settler_, uint256 maxInput, uint128 maxDepositFee) internal view returns (bytes memory) {
        return abi.encode(
            ZoneRouter.SpendData({
                op: ZoneRouter.Op.Spend,
                settler: settler_,
                maxInput: uint128(maxInput),
                settlerData: hex"",
                zoneReturn: ZoneRouter.SpendReturn({
                    keyIndex: 1, encrypted: _encrypted(), refundRecipient: refundRecipient, maxDepositFee: maxDepositFee
                })
            })
        );
    }

    function _deliverSpend(ZoneRouter zr, uint256 amount, uint256 maxInput, uint128 maxDepositFee) internal {
        vm.prank(ZONE_MESSENGER_ADDRESS);
        zr.onWithdrawalReceived(
            ZONE_A,
            address(portalA),
            bytes32(0),
            address(alternate),
            uint128(amount),
            _spend(address(settler), maxInput, maxDepositFee)
        );
    }

    /// @dev A rejected spend moves nothing: the payee, Zone and settler balances are unchanged and the
    ///      router holds exactly the delivered input, with no allowance left.
    function _expectSpendRevert(ZoneRouter zr, uint256 amount, uint256 maxInput, bytes memory reason) internal {
        alternate.mint(address(zr), amount);
        uint256 payeeBefore = alternate.balanceOf(payee);
        uint256 settlerBefore = alternate.balanceOf(address(settler));
        uint256 depositsBefore = portalA.depositCount();
        vm.prank(ZONE_MESSENGER_ADDRESS);
        if (reason.length == 0) vm.expectRevert();
        else vm.expectRevert(reason);
        zr.onWithdrawalReceived(
            ZONE_A,
            address(portalA),
            bytes32(0),
            address(alternate),
            uint128(amount),
            _spend(address(settler), maxInput, 0)
        );
        assertEq(alternate.balanceOf(payee), payeeBefore);
        assertEq(alternate.balanceOf(address(settler)), settlerBefore);
        assertEq(portalA.depositCount(), depositsBefore);
        assertEq(alternate.balanceOf(address(zr)), amount);
        assertEq(alternate.allowance(address(zr), address(settler)), 0);
        // Clear the undelivered input so later cases start empty.
        vm.prank(address(zr));
        alternate.transfer(address(0xdead), amount);
    }

    function _assertEmpty(ZoneRouter zr) internal view {
        MemoMockToken[3] memory tokens = [alternate, assetA, earnA];
        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(tokens[i].balanceOf(address(zr)), 0);
            // A spend leaves its standing approval to the Portal (less what deposits used); nothing else.
            uint256 portalAllowance = tokens[i].allowance(address(zr), address(portalA));
            assertTrue(portalAllowance == 0 || portalAllowance > type(uint128).max, "portal allowance");
            assertEq(tokens[i].allowance(address(zr), address(settler)), 0);
            assertEq(tokens[i].allowance(address(zr), address(earnVaultA)), 0);
            assertEq(tokens[i].allowance(address(zr), address(pool)), 0);
        }
    }
}
