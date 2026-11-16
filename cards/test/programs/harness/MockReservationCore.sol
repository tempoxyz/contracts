// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Vm } from "forge-std/Vm.sol";

import { IReservationCore } from "../../../src/programs/interfaces/IReservationCore.sol";

interface IBalanceToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title MockReservationCore
/// @notice TEST MODEL ONLY of the reservation core precompile at 0x5245535600000000000000000000000000000000, which
///         the test EVM's hardfork predates. Tests etch it at that address and allow it cheatcodes. It keeps the
///         node's rules (placer, payee and holder rights, outstanding allowance, hard expiry, capture tolerance,
///         stand-in cap, capped debt, refunds, liens) against real token balances.
/// @dev Where the node moves amounts between an owner's balance slot and its reserved position, this model moves
///      the tokens between the owner and its own address, so the owner's balance is exactly the balance slot and
///      this contract's balance of a token equals the token's total reserved (`totalReserved`). Differences from
///      the node, all test-only: it cannot tell a root key from an access key, so "root key only" means the owner;
///      `LIEN_ROLE` is granted with `grantLienRole`; debt is repaid from the owner's balance at the start of the
///      next operation on that owner and token, or by `repay`, rather than from each incoming credit as it lands.
contract MockReservationCore is IReservationCore {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant MAX_HOLD = 31 days;
    uint256 private constant BPS = 10_000;

    struct Debt {
        address creditor;
        uint128 amount;
    }

    struct Lien {
        address owner;
        address token;
        uint128 amount;
        uint64 expiresAt;
        bool pledged;
    }

    mapping(address owner => mapping(bytes32 id => HoldRecord)) private _holds;
    mapping(address owner => mapping(address token => uint128)) private _reserved;
    mapping(address owner => mapping(address token => uint128)) private _liened;
    mapping(address owner => mapping(address holder => mapping(address token => uint128))) private _allowance;
    mapping(address owner => mapping(address holder => mapping(address token => uint128))) private _outstanding;
    mapping(address owner => mapping(address creditor => mapping(address token => uint128))) private _debtCap;
    mapping(address owner => mapping(address token => Debt)) private _debt;
    mapping(address owner => mapping(address payee => mapping(address token => uint32))) private _tolerance;
    mapping(address owner => mapping(address payee => mapping(address token => uint128))) private _offlineCap;
    mapping(address authority => mapping(bytes32 id => Lien)) private _liens;

    /// @notice Everything reserved in `token` across owners: holds and liens. Equals this contract's balance.
    mapping(address token => uint256) public totalReserved;
    /// @notice Accounts holding `LIEN_ROLE`.
    mapping(address account => bool) public hasLienRole;

    // Test hooks.

    function grantLienRole(address account, bool granted) external {
        hasLienRole[account] = granted;
    }

    /// @notice Repays `owner`'s debt in `token` from its balance, as the node does when credits arrive.
    function repay(address owner, address token) external {
        _repay(owner, token);
    }

    // Owner settings.

    function approveHolder(address holder, address token, uint128 allowance_) external {
        _allowance[msg.sender][holder][token] = allowance_;
        emit HolderApproved(msg.sender, holder, token, allowance_);
    }

    function setDebtCap(address creditor, address token, uint128 cap) external {
        _debtCap[msg.sender][creditor][token] = cap;
    }

    function setCaptureTolerance(address payee, address token, uint32 toleranceBps) external {
        _tolerance[msg.sender][payee][token] = toleranceBps;
    }

    function setOfflineCap(address payee, address token, uint128 cap) external {
        _offlineCap[msg.sender][payee][token] = cap;
    }

    // Holds.

    function hold(HoldRequest calldata request) external {
        _place(msg.sender, msg.sender, request);
    }

    function holdFrom(address owner, HoldRequest calldata request) external {
        _place(owner, msg.sender, request);
    }

    function adjust(address owner, bytes32 id, uint128 amount) external {
        HoldRecord storage h = _live(owner, id);
        if (msg.sender != h.placer) revert Unauthorized();
        uint128 held = h.held;
        if (amount > held) {
            uint128 delta = amount - held;
            if (h.standIn && h.captured + amount > h.approved) revert InvalidAmount();
            _repay(owner, h.token);
            if (_balance(h.token, owner) < delta) revert InsufficientAvailable();
            if (h.placer != owner) _useAllowance(owner, h.placer, h.token, delta, delta);
            _reserve(owner, h.token, delta);
            // The approval is the high-water mark of what was authorized, so an incremental increase raises the cap.
            if (!h.standIn && h.captured + amount > h.approved) h.approved = h.captured + amount;
        } else if (amount < held) {
            uint128 delta = held - amount;
            if (h.placer != owner) _outstanding[owner][h.placer][h.token] -= delta;
            _unreserveTo(owner, h.token, delta, owner);
        }
        h.held = amount;
        emit HoldAdjusted(owner, id, h.token, amount);
    }

    function capture(address owner, bytes32 id, uint128 amount, bool isFinal) external {
        HoldRecord storage h = _live(owner, id);
        address token = h.token;
        address payee = h.payee;
        if (msg.sender != h.placer && msg.sender != payee) revert Unauthorized();
        if (amount == 0 && !isFinal) revert InvalidAmount();
        uint256 cap = uint256(h.approved) + uint256(h.approved) * _tolerance[owner][payee][token] / BPS;
        if (uint256(h.captured) + amount > cap) revert ToleranceExceeded();

        uint128 fromHeld = amount < h.held ? amount : h.held;
        h.held -= fromHeld;
        if (h.placer != owner) _outstanding[owner][h.placer][token] -= fromHeld;
        _unreserveTo(owner, token, fromHeld, payee);

        uint128 debt;
        uint128 excess = amount - fromHeld;
        if (excess != 0) {
            _repay(owner, token);
            uint256 balance = _balance(token, owner);
            uint128 fromBalance = excess < balance ? excess : uint128(balance);
            _move(token, owner, payee, fromBalance);
            debt = excess - fromBalance;
            if (debt != 0) _addDebt(owner, payee, token, debt, h.standIn);
        }
        h.captured += amount;

        if (isFinal) {
            uint128 rest = h.held;
            h.held = 0;
            h.settled = true;
            if (h.placer != owner) _outstanding[owner][h.placer][token] -= rest;
            _unreserveTo(owner, token, rest, owner);
        }
        emit HoldCaptured(owner, id, token, payee, amount, debt, isFinal);
    }

    function release(address owner, bytes32 id) external {
        HoldRecord storage h = _open(owner, id);
        if (msg.sender != h.placer && msg.sender != h.payee) revert Unauthorized();
        _end(owner, id, h, block.timestamp >= h.expiresAt);
    }

    function releaseExpired(address owner, bytes32 id) external {
        HoldRecord storage h = _open(owner, id);
        if (block.timestamp < h.expiresAt) revert HoldNotExpired();
        _end(owner, id, h, true);
    }

    function refund(address owner, bytes32 id, uint128 amount) external {
        HoldRecord storage h = _holds[owner][id];
        if (h.placer == address(0)) revert HoldNotFound();
        if (msg.sender != h.payee) revert Unauthorized();
        if (amount == 0) revert InvalidAmount();
        if (uint256(h.refunded) + amount > h.captured) revert RefundExceedsCapture();
        h.refunded += amount;
        _move(h.token, msg.sender, owner, amount);
        emit Refunded(owner, id, h.token, msg.sender, amount);
        _repay(owner, h.token);
    }

    function charge(address owner, address token, bytes32 id, uint128 amount, address payee, bool standIn) external {
        if (amount == 0) revert InvalidAmount();
        if (token == address(0) || payee == address(0)) revert PolicyForbids();
        HoldRecord storage h = _holds[owner][id];
        if (h.placer != address(0)) revert HoldExists();
        // A charge counts against the holder's allowance for its own call only: nothing stays outstanding.
        if (msg.sender != owner) _useAllowance(owner, msg.sender, token, amount, 0);

        _repay(owner, token);
        uint256 balance = _balance(token, owner);
        uint128 fromBalance = amount < balance ? amount : uint128(balance);
        _move(token, owner, payee, fromBalance);
        uint128 debt = amount - fromBalance;
        if (debt != 0) _addDebt(owner, payee, token, debt, standIn);

        h.token = token;
        h.placer = msg.sender;
        h.payee = payee;
        h.approved = amount;
        h.captured = amount;
        h.standIn = standIn;
        h.settled = true;
        emit Charged(owner, id, token, payee, amount, debt);
    }

    // Liens.

    function lien(address owner, address token, bytes32 id, uint128 amount, uint64 expiresAt) external {
        if (!hasLienRole[msg.sender]) revert Unauthorized();
        _placeLien(owner, msg.sender, token, id, amount, expiresAt, false);
    }

    function pledge(address authority, address token, bytes32 id, uint128 amount, uint64 expiresAt) external {
        if (expiresAt == 0) revert InvalidExpiry();
        _placeLien(msg.sender, authority, token, id, amount, expiresAt, true);
    }

    function releaseLien(bytes32 id) external {
        Lien storage l = _liens[msg.sender][id];
        if (l.owner == address(0)) revert LienNotFound();
        _endLien(msg.sender, id, l, false);
    }

    function reduceLien(bytes32 id, uint128 amount) external {
        Lien storage l = _liens[msg.sender][id];
        if (l.owner == address(0)) revert LienNotFound();
        if (amount == 0 || amount > l.amount) revert InvalidAmount();
        (address owner, address token) = (l.owner, l.token);
        uint128 remaining = l.amount - amount;
        l.amount = remaining;
        _liened[owner][token] -= amount;
        _unreserveTo(owner, token, amount, owner);
        if (remaining == 0) delete _liens[msg.sender][id];
        emit LienReduced(owner, msg.sender, token, id, remaining);
    }

    function seizeLien(bytes32 id, uint128 amount) external {
        Lien storage l = _liens[msg.sender][id];
        if (l.owner == address(0)) revert LienNotFound();
        if (!l.pledged && !hasLienRole[msg.sender]) revert Unauthorized();
        // Past its expiry a lien can only be released, as a hold can.
        if (l.expiresAt != 0 && block.timestamp >= l.expiresAt) revert InvalidExpiry();
        if (amount == 0 || amount > l.amount) revert InvalidAmount();
        (address owner, address token) = (l.owner, l.token);
        uint128 remaining = l.amount - amount;
        l.amount = remaining;
        _liened[owner][token] -= amount;
        _unreserveTo(owner, token, amount, msg.sender);
        if (remaining == 0) delete _liens[msg.sender][id];
        emit LienSeized(owner, msg.sender, token, id, amount, remaining);
    }

    function releaseExpiredLien(address authority, bytes32 id) external {
        Lien storage l = _liens[authority][id];
        if (l.owner == address(0)) revert LienNotFound();
        if (l.expiresAt == 0 || block.timestamp < l.expiresAt) revert LienNotExpired();
        _endLien(authority, id, l, true);
    }

    // Views.

    function getHold(address owner, bytes32 id) external view returns (HoldRecord memory) {
        return _holds[owner][id];
    }

    function reserved(address owner, address token) external view returns (uint128) {
        return _reserved[owner][token];
    }

    function available(address owner, address token) external view returns (uint128) {
        uint256 balance = _balance(token, owner);
        uint256 debt = _debt[owner][token].amount;
        return balance > debt ? uint128(balance - debt) : 0;
    }

    function allowance(address owner, address holder, address token)
        external
        view
        returns (uint128 allowance_, uint128 outstanding)
    {
        return (_allowance[owner][holder][token], _outstanding[owner][holder][token]);
    }

    function debtOf(address owner, address token) external view returns (address creditor, uint128 amount) {
        Debt storage d = _debt[owner][token];
        return (d.creditor, d.amount);
    }

    function debtCap(address owner, address creditor, address token) external view returns (uint128) {
        return _debtCap[owner][creditor][token];
    }

    function captureTolerance(address owner, address payee, address token) external view returns (uint32) {
        return _tolerance[owner][payee][token];
    }

    function offlineCap(address owner, address payee, address token) external view returns (uint128) {
        return _offlineCap[owner][payee][token];
    }

    function lienOf(address authority, bytes32 id)
        external
        view
        returns (address owner, address token, uint128 amount, uint64 expiresAt, bool pledged)
    {
        Lien storage l = _liens[authority][id];
        return (l.owner, l.token, l.amount, l.expiresAt, l.pledged);
    }

    function liened(address owner, address token) external view returns (uint128) {
        return _liened[owner][token];
    }

    // Internals.

    function _place(address owner, address placer, HoldRequest calldata r) private {
        if (r.amount == 0) revert InvalidAmount();
        if (r.token == address(0) || r.payee == address(0)) revert PolicyForbids();
        if (r.expiresAt <= block.timestamp || r.expiresAt > block.timestamp + MAX_HOLD) revert InvalidExpiry();
        HoldRecord storage h = _holds[owner][r.id];
        if (h.placer != address(0)) revert HoldExists();

        _repay(owner, r.token);
        uint256 balance = _balance(r.token, owner);
        uint128 held = r.amount;
        if (r.standIn) {
            // A stand-in records what was approved offline and reserves only what is there.
            if (balance < held) held = uint128(balance);
        } else if (balance < held) {
            revert InsufficientAvailable();
        }
        if (placer != owner) _useAllowance(owner, placer, r.token, r.amount, held);
        _reserve(owner, r.token, held);

        h.token = r.token;
        h.placer = placer;
        h.payee = r.payee;
        h.held = held;
        h.approved = r.amount;
        h.expiresAt = r.expiresAt;
        h.standIn = r.standIn;
        emit HoldPlaced(owner, r.id, r.token, placer, r.payee, r.amount, held, r.expiresAt, r.standIn);
    }

    /// @dev Checks `amount` against the holder's allowance, then keeps `kept` of it outstanding.
    function _useAllowance(address owner, address holder, address token, uint128 amount, uint128 kept) private {
        uint128 allowed = _allowance[owner][holder][token];
        if (allowed == 0) revert Unauthorized();
        uint128 outstanding = _outstanding[owner][holder][token];
        if (uint256(outstanding) + amount > allowed) revert AllowanceExceeded();
        _outstanding[owner][holder][token] = outstanding + kept;
    }

    function _live(address owner, bytes32 id) private view returns (HoldRecord storage h) {
        h = _open(owner, id);
        if (block.timestamp >= h.expiresAt) revert HoldExpired();
    }

    function _open(address owner, bytes32 id) private view returns (HoldRecord storage h) {
        h = _holds[owner][id];
        if (h.placer == address(0)) revert HoldNotFound();
        if (h.settled) revert HoldSettled();
    }

    function _end(address owner, bytes32 id, HoldRecord storage h, bool expired) private {
        uint128 rest = h.held;
        h.held = 0;
        h.settled = true;
        if (h.placer != owner) _outstanding[owner][h.placer][h.token] -= rest;
        _unreserveTo(owner, h.token, rest, owner);
        emit HoldReleased(owner, id, h.token, rest, expired);
    }

    function _placeLien(
        address owner,
        address authority,
        address token,
        bytes32 id,
        uint128 amount,
        uint64 expiresAt,
        bool pledged
    ) private {
        if (amount == 0) revert InvalidAmount();
        if (authority == address(0) || token == address(0)) revert PolicyForbids();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert InvalidExpiry();
        Lien storage l = _liens[authority][id];
        if (l.owner != address(0)) revert LienExists();
        _repay(owner, token);
        if (_balance(token, owner) < amount) revert InsufficientAvailable();
        _reserve(owner, token, amount);
        _liened[owner][token] += amount;
        l.owner = owner;
        l.token = token;
        l.amount = amount;
        l.expiresAt = expiresAt;
        l.pledged = pledged;
        emit Liened(owner, authority, token, id, amount, expiresAt, pledged);
    }

    function _endLien(address authority, bytes32 id, Lien storage l, bool expired) private {
        (address owner, address token, uint128 amount) = (l.owner, l.token, l.amount);
        _liened[owner][token] -= amount;
        delete _liens[authority][id];
        _unreserveTo(owner, token, amount, owner);
        emit LienReleased(owner, authority, token, id, amount, expired);
    }

    function _addDebt(address owner, address creditor, address token, uint128 amount, bool standIn) private {
        Debt storage d = _debt[owner][token];
        // One creditor at a time per owner and token.
        if (d.amount != 0 && d.creditor != creditor) revert DebtCapExceeded();
        uint128 cap = _debtCap[owner][creditor][token];
        if (standIn) {
            uint128 offline = _offlineCap[owner][creditor][token];
            if (offline > cap) cap = offline;
        }
        if (uint256(d.amount) + amount > cap) revert DebtCapExceeded();
        d.creditor = creditor;
        d.amount += amount;
    }

    function _repay(address owner, address token) private {
        Debt storage d = _debt[owner][token];
        uint128 debt = d.amount;
        if (debt == 0) return;
        uint256 balance = _balance(token, owner);
        if (balance == 0) return;
        uint128 paid = debt < balance ? debt : uint128(balance);
        d.amount = debt - paid;
        address creditor = d.creditor;
        _move(token, owner, creditor, paid);
        emit DebtRepaid(owner, token, creditor, paid);
    }

    function _reserve(address owner, address token, uint128 amount) private {
        if (amount == 0) return;
        _move(token, owner, address(this), amount);
        _reserved[owner][token] += amount;
        totalReserved[token] += amount;
    }

    function _unreserveTo(address owner, address token, uint128 amount, address to) private {
        if (amount == 0) return;
        _reserved[owner][token] -= amount;
        totalReserved[token] -= amount;
        if (!IBalanceToken(token).transfer(to, amount)) revert InsufficientAvailable();
    }

    /// @dev Moves an account's own tokens as the node's balance internals would, without its approval.
    function _move(address token, address from, address to, uint128 amount) private {
        if (amount == 0) return;
        VM.prank(from);
        if (!IBalanceToken(token).transfer(to, amount)) revert InsufficientAvailable();
    }

    function _balance(address token, address account) private view returns (uint256) {
        return IBalanceToken(token).balanceOf(account);
    }
}
