// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice Gas of CardAuth's purchase paths, one call each, recorded under snapshots/AuthGas.json and checked with
///         `forge snapshot --check snapshots/auth.gas-snapshot`, and the CardAuth storage slots each path writes.
/// @dev The core is the Solidity mock, so the numbers track CardAuth's and the sources' own work and their core calls
///      as the mock prices them, not the precompile's gas.
contract AuthGasTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("gas-1");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 1000e6);
        usd.mint(issuer, 1000e6);
        vm.prank(issuer);
        usd.approve(address(cards), type(uint256).max);
    }

    function test_gas_authorize_singleCashLeg() public {
        vm.prank(issuer);
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 7 days), 0);
        vm.snapshotGasLastCall("AuthGas", "authorize_singleCashLeg");
    }

    function test_gas_capture_finalCashLeg() public {
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.capture(P1, 100e6, true);
        vm.snapshotGasLastCall("AuthGas", "capture_finalCashLeg");
    }

    function test_gas_capture_partialCashLeg() public {
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.capture(P1, 40e6, false);
        vm.snapshotGasLastCall("AuthGas", "capture_partialCashLeg");
    }

    function test_gas_capture_beyondHoldIntoDebt() public {
        _setDebtCap(alice, address(cash), address(usd), 100e6);
        _setTolerance(alice, address(cash), address(usd), 5000);
        _authorize(P1, 100e6);
        vm.prank(alice);
        usd.transfer(bob, 900e6);
        vm.prank(issuer);
        cards.capture(P1, 140e6, true);
        vm.snapshotGasLastCall("AuthGas", "capture_beyondHoldIntoDebt");
    }

    function test_gas_adjust_upCashLeg() public {
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.adjust(P1, 150e6);
        vm.snapshotGasLastCall("AuthGas", "adjust_upCashLeg");
    }

    function test_gas_release_cashLeg() public {
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.release(P1);
        vm.snapshotGasLastCall("AuthGas", "release_cashLeg");
    }

    function test_gas_refund_cashLeg() public {
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        vm.prank(issuer);
        cards.refund(P1, 50e6);
        vm.snapshotGasLastCall("AuthGas", "refund_cashLeg");
    }

    function test_gas_charge_cash() public {
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        vm.snapshotGasLastCall("AuthGas", "charge_cash");
    }

    function test_gas_refund_charge() public {
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        vm.prank(issuer);
        cards.refund(P1, 50e6);
        vm.snapshotGasLastCall("AuthGas", "refund_charge");
    }

    function test_gas_authorize_standIn() public {
        _setOfflineCap(alice, address(cash), address(usd), 500e6);
        vm.prank(alice);
        usd.transfer(bob, 950e6);
        vm.prank(issuer);
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 7 days), 2);
        vm.snapshotGasLastCall("AuthGas", "authorize_standIn");
    }

    function test_gas_authorize_cashAndSavings() public {
        _splitCashAndSavings();
        vm.prank(issuer);
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 7 days), 0);
        vm.snapshotGasLastCall("AuthGas", "authorize_cashAndSavings");
    }

    function test_gas_capture_cashAndSavings() public {
        _splitCashAndSavings();
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.capture(P1, 100e6, true);
        vm.snapshotGasLastCall("AuthGas", "capture_cashAndSavings");
    }

    function test_gas_refund_cashAndSavings() public {
        _splitCashAndSavings();
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        vm.prank(issuer);
        cards.refund(P1, 100e6);
        vm.snapshotGasLastCall("AuthGas", "refund_cashAndSavings");
    }

    /// @notice CardAuth's own storage writes per path, for an operator: a new purchase writes one new slot (its
    ///         record) and updates the operator's cap, the program's held total and step counter, and the owner's
    ///         usage, card window and merchant mandate; later steps update the record, the totals and the limits.
    function test_slots_perPath() public {
        address key = makeAddr("operator");
        vm.prank(issuer);
        cards.setOperator(key, 7, 10_000e6);
        vm.prank(key);
        usd.approve(address(cards), type(uint256).max);
        usd.mint(key, 1000e6);
        // A first purchase and refund start the operator's cap, the totals and the owner's windows.
        vm.startPrank(key);
        cards.authorize(CARD, "p0", 10e6, merchant, _expiry(), 0);
        cards.capture("p0", 10e6, true);
        cards.refund("p0", 1e6);
        vm.stopPrank();

        _assertSlots(key, abi.encodeCall(cards.authorize, (CARD, P1, 100e6, merchant, _expiry(), 0)), 7, 1, "authorize");
        _assertSlots(key, abi.encodeCall(cards.capture, (P1, 40e6, false)), 3, 0, "capture partial");
        _assertSlots(key, abi.encodeCall(cards.capture, (P1, 60e6, true)), 3, 0, "capture final");
        _assertSlots(key, abi.encodeCall(cards.refund, (P1, 50e6)), 5, 0, "refund");
        _assertSlots(key, abi.encodeCall(cards.charge, (CARD, "p2", 10e6, merchant)), 6, 1, "charge");
        _assertSlots(key, abi.encodeCall(cards.authorize, (CARD, "p3", 10e6, merchant, _expiry(), 0)), 7, 1, "auth2");
        _assertSlots(key, abi.encodeCall(cards.release, ("p3")), 6, 0, "release");
    }

    function _expiry() internal view returns (uint64) {
        return uint64(block.timestamp + 7 days);
    }

    /// @dev Checks that `data`, sent by `caller`, writes `written` distinct CardAuth slots, `fresh` of them new
    ///      (zero before the call), then lands it.
    function _assertSlots(address caller, bytes memory data, uint256 written, uint256 fresh, string memory label)
        internal
    {
        uint256 snapshot = vm.snapshotState();
        vm.record();
        vm.prank(caller);
        (bool ok,) = address(cards).call(data);
        assertTrue(ok, label);
        (, bytes32[] memory writes) = vm.accesses(address(cards));
        bytes32[] memory slots = new bytes32[](writes.length);
        uint256 n;
        for (uint256 i; i < writes.length; ++i) {
            bool seen;
            for (uint256 j; j < n; ++j) {
                if (slots[j] == writes[i]) seen = true;
            }
            if (!seen) slots[n++] = writes[i];
        }
        vm.revertToState(snapshot);
        uint256 zero;
        for (uint256 i; i < n; ++i) {
            if (vm.load(address(cards), slots[i]) == 0) ++zero;
        }
        assertEq(n, written, string.concat(label, ": slots written"));
        assertEq(zero, fresh, string.concat(label, ": new slots"));
        vm.prank(caller);
        (ok,) = address(cards).call(data);
        assertTrue(ok, label);
    }

    /// @dev Alice keeps 40 in cash and 200 in savings, so a 100 purchase draws on both.
    function _splitCashAndSavings() internal {
        _depositEarn(alice, 200e6);
        uint256 spare = usd.balanceOf(alice) - 40e6;
        vm.prank(alice);
        usd.transfer(bob, spare);
    }
}
