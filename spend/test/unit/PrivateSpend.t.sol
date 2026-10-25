// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IZonePortal, ZONE_MESSENGER_ADDRESS } from "tempo-zones/interfaces/IZone.sol";

import { Spend, SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { ZoneSpendReceiver } from "../../src/ZoneSpendReceiver.sol";
import { DivertingSpendHandler } from "../harness/Mocks.sol";
import { PrivateSpendFixture } from "../harness/PrivateSpendFixture.sol";
import { ISpenderHandler } from "bridge-spender/src/ISpenderHandler.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";

/// @notice Private spend through a closed-loop Zone with portal and outbox fees switched on.
contract PrivateSpendTest is PrivateSpendFixture {
    function setUp() public {
        _setUpPrivateSpend();
    }

    function test_spendSettlesAndReturnsChange() public {
        uint256 change = _change();
        uint256 withdrawalFee = zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS);
        uint256 before = usd.balanceOf(settlement);
        uint256 zoneBefore = _zoneBalance(address(usd), alice);

        assertTrue(_request(alice, 40e6 + change, _callback(_spend(40e6, settlement))));
        _zoneSettle();

        assertTrue(lastCallbackResults[0], "callback settled");
        assertEq(usd.balanceOf(settlement) - before, 40e6, "destination paid");
        uint256 spent = zoneBefore - _zoneBalance(address(usd), alice);
        assertEq(spent, 40e6 + withdrawalFee + portal.calculateDepositFee(), "amount plus fees");
        assertEq(usd.balanceOf(address(receiver)), 0, "nothing left in the receiver");
        assertTrue(_lastSettlementLogged(ZoneSpendReceiver.PrivateSpendSettled.selector), "logged");
        _assertNoApprovals(address(usd));
    }

    /// @notice Any amount with any change above the portal's fees settles exactly: the destination
    ///         gets the amount, the cardholder pays only it and the fees, and the receiver and
    ///         clone keep nothing and approve nothing.
    function testFuzz_spendSettlesAndReturnsChange(uint256 amount, uint256 extra) public {
        amount = bound(amount, 1, 500e6);
        extra = bound(extra, 0, 400e6);
        uint256 withdrawalFee = zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS);
        uint256 before = usd.balanceOf(settlement);
        uint256 zoneBefore = _zoneBalance(address(usd), alice);

        bytes memory callbackData = _callback(_spend(amount, settlement));
        assertTrue(_request(alice, amount + _change() + extra, callbackData));
        _zoneSettle();

        assertTrue(lastCallbackResults[0], "callback settled");
        assertEq(usd.balanceOf(settlement) - before, amount, "destination paid");
        assertEq(
            zoneBefore - _zoneBalance(address(usd), alice),
            amount + withdrawalFee + portal.calculateDepositFee(),
            "amount plus fees"
        );
        assertEq(usd.balanceOf(address(receiver)), 0, "nothing left in the receiver");
        assertEq(usd.balanceOf(spender), 0, "nothing left in the clone");
        _assertNoApprovals(address(usd));
    }

    function test_changeBelowPortalFeesBounces() public {
        uint256 before = usd.balanceOf(settlement);
        assertTrue(_request(alice, 40e6 + 1, _callback(_spend(40e6, settlement))));
        _zoneSettle();

        assertFalse(lastCallbackResults[0], "one unit of change cannot pay the deposit fee");
        assertEq(bytes4(lastCallbackErrors[0]), IZonePortal.DepositTooSmall.selector);
        assertEq(usd.balanceOf(settlement), before, "nothing paid");
        assertFalse(_lastSettlementLogged(ZoneSpendReceiver.PrivateSpendSettled.selector));
    }

    /// @notice The clone reports the receiver as the payer, and the receiver reports the Zone's
    ///         `senderTag` with the input split between what the spend consumed and what came back.
    function test_settledSpendEmitsEvents() public {
        bytes32 senderTag = keccak256("zone.sender-tag");
        Spend memory spend = _spend(40e6, settlement);
        spend.ref = keccak256("card.auth");
        uint256 change = _change();
        _fundReceiver(address(usd), 40e6 + change);

        bytes memory data = _callback(spend);
        vm.expectEmit(true, true, true, true, spender);
        emit SpenderTempoSpend.TempoSpendExecuted(
            spend.ref, address(receiver), settlement, address(usd), 40e6, 40e6, 0, 0
        );
        vm.expectEmit(true, true, true, true, address(receiver));
        emit ZoneSpendReceiver.PrivateSpendSettled(senderTag, spend.ref, address(usd), 40e6, change);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        receiver.onWithdrawalReceived(
            ZONE_ID, address(portal), senderTag, address(usd), uint128(40e6 + change), data
        );
        _assertNoApprovals(address(usd));
    }

    // ------------------------------------------------------------------
    // Hostile callback data
    // ------------------------------------------------------------------

    /// @notice A spend naming a token other than the one withdrawn cannot pay from it.
    function test_spendInAnotherTokenBounces() public {
        Spend memory spend = _spend(10e6, settlement);
        spend.token = address(_createToken("Deel USD", "DLUSD"));
        _assertBouncesWith(
            10e6 + _change(),
            _callbackAsIs(spend),
            abi.encodeWithSelector(SafeTransferLib.TransferFromFailed.selector)
        );
    }

    /// @notice A spend for another program's ID cannot use this program's receiver.
    function test_spendForAnotherProgramBounces() public {
        Spend memory spend = _spend(10e6, settlement);
        spend.spenderId = keccak256("another.program");
        _assertBouncesWith(
            10e6 + _change(),
            _callback(spend),
            abi.encodeWithSelector(SpenderTempoSpend.WrongProgram.selector, spend.spenderId)
        );
    }

    /// @notice A spend larger than the withdrawn input cannot pay from the receiver's balance.
    function test_spendAboveTheInputBounces() public {
        uint256 input = 10e6 + _change();
        _assertBouncesWith(
            input,
            _callback(_spend(input + 1, settlement)),
            abi.encodeWithSelector(SafeTransferLib.TransferFromFailed.selector)
        );
    }

    /// @notice Any Zone account can send a withdrawal to the receiver, but it only ever pays a
    ///         program destination, from that account's own funds.
    function test_spendOutsideProgramBounces() public {
        address attacker = makeAddr("attacker");
        uint256 zoneBefore = _zoneBalance(address(usd), mallory);
        _requestAsSelf(mallory, 10e6 + _change(), _callback(_spend(10e6, attacker)));
        _zoneSettle();
        assertFalse(lastCallbackResults[0], "callback rejected");
        assertEq(usd.balanceOf(attacker), 0);
        uint256 fees =
            zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS) + portal.calculateBouncebackFee();
        assertLe(zoneBefore - _zoneBalance(address(usd), mallory), fees, "input bounced back");
    }

    /// @notice A withdrawal carries its destination into the next batch. If governance removes that
    ///         destination first, the callback reverts and the input bounces back into the Zone.
    function test_destinationRemovedBeforeBatchBounces() public {
        uint256 zoneBefore = _zoneBalance(address(usd), alice);
        uint256 before = usd.balanceOf(settlement);
        assertTrue(_request(alice, 40e6 + _change(), _callback(_spend(40e6, settlement))));

        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderDestination(SPENDER_ID, settlement, false);
        _zoneSettle();

        assertFalse(lastCallbackResults[0], "callback rejected");
        assertEq(usd.balanceOf(settlement), before, "nothing paid");
        uint256 fees =
            zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS) + portal.calculateBouncebackFee();
        assertLe(zoneBefore - _zoneBalance(address(usd), alice), fees, "input bounced back");
    }

    /// @notice Adding the new destination first, and removing the old one only after in-flight
    ///         withdrawals settle, switches destinations without a bounce.
    function test_destinationSwitchAddsBeforeRemoving() public {
        address next = makeAddr("bridge.settlement.next");
        uint256 before = usd.balanceOf(settlement);
        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderDestination(SPENDER_ID, next, true);

        assertTrue(_request(alice, 40e6 + _change(), _callback(_spend(40e6, settlement))));
        assertTrue(_request(alice, 25e6 + _change(), _callback(_spend(25e6, next))));
        _zoneSettle();
        assertTrue(lastCallbackResults[0], "in-flight spend to the old destination");
        assertTrue(lastCallbackResults[1], "first spend to the new destination");

        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderDestination(SPENDER_ID, settlement, false);
        assertTrue(_request(alice, 10e6 + _change(), _callback(_spend(10e6, next))));
        _zoneSettle();

        assertTrue(lastCallbackResults[0], "spend after the switch");
        assertEq(usd.balanceOf(settlement) - before, 40e6, "old destination");
        assertEq(usd.balanceOf(next), 35e6, "new destination");
    }

    /// @dev The request is accepted and its callback reverts with `err`: nothing is paid, nothing is
    ///      reported settled, and the input returns to the Zone, losing only the withdrawal fee.
    function _assertBouncesWith(uint256 input, bytes memory callbackData, bytes memory err)
        internal
    {
        uint256 before = usd.balanceOf(settlement);
        uint256 zoneBefore = _zoneBalance(address(usd), alice);
        assertTrue(_request(alice, input, callbackData), "Zone accepted the request");
        _zoneSettle();

        assertFalse(lastCallbackResults[0], "callback rejected");
        assertEq(lastCallbackErrors[0], err, "callback error");
        assertEq(usd.balanceOf(settlement), before, "nothing paid");
        assertFalse(_lastSettlementLogged(ZoneSpendReceiver.PrivateSpendSettled.selector));
        assertEq(
            zoneBefore - _zoneBalance(address(usd), alice),
            zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS),
            "input returned to the Zone"
        );
        assertEq(usd.balanceOf(address(receiver)), 0, "nothing left in the receiver");
    }

    function test_outboxChargesTheWithdrawalFee() public {
        uint256 withdrawalFee = zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS);
        assertGt(withdrawalFee, 0);
        uint256 zoneBefore = _zoneBalance(address(usd), alice);
        uint256 input = 10e6 + _change();
        assertTrue(_request(alice, input, _callback(_spend(10e6, settlement))));
        assertEq(zoneBefore - _zoneBalance(address(usd), alice), input + withdrawalFee);
    }

    // ------------------------------------------------------------------
    // Changes between the request and its batch
    // ------------------------------------------------------------------

    /// @notice A handler replaced while a spend is in flight cannot divert it and look settled:
    ///         the receiver checks the destination was paid, so the spend bounces.
    function test_replacedHandlerThatDivertsTheSpendBounces() public {
        address thief = makeAddr("thief");
        uint256 input = 40e6 + _change();
        assertTrue(_request(alice, input, _callback(_spend(40e6, settlement))));
        ISpenderHandler diverting = ISpenderHandler(
            address(new DivertingSpendHandler(IFactory(address(bridgeFactory)), thief))
        );
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler("TS", diverting);
        uint256 before = usd.balanceOf(settlement);
        _zoneSettle();
        assertFalse(lastCallbackResults[0], "callback rejected");
        assertEq(
            lastCallbackErrors[0],
            abi.encodeWithSelector(ZoneSpendReceiver.DestinationNotPaid.selector)
        );
        assertEq(usd.balanceOf(thief), 0, "nothing diverted");
        assertEq(usd.balanceOf(settlement), before, "nothing paid");
        assertFalse(_lastSettlementLogged(ZoneSpendReceiver.PrivateSpendSettled.selector));
    }

    /// @notice A deposit fee the Zone admin raises above the return's cap bounces the spend
    ///         instead of letting the portal keep the change.
    function test_depositFeeRaisedAboveTheCapBounces() public {
        uint256 input = 40e6 + _change();
        assertTrue(_request(alice, input, _callback(_spend(40e6, settlement))));
        vm.prank(zoneAdmin);
        portal.setZoneGasRate(1000);
        uint128 fee = portal.calculateDepositFee();
        uint256 before = usd.balanceOf(settlement);
        _zoneSettle();
        assertFalse(lastCallbackResults[0], "callback rejected");
        assertEq(
            lastCallbackErrors[0],
            abi.encodeWithSelector(ZoneSpendReceiver.DepositFeeTooHigh.selector, fee)
        );
        assertEq(usd.balanceOf(settlement), before, "nothing paid");
    }
}
