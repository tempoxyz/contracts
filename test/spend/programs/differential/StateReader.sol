// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {
    IReservationCore,
    RESERVATION_CORE_ADDRESS
} from "../../../../src/interfaces/spend/programs/IReservationCore.sol";

interface IStateReaderToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Reads the reservation core's whole observable state over a fixed universe of accounts, tokens and hold ids
///         as one flat vector. The differential generator calls it on the node at each operation's block, and the
///         replay calls the same code against the model, so both sides encode state identically.
contract StateReader {
    IReservationCore private constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);

    /// @notice The state vector: the block time; per token its supply and each account's available and reserved;
    ///         per (owner, other account, token) the budget and capture tolerance; per (owner, placer, id) the hold
    ///         record.
    function snapshot(address[] calldata accounts, address[] calldata tokens, bytes32[] calldata ids)
        external
        view
        returns (uint256[] memory out)
    {
        uint256 a = accounts.length;
        uint256 t = tokens.length;
        out = new uint256[](1 + t * (1 + 2 * a) + a * a * t * 6 + a * a * ids.length * 6);
        uint256 n;
        out[n++] = block.timestamp;
        for (uint256 i; i < t; ++i) {
            out[n++] = IStateReaderToken(tokens[i]).totalSupply();
            for (uint256 j; j < a; ++j) {
                out[n++] = CORE.available(accounts[j], tokens[i]);
                out[n++] = CORE.reserved(accounts[j], tokens[i]);
            }
        }
        for (uint256 o; o < a; ++o) {
            for (uint256 h; h < a; ++h) {
                for (uint256 i; i < t; ++i) {
                    IReservationCore.Budget memory b = CORE.budget(accounts[o], accounts[h], tokens[i]);
                    out[n++] = b.limit;
                    out[n++] = b.spent;
                    out[n++] = b.outstanding;
                    out[n++] = b.period;
                    out[n++] = b.periodStart;
                    out[n++] = CORE.captureTolerance(accounts[o], accounts[h], tokens[i]);
                }
            }
        }
        for (uint256 o; o < a; ++o) {
            for (uint256 p; p < a; ++p) {
                for (uint256 k; k < ids.length; ++k) {
                    IReservationCore.HoldRecord memory r = CORE.getHold(accounts[o], accounts[p], ids[k]);
                    out[n++] = uint160(r.token);
                    out[n++] = uint160(r.payee);
                    out[n++] = r.held;
                    out[n++] = r.captureLimit;
                    out[n++] = r.expiresAt;
                    out[n++] = r.kind;
                }
            }
        }
    }

    /// @notice Each account's token balance, token-major. On the node it counts reserved amounts; the model keeps
    ///         reserved amounts in its own balance.
    function balances(address[] calldata accounts, address[] calldata tokens)
        external
        view
        returns (uint256[] memory out)
    {
        out = new uint256[](accounts.length * tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < accounts.length; ++j) {
                out[i * accounts.length + j] = IStateReaderToken(tokens[i]).balanceOf(accounts[j]);
            }
        }
    }
}
