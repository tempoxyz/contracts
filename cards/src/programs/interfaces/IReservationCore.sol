// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @dev The reservation core precompile (TIP-1153), active from T16.
address constant RESERVATION_CORE_ADDRESS = 0x5245535600000000000000000000000000000000;

/// @dev Longest a hold may stand: `now < expiresAt <= now + MAX_HOLD_DURATION`.
uint64 constant MAX_HOLD_DURATION = 31 days;
/// @dev Longest a pledge may stand.
uint64 constant MAX_PLEDGE_DURATION = 400 days;
/// @dev Longest a debt stands before it lapses; a zero `debtTerm` means this.
uint64 constant MAX_DEBT_TERM = 365 days;
/// @dev Most creditors one owner may owe in one token.
uint8 constant MAX_CREDITORS = 4;

/// @dev Record kinds in `HoldRecord.kind`.
uint8 constant KIND_NONE = 0;
uint8 constant KIND_HOLD = 1;
uint8 constant KIND_PLEDGE = 2;
uint8 constant KIND_LIEN = 3;

/// @title IReservationCore
/// @notice Holds, captures, charges, refunds, capped debt, pledges and liens on TIP-20 balances. Every record is keyed
///         by `(owner, placer, id)`: each placer's ids are its own namespace, and a record is deleted when it settles,
///         after which its id may be used again. Placers keep their own replay protection, purchase linkage and
///         cumulative refund caps.
interface IReservationCore {
    /// @notice A hold to place on the owner's balance.
    struct HoldRequest {
        address token;
        bytes32 id;
        /// @dev Amount to reserve; for a stand-in, the amount approved offline.
        uint128 amount;
        /// @dev Must satisfy `now < expiresAt <= now + 31 days`.
        uint64 expiresAt;
        address payee;
        bool standIn;
    }

    /// @notice A live hold. Every field is zero once the hold settles or if it never existed.
    struct HoldRecord {
        address token;
        /// @dev Who captures it: the merchant of an ordinary hold, the authority of a pledge or lien.
        address payee;
        /// @dev Amount still reserved.
        uint128 held;
        /// @dev What captures may still pay in total, tolerance included.
        uint128 captureLimit;
        /// @dev Zero for a lien without expiry.
        uint64 expiresAt;
        /// @dev 0: none, 1: hold, 2: pledge, 3: lien.
        uint8 kind;
        bool standIn;
    }

    /// @notice A holder's spend budget on one owner's balance of one token.
    struct Budget {
        /// @dev Most `spent + outstanding` may reach; zero revokes.
        uint128 limit;
        /// @dev What captures, charges and seizures paid this period; never returned.
        uint128 spent;
        /// @dev What the holder's live holds and pledges still reserve.
        uint128 outstanding;
        /// @dev Seconds after which `spent` resets; zero for a lifetime budget.
        uint32 period;
        /// @dev Start of the current period.
        uint64 periodStart;
    }

    /// @notice The terms an owner sets for one payee in one token.
    struct PayeeTerms {
        /// @dev Debt captures and charges for the payee may leave.
        uint128 debtCap;
        /// @dev Debt stand-in holds and charges for the payee may leave, if above `debtCap`.
        uint128 offlineCap;
        /// @dev How far captures may exceed a new hold's amount, in basis points.
        uint16 toleranceBps;
        /// @dev Seconds a debt to the payee stands before it lapses; zero for the longest, 365 days.
        uint32 debtTerm;
    }

    /// @notice A debt the owner owes one creditor in one token.
    struct Debt {
        address creditor;
        uint128 amount;
        /// @dev When the debt lapses.
        uint64 lapsesAt;
    }

    /// @notice Sets `holder`'s spend budget on the caller's `token`: `limit` (saturated to 2^64 - 1) bounds what it
    ///         spends per `period` plus what it holds. A zero limit revokes: no new holds, charges or pledges, while
    ///         existing holds still settle. Root key only.
    function approveHolder(address holder, address token, uint128 limit, uint32 period) external;
    /// @notice Sets the caller's terms for `payee` in `token`. Root key only.
    function setPayeeTerms(address payee, address token, PayeeTerms calldata terms) external;

    /// @notice Places a hold on the caller's own balance.
    function hold(HoldRequest calldata request) external;
    /// @notice Places a hold on `owner`'s balance as a holder within its budget.
    function holdFrom(address owner, HoldRequest calldata request) external;
    /// @notice Pledges the caller's available balance to `authority` until `expiresAt`, at most 400 days away. Root
    ///         key only.
    function pledge(address authority, address token, bytes32 id, uint128 amount, uint64 expiresAt) external;
    /// @notice Pledges `owner`'s available balance to the caller, a holder within its budget, until `expiresAt`, at
    ///         most 400 days away.
    function pledgeFrom(address owner, address token, bytes32 id, uint128 amount, uint64 expiresAt) external;
    /// @notice Liens `owner`'s available balance for the caller. Needs the token's `LIEN_ROLE` and the caller's root
    ///         key; `expiresAt` zero means no expiry.
    function lien(address owner, address token, bytes32 id, uint128 amount, uint64 expiresAt) external;

    /// @notice Sets what a live hold reserves. The placer of a hold; the payee of a pledge or lien, only downward.
    function adjust(address owner, address placer, bytes32 id, uint128 amount) external;
    /// @notice Pays `amount` of a live hold to its payee; a final capture releases the rest. The placer or payee of a
    ///         hold; the payee of a pledge or lien.
    function capture(address owner, address placer, bytes32 id, uint128 amount, bool isFinal) external;
    /// @notice Ends a live hold, returning what it reserves. The placer or payee of a hold; the payee of a pledge or
    ///         lien.
    function release(address owner, address placer, bytes32 id) external;
    /// @notice Ends a hold past its expiry. Anyone.
    function releaseExpired(address owner, address placer, bytes32 id) external;
    /// @notice Pays `payee` from `owner`'s balance without a hold. The owner or a holder within its budget.
    function charge(address owner, address token, bytes32 id, uint128 amount, address payee, bool standIn) external;
    /// @notice Pays `amount` from the caller back to `owner` for `placer`'s hold `id`, first forgiving what `owner`
    ///         owes the caller in `token`.
    function refund(address owner, address token, address placer, bytes32 id, uint128 amount) external;
    /// @notice Drops `owner`'s debts in `token` past their term. Anyone.
    function clearLapsedDebt(address owner, address token) external;

    function getHold(address owner, address placer, bytes32 id) external view returns (HoldRecord memory);
    function reserved(address owner, address token) external view returns (uint128);
    function available(address owner, address token) external view returns (uint128);
    function budget(address owner, address holder, address token) external view returns (Budget memory);
    function payeeTerms(address owner, address payee, address token) external view returns (PayeeTerms memory);
    function debtOf(address owner, address token) external view returns (Debt[] memory);

    event HolderApproved(
        address indexed owner, address indexed holder, address indexed token, uint128 limit, uint32 period
    );
    event PayeeTermsSet(address indexed owner, address indexed payee, address indexed token, PayeeTerms terms);
    event HoldPlaced(
        address indexed owner,
        address indexed placer,
        address indexed token,
        bytes32 id,
        uint8 kind,
        address payee,
        uint128 amount,
        uint128 held,
        uint128 captureLimit,
        uint64 expiresAt,
        bool standIn
    );
    event HoldAdjusted(
        address indexed owner,
        address indexed placer,
        address indexed token,
        bytes32 id,
        uint128 held,
        uint128 captureLimit
    );
    event HoldCaptured(
        address indexed owner,
        address indexed placer,
        address indexed token,
        bytes32 id,
        address payee,
        uint128 amount,
        uint128 debt,
        bool isFinal
    );
    event HoldReleased(
        address indexed owner, address indexed placer, address indexed token, bytes32 id, uint128 amount, bool expired
    );
    event Charged(
        address indexed owner,
        address indexed charger,
        address indexed token,
        bytes32 id,
        address payee,
        uint128 amount,
        uint128 debt
    );
    event Refunded(
        address indexed owner,
        address indexed payee,
        address indexed token,
        address placer,
        bytes32 id,
        uint128 amount,
        uint128 forgiven
    );
    event DebtRepaid(address indexed owner, address indexed creditor, address indexed token, uint128 amount);
    event DebtLapsed(address indexed owner, address indexed creditor, address indexed token, uint128 amount);

    error HoldExists();
    error HoldNotFound();
    error HoldExpired();
    error HoldNotExpired();
    error InsufficientAvailable();
    error BudgetExceeded();
    error CaptureLimitExceeded();
    error DebtCapExceeded();
    error TooManyCreditors();
    error PolicyForbids();
    error Unauthorized();
    error InvalidAmount();
    error InvalidExpiry();
}
