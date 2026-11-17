// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";

/// @title CoverageRegistry
/// @notice Which balances a deposit insurance scheme covers, and up to how much per account: cash in a token or the
///         shares of a vault. The registrar records each asset's scheme and cap; disclose splits an account's
///         positions into insured and uninsured value, counting each scheme's cap once per account across every
///         asset it covers, in the order the caller lists them.
/// @custom:invariant REGISTRAR != address(0)
contract CoverageRegistry {
    struct Coverage {
        string scheme;
        uint128 cap;
    }

    struct Position {
        address asset;
        uint256 units;
        uint256 value;
        uint256 insured;
        string scheme;
    }

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);

    /// @notice The registrar that records coverage.
    address public immutable REGISTRAR;

    mapping(address asset => Coverage) internal _coverage;

    event CoverageSet(address indexed asset, string scheme, uint128 cap);

    error NotRegistrar();
    error ZeroAddress();

    /// @custom:ensures REGISTRAR == registrar
    constructor(address registrar) {
        if (registrar == address(0)) revert ZeroAddress();
        REGISTRAR = registrar;
    }

    /// @notice Records the scheme that covers an asset and how much of it each account is covered for. An empty
    ///         scheme marks the asset uninsured.
    function setCoverage(address asset, string calldata scheme, uint128 cap) external {
        if (msg.sender != REGISTRAR) revert NotRegistrar();
        if (asset == address(0)) revert ZeroAddress();
        if (bytes(scheme).length == 0) delete _coverage[asset];
        else _coverage[asset] = Coverage({ scheme: scheme, cap: cap });
        emit CoverageSet(asset, scheme, bytes(scheme).length == 0 ? 0 : cap);
    }

    function coverageOf(address asset) external view returns (Coverage memory) {
        return _coverage[asset];
    }

    /// @notice An account's cash in a token and its shares of each vault, valued in the vault's asset (holds and
    ///         liens included), each split into what its scheme insures and what it doesn't.
    function disclose(address account, address cash, address[] calldata vaults)
        external
        view
        returns (Position[] memory positions)
    {
        positions = new Position[](vaults.length + 1);
        bytes32[] memory schemes = new bytes32[](vaults.length + 1);
        uint256[] memory used = new uint256[](vaults.length + 1);
        uint256 units = _held(account, cash);
        positions[0] = _split(cash, units, units, schemes, used);
        // A view over the vaults the caller names.
        // forge-lint: disable-start(calls-loop)
        for (uint256 i; i < vaults.length; ++i) {
            IEarnVault vault = IEarnVault(vaults[i]);
            units = _held(account, vault.earnShare());
            uint256 value = units == 0 ? 0 : vault.previewRedeem(units);
            positions[i + 1] = _split(address(vault), units, value, schemes, used);
        }
        // forge-lint: disable-end(calls-loop)
    }

    /// @dev Everything the account holds of a token: what it can move plus what holds and liens reserve.
    function _held(address account, address token) private view returns (uint256) {
        // Reads of the reservation core, also made once per vault the caller names.
        // forge-lint: disable-next-line(calls-loop)
        return uint256(CORE.available(account, token)) + CORE.reserved(account, token);
    }

    /// @dev Insures what is left of the asset's scheme cap for this account, recording what it used.
    function _split(address asset, uint256 units, uint256 value, bytes32[] memory schemes, uint256[] memory used)
        private
        view
        returns (Position memory position)
    {
        position = Position({ asset: asset, units: units, value: value, insured: 0, scheme: "" });
        Coverage storage cover = _coverage[asset];
        if (bytes(cover.scheme).length == 0) return position;
        position.scheme = cover.scheme;
        bytes32 key = keccak256(bytes(cover.scheme));
        uint256 slot;
        while (schemes[slot] != key && schemes[slot] != bytes32(0)) ++slot;
        schemes[slot] = key;
        uint256 room = cover.cap > used[slot] ? cover.cap - used[slot] : 0;
        position.insured = value < room ? value : room;
        used[slot] += position.insured;
    }
}
