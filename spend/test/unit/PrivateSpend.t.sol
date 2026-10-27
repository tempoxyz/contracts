// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ISpenderHandler } from "bridge-spender/src/ISpenderHandler.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import { Vm } from "forge-std/Vm.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ZoneRouter } from "tempo-router/ZoneRouter.sol";
import { IZonePortal, ZONE_MESSENGER_ADDRESS } from "tempo-zones/interfaces/IZone.sol";

import { Spend, SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { BridgeSettler } from "../../src/settler/BridgeSettler.sol";
import { ChangeKeepingSpendHandler, DivertingSpendHandler, OlderBridgeSettler } from "../harness/Mocks.sol";
import { PrivateSpendFixture } from "../harness/PrivateSpendFixture.sol";

/// @notice Private spend through the program's Spend-mode ZoneRouter and BridgeSettler, on a
///         closed-loop Zone with portal and outbox fees switched on.
contract PrivateSpendTest is PrivateSpendFixture {
    function setUp() public {
        _setUpPrivateSpend();
    }

    function test_spendSettlesAndReturnsChange() public {
        uint256 change = _change();
        uint256 withdrawalFee = zoneOutbox.calculateWithdrawalFee(callbackGas);
        uint256 before = usd.balanceOf(settlement);
        uint256 zoneBefore = _zoneBalance(address(usd), alice);

        assertTrue(_request(alice, 40e6 + change, _callback(_spend(40e6, settlement))));
        _zoneSettle();

        assertTrue(lastCallbackResults[0], "callback settled");
        assertEq(usd.balanceOf(settlement) - before, 40e6, "destination paid");
        uint256 spent = zoneBefore - _zoneBalance(address(usd), alice);
        assertEq(spent, 40e6 + withdrawalFee + portal.calculateDepositFee(), "amount plus fees");
        assertTrue(_lastSettlementLogged(ZoneRouter.Spent.selector), "router logged");
        assertTrue(_lastSettlementLogged(BridgeSettler.SpendSettled.selector), "settler logged");
        _assertNothingHeld(address(usd));
    }

    /// @notice Any amount with any change above the portal's fees settles exactly: the destination
    ///         gets the amount, the cardholder pays only it and the fees, and the router, settler
    ///         and clone keep nothing and approve nothing.
    function testFuzz_spendSettlesAndReturnsChange(uint256 amount, uint256 extra) public {
        amount = bound(amount, 1, 500e6);
        extra = bound(extra, 0, 400e6);
        uint256 withdrawalFee = zoneOutbox.calculateWithdrawalFee(callbackGas);
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
        _assertNothingHeld(address(usd));
    }

    function test_changeBelowPortalFeesBounces() public {
        uint256 before = usd.balanceOf(settlement);
        assertTrue(_request(alice, 40e6 + 1, _callback(_spend(40e6, settlement))));
        _zoneSettle();

        assertFalse(lastCallbackResults[0], "one unit of change cannot pay the deposit fee");
        assertEq(bytes4(lastCallbackErrors[0]), IZonePortal.DepositTooSmall.selector);
        assertEq(usd.balanceOf(settlement), before, "nothing paid");
        assertFalse(_lastSettlementLogged(ZoneRouter.Spent.selector));
    }

    /// @notice The clone reports the settler as the payer, the settler the input split between what
    ///         the spend consumed and what it handed back, and the router the change it returned to
    ///         the Zone. None of them carries the withdrawal's `senderTag`.
    function test_settledSpendEmitsEventsWithoutTheSenderTag() public {
        bytes32 senderTag = keccak256("zone.sender-tag");
        Spend memory spend = _spend(40e6, settlement);
        spend.ref = keccak256("card.auth");
        uint256 change = _change();
        _fundRouter(address(usd), 40e6 + change);

        bytes memory data = _callback(spend);
        vm.recordLogs();
        vm.expectEmit(true, true, true, true, spender);
        emit SpenderTempoSpend.TempoSpendExecuted(
            spend.ref, address(settler), settlement, address(usd), 40e6, 40e6, 0, 0
        );
        vm.expectEmit(true, true, true, true, address(settler));
        emit BridgeSettler.SpendSettled(spend.ref, address(usd), 40e6, 0);
        // The Zone deposit hash is the portal's; the rest is checked.
        vm.expectEmit(true, true, false, false, address(zoneRouter));
        emit ZoneRouter.Spent(address(settler), address(usd), 40e6, change, bytes32(0));
        vm.prank(ZONE_MESSENGER_ADDRESS);
        zoneRouter.onWithdrawalReceived(ZONE_ID, address(portal), senderTag, address(usd), uint128(40e6 + change), data);
        _assertNothingHeld(address(usd));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            for (uint256 t; t < logs[i].topics.length; ++t) {
                assertTrue(logs[i].topics[t] != senderTag, "senderTag not in a topic");
            }
            bytes memory blob = logs[i].data;
            for (uint256 w; w + 32 <= blob.length; ++w) {
                bytes32 word;
                assembly {
                    word := mload(add(add(blob, 0x20), w))
                }
                assertTrue(word != senderTag, "senderTag not in event data");
            }
        }
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
            abi.encodeWithSelector(BridgeSettler.WrongInputToken.selector, address(usd))
        );
    }

    /// @notice A spend for another program's ID cannot use this program's settler.
    function test_spendForAnotherProgramBounces() public {
        Spend memory spend = _spend(10e6, settlement);
        spend.spenderId = keccak256("another.program");
        _assertBouncesWith(
            10e6 + _change(),
            _callback(spend),
            abi.encodeWithSelector(BridgeSettler.WrongProgram.selector, spend.spenderId)
        );
    }

    /// @notice A `maxInput` above the withdrawn input is refused before the settler is called.
    function test_maxInputAboveTheInputBounces() public {
        uint256 input = 10e6 + _change();
        _assertBouncesWith(
            input, _callback(_spend(input + 1, settlement)), abi.encodeWithSelector(ZoneRouter.InvalidMaxInput.selector)
        );
    }

    /// @notice A spend larger than its `maxInput` cannot pay from the rest of the withdrawal: the
    ///         settler only ever holds `maxInput`.
    function test_spendAboveMaxInputBounces() public {
        Spend memory spend = _spend(10e6, settlement);
        spend.token = address(usd);
        _assertBouncesWith(
            10e6 + _change() + 5e6,
            _spendData(address(settler), 10e6 - 1, spend),
            abi.encodeWithSelector(SafeTransferLib.TransferFromFailed.selector)
        );
    }

    /// @notice Any Zone account can send a withdrawal to the router, but it only ever pays a
    ///         program destination, from that account's own funds.
    function test_spendOutsideProgramBounces() public {
        address attacker = makeAddr("attacker");
        uint256 zoneBefore = _zoneBalance(address(usd), mallory);
        _requestAsSelf(mallory, 10e6 + _change(), _callback(_spend(10e6, attacker)));
        _zoneSettle();
        assertFalse(lastCallbackResults[0], "callback rejected");
        assertEq(usd.balanceOf(attacker), 0);
        uint256 fees = zoneOutbox.calculateWithdrawalFee(callbackGas) + portal.calculateBouncebackFee();
        assertLe(zoneBefore - _zoneBalance(address(usd), mallory), fees, "input bounced back");
    }

    /// @notice A settler the router was not deployed with cannot be named, even one built for the
    ///         same program.
    function test_unlistedSettlerBounces() public {
        BridgeSettler other = new BridgeSettler(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID);
        Spend memory spend = _spend(10e6, settlement);
        spend.token = address(usd);
        _assertBouncesWith(
            10e6 + _change(),
            _spendData(address(other), 10e6, spend),
            abi.encodeWithSelector(ZoneRouter.UnknownSettler.selector)
        );
    }

    /// @notice A listed settler that takes nothing cannot make a spend look settled: the router
    ///         measures its own balance, so the spend bounces.
    function test_settlerThatTakesNothingBounces() public {
        OlderBridgeSettler idle = new OlderBridgeSettler(address(bridgeFactory), SPENDER_ID);
        address[] memory list = new address[](2);
        list[0] = address(settler);
        list[1] = address(idle);
        zoneRouter = _deployRouter(list);
        Spend memory spend = _spend(10e6, settlement);
        spend.token = address(usd);
        _assertBouncesWith(
            10e6 + _change(),
            _spendData(address(idle), 10e6, spend),
            abi.encodeWithSelector(ZoneRouter.InvalidSettlement.selector)
        );
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
        uint256 fees = zoneOutbox.calculateWithdrawalFee(callbackGas) + portal.calculateBouncebackFee();
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
    function _assertBouncesWith(uint256 input, bytes memory callbackData, bytes memory err) internal {
        uint256 before = usd.balanceOf(settlement);
        uint256 zoneBefore = _zoneBalance(address(usd), alice);
        assertTrue(_request(alice, input, callbackData), "Zone accepted the request");
        _zoneSettle();

        assertFalse(lastCallbackResults[0], "callback rejected");
        assertEq(lastCallbackErrors[0], err, "callback error");
        assertEq(usd.balanceOf(settlement), before, "nothing paid");
        assertFalse(_lastSettlementLogged(ZoneRouter.Spent.selector));
        assertFalse(_lastSettlementLogged(BridgeSettler.SpendSettled.selector));
        assertEq(
            zoneBefore - _zoneBalance(address(usd), alice),
            zoneOutbox.calculateWithdrawalFee(callbackGas),
            "input returned to the Zone"
        );
        _assertNothingHeld(address(usd));
    }

    function test_outboxChargesTheWithdrawalFee() public {
        uint256 withdrawalFee = zoneOutbox.calculateWithdrawalFee(callbackGas);
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
    ///         the settler checks the destination was paid, so the spend bounces.
    function test_replacedHandlerThatDivertsTheSpendBounces() public {
        address thief = makeAddr("thief");
        uint256 input = 40e6 + _change();
        assertTrue(_request(alice, input, _callback(_spend(40e6, settlement))));
        _replaceHandler(ISpenderHandler(address(new DivertingSpendHandler(IFactory(address(bridgeFactory)), thief))));
        uint256 before = usd.balanceOf(settlement);
        _zoneSettle();
        assertFalse(lastCallbackResults[0], "callback rejected");
        assertEq(lastCallbackErrors[0], abi.encodeWithSelector(BridgeSettler.DestinationNotPaid.selector));
        assertEq(usd.balanceOf(thief), 0, "nothing diverted");
        assertEq(usd.balanceOf(settlement), before, "nothing paid");
        assertFalse(_lastSettlementLogged(ZoneRouter.Spent.selector));
    }

    /// @notice The Cyclops finding: a replaced "TS" handler that pays the destination exactly and
    ///         takes the rest of its approval. The router caps the settler at the cardholder's
    ///         `maxInput`, so the change still returns to the Zone and the handler gets nothing extra.
    function test_replacedHandlerCannotKeepTheChange() public {
        address thief = makeAddr("thief");
        _replaceHandler(
            ISpenderHandler(address(new ChangeKeepingSpendHandler(IFactory(address(bridgeFactory)), thief)))
        );

        uint256 extra = 25e6;
        uint256 withdrawalFee = zoneOutbox.calculateWithdrawalFee(callbackGas);
        uint256 zoneBefore = _zoneBalance(address(usd), alice);
        assertTrue(_request(alice, 40e6 + _change() + extra, _callback(_spend(40e6, settlement))));
        _zoneSettle();

        assertTrue(lastCallbackResults[0], "callback settled");
        assertEq(usd.balanceOf(thief), 0, "handler kept nothing");
        assertEq(
            zoneBefore - _zoneBalance(address(usd), alice),
            40e6 + withdrawalFee + portal.calculateDepositFee(),
            "the change came back"
        );
        _assertNothingHeld(address(usd));
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
        assertEq(lastCallbackErrors[0], abi.encodeWithSelector(ZoneRouter.DepositFeeTooHigh.selector, fee));
        assertEq(usd.balanceOf(settlement), before, "nothing paid");
    }

    function _replaceHandler(ISpenderHandler handler) internal {
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler(PREFIX_TEMPO_SPEND, handler);
    }
}
