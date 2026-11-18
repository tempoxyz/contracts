// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";

/// @title LegBook
/// @notice What a card program records about its purchases' legs and charges once the core forgets them: the core
///         deletes a hold when it settles and keeps no record of a charge, so the program bounds refunds itself.
/// @dev Internal library with its own storage slot, shared by the program and the libraries it links.
library LegBook {
    /// @dev One leg's settlement, in its token's units: one slot, written on its first capture or when it ends empty.
    struct Leg {
        uint64 captured;
        uint64 refunded;
        /// @dev Released without a capture, so it is never placed again.
        bool ended;
    }

    /// @dev One charge: one slot. The purchase's first capture charge also counts the purchase's capture charges.
    struct Charge {
        address token;
        uint64 captured;
        uint8 count;
    }

    struct Layout {
        mapping(bytes32 id => Leg) legs;
        mapping(bytes32 id => Charge) charges;
        /// @dev Written only when a charge is refunded.
        mapping(bytes32 id => uint64) chargeRefunded;
    }

    bytes32 private constant SLOT = keccak256("tempo.cards.LegBook.v1");

    function layout() internal pure returns (Layout storage L) {
        bytes32 slot = SLOT;
        assembly {
            L.slot := slot
        }
    }

    /// @dev Records a charge of `tokens` of `token` under `id`.
    function noteCharge(bytes32 id, address token, uint256 tokens) internal {
        // Charges are core amounts, which fit in 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        layout().charges[id] = Charge({ token: token, captured: uint64(tokens), count: 0 });
    }
}

/// @title CoreDebt
/// @notice Reads one creditor's share of an owner's debt from the core, which tracks up to MAX_CREDITORS per token.
library CoreDebt {
    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);

    /// @dev What `owner` owes `creditor` in `token`, and how many creditors it owes in all.
    function owed(address owner, address token, address creditor)
        internal
        view
        returns (uint128 amount, uint256 creditors)
    {
        IReservationCore.Debt[] memory debts = CORE.debtOf(owner, token);
        creditors = debts.length;
        for (uint256 i; i < debts.length; ++i) {
            if (debts[i].creditor == creditor) return (debts[i].amount, creditors);
        }
    }

    /// @dev What `owner` owes `creditor` in `token`.
    function owedTo(address owner, address token, address creditor) internal view returns (uint128 amount) {
        (amount,) = owed(owner, token, creditor);
    }

    /// @dev What `owner` owes every creditor in `token`.
    function total(address owner, address token) internal view returns (uint256 sum) {
        IReservationCore.Debt[] memory debts = CORE.debtOf(owner, token);
        for (uint256 i; i < debts.length; ++i) {
            sum += debts[i].amount;
        }
    }
}
