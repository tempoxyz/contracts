// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ISource
/// @notice One way a card purchase is funded, behind a card authorization contract (CardAuth). A source places,
///         resizes, captures and releases its own core holds (it is their placer), converts what it takes into the
///         program's settlement token, pays it to the program's settlement account, and refunds the owner. Every
///         amount across this interface is in units of the program's current settlement token. `position` selects
///         what the source draws on for the owner: for cash the token (low 160 bits) and the most a conversion may
///         cost in basis points (the 16 bits above); for credit the line id; zero for savings.
/// @dev Each source serves one CardAuth (its `PROGRAM`), the only caller of the mutating functions. A leg is
///      identified by `(owner, legId)`; CardAuth derives `legId` from the purchase and the order entry and never
///      reuses a purchase reference, so a source needs no replay record of its own.
interface ISource {
    /// @notice What the source is: 1 cash, 2 savings, 4 credit. Cards and programs allow sources by kind; only
    ///         cash takes stand-in holds and charges.
    function KIND() external view returns (uint8);

    /// @notice What the source could hold for `owner` at `position` now.
    function coverable(address owner, bytes32 position) external view returns (uint256 units);

    /// @notice What leg `legId` holds now, at the rate it locked; zero once it settled.
    function held(address owner, bytes32 position, bytes32 legId) external view returns (uint256 units);

    /// @notice What `owner` owes this source as debt at `position`, which a refund through it repays first; zero
    ///         for a source that never lends through debt.
    function owed(address owner, bytes32 position) external view returns (uint256 units);

    /// @notice What leg `legId` can still take back in refunds: what it captured less what it was refunded. Cash,
    ///         whose first leg takes whatever a purchase refunds past its other legs, returns type(uint256).max.
    function refundable(address owner, bytes32 position, bytes32 legId) external view returns (uint256 units);

    /// @notice The capture tolerance the owner gave this source at `position`, in basis points: how far past a
    ///         purchase's authorized amount a capture may go.
    function toleranceBps(address owner, bytes32 position) external view returns (uint16);

    /// @notice Holds up to `units` for leg `legId`: places the leg, or moves a live leg's hold to what it can of
    ///         `units` (releasing it at zero). A stand-in (cash only) reserves what is available and lets captures
    ///         reach `units` through debt within the owner's offline cap. Returns what the leg now holds, at most
    ///         `units` (for a stand-in, `units`); zero places nothing.
    function hold(address owner, bytes32 position, bytes32 legId, uint256 units, uint64 expiresAt, bool standIn)
        external
        returns (uint256 heldUnits);

    /// @notice Captures up to `units` for leg `legId` and pays the settlement account. Without a flag it takes only
    ///         what the leg holds. CAPTURE_FREE also takes what the source can still cover for the owner (unheld
    ///         cash or shares, credit room), never debt; CAPTURE_BEYOND does too and, for cash, then debt within the
    ///         owner's caps. CAPTURE_FINAL releases what is left, except that a CAPTURE_FREE capture covering less
    ///         than `units` keeps the leg live for a later CAPTURE_BEYOND. Returns the units paid to the settlement
    ///         account and the units of the purchase it covered: more than paid only for a converted leg within its
    ///         locked rate, whose slippage the issuer carries (both zero for a settled leg).
    function capture(address owner, bytes32 position, bytes32 legId, uint256 units, uint8 flags)
        external
        returns (uint256 paid, uint256 covered);

    /// @notice Charges up to `units` with no hold: the owner's free funds, then debt to this source within the
    ///         owner's debt cap (with `standIn`, the offline cap where higher). Returns the units it covered; zero
    ///         for a source that does not charge.
    function charge(address owner, bytes32 position, bytes32 legId, uint256 units, bool standIn)
        external
        returns (uint256 taken);

    /// @notice Ends leg `legId`, returning what it holds; an expired hold ends as expired. Does nothing for a leg
    ///         already settled.
    function release(address owner, bytes32 position, bytes32 legId) external;

    /// @notice Pays `units` back to the owner for leg `legId` from settlement tokens CardAuth already moved to this
    ///         source; at most `refundable`. Debt the owner owes this source is forgiven first.
    function refund(address owner, bytes32 position, bytes32 legId, uint256 units) external;
}

/// @dev ISource.capture flags.
uint8 constant CAPTURE_FINAL = 1;
uint8 constant CAPTURE_BEYOND = 2;
uint8 constant CAPTURE_FREE = 4;
