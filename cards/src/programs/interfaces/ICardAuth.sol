// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ICardAuthState
/// @notice The settings a card authorization contract keeps as public state, which companions read.
interface ICardAuthState {
    /// @notice Role bits: authorize (authorize, adjust, capture, charge, release), settle (refund, credit back,
    ///         reserve settlement), treasury (settlement token and treasury companions' own calls).
    function ROLE_AUTHORIZE() external view returns (uint8);
    function ROLE_SETTLE() external view returns (uint8);
    function ROLE_TREASURY() external view returns (uint8);
    /// @notice How long issuer settings wait before they apply once any owner granted terms.
    function SETTINGS_DELAY() external view returns (uint64);
    /// @notice The shared conversion the program and its sources price tokens with.
    function conversion() external view returns (address);
    /// @notice Whether `account` is one of the program's registered companion contracts.
    function isCompanion(address account) external view returns (bool);
}

/// @title ICardAuth
/// @notice What companion contracts (sources, the issuer treasury, the issuer desk, merchant reserves) read from and
///         call on a card authorization contract. Amounts are settlement-token units.
interface ICardAuth is ICardAuthState {
    /// @notice A purchase as CardAuth records it, in units of the settlement token it was booked in (`token`).
    ///         `captured` is everything captured or charged; `refunded` is what was refunded or credited back plus
    ///         what the issuer absorbed because the sources could not cover it, so `captured - refunded` is what can
    ///         still be refunded. `held` is what an open purchase still holds.
    struct PurchaseView {
        address owner;
        bytes32 card;
        address token;
        uint64 expiresAt;
        uint64 held;
        uint64 captured;
        uint64 refunded;
        bool open;
        bool standIn;
        bool charged;
    }

    /// @notice Where captures and payments for the program land.
    function SETTLEMENT_ACCOUNT() external view returns (address);
    /// @notice Owners that ever granted the program terms.
    function grantedOwners() external view returns (uint64);
    /// @notice The program's issuer (its rotatable root).
    function ISSUER() external view returns (address);
    /// @notice The token the program settles in now.
    function settlementToken() external view returns (address);
    /// @notice Whether `operator` holds every role bit in `roles` (the issuer holds them all).
    function hasRoles(address operator, uint8 roles) external view returns (bool);
    /// @notice Counts `value` against `operator`'s cumulative cap; reverts past it. Companions only, for the
    ///         operator that called them; the issuer has no cap.
    function useOperatorCap(address operator, uint256 value) external;
    /// @notice Switches the settlement token to `token`; `scale` is how many units of `token` one unit of the
    ///         current token is worth, with 18 decimals. Companions only (the issuer treasury, which applies the
    ///         settings delay and its guards); refused while purchases are open or captures are unsettled.
    function setSettlementToken(address token, uint256 scale) external;

    /// @notice A purchase's record; `owner` is zero for an unknown reference.
    function purchaseOf(bytes32 ref) external view returns (PurchaseView memory);
    /// @notice The purchase's funding legs: the source, position and leg id of each order entry it drew on (and the
    ///         first cash entry, which takes refunds past the other legs).
    function legsOf(bytes32 ref)
        external
        view
        returns (address[] memory sources, bytes32[] memory positions, bytes32[] memory legIds);
    /// @notice What open purchases hold, the stand-in part of it, and what the sources covered net of refunds since
    ///         the issuer last acknowledged settlement (zero when refunds outran it).
    function exposure() external view returns (uint256 held, uint256 standIn, uint256 unsettled);
    /// @notice Purchase steps so far, the last one the issuer acknowledged, net captured units and the net at that
    ///         acknowledgement.
    function ledger() external view returns (uint64 seq, uint64 settledThrough, int128 net, int128 settledNet);

    /// @notice Captures `amount` of purchase `ref`. Authorize role.
    function capture(bytes32 ref, uint128 amount, bool isFinal) external;
    /// @notice Charges card `card` `amount` with no hold under reference `ref`, or late on a purchase whose hold
    ///         ended. Authorize role.
    function charge(bytes32 card, bytes32 ref, uint128 amount, address merchant) external;
    /// @notice Refunds `amount` of purchase `ref` (in the token it was booked in) to the cardholder's legs,
    ///         paid by the caller in today's settlement token; never past what the cardholder's sources covered.
    ///         Settle role.
    function refund(bytes32 ref, uint128 amount) external;
    /// @notice Gives `amount` back to the cardholder's limits and books it refunded without moving money (the caller
    ///         paid the cardholder itself); settlement counts `settles` of it as a refund, at most `amount`, negative
    ///         by at most what the purchase refunded when the caller recovered more elsewhere than the network charges
    ///         back. Registered companions only.
    function creditBack(bytes32 ref, uint128 amount, int128 settles) external;
    /// @notice Acknowledges purchase steps through `throughSeq` as settled: the exposure guard once one is set, else
    ///         the issuer.
    function acknowledgeSettlement(uint64 throughSeq) external;
}
