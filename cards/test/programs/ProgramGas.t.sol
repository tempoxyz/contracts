// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice Gas of the program's main entry points, one call each, recorded under snapshots/ProgramGas.json.
/// @dev The core is the Solidity mock, so the numbers track the program's own work and its core calls as the mock
///      prices them, not the precompile's gas. `forge snapshot --check` and the JSON diff catch regressions.
contract ProgramGasTest is ProgramsEnv {
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
        vm.snapshotGasLastCall("ProgramGas", "authorize_singleCashLeg");
    }

    function test_gas_capture_finalCashLeg() public {
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.capture(P1, 100e6, true);
        vm.snapshotGasLastCall("ProgramGas", "capture_finalCashLeg");
    }

    function test_gas_capture_partialCashLeg() public {
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.capture(P1, 40e6, false);
        vm.snapshotGasLastCall("ProgramGas", "capture_partialCashLeg");
    }

    function test_gas_refund_cashLeg() public {
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        vm.prank(issuer);
        cards.refund(P1, 50e6);
        vm.snapshotGasLastCall("ProgramGas", "refund_cashLeg");
    }

    function test_gas_charge_cash() public {
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        vm.snapshotGasLastCall("ProgramGas", "charge_cash");
    }

    function test_gas_refund_charge() public {
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        vm.prank(issuer);
        cards.refund(P1, 50e6);
        vm.snapshotGasLastCall("ProgramGas", "refund_charge");
    }
}
