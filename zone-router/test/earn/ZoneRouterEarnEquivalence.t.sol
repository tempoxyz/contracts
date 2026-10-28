// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Test-only mocks use simple ERC-20 calls and bounded uint128 fixtures; low-level calls capture both outcomes.
// forge-lint: disable-start(erc20-unchecked-transfer,unsafe-typecast,low-level-calls)

import { ZoneRouter } from "../../src/ZoneRouter.sol";
import { ISpendSettler } from "../../src/interfaces/ISpendSettler.sol";
import { ZoneRouterEarnTestBase } from "./ZoneRouterEarnTestBase.sol";
import { IRouterPropAMMPool } from "earn-test/helpers/EarnRouterTestBase.sol";
import { MemoMockToken } from "earn-test/helpers/PropAMMEngineMocks.sol";
import { Vm } from "forge-std/Vm.sol";
import {
    EncryptedDepositPayload,
    IWithdrawalReceiver,
    ZONE_MESSENGER_ADDRESS
} from "tempo-earn/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "tempo-earn/router/SingleZoneEarnRouter.sol";

/// @dev Pays a configured part of the input the router sent to a payee and hands the rest back.
contract PayingSettler is ISpendSettler {
    address public immutable payee;
    uint256 public use;

    constructor(address payee_) {
        payee = payee_;
    }

    function setUse(uint256 use_) external {
        use = use_;
    }

    function settle(address token, uint256 maxInput, bytes calldata) external {
        MemoMockToken(token).transfer(payee, use);
        MemoMockToken(token).transfer(msg.sender, maxInput - use);
    }
}

/// @dev Differential tests: for the same state and callback, ZoneRouter's Earn ops (with and without Spend
///      enabled) and SingleZoneEarnRouter succeed or fail alike, with the same revert data, events, Zone
///      deposit and resulting balances. The one intended difference is raw op 2, which SingleZoneEarnRouter
///      rejects as BadFlow, an Earn-only ZoneRouter as OpDisabled, and a ZoneRouter with Spend decodes as
///      Spend data.
contract ZoneRouterEarnEquivalenceTest is ZoneRouterEarnTestBase {
    uint256 private constant HAZARDS = 7;

    struct Case {
        bool sameAsset;
        uint8 op;
        uint8 token;
        uint128 amount;
        uint128 minVaultAssets;
        uint128 minSecondLeg;
        uint8 hazard;
        bool zeroRefund;
        bytes32 actionId;
    }

    struct Outcome {
        bool ok;
        bytes ret;
        bytes32 events;
        bytes32 state;
    }

    IRouterPropAMMPool private pool;
    PayingSettler private settler;
    address private payee = makeAddr("payee");

    SingleZoneEarnRouter private legacy;
    ZoneRouter private earnOnly;
    ZoneRouter private earnAndSpend;
    SingleZoneEarnRouter private legacySame;
    ZoneRouter private earnOnlySame;
    ZoneRouter private earnAndSpendSame;

    function setUp() public override {
        super.setUp();
        pool = _routerPool(address(alternate), address(assetA));
        settler = new PayingSettler(payee);

        legacy = new SingleZoneEarnRouter(ZONE_A, address(earnVaultA), address(alternate), address(pool), CUSTOMER_ID);
        earnOnly = _zoneRouterFor(3, address(alternate), address(pool), CUSTOMER_ID);
        earnAndSpend = _zoneRouterFor(7, address(alternate), address(pool), CUSTOMER_ID);
        address[3] memory converting = [address(legacy), address(earnOnly), address(earnAndSpend)];
        for (uint256 i = 0; i < converting.length; i++) {
            pool.setTakerAllowed(converting[i], true);
            pool.setRecipientAllowed(converting[i], true);
        }

        legacySame = new SingleZoneEarnRouter(ZONE_A, address(earnVaultA), address(assetA), address(0), bytes32(0));
        earnOnlySame = _zoneRouterFor(3, address(assetA), address(0), bytes32(0));
        earnAndSpendSame = _zoneRouterFor(7, address(assetA), address(0), bytes32(0));
    }

    // ---------------------------------------------------------------------------------------------
    // Layout and views
    // ---------------------------------------------------------------------------------------------

    function testFuzzCallbackStructsEncodeIdentically(
        bool redeemFlow,
        uint128 minVaultAssets,
        uint128 minEarnShares,
        uint128 minOutputAmount,
        bytes32 actionId,
        uint256 keyIndex,
        EncryptedDepositPayload memory encrypted,
        address refund
    ) public pure {
        bytes memory legacyData = abi.encode(
            SingleZoneEarnRouter.CallbackData({
                flow: redeemFlow ? SingleZoneEarnRouter.Flow.Redeem : SingleZoneEarnRouter.Flow.Deposit,
                minVaultAssets: minVaultAssets,
                minEarnShares: minEarnShares,
                minOutputAmount: minOutputAmount,
                actionId: actionId,
                zoneReturn: SingleZoneEarnRouter.ZoneReturn({
                    keyIndex: keyIndex, encrypted: encrypted, refundRecipient: refund
                })
            })
        );
        bytes memory zoneRouterData = abi.encode(
            ZoneRouter.CallbackData({
                op: redeemFlow ? ZoneRouter.Op.Redeem : ZoneRouter.Op.Deposit,
                minVaultAssets: minVaultAssets,
                minEarnShares: minEarnShares,
                minOutputAmount: minOutputAmount,
                actionId: actionId,
                zoneReturn: ZoneRouter.ZoneReturn({ keyIndex: keyIndex, encrypted: encrypted, refundRecipient: refund })
            })
        );
        assertEq(zoneRouterData, legacyData);
    }

    /// @dev Events and errors keep SingleZoneEarnRouter's signatures, so clients decode both alike.
    function testEventsAndErrorsShareSingleZoneEarnRouterSelectors() public pure {
        assertEq(ZoneRouter.EarnDeposit.selector, SingleZoneEarnRouter.EarnDeposit.selector);
        assertEq(ZoneRouter.EarnRedeem.selector, SingleZoneEarnRouter.EarnRedeem.selector);
        bytes4[18] memory zoneRouterErrors = [
            ZoneRouter.AmountOverflow.selector,
            ZoneRouter.BadFlow.selector,
            ZoneRouter.InsufficientOutput.selector,
            ZoneRouter.InvalidCustomerId.selector,
            ZoneRouter.InvalidEarnVault.selector,
            ZoneRouter.InvalidPool.selector,
            ZoneRouter.InvalidPrivateAsset.selector,
            ZoneRouter.InvalidReturnToken.selector,
            ZoneRouter.InvalidRoutePair.selector,
            ZoneRouter.InvalidSourcePortal.selector,
            ZoneRouter.NotZoneMessenger.selector,
            ZoneRouter.ReentrantCall.selector,
            ZoneRouter.ResidualBalance.selector,
            ZoneRouter.TokenCallFailed.selector,
            ZoneRouter.TokenCallFalse.selector,
            ZoneRouter.WrongInputToken.selector,
            ZoneRouter.WrongSourceZone.selector,
            ZoneRouter.ZeroAmount.selector
        ];
        bytes4[18] memory legacyErrors = [
            SingleZoneEarnRouter.AmountOverflow.selector,
            SingleZoneEarnRouter.BadFlow.selector,
            SingleZoneEarnRouter.InsufficientOutput.selector,
            SingleZoneEarnRouter.InvalidCustomerId.selector,
            SingleZoneEarnRouter.InvalidEarnVault.selector,
            SingleZoneEarnRouter.InvalidPool.selector,
            SingleZoneEarnRouter.InvalidPrivateAsset.selector,
            SingleZoneEarnRouter.InvalidReturnToken.selector,
            SingleZoneEarnRouter.InvalidRoutePair.selector,
            SingleZoneEarnRouter.InvalidSourcePortal.selector,
            SingleZoneEarnRouter.NotZoneMessenger.selector,
            SingleZoneEarnRouter.ReentrantCall.selector,
            SingleZoneEarnRouter.ResidualBalance.selector,
            SingleZoneEarnRouter.TokenCallFailed.selector,
            SingleZoneEarnRouter.TokenCallFalse.selector,
            SingleZoneEarnRouter.WrongInputToken.selector,
            SingleZoneEarnRouter.WrongSourceZone.selector,
            SingleZoneEarnRouter.ZeroAmount.selector
        ];
        for (uint256 i = 0; i < zoneRouterErrors.length; i++) {
            assertEq(zoneRouterErrors[i], legacyErrors[i]);
        }
    }

    /// @dev Every view SingleZoneEarnRouter exposes reads the same, except supportsFlow(2) with Spend enabled.
    function testViewsMatchSingleZoneEarnRouter() public {
        _assertSameViews(legacy, earnOnly, false);
        _assertSameViews(legacy, earnAndSpend, true);
        _assertSameViews(legacySame, earnOnlySame, false);
        _assertSameViews(legacySame, earnAndSpendSame, true);

        pool.pause();
        oracle.set(PAR + 1, vm.getBlockTimestamp());
        pool.setTakerAllowed(address(earnOnly), false);
        pool.setTakerAllowed(address(legacy), false);
        _assertSameViews(legacy, earnOnly, false);
    }

    // ---------------------------------------------------------------------------------------------
    // Differential callbacks
    // ---------------------------------------------------------------------------------------------

    /// @dev Well-formed callbacks for every op value, input token, bound and failure source.
    function testFuzzCallbacksMatchSingleZoneEarnRouter(
        bool sameAsset,
        uint8 rawOp,
        uint8 rawToken,
        uint128 rawAmount,
        uint128 rawMinVaultAssets,
        uint128 rawMinSecondLeg,
        uint8 rawHazard,
        bool zeroRefund,
        bytes32 actionId
    ) public {
        Case memory c;
        c.sameAsset = sameAsset;
        c.op = uint8(bound(rawOp, 0, 3));
        c.token = uint8(bound(rawToken, 0, 2));
        c.amount = uint128(bound(rawAmount, 0, 2 * POOL_INVENTORY));
        c.minVaultAssets = uint128(bound(rawMinVaultAssets, 0, uint256(c.amount) + 1));
        c.minSecondLeg = uint128(bound(rawMinSecondLeg, 0, uint256(c.amount) + 1));
        c.hazard = uint8(bound(rawHazard, 0, HAZARDS));
        c.zeroRefund = zeroRefund;
        c.actionId = actionId;

        _compare(c, _callbackFor(c));
    }

    /// @dev Arbitrary callback bytes for a delivered private-asset deposit.
    function testFuzzArbitraryCallbackBytesMatchSingleZoneEarnRouter(bool sameAsset, bytes calldata callbackData)
        public
    {
        Case memory c;
        c.sameAsset = sameAsset;
        c.amount = uint128(ONE);
        c.op = _rawOp(callbackData);
        _compare(c, callbackData);
    }

    /// @dev The documented successful round trip, run through all three routers.
    function testDepositAndRedeemMatchSingleZoneEarnRouter() public {
        for (uint256 same = 0; same < 2; same++) {
            Case memory c;
            c.sameAsset = same == 1;
            c.amount = uint128(3 * ONE);
            c.minVaultAssets = c.amount;
            c.minSecondLeg = c.amount;
            c.actionId = ACTION_ID;
            Outcome memory deposit = _compare(c, _callbackFor(c));
            assertTrue(deposit.ok);

            c.op = 1;
            c.token = 1;
            Outcome memory redemption = _compare(c, _callbackFor(c));
            assertTrue(redemption.ok);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Spend alongside Earn
    // ---------------------------------------------------------------------------------------------

    /// @dev With Spend enabled, Spend and Earn ops interleave on one router without affecting each other.
    function testSpendAndEarnOpsInterleave() public {
        ZoneRouter zr = _zoneRouterFor(7, address(alternate), address(pool), CUSTOMER_ID, address(settler));
        pool.setTakerAllowed(address(zr), true);
        pool.setRecipientAllowed(address(zr), true);
        _use(zr);
        settler.setUse(ONE);

        _deposit(2 * ONE, 2 * ONE, 2 * ONE);
        assertEq(earnA.balanceOf(address(portalA)), 2 * ONE);
        _assertRouterState(0, 0, 0);

        alternate.mint(address(zr), 3 * ONE);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        zr.onWithdrawalReceived(
            ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(3 * ONE), _spend(2 * ONE)
        );
        assertEq(alternate.balanceOf(payee), ONE);
        assertEq(portalA.lastToken(), address(alternate));
        assertEq(portalA.lastAmount(), 2 * ONE);
        // The spend leaves only its standing approval to the Portal, which the Earn ops share.
        uint256 standing = alternate.allowance(address(zr), address(portalA));
        assertGt(standing, type(uint128).max);
        _assertBalances(zr);
        assertEq(alternate.allowance(address(zr), address(settler)), 0);

        portalA.release(address(earnA), address(zr), 2 * ONE);
        _redeem(2 * ONE, 2 * ONE, 2 * ONE);
        assertEq(portalA.lastToken(), address(alternate));
        assertEq(portalA.lastAmount(), 2 * ONE);
        assertEq(earnA.totalSupply(), 0);
        // The redeem's output went back through the same standing approval and left it standing.
        assertGt(alternate.allowance(address(zr), address(portalA)), type(uint128).max);
        _assertBalances(zr);
        assertEq(portalA.depositCount(), 3);
    }

    /// @dev The router holds none of the three tokens, approves the pool and vault nothing, and keeps
    ///      at most a standing approval to its Portal (none or more than any amount it moves).
    function _assertBalances(ZoneRouter zr) private view {
        MemoMockToken[3] memory tokens = [alternate, assetA, earnA];
        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(tokens[i].balanceOf(address(zr)), 0);
            assertEq(tokens[i].allowance(address(zr), address(pool)), 0);
            assertEq(tokens[i].allowance(address(zr), address(earnVaultA)), 0);
            uint256 portal = tokens[i].allowance(address(zr), address(portalA));
            assertTrue(portal == 0 || portal > type(uint128).max, "portal allowance");
        }
    }

    /// @dev Spend data sent to an Earn-only router is rejected before any decoding or transfer.
    function testSpendDataOnEarnOnlyRouterIsRejected() public {
        alternate.mint(address(earnOnly), ONE);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneRouter.OpDisabled.selector);
        earnOnly.onWithdrawalReceived(
            ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), _spend(ONE)
        );

        alternate.mint(address(legacy), ONE);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(SingleZoneEarnRouter.BadFlow.selector);
        legacy.onWithdrawalReceived(ZONE_A, address(portalA), bytes32(0), address(alternate), uint128(ONE), _spend(ONE));

        assertEq(alternate.balanceOf(address(earnOnly)), ONE);
        assertEq(portalA.depositCount(), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _zoneRouterFor(uint8 ops, address privateAsset, address pool_, bytes32 customerId)
        private
        returns (ZoneRouter)
    {
        return _zoneRouterFor(ops, privateAsset, pool_, customerId, address(idleSettler));
    }

    function _zoneRouterFor(uint8 ops, address privateAsset, address pool_, bytes32 customerId, address settler_)
        private
        returns (ZoneRouter)
    {
        ZoneRouter.Mode memory mode = _earnMode(ZONE_A, privateAsset, pool_, customerId);
        mode.enabledOps = ops;
        mode.settlers = new address[](ops & 4 != 0 ? 1 : 0);
        if (ops & 4 != 0) mode.settlers[0] = settler_;
        return ZoneRouter(factory.deploy(mode));
    }

    function _assertSameViews(SingleZoneEarnRouter old, ZoneRouter zr, bool spends) private view {
        assertEq(zr.allowedZoneId(), old.allowedZoneId());
        assertEq(zr.earnVault(), old.earnVault());
        assertEq(zr.privateAsset(), old.privateAsset());
        assertEq(zr.vaultAsset(), old.vaultAsset());
        assertEq(zr.earnShare(), old.earnShare());
        assertEq(address(zr.pool()), address(old.pool()));
        assertEq(zr.customerId(), old.customerId());
        assertEq(zr.privateAssetIsBase(), old.privateAssetIsBase());
        assertEq(zr.parPrice(), old.parPrice());
        (bool p1, bool a1, bool r1, uint256 d1, uint256 l1) = zr.liquidityStatus();
        (bool p2, bool a2, bool r2, uint256 d2, uint256 l2) = old.liquidityStatus();
        assertEq(abi.encode(p1, a1, r1, d1, l1), abi.encode(p2, a2, r2, d2, l2));
        for (uint256 flow = 0; flow <= type(uint8).max; flow++) {
            bool expected = old.supportsFlow(uint8(flow)) || (spends && flow == 2);
            assertEq(zr.supportsFlow(uint8(flow)), expected);
        }
    }

    function _callbackFor(Case memory c) private view returns (bytes memory data) {
        bool redeemShape = c.op == 1;
        data = abi.encode(
            SingleZoneEarnRouter.CallbackData({
                flow: SingleZoneEarnRouter.Flow.Deposit,
                minVaultAssets: c.minVaultAssets,
                minEarnShares: redeemShape ? 0 : c.minSecondLeg,
                minOutputAmount: redeemShape ? c.minSecondLeg : 0,
                actionId: c.actionId,
                zoneReturn: SingleZoneEarnRouter.ZoneReturn({
                    keyIndex: 1, encrypted: _encrypted(), refundRecipient: c.zeroRefund ? address(0) : refundRecipient
                })
            })
        );
        // The op word follows the tuple offset; raw values past the enum need it written directly.
        data[63] = bytes1(c.op);
    }

    function _spend(uint256 maxInput) private view returns (bytes memory) {
        return abi.encode(
            ZoneRouter.SpendData({
                op: ZoneRouter.Op.Spend,
                settler: address(settler),
                maxInput: uint128(maxInput),
                settlerData: hex"",
                zoneReturn: ZoneRouter.SpendReturn({
                    keyIndex: 1, encrypted: _encrypted(), refundRecipient: refundRecipient, maxDepositFee: 0
                })
            })
        );
    }

    /// @dev Runs `data` through the legacy router and both ZoneRouter modes from the same state and compares.
    function _compare(Case memory c, bytes memory data) private returns (Outcome memory expected) {
        (SingleZoneEarnRouter old, ZoneRouter only, ZoneRouter both) =
            c.sameAsset ? (legacySame, earnOnlySame, earnAndSpendSame) : (legacy, earnOnly, earnAndSpend);
        uint256 snapshot = vm.snapshotState();
        expected = _run(address(old), c, data);
        vm.revertToState(snapshot);
        Outcome memory earnOnlyOutcome = _run(address(only), c, data);
        vm.revertToState(snapshot);
        Outcome memory earnAndSpendOutcome = _run(address(both), c, data);
        vm.revertToState(snapshot);

        if (
            !expected.ok && c.op == 2
                && keccak256(expected.ret) == keccak256(abi.encodeWithSelector(SingleZoneEarnRouter.BadFlow.selector))
        ) {
            // The one intended difference: op 2 is Spend in ZoneRouter.
            assertEq(earnOnlyOutcome.ret, abi.encodeWithSelector(ZoneRouter.OpDisabled.selector), "earn-only op 2");
            assertFalse(earnAndSpendOutcome.ok, "earn data as spend");
            assertEq(earnOnlyOutcome.state, expected.state, "earn-only op 2 state");
            assertEq(earnAndSpendOutcome.state, expected.state, "earn-and-spend op 2 state");
            return expected;
        }
        _assertSameOutcome(expected, earnOnlyOutcome, "earn-only");
        _assertSameOutcome(expected, earnAndSpendOutcome, "earn-and-spend");
    }

    function _assertSameOutcome(Outcome memory expected, Outcome memory actual, string memory label) private pure {
        assertEq(actual.ok, expected.ok, label);
        assertEq(actual.ret, expected.ret, label);
        assertEq(actual.events, expected.events, label);
        assertEq(actual.state, expected.state, label);
    }

    function _run(address r, Case memory c, bytes memory data) private returns (Outcome memory o) {
        MemoMockToken privateToken = c.sameAsset ? assetA : alternate;
        MemoMockToken otherToken = c.sameAsset ? alternate : assetA;
        MemoMockToken input = c.token == 0 ? privateToken : c.token == 1 ? earnA : otherToken;
        if (c.amount != 0) {
            if (input == earnA) {
                _publicDeposit(user, c.amount);
                vm.prank(user);
                earnA.transfer(r, c.amount);
            } else {
                input.mint(r, c.amount);
            }
        }

        uint32 zoneId = ZONE_A;
        address portal = address(portalA);
        address caller = ZONE_MESSENGER_ADDRESS;
        if (c.hazard == 1) oracle.set(PAR + 1, vm.getBlockTimestamp());
        else if (c.hazard == 2) pool.pause();
        else if (c.hazard == 3) portalA.setToken(c.op == 1 ? address(privateToken) : address(earnA), false, false);
        else if (c.hazard == 4) earnVaultA.setDepositsPaused(true);
        else if (c.hazard == 5) (zoneId, portal) = (ZONE_B, address(portalB));
        else if (c.hazard == 6) caller = user;
        else if (c.hazard == 7) pool.setTakerAllowed(r, false);

        vm.recordLogs();
        vm.prank(caller);
        (o.ok, o.ret) = r.call(
            abi.encodeCall(
                IWithdrawalReceiver.onWithdrawalReceived, (zoneId, portal, bytes32(0), address(input), c.amount, data)
            )
        );
        o.ret = _withoutAddress(o.ret, r);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == r) o.events = keccak256(abi.encode(o.events, logs[i].topics, logs[i].data));
        }
        o.state = _state(r);
    }

    function _state(address r) private view returns (bytes32) {
        MemoMockToken[3] memory tokens = [alternate, assetA, earnA];
        address[3] memory spenders = [address(pool), address(earnVaultA), address(portalA)];
        bytes memory balances;
        for (uint256 i = 0; i < tokens.length; i++) {
            balances = abi.encode(
                balances,
                tokens[i].balanceOf(r),
                tokens[i].balanceOf(address(pool)),
                tokens[i].balanceOf(address(portalA)),
                tokens[i].totalSupply()
            );
            for (uint256 j = 0; j < spenders.length; j++) {
                balances = abi.encode(balances, tokens[i].allowance(r, spenders[j]));
            }
        }
        return keccak256(
            abi.encode(
                balances,
                portalA.depositCount(),
                portalA.lastToken(),
                portalA.lastAmount(),
                portalA.lastRefundRecipient()
            )
        );
    }

    /// @dev Zeroes revert-data words naming the router itself, such as the pool's TakerNotAllowed(router).
    function _withoutAddress(bytes memory ret, address r) private pure returns (bytes memory) {
        for (uint256 offset = 4; offset + 32 <= ret.length; offset += 32) {
            bytes32 word;
            assembly {
                word := mload(add(add(ret, 32), offset))
            }
            if (word == bytes32(uint256(uint160(r)))) {
                assembly {
                    mstore(add(add(ret, 32), offset), 0)
                }
            }
        }
        return ret;
    }

    /// @dev The op word as the routers read it, or 0 when they would reject the bytes as malformed.
    function _rawOp(bytes calldata data) private pure returns (uint8) {
        if (data.length < 32) return 0;
        uint256 offset = abi.decode(data, (uint256));
        if (offset > data.length || data.length - offset < 32) return 0;
        uint256 rawOp = uint256(bytes32(data[offset:offset + 32]));
        return rawOp > 3 ? 3 : uint8(rawOp);
    }
}
