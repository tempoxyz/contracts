// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CoreEnv } from "../core/harness/CoreEnv.sol";

/// @notice EarnVault user paths measured on real TIP-20 precompiles, where every zero-to-nonzero storage
///         write is charged as a new slot (TIP-1000). Earn's own gas suite uses mock ERC-20s and cannot
///         see that cost, and `snapshotGasLastCall` leaves the new-slot charge out, so each call is
///         measured with `gasleft`. `FOUNDRY_PROFILE=spend forge test --match-path test/spend/gas/*` writes the results to snapshots/.
contract EarnTip20GasTest is CoreEnv {
    address internal returning = makeAddr("gas.returning");
    address internal newcomer = makeAddr("gas.newcomer");

    function setUp() public {
        _deployCore();
        usd.mint(returning, 10_000e6);
        usd.mint(newcomer, 10_000e6);
        vm.startPrank(returning);
        usd.approve(address(earnVault), type(uint256).max);
        earnShare.approve(address(earnVault), type(uint256).max);
        earnVault.deposit(1000e6, returning, 1);
        vm.stopPrank();
        vm.prank(newcomer);
        usd.approve(address(earnVault), type(uint256).max);
    }

    function test_gasDepositReturningHolder() public {
        vm.prank(returning);
        uint256 before = gasleft();
        earnVault.deposit(1000e6, returning, 1);
        vm.snapshotValue("earn-tip20", "deposit.returning", before - gasleft());
    }

    function test_gasDepositNewHolder() public {
        vm.prank(newcomer);
        uint256 before = gasleft();
        earnVault.deposit(1000e6, newcomer, 1);
        vm.snapshotValue("earn-tip20", "deposit.new-holder", before - gasleft());
    }

    function test_gasRedeemPartial() public {
        vm.prank(returning);
        uint256 before = gasleft();
        earnVault.redeem(500e6, returning, 1);
        vm.snapshotValue("earn-tip20", "redeem.partial", before - gasleft());
    }

    /// @dev One unit of base asset left with the vault and engine keeps their balance slots nonzero between
    ///      calls. Every path here already has the EarnShare unit the vault mints itself at initialization.
    function test_gasDepositReturningHolderWithResidue() public {
        _leaveResidue();
        vm.prank(returning);
        uint256 before = gasleft();
        earnVault.deposit(1000e6, returning, 1);
        vm.snapshotValue("earn-tip20", "deposit.returning.residue", before - gasleft());
    }

    function test_gasRedeemPartialWithResidue() public {
        _leaveResidue();
        vm.prank(returning);
        uint256 before = gasleft();
        earnVault.redeem(500e6, returning, 1);
        vm.snapshotValue("earn-tip20", "redeem.partial.residue", before - gasleft());
    }

    function _leaveResidue() private {
        usd.mint(address(earnVault), 1);
        usd.mint(earnVault.engine(), 1);
    }
}
