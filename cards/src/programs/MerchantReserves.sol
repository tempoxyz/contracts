// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { ICardAuth } from "./interfaces/ICardAuth.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";
import { ISettlementTokenGuard } from "./interfaces/ISettlementTokenGuard.sol";

/// @title MerchantReserves
/// @notice The acquirer side of a card program: reserves held back on merchants' balances (and the settlement
///         account's), as core pledges this contract places and is payee of. Only owners that approved this contract
///         as holder can be reserved, and an owner other than the settlement account only for a purpose it consented
///         to, never collected past the cap it set, or for disputes once it allowed dispute reserves. Collecting pays
///         the program's settlement account. It sits outside the card program: merchants need no card grant.
/// @custom:reentrancy-guard _locked
contract MerchantReserves is ISettlementTokenGuard {
    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    /// @notice The longest a dispute reserve holds, the networks' dispute window.
    uint256 public constant MAX_DISPUTE_RESERVE = 120 days;
    /// @dev The settlement-token-in-use reason for a reserve still held.
    uint8 private constant IN_USE_RESERVES = 9;

    ICardAuth public immutable PROGRAM;

    /// @notice An owner's consent to reserves of one token: the purpose, the most collected over its life, and what
    ///         was collected so far.
    struct Consent {
        uint128 cap;
        uint128 collected;
        bytes32 purpose;
    }

    struct Reserve {
        address owner;
        bool consented;
    }

    mapping(address owner => mapping(address token => Consent)) public consentOf;
    /// @notice Merchants that allow dispute reserves.
    mapping(address merchant => bool) public disputeReserves;
    mapping(bytes32 id => Reserve) public reserveOf;
    /// @dev Reserves that may still be held, pruned as new ones are placed.
    bytes32[] internal _live;

    bool private transient _locked;

    event ReservesAllowed(address indexed owner, address indexed token, uint128 cap, bytes32 purpose);
    event DisputeReservesSet(address indexed merchant, bool allowed);
    event ReservePlaced(bytes32 indexed id, address indexed owner, address token, uint128 amount, uint64 expiresAt);
    event DisputeReserved(
        bytes32 indexed purchaseRef,
        address indexed merchant,
        address token,
        uint128[2] tokens,
        uint128[2] covers,
        uint64 expiresAt
    );
    event ReserveReleased(bytes32 indexed id);
    event ReserveCollected(bytes32 indexed id, address indexed to, uint128 amount);

    error NotOperator();
    error Reentrancy();
    error ReserveExists();
    error ReserveNotAllowed();
    error ReserveTooLong();
    error UnknownReserve();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(ICardAuth program) {
        PROGRAM = program;
    }

    // Every entry point that moves money holds the transient lock for its whole call; the program and the core it
    // calls are fixed.
    // forge-lint: disable-start(reentrancy-no-eth)

    /// @notice Lets the program's operators reserve the caller's token for purpose and collect up to cap of it over the
    ///         consent's life, counting what they already collected. A zero cap withdraws the consent.
    function allowReserves(address token, uint128 cap, bytes32 purpose) external {
        Consent storage c = consentOf[msg.sender][token];
        (c.cap, c.purpose) = (cap, purpose);
        emit ReservesAllowed(msg.sender, token, cap, purpose);
    }

    /// @notice Lets the program's operators reserve the caller's balance against disputes on its purchases.
    function setDisputeReserves(bool allowed) external {
        disputeReserves[msg.sender] = allowed;
        emit DisputeReservesSet(msg.sender, allowed);
    }

    /// @notice Holds back amount of owner's token until expiresAt. An owner other than the settlement account needs its
    ///         consent for purpose, with room for amount left under its cap.
    function reserve(address owner, address token, bytes32 id, uint128 amount, uint64 expiresAt, bytes32 purpose)
        external
        nonReentrant
    {
        address account = PROGRAM.SETTLEMENT_ACCOUNT();
        bool consented = owner != account;
        if (consented) {
            Consent storage c = consentOf[owner][token];
            if (c.purpose != purpose || uint256(amount) + c.collected > c.cap) revert ReserveNotAllowed();
        }
        _operator(consented ? amount : 0);
        _reserve(owner, token, id, amount, expiresAt, consented);
    }

    /// @notice Reserves a disputed purchase for at most the dispute window: tokens[0] on the merchant's balance, once
    ///         it allows dispute reserves, and tokens[1] on the settlement account. covers records what each part
    ///         covers in the purchase's units.
    function reserveDispute(
        address merchant,
        address token,
        bytes32 purchaseRef,
        uint128[2] calldata tokens,
        uint128[2] calldata covers,
        uint64 expiresAt
    ) external nonReentrant {
        if (!disputeReserves[merchant]) revert ReserveNotAllowed();
        // forge-lint: disable-next-line(block-timestamp)
        if (expiresAt > block.timestamp + MAX_DISPUTE_RESERVE) revert ReserveTooLong();
        _operator(tokens[0]);
        if (tokens[0] != 0) _reserve(merchant, token, reserveId(purchaseRef, merchant), tokens[0], expiresAt, false);
        address account = PROGRAM.SETTLEMENT_ACCOUNT();
        if (tokens[1] != 0) _reserve(account, token, reserveId(purchaseRef, account), tokens[1], expiresAt, false);
        emit DisputeReserved(purchaseRef, merchant, token, tokens, covers, expiresAt);
    }

    /// @notice Releases a reserve before it expires.
    function releaseReserve(bytes32 id) external nonReentrant {
        _operator(0);
        address owner = reserveOf[id].owner;
        if (owner == address(0)) revert UnknownReserve();
        CORE.release(owner, address(this), id);
        emit ReserveReleased(id);
    }

    /// @notice Takes amount of a reserve and pays it to the settlement account, releasing the rest. A reserve placed
    ///         under an owner's consent counts against its cap, and the owner may have withdrawn it since.
    function collectReserve(bytes32 id, uint128 amount) external nonReentrant {
        Reserve memory r = reserveOf[id];
        address owner = r.owner;
        IReservationCore.HoldRecord memory h = CORE.getHold(owner, address(this), id);
        address token = h.token;
        if (token == address(0)) revert IReservationCore.HoldNotFound();
        if (r.consented) {
            Consent storage c = consentOf[owner][token];
            uint256 collected = uint256(c.collected) + amount;
            if (collected > c.cap) revert ReserveNotAllowed();
            // Bounded by the 128-bit cap just checked.
            // forge-lint: disable-next-line(unsafe-typecast)
            c.collected = uint128(collected);
        }
        address account = PROGRAM.SETTLEMENT_ACCOUNT();
        _operator(owner != account ? amount : 0);
        // Collecting part of a reserve ends it and releases the rest.
        if (amount != 0) {
            CORE.capture(owner, address(this), id, amount, true);
            SafeTransferLib.safeTransfer(token, account, amount);
        } else if (h.held != 0) {
            CORE.release(owner, address(this), id);
        }
        emit ReserveCollected(id, account, amount);
    }

    /// @notice The core id of the reserve a dispute placed on owner.
    function reserveId(bytes32 purchaseRef, address owner) public pure returns (bytes32) {
        return keccak256(abi.encode(purchaseRef, owner));
    }

    /// @notice A reserve still held keeps the settlement token from changing (reason 9).
    // At most the reserves still live, one core read each.
    // forge-lint: disable-next-item(calls-loop)
    function settlementTokenInUse(address) external view returns (uint8) {
        uint256 n = _live.length;
        for (uint256 i; i < n; ++i) {
            bytes32 id = _live[i];
            if (CORE.getHold(reserveOf[id].owner, address(this), id).held != 0) return IN_USE_RESERVES;
        }
        return 0;
    }

    /// @dev The caller must be the issuer or a treasury operator, which counts value against its cap.
    function _operator(uint256 value) private {
        if (msg.sender == PROGRAM.ISSUER()) return;
        if (!PROGRAM.hasRoles(msg.sender, PROGRAM.ROLE_TREASURY())) revert NotOperator();
        if (value != 0) PROGRAM.useOperatorCap(msg.sender, value);
    }

    // forge-lint: disable-next-item(calls-loop)
    function _reserve(address owner, address token, bytes32 id, uint128 amount, uint64 expiresAt, bool consented)
        private
    {
        // The core keys a reserve by its owner, so an id names one reserve at a time across owners.
        address prior = reserveOf[id].owner;
        if (prior != address(0) && CORE.getHold(prior, address(this), id).token != address(0)) revert ReserveExists();
        // Drop reserves that ended, so the token guard reads only live ones.
        uint256 i = _live.length;
        while (i != 0) {
            bytes32 old = _live[--i];
            if (CORE.getHold(reserveOf[old].owner, address(this), old).held != 0) continue;
            _live[i] = _live[_live.length - 1];
            _live.pop();
        }
        reserveOf[id] = Reserve({ owner: owner, consented: consented });
        CORE.pledgeFrom(owner, token, id, amount, expiresAt);
        _live.push(id);
        emit ReservePlaced(id, owner, token, amount, expiresAt);
    }
    // forge-lint: disable-end(reentrancy-no-eth)
}
