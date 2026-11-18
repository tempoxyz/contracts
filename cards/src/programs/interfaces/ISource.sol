// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ISource
/// @notice One way a card purchase is funded, behind a card authorization contract (CardAuth). A source places,
///         resizes, captures, releases and refunds its own core holds (it is their placer), converts what it holds into
///         the program's settlement token itself, and pays captures to the program's settlement account. Every amount
///         across this interface is in settlement-token units; `position` selects what the source draws on for the
///         owner: the token for cash, the line id for credit, zero for savings.
/// @dev Each source serves one CardAuth (its `PROGRAM`), the only caller of the mutating functions. A leg is
///      identified by `(owner, legId)`; `legId` is unique per purchase and source in the CardAuth's own id space.
interface ISource {
    /// @notice What the source could still hold for `owner` at `position` now, in settlement units, at a conversion
    ///         cost of at most `maxCostBps` (ignored where nothing converts).
    function coverable(address owner, bytes32 position, uint16 maxCostBps) external view returns (uint256 units);

    /// @notice What leg `legId` holds now, in settlement units at the rate it locked; zero once it settled.
    function held(address owner, bytes32 position, bytes32 legId) external view returns (uint256 units);

    /// @notice Places leg `legId` holding `units`, or for a live leg moves what it holds to `units`. A stand-in leg
    ///         reserves what is available and lets captures reach `units`. Returns what the leg now holds.
    function hold(address owner, bytes32 position, bytes32 legId, uint256 units, uint64 expiresAt, bool standIn)
        external
        returns (uint256 heldUnits);

    /// @notice Captures `units` of leg `legId` (more than it holds when the source can still cover the rest), paying
    ///         the program's settlement account. A final capture releases what is left. Returns the settlement units
    ///         the settlement account received and the source-token units taken from the owner (or lender).
    function capture(address owner, bytes32 position, bytes32 legId, uint256 units, bool isFinal)
        external
        returns (uint256 paid, uint256 tokens);

    /// @notice Ends leg `legId`, returning what it holds.
    function release(address owner, bytes32 position, bytes32 legId) external;

    /// @notice Puts up to `units` back onto leg `legId` for the owner, from settlement tokens the program already sent
    ///         to this source. Returns the settlement units the leg took; the program sends the rest elsewhere.
    function refund(address owner, bytes32 position, bytes32 legId, uint256 units) external returns (uint256 taken);
}
