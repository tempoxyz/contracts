// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @dev Tempo's reservation core precompile (ASCII "RESV"), gated at T15.
address constant RESERVATION_CORE_ADDRESS = 0x5245535600000000000000000000000000000000;
/// @dev The longest a holder's pledge (`pledgeFrom`) may run.
uint64 constant MAX_PLEDGE_DURATION = 400 days;

/// @notice Holds, captures, refunds, capped debt and liens on TIP-20 balances, kept atomic with the balances
///         themselves. Card programs are holder contracts an owner approves per token; everything card-specific
///         lives in them. Hold ids are scoped per owner, lien ids per authority.
interface IReservationCore {
    struct HoldRequest {
        address token;
        bytes32 id;
        /// @dev The amount to reserve; for a stand-in, the amount approved offline.
        uint128 amount;
        /// @dev now < expiresAt <= now + 31 days.
        uint64 expiresAt;
        address payee;
        bool standIn;
    }

    struct HoldRecord {
        address token;
        /// @dev The owner for a direct hold, else the holder contract.
        address placer;
        address payee;
        /// @dev Still reserved.
        uint128 held;
        /// @dev The original approval (stand-in cap; equals the first amount otherwise).
        uint128 approved;
        uint128 captured;
        uint128 refunded;
        uint64 expiresAt;
        bool standIn;
        /// @dev A final capture or a release ended it.
        bool settled;
    }

    // Owner: root key only.
    function approveHolder(address holder, address token, uint128 allowance) external;
    function setDebtCap(address creditor, address token, uint128 cap) external;
    function setCaptureTolerance(address payee, address token, uint32 toleranceBps) external;
    function setOfflineCap(address payee, address token, uint128 cap) external;

    // Holds. hold: the caller is the owner. holdFrom: the caller is an approved holder.
    function hold(HoldRequest calldata request) external;
    function holdFrom(address owner, HoldRequest calldata request) external;
    /// @dev Placer only; sets what the hold still reserves.
    function adjust(address owner, bytes32 id, uint128 amount) external;
    /// @dev Placer or payee.
    function capture(address owner, bytes32 id, uint128 amount, bool isFinal) external;
    /// @dev Placer or payee.
    function release(address owner, bytes32 id) external;
    /// @dev Anyone, after expiresAt.
    function releaseExpired(address owner, bytes32 id) external;
    /// @dev Payee, up to captured - refunded.
    function refund(address owner, bytes32 id, uint128 amount) external;
    /// @dev Owner or approved holder.
    function charge(address owner, address token, bytes32 id, uint128 amount, address payee, bool standIn) external;

    // Liens.
    /// @dev LIEN_ROLE, root key; expiresAt 0 = none.
    function lien(address owner, address token, bytes32 id, uint128 amount, uint64 expiresAt) external;
    /// @dev Owner root key; expiresAt required.
    function pledge(address authority, address token, bytes32 id, uint128 amount, uint64 expiresAt) external;
    /// @dev Authority.
    function releaseLien(bytes32 id) external;
    /// @dev Authority.
    function reduceLien(bytes32 id, uint128 amount) external;
    /// @dev Authority; pays the authority.
    function seizeLien(bytes32 id, uint128 amount) external;
    /// @dev Anyone, after expiresAt.
    function releaseExpiredLien(address authority, bytes32 id) external;
    /// @dev Holder root key, within the owner's allowance for it; the holder becomes the authority. Needs
    ///      now < expiresAt <= now + MAX_PLEDGE_DURATION.
    function pledgeFrom(address owner, address token, bytes32 id, uint128 amount, uint64 expiresAt) external;

    // Views.
    function getHold(address owner, bytes32 id) external view returns (HoldRecord memory);
    function reserved(address owner, address token) external view returns (uint128);
    function available(address owner, address token) external view returns (uint128);
    function allowance(address owner, address holder, address token)
        external
        view
        returns (uint128 allowance, uint128 outstanding);
    function debtOf(address owner, address token) external view returns (address creditor, uint128 amount);
    function debtCap(address owner, address creditor, address token) external view returns (uint128);
    function captureTolerance(address owner, address payee, address token) external view returns (uint32);
    function offlineCap(address owner, address payee, address token) external view returns (uint128);
    function lienOf(address authority, bytes32 id)
        external
        view
        returns (address owner, address token, uint128 amount, uint64 expiresAt, bool pledged);
    function liened(address owner, address token) external view returns (uint128);

    event HolderApproved(address indexed owner, address indexed holder, address indexed token, uint128 allowance);
    event HoldPlaced(
        address indexed owner,
        bytes32 indexed id,
        address indexed token,
        address placer,
        address payee,
        uint128 amount,
        uint128 held,
        uint64 expiresAt,
        bool standIn
    );
    event HoldAdjusted(address indexed owner, bytes32 indexed id, address indexed token, uint128 held);
    event HoldCaptured(
        address indexed owner,
        bytes32 indexed id,
        address indexed token,
        address payee,
        uint128 amount,
        uint128 debt,
        bool isFinal
    );
    event HoldReleased(address indexed owner, bytes32 indexed id, address indexed token, uint128 amount, bool expired);
    event Charged(
        address indexed owner, bytes32 indexed id, address indexed token, address payee, uint128 amount, uint128 debt
    );
    event Refunded(address indexed owner, bytes32 indexed id, address indexed token, address payee, uint128 amount);
    event DebtRepaid(address indexed owner, address indexed token, address indexed creditor, uint128 amount);
    event Liened(
        address indexed owner,
        address indexed authority,
        address indexed token,
        bytes32 id,
        uint128 amount,
        uint64 expiresAt,
        bool pledged
    );
    event LienReleased(
        address indexed owner,
        address indexed authority,
        address indexed token,
        bytes32 id,
        uint128 amount,
        bool expired
    );
    event LienReduced(
        address indexed owner, address indexed authority, address indexed token, bytes32 id, uint128 remaining
    );
    event LienSeized(
        address indexed owner,
        address indexed authority,
        address indexed token,
        bytes32 id,
        uint128 amount,
        uint128 remaining
    );

    error HoldExists();
    error HoldNotFound();
    error HoldExpired();
    error HoldNotExpired();
    error HoldSettled();
    error InsufficientAvailable();
    error AllowanceExceeded();
    error ToleranceExceeded();
    error RefundExceedsCapture();
    error DebtCapExceeded();
    error PolicyForbids();
    error Unauthorized();
    error InvalidAmount();
    error InvalidExpiry();
    error LienExists();
    error LienNotFound();
    error LienNotExpired();
}
