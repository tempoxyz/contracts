// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Vm } from "forge-std/Vm.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

import {
    IReservationCore,
    KIND_HOLD,
    KIND_LIEN,
    KIND_PLEDGE,
    MAX_HOLD_DURATION,
    MAX_PLEDGE_DURATION
} from "../../../../src/interfaces/spend/programs/IReservationCore.sol";

interface IMockCoreToken {
    function balanceOf(address account) external view returns (uint256);
    function paused() external view returns (bool);
    function transferPolicyId() external view returns (uint64);
    function hasRole(address account, bytes32 role) external view returns (bool);
}

/// @title MockReservationCore
/// @notice TEST MODEL ONLY of the reservation core precompile at 0x5245535600000000000000000000000000000000, which
///         the test EVM's hardfork predates. Tests etch it at that address and allow it cheatcodes. It follows the
///         node's rules: records keyed by (owner, placer, id) and deleted on settlement; hold, pledge and lien kinds;
///         holder budgets with periods; capture tolerances; payments only from what a record backs or the owner's
///         free balance; and the token's pause and TIP-403 checks on every payment.
/// @dev Where the node moves amounts between an owner's balance slot and its reserved position, this model moves the
///      token balance between the owner and this contract by writing the token's balance slots, so an owner's
///      `balanceOf` is exactly the node's balance slot (`available`), and this contract's balance of a token equals
///      the token's total reserved (`totalReserved`). The node's `balanceOf` also counts reserved amounts; this one
///      does not. Other differences, all test-only:
///      - It cannot tell a root key from an access key, so "root key only" checks pass for every caller, and access
///        key spending limits are not applied.
///      - Burning reserved balance (the node's unbacked shortfall) is not modeled.
///      - Token rewards accounting is untouched by reservations.
contract MockReservationCore is IReservationCore {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    /// @notice The token role allowed to place and seize liens.
    bytes32 public constant LIEN_ROLE = keccak256("LIEN_ROLE");
    /// @dev Storage slot of the TIP-20 precompile's `balances` mapping.
    uint256 private constant BALANCES_SLOT = 9;
    uint256 private constant BPS = 10_000;
    bytes12 private constant TIP20_PREFIX = 0x20c000000000000000000000;

    error InvalidToken();
    error InvalidRecipient();

    struct Record {
        address token;
        uint64 held;
        uint32 expiresAt;
        address payee;
        uint64 captureLimit;
        uint16 toleranceBps;
        uint8 kind;
    }

    struct Hold {
        address owner;
        address placer;
        bytes32 id;
        Record r;
    }

    struct BudgetState {
        uint64 limit;
        uint64 spent;
        uint64 outstanding;
        uint32 period;
        uint32 periodStart;
    }

    mapping(address owner => mapping(address placer => mapping(bytes32 id => Record))) private _records;
    mapping(address owner => mapping(address token => uint128)) private _reserved;
    mapping(address owner => mapping(address holder => mapping(address token => BudgetState))) private _budgets;
    mapping(address owner => mapping(address payee => mapping(address token => uint16))) private _tolerances;

    /// @notice Everything reserved in `token` across owners. Equals this contract's balance of `token`.
    mapping(address token => uint256) public totalReserved;

    // Owner settings.

    function approveHolder(address holder, address token, uint128 limit, uint32 period) external {
        address owner = msg.sender;
        if (holder == address(0) || holder == owner) revert Unauthorized();
        _tip20(token);
        uint64 now_ = _now();
        BudgetState memory b = _budgets[owner][holder][token];
        _roll(b, now_);
        b.limit = _sat64(limit);
        if (b.period != period) {
            b.period = period;
            b.periodStart = _ts32(now_);
        }
        _budgets[owner][holder][token] = b;
        emit HolderApproved(owner, holder, token, b.limit, period);
    }

    function setCaptureTolerance(address payee, address token, uint16 toleranceBps) external {
        address owner = msg.sender;
        address resolved = _counterparty(owner, payee, token);
        _tolerances[owner][resolved][token] = toleranceBps;
        emit CaptureToleranceSet(owner, resolved, token, toleranceBps);
    }

    // Placing.

    function hold(HoldRequest calldata request) external {
        _place(msg.sender, msg.sender, request);
    }

    function holdFrom(address owner, HoldRequest calldata request) external {
        _place(msg.sender, owner, request);
    }

    function pledge(address authority, address token, bytes32 id, uint128 amount, uint64 expiresAt) external {
        address resolved = _counterparty(msg.sender, authority, token);
        _placePledge(msg.sender, msg.sender, resolved, token, id, amount, expiresAt);
    }

    function pledgeFrom(address owner, address token, bytes32 id, uint128 amount, uint64 expiresAt) external {
        if (msg.sender == owner) revert Unauthorized();
        _placePledge(msg.sender, owner, msg.sender, token, id, amount, expiresAt);
    }

    function lien(address owner, address token, bytes32 id, uint128 amount, uint64 expiresAt) external {
        address authority = msg.sender;
        _tip20(token);
        if (!IMockCoreToken(token).hasRole(authority, LIEN_ROLE)) revert Unauthorized();
        if (expiresAt != 0 && (expiresAt <= _now() || expiresAt > type(uint32).max)) revert InvalidExpiry();
        uint64 amt = _amount64(amount);
        address resolvedOwner = _payee(owner);
        if (resolvedOwner == authority) revert Unauthorized();
        _ensureVacant(resolvedOwner, authority, id);
        if (amt > _available(token, resolvedOwner)) revert InsufficientAvailable();
        _reserve(token, resolvedOwner, amt);
        _records[resolvedOwner][authority][id] = Record({
            token: token,
            held: amt,
            expiresAt: _ts32(expiresAt),
            payee: authority,
            captureLimit: amt,
            toleranceBps: 0,
            kind: KIND_LIEN
        });
        emit HoldPlaced(resolvedOwner, authority, token, id, KIND_LIEN, authority, amt, amt, expiresAt);
    }

    // Settling.

    function adjust(address owner, address placer, bytes32 id, uint128 amount) external {
        Hold memory h = _liveHold(owner, placer, id);
        uint64 amt = _amount64(amount);
        uint64 held = h.r.held;
        if (h.r.kind == KIND_HOLD) {
            if (msg.sender != h.placer) revert Unauthorized();
        } else if (msg.sender != h.r.payee) {
            revert Unauthorized();
        } else if (amt > held) {
            revert InvalidAmount();
        }
        address token = h.r.token;
        _tip20(token);
        if (amt > held) {
            uint64 increase = amt - held;
            uint64 wanted = _withTolerance(amt, h.r.toleranceBps);
            uint64 raise = wanted > h.r.captureLimit ? wanted - h.r.captureLimit : 0;
            _ensureAllowed(token, owner, h.r.payee, false);
            if (increase > _available(token, owner)) revert InsufficientAvailable();
            if (_budgeted(h)) _drawBudget(owner, h.placer, token, increase, increase, 0);
            _reserve(token, owner, increase);
            if (raise != 0) h.r.captureLimit = wanted;
        } else if (amt < held) {
            uint64 decrease = held - amt;
            _unreserve(token, owner, decrease);
            if (_budgeted(h)) _settleBudget(owner, h.placer, token, 0, decrease, 0);
            if (h.r.kind != KIND_HOLD) h.r.captureLimit = amt;
        }
        h.r.held = amt;
        _records[owner][h.placer][id] = h.r;
        emit HoldAdjusted(owner, h.placer, token, id, amt, h.r.captureLimit);
    }

    function capture(address owner, address placer, bytes32 id, uint128 amount, bool isFinal) external {
        Hold memory h = _liveHold(owner, placer, id);
        address payee = h.r.payee;
        address token = h.r.token;
        _tip20(token);
        uint8 k = h.r.kind;
        if (k == KIND_HOLD) {
            if (msg.sender != h.placer && msg.sender != payee) revert Unauthorized();
        } else if (msg.sender != payee) {
            revert Unauthorized();
        } else if (k == KIND_LIEN && !IMockCoreToken(token).hasRole(msg.sender, LIEN_ROLE)) {
            revert Unauthorized();
        }
        if (amount == 0 && !isFinal) revert InvalidAmount();
        if (amount > h.r.captureLimit) revert CaptureLimitExceeded();
        uint64 amt = uint64(amount);
        uint64 held = h.r.held;
        uint64 fromHold = amt < held ? amt : held;
        uint64 excess = amt - fromHold;
        uint64 rest = isFinal ? held - fromHold : 0;
        // What the hold still backs pays its payee even after the owner is blocked; a payment that also draws on the
        // free balance is new, so it needs the owner's authorization too.
        bool senderExempt = (k == KIND_HOLD && excess == 0) || k == KIND_LIEN;
        _ensureAllowed(token, owner, payee, senderExempt);
        if (_budgeted(h)) _settleBudget(owner, h.placer, token, fromHold, rest, excess);
        uint128 paid;
        if (k == KIND_HOLD) {
            // The hold returns what it backs to the balance first; the excess must be free there, or nothing is paid.
            _unreserve(token, owner, uint128(fromHold) + rest);
            _pay(token, owner, payee, amt, senderExempt);
            paid = amt;
        } else {
            _unreserve(token, owner, fromHold);
            _transfer(token, owner, payee, fromHold, senderExempt);
            _unreserve(token, owner, rest);
            paid = fromHold;
        }
        h.r.held -= fromHold + rest;
        h.r.captureLimit = k == KIND_HOLD ? h.r.captureLimit - amt : h.r.held;
        bool settled = isFinal || (k != KIND_HOLD && h.r.held == 0);
        if (settled) delete _records[owner][h.placer][id];
        else _records[owner][h.placer][id] = h.r;
        emit HoldCaptured(owner, h.placer, token, id, payee, paid, settled);
    }

    function release(address owner, address placer, bytes32 id) external {
        Hold memory h = _loadHold(owner, placer, id);
        bool allowed = msg.sender == h.r.payee || (h.r.kind == KIND_HOLD && msg.sender == h.placer);
        if (!allowed) revert Unauthorized();
        _endHold(h, false);
    }

    function releaseExpired(address owner, address placer, bytes32 id) external {
        Hold memory h = _loadHold(owner, placer, id);
        if (!_expired(h.r, _now())) revert HoldNotExpired();
        _endHold(h, true);
    }

    function charge(address owner, address token, bytes32 id, uint128 amount, address payee) external {
        address resolved = _payee(payee);
        uint64 amt = _amount64(amount);
        _tip20(token);
        // A holder's budget is checked before the owner's policy and balance, as the node does.
        if (msg.sender != owner) _drawBudget(owner, msg.sender, token, amt, 0, amt);
        _ensureAllowed(token, owner, resolved, false);
        _pay(token, owner, resolved, amt, false);
        emit Charged(owner, msg.sender, token, id, resolved, amt);
    }

    function refund(address owner, address token, address placer, bytes32 id, uint128 amount) external {
        if (amount == 0) revert InvalidAmount();
        address resolved = _payee(owner);
        _tip20(token);
        _ensureAllowed(token, msg.sender, resolved, false);
        if (amount > _available(token, msg.sender)) revert InsufficientAvailable();
        _transfer(token, msg.sender, resolved, amount, false);
        emit Refunded(resolved, msg.sender, token, placer, id, amount);
    }

    // Views.

    function getHold(address owner, address placer, bytes32 id) external view returns (HoldRecord memory record) {
        Record memory r = _records[owner][placer][id];
        if (r.token == address(0)) return record;
        record = HoldRecord({
            token: r.token,
            payee: r.payee,
            held: r.held,
            captureLimit: r.captureLimit,
            expiresAt: r.expiresAt,
            kind: r.kind
        });
    }

    function reserved(address owner, address token) external view returns (uint128) {
        return _reserved[owner][token];
    }

    function available(address owner, address token) external view returns (uint128) {
        _tip20(token);
        return _available(token, owner);
    }

    function budget(address owner, address holder, address token) external view returns (Budget memory) {
        BudgetState memory b = _budgets[owner][holder][token];
        _roll(b, _now());
        return Budget({
            limit: b.limit, spent: b.spent, outstanding: b.outstanding, period: b.period, periodStart: b.periodStart
        });
    }

    function captureTolerance(address owner, address payee, address token) external view returns (uint16) {
        address resolved = StdPrecompiles.ADDRESS_REGISTRY.resolveRecipient(payee);
        return _tolerances[owner][resolved][token];
    }

    // Placement internals.

    function _place(address placer, address owner, HoldRequest calldata request) private {
        uint64 amt = _amount64(request.amount);
        uint64 now_ = _now();
        if (
            request.expiresAt <= now_ || request.expiresAt > now_ + MAX_HOLD_DURATION
                || request.expiresAt > type(uint32).max
        ) revert InvalidExpiry();
        _ensureVacant(owner, placer, request.id);
        address payee = _payee(request.payee);
        address token = request.token;
        _tip20(token);
        // The placer's budget is checked before the owner's policy and balance, as the node does.
        if (placer != owner) _drawBudget(owner, placer, token, amt, amt, 0);
        _ensureAllowed(token, owner, payee, false);
        if (amt > _available(token, owner)) revert InsufficientAvailable();
        uint16 tolerance = _tolerances[owner][payee][token];
        uint64 captureLimit = _withTolerance(amt, tolerance);
        _reserve(token, owner, amt);
        _records[owner][placer][request.id] = Record({
            token: token,
            held: amt,
            expiresAt: _ts32(request.expiresAt),
            payee: payee,
            captureLimit: captureLimit,
            toleranceBps: tolerance,
            kind: KIND_HOLD
        });
        emit HoldPlaced(
            owner, placer, token, request.id, KIND_HOLD, payee, request.amount, captureLimit, request.expiresAt
        );
    }

    function _placePledge(
        address placer,
        address owner,
        address authority,
        address token,
        bytes32 id,
        uint128 amount,
        uint64 expiresAt
    ) private {
        uint64 amt = _amount64(amount);
        uint64 now_ = _now();
        if (expiresAt <= now_ || expiresAt > now_ + MAX_PLEDGE_DURATION || expiresAt > type(uint32).max) {
            revert InvalidExpiry();
        }
        _ensureVacant(owner, placer, id);
        _tip20(token);
        // The holder's budget is checked before the owner's policy and balance, as the node does.
        if (placer != owner) _drawBudget(owner, placer, token, amt, amt, 0);
        _ensureAllowed(token, owner, authority, false);
        if (amt > _available(token, owner)) revert InsufficientAvailable();
        _reserve(token, owner, amt);
        _records[owner][placer][id] = Record({
            token: token,
            held: amt,
            expiresAt: _ts32(expiresAt),
            payee: authority,
            captureLimit: amt,
            toleranceBps: 0,
            kind: KIND_PLEDGE
        });
        emit HoldPlaced(owner, placer, token, id, KIND_PLEDGE, authority, amt, amt, expiresAt);
    }

    function _ensureVacant(address owner, address placer, bytes32 id) private view {
        if (_records[owner][placer][id].token != address(0)) revert HoldExists();
    }

    function _loadHold(address owner, address placer, bytes32 id) private view returns (Hold memory h) {
        h = Hold({ owner: owner, placer: placer, id: id, r: _records[owner][placer][id] });
        if (h.r.token == address(0)) revert HoldNotFound();
    }

    function _liveHold(address owner, address placer, bytes32 id) private view returns (Hold memory h) {
        h = _loadHold(owner, placer, id);
        if (_expired(h.r, _now())) revert HoldExpired();
    }

    function _endHold(Hold memory h, bool expired) private {
        uint64 held = h.r.held;
        if (held != 0) {
            _unreserve(h.r.token, h.owner, held);
            if (_budgeted(h)) _settleBudget(h.owner, h.placer, h.r.token, 0, held, 0);
        }
        delete _records[h.owner][h.placer][h.id];
        emit HoldReleased(h.owner, h.placer, h.r.token, h.id, held, expired);
    }

    function _budgeted(Hold memory h) private pure returns (bool) {
        return h.placer != h.owner && h.r.kind != KIND_LIEN;
    }

    function _expired(Record memory r, uint64 now_) private pure returns (bool) {
        return r.expiresAt != 0 && now_ >= r.expiresAt;
    }

    // Budgets.

    function _roll(BudgetState memory b, uint64 now_) private pure {
        if (b.period == 0) return;
        uint64 start = b.periodStart;
        uint64 period = b.period;
        if (now_ >= start + period) {
            uint64 elapsed = (now_ - start) / period * period;
            b.periodStart = _ts32(start + elapsed);
            b.spent = 0;
        }
    }

    function _admitWithinLimit(BudgetState memory b, uint64 amount) private pure {
        if (uint256(b.spent) + b.outstanding + amount > b.limit) revert BudgetExceeded();
    }

    function _drawBudget(address owner, address holder, address token, uint64 check, uint64 outstanding, uint64 spent)
        private
    {
        BudgetState memory b = _budgets[owner][holder][token];
        _roll(b, _now());
        if (b.limit == 0) revert Unauthorized();
        _admitWithinLimit(b, check);
        b.outstanding += outstanding;
        b.spent += spent;
        _budgets[owner][holder][token] = b;
    }

    function _settleBudget(address owner, address holder, address token, uint64 paid, uint64 released, uint64 excess)
        private
    {
        if (paid == 0 && released == 0 && excess == 0) return;
        BudgetState memory b = _budgets[owner][holder][token];
        _roll(b, _now());
        b.outstanding -= paid + released;
        b.spent = uint256(b.spent) + paid > type(uint64).max ? type(uint64).max : b.spent + paid;
        if (excess != 0) {
            _admitWithinLimit(b, excess);
            b.spent += excess;
        }
        _budgets[owner][holder][token] = b;
    }

    // Payments.

    /// @dev Pays `amount` from `owner`'s free balance; nothing is paid beyond it.
    function _pay(address token, address owner, address payee, uint64 amount, bool senderExempt) private {
        if (amount > _available(token, owner)) revert InsufficientAvailable();
        _transfer(token, owner, payee, amount, senderExempt);
    }

    // Policy.

    function _ensureAllowed(address token, address from, address to, bool senderExempt) private view {
        if (!_paymentAllowed(token, from, to, senderExempt)) revert PolicyForbids();
    }

    /// @dev The node's check for a payment the core makes: pause, the token's TIP-403 policy (the recipient only when
    ///      the sender is exempt) and the recipient's receive policy.
    function _paymentAllowed(address token, address from, address to, bool senderExempt) private view returns (bool) {
        if (
            to == address(0) || to == from || bytes12(bytes20(to)) == TIP20_PREFIX
                || to == StdPrecompiles.RECEIVE_POLICY_GUARD_ADDRESS || IMockCoreToken(token).paused()
        ) return false;
        ITIP403Registry registry = StdPrecompiles.TIP403_REGISTRY;
        uint64 policy = IMockCoreToken(token).transferPolicyId();
        bool authorized = senderExempt
            ? registry.isAuthorizedRecipient(policy, to)
            : registry.isAuthorizedSender(policy, from) && registry.isAuthorizedRecipient(policy, to);
        if (!authorized) return false;
        (bool receivable,) = registry.validateReceivePolicy(token, from, to);
        return receivable;
    }

    // Balances.

    function _available(address token, address owner) private view returns (uint128) {
        uint256 balance = IMockCoreToken(token).balanceOf(owner);
        return balance > type(uint128).max ? type(uint128).max : uint128(balance);
    }

    function _reserve(address token, address owner, uint128 amount) private {
        if (amount == 0) return;
        _reserved[owner][token] += amount;
        totalReserved[token] += amount;
        _move(token, owner, address(this), amount);
    }

    function _unreserve(address token, address owner, uint128 amount) private {
        if (amount == 0) return;
        _reserved[owner][token] -= amount;
        totalReserved[token] -= amount;
        _move(token, address(this), owner, amount);
    }

    /// @dev A core payment: checks policy and moves the balance.
    function _transfer(address token, address from, address to, uint128 amount, bool senderExempt) private {
        _ensureAllowed(token, from, to, senderExempt);
        if (amount == 0) return;
        _move(token, from, to, amount);
    }

    /// @dev Moves a balance between two accounts' slots, without the token's own checks.
    function _move(address token, address from, address to, uint256 amount) private {
        if (amount == 0) return;
        bytes32 fromSlot = keccak256(abi.encode(from, BALANCES_SLOT));
        bytes32 toSlot = keccak256(abi.encode(to, BALANCES_SLOT));
        VM.store(token, fromSlot, bytes32(uint256(VM.load(token, fromSlot)) - amount));
        VM.store(token, toSlot, bytes32(uint256(VM.load(token, toSlot)) + amount));
    }

    // Validation.

    function _tip20(address token) private pure {
        if (bytes12(bytes20(token)) != TIP20_PREFIX) revert InvalidToken();
    }

    function _payee(address account) private view returns (address resolved) {
        resolved = StdPrecompiles.ADDRESS_REGISTRY.resolveRecipient(account);
        if (resolved == address(0) || bytes12(bytes20(resolved)) == TIP20_PREFIX) revert InvalidRecipient();
    }

    function _counterparty(address owner, address account, address token) private view returns (address resolved) {
        resolved = StdPrecompiles.ADDRESS_REGISTRY.resolveRecipient(account);
        if (resolved == address(0) || resolved == owner) revert Unauthorized();
        _tip20(token);
    }

    function _amount64(uint128 amount) private pure returns (uint64) {
        if (amount == 0 || amount > type(uint64).max) revert InvalidAmount();
        return uint64(amount);
    }

    function _withTolerance(uint64 amount, uint16 bps) private pure returns (uint64) {
        uint256 limit = uint256(amount) * (BPS + bps) / BPS;
        return limit > type(uint64).max ? type(uint64).max : uint64(limit);
    }

    function _sat64(uint128 value) private pure returns (uint64) {
        return value > type(uint64).max ? type(uint64).max : uint64(value);
    }

    function _ts32(uint64 timestamp) private pure returns (uint32) {
        return timestamp > type(uint32).max ? type(uint32).max : uint32(timestamp);
    }

    function _now() private view returns (uint64) {
        return uint64(VM.getBlockTimestamp());
    }
}
