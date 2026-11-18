// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { AccountKeys } from "./AccountKeys.sol";
import { CardLimits } from "./CardLimits.sol";
import { ICardAuth } from "./interfaces/ICardAuth.sol";
import { CardLegs } from "./CardLegs.sol";
import { ISource } from "./interfaces/ISource.sol";

/// @title CardAuth
/// @notice A card program's authorization contract: its cards, the owners' grants and limits, merchant mandates,
///         operator roles and caps, and every purchase. A purchase is funded by a waterfall over the funding sources
///         its owner listed, in the owner's order; each source holds, captures, releases and refunds its own part.
///         A purchase is one storage slot, never deleted, so a reference never repeats.
/// @dev Not upgradeable. Amounts are settlement-token units; limits and operator caps are kept in base units (the
///      program's first settlement token) so they survive a change of settlement token.
// Sources are contracts the issuer approved; each call into one runs inside a role-gated purchase step.
// forge-lint: disable-start(reentrancy-no-eth, calls-loop)
contract CardAuth is ICardAuth {
    using FixedPointMathLib for uint256;

    uint8 public constant ROLE_AUTHORIZE = 1;
    uint8 public constant ROLE_SETTLE = 2;
    uint8 public constant ROLE_TREASURY = 4;
    /// @notice Source kinds.
    uint8 public constant CASH = 1;
    uint8 public constant SAVINGS = 2;
    uint8 public constant CREDIT = 4;
    /// @notice authorize flags: approve what the sources hold when they hold less; a stand-in approved offline.
    uint8 public constant PARTIAL = 1;
    uint8 public constant STAND_IN = 2;
    uint64 public constant SETTINGS_DELAY = 2 days;
    /// @notice Most order entries an owner may list.
    uint256 public constant MAX_LEGS = 4;

    uint256 internal constant ONE = 1e18;
    uint256 internal constant MAX_AMOUNT = type(uint48).max;
    // Purchase word: card number [0,32), amount [32,80), captured [80,128), refunded [128,176), expiresAt [176,208),
    // local day [208,224), grant epoch [224,232), order version [232,240), settlement era [240,248), flags [248,256).
    // Flags: open, stand-in, charged, then one bit per order entry it drew on.
    uint256 internal constant OPEN = 1;
    uint256 internal constant STANDIN = 2;
    uint256 internal constant CHARGED = 4;

    struct Purchase {
        uint32 index;
        uint256 amount;
        uint256 captured;
        uint256 refunded;
        uint64 expiresAt;
        uint32 day;
        uint8 epoch;
        uint8 version;
        uint8 era;
        uint256 flags;
    }

    struct Operator {
        uint8 roles;
        uint120 cap;
        uint120 used;
    }




    address public immutable SETTLEMENT_ACCOUNT;

    address internal _issuer;
    address public pendingIssuer;
    address public accountKeys;
    address public identityRules;
    address public lifecycle;
    address public conversion;
    CardLegs.State internal _state;
    CardLegs.Ledger internal _ledger;
    mapping(uint8 era => CardLegs.Era) public eras;
    mapping(bytes32 id => uint64 eta) public pendingSetting;
    mapping(address key => Operator) internal _operators;
    /// @notice The kind of each source the issuer approved; zero for one it did not or stopped.
    mapping(address source => uint8 kind) public sourceKind;
    mapping(address account => bool) public isCompanion;
    mapping(bytes32 card => CardLimits.Card) internal _cards;
    mapping(uint32 index => bytes32 card) public cardAt;
    mapping(bytes32 card => bytes32 next) public replacedBy;
    mapping(address owner => CardLimits.Grant) public grants;
    mapping(address owner => CardLimits.Usage) public usageOf;
    mapping(address owner => mapping(address merchant => CardLimits.Mandate)) public mandates;
    mapping(address owner => uint8 version) public fundingVersion;
    mapping(address owner => mapping(uint8 version => CardLegs.Funding[])) internal _funding;
    mapping(bytes32 ref => uint256) internal _purchases;

    event PurchaseAuthorized(
        bytes32 indexed ref, bytes32 indexed card, address indexed owner, uint256 amount, uint256 legs, uint64 seq
    );
    event PurchaseAdjusted(bytes32 indexed ref, uint256 amount, uint256 legs, uint64 seq);
    /// @notice `amount` was captured or charged; the sources covered `covered` and the issuer absorbed the rest.
    event PurchaseCaptured(bytes32 indexed ref, uint256 amount, uint256 covered, bool isFinal, bool charged, uint64 seq);
    event PurchaseReleased(bytes32 indexed ref, uint256 released, uint64 seq);
    /// @notice `amount` was refunded in the purchase's token, `paid` in today's settlement token.
    event PurchaseRefunded(bytes32 indexed ref, uint256 amount, uint256 paid, uint64 seq);
    event CreditedBack(bytes32 indexed ref, uint256 usage, uint256 net);
    event ReserveSettled(bytes32 indexed ref, uint256 amount, uint64 seq);
    event Revoked(address indexed owner);
    event OperatorSet(address indexed key, uint8 roles, uint256 cap);
    event SourceSet(address indexed source, uint8 kind);
    event CompanionSet(address indexed account, bool active);
    event CompanionsSet(address accountKeys, address identityRules, address lifecycle, address conversion);
    event IssuerOffered(address indexed issuer, address indexed next);
    event IssuerTransferred(address indexed previous, address indexed next);
    event SettingProposed(bytes32 indexed id, bytes data, uint64 eta);
    event SettingCancelled(bytes32 indexed id);

    error CaptureLimitExceeded();
    error InsufficientAvailable();
    error InvalidAmount();
    error InvalidOrder();
    error NotCardOwner();
    error NotCompanion();
    error NotIssuer();
    error OperatorCapExceeded();
    error PurchaseExists();
    error PurchaseExpired();
    error PurchaseNotOpen();
    error SettingPending(uint64 eta);
    error Unauthorized();

    /// @param issuer The program's issuer.
    /// @param settlementAccount Where the sources pay what they take.
    /// @param settlementToken The token the program settles in first, which sets its base units.
    constructor(address issuer, address settlementAccount, address settlementToken) {
        if (issuer == address(0) || settlementAccount == address(0) || settlementToken == address(0)) {
            revert InvalidAmount();
        }
        _issuer = issuer;
        SETTLEMENT_ACCOUNT = settlementAccount;
        eras[0] = CardLegs.Era(settlementToken, uint96(ONE));
    }

    // Issuer.

    function issueCard(bytes32 card, address owner, uint40 expiry, CardLimits.Limits calldata limits, uint8 kinds)
        external
    {
        _onlyIssuer();
        CardLimits.issue(_cards[card], card, owner, expiry, limits, kinds, _newIndex(card), _scale());
    }

    /// @notice Replaces `oldCard` with `newCard`; open purchases follow the replacement.
    function replaceCard(bytes32 oldCard, bytes32 newCard, uint40 expiry) external {
        _onlyIssuer();
        CardLimits.replace(_cards[oldCard], _cards[newCard], oldCard, newCard, expiry, _newIndex(newCard));
        replacedBy[oldCard] = newCard;
    }

    /// @notice Sets a card's spending cap in units, expiry, or status (as CardLimits.set reads `what`).
    function setCard(bytes32 card, uint8 what, uint256 value) external {
        _onlyIssuer();
        CardLimits.set(_cards[card], card, what, value, _scale());
    }

    /// @notice Carries an owner's usage counted on another instance of the program: `data` is the ABI encoding of
    ///         (Usage usage, bytes32[] cards, Window[] windows, address[] merchants, Mandate[] spent), as CardLimits.carry
    ///         reads it.
    function carryUsage(address owner, bytes calldata data) external {
        _onlyIssuer();
        CardLimits.carry(_cards, mandates[owner], usageOf[owner], owner, data);
    }

    /// @notice Gives `key` the role bits `roles` and a cumulative cap of `cap` units; zero roles removes it.
    function setOperator(address key, uint8 roles, uint256 cap) external {
        _onlyIssuer();
        uint256 base;
        if (roles != 0) {
            base = _base(cap);
            if (roles > 7 || base == 0 || base > type(uint120).max) revert InvalidAmount();
        }
        _operators[key] = Operator(roles, uint120(base), 0);
        emit OperatorSet(key, roles, cap);
    }

    /// @notice Approves `source` as a funding source after the settings delay, or stops it at once. A stopped
    ///         source still settles the purchases it holds.
    function setSource(address source, bool approved) external {
        _onlyIssuer();
        if (!_settle(!approved)) return;
        uint8 kind = approved ? ISource(source).KIND() : 0;
        if (approved && kind != CASH && kind != SAVINGS && kind != CREDIT) revert InvalidOrder();
        sourceKind[source] = kind;
        emit SourceSet(source, kind);
    }

    /// @notice Registers a companion contract (treasury, desk, reserves) after the settings delay, or removes one at
    ///         once.
    function setCompanion(address account, bool active) external {
        _onlyIssuer();
        if (!_settle(!active)) return;
        isCompanion[account] = active;
        emit CompanionSet(account, active);
    }

    /// @notice Sets the account key registry, identity rules, account lifecycle and conversion the program follows.
    // Zero is meaningful for each: owners sign as themselves, no identity check, no lifecycle, no conversion.
    // forge-lint: disable-next-item(missing-zero-check)
    function setCompanions(address accountKeys_, address identityRules_, address lifecycle_, address conversion_)
        external
    {
        _onlyIssuer();
        if (!_settle(false)) return;
        (accountKeys, identityRules, lifecycle, conversion) = (accountKeys_, identityRules_, lifecycle_, conversion_);
        emit CompanionsSet(accountKeys_, identityRules_, lifecycle_, conversion_);
    }

    function cancelSetting(bytes32 id) external {
        _onlyIssuer();
        delete pendingSetting[id];
        emit SettingCancelled(id);
    }

    // Zero is how the issuer withdraws an offer.
    // forge-lint: disable-next-item(missing-zero-check)
    function transferIssuer(address next) external {
        _onlyIssuer();
        pendingIssuer = next;
        emit IssuerOffered(msg.sender, next);
    }

    function acceptIssuer() external {
        if (msg.sender != pendingIssuer) revert NotIssuer();
        emit IssuerTransferred(_issuer, msg.sender);
        _issuer = msg.sender;
        delete pendingIssuer;
    }

    /// @notice Acknowledges purchase steps through `throughSeq` as settled off chain.
    function acknowledgeSettlement(uint64 throughSeq) external {
        _onlyIssuer();
        CardLegs.acknowledge(_ledger, throughSeq);
    }

    // Companions.

    function useOperatorCap(address operator, uint256 value) external {
        if (!isCompanion[msg.sender]) revert NotCompanion();
        _useCap(operator, value);
    }

    function setSettlementToken(address token, uint256 scale) external {
        if (!isCompanion[msg.sender]) revert NotCompanion();
        CardLegs.switchToken(eras, _state, _ledger, token, scale);
    }

    // Cardholder.

    /// @notice Freezes (1), unfreezes (2) or closes (3) the caller's card.
    function setOwnStatus(bytes32 card, uint8 how) external {
        CardLimits.setOwnStatus(_ownedCard(card), card, how);
    }

    /// @notice Sets a card's limits: `how` 0 the issuer raises them within the ceiling the owner allows, 1 the owner
    ///         lowers them (and the ceiling with them), 2 the owner sets the ceiling.
    function setLimits(bytes32 card, CardLimits.Limits calldata limits, uint8 how) external {
        CardLimits.Card storage c = _cards[card];
        if (how == 0) _onlyIssuer();
        else _ownedCard(card);
        CardLimits.setLimits(c, card, limits, how, _scale());
    }

    function setMandate(address merchant, bool revoked, uint96 monthlyLimit) external {
        CardLimits.setMandate(mandates[msg.sender][merchant], merchant, revoked, monthlyLimit, _scale());
    }

    /// @notice Lists the approved sources the caller's purchases draw on, in order. Open purchases keep the order
    ///         they were placed under. Versions count modulo 256.
    function setFunding(CardLegs.Funding[] calldata order) external {
        uint8 version;
        unchecked {
            version = fundingVersion[msg.sender] + 1;
        }
        CardLegs.setOrder(_funding[msg.sender][version], sourceKind, order, version);
        fundingVersion[msg.sender] = version;
    }

    /// @notice Grants the program `given` terms across the caller's cards, starting their usage afresh.
    function grant(CardLimits.Terms calldata given) external {
        if (CardLimits.grant(grants[msg.sender], usageOf[msg.sender], given, eras[_state.era].scale)) {
            ++_state.grantedOwners;
        }
    }

    function revoke() external {
        grants[msg.sender].active = false;
        emit Revoked(msg.sender);
    }

    // Purchases.

    /// @notice Authorizes `amount` on `card` under the new reference `ref`, holding it across the owner's
    ///         sources in order. With PARTIAL it approves what the sources hold; with STAND_IN (approved offline)
    ///         the owner's first cash source holds all of it, the shortfall becoming debt when captured. Returns what
    ///         it approved.
    function authorize(bytes32 card, bytes32 ref, uint128 amount, address merchant, uint64 expiresAt, uint8 flags)
        external
        returns (uint256 approved)
    {
        _role(ROLE_AUTHORIZE, amount);
        if (_purchases[ref] != 0) revert PurchaseExists();
        if (amount == 0 || amount > MAX_AMOUNT || expiresAt > type(uint32).max) revert InvalidAmount();
        CardLimits.Card storage c = _cards[card];
        address owner = _admit(c);
        uint8 version = fundingVersion[owner];
        CardLegs.Funding[] storage order = _funding[owner][version];
        bool standIn = flags & STAND_IN != 0;
        uint256 legs;
        (approved, legs) = CardLegs.place(order, sourceKind, ref, owner, c.kinds, amount, expiresAt, standIn);
        if (approved == 0 || (approved < amount && flags & PARTIAL == 0)) revert InsufficientAvailable();
        (uint32 day, uint8 epoch) = _spend(c, owner, merchant, approved, approved, true);
        _purchases[ref] = _pack(
            Purchase(
                c.index,
                approved,
                0,
                0,
                expiresAt,
                day,
                epoch,
                version,
                _state.era,
                OPEN | (standIn ? STANDIN : 0) | legs << 3
            )
        );
        _moveHeld(int256(approved), standIn);
        emit PurchaseAuthorized(ref, card, owner, approved, legs, _step());
    }

    /// @notice Moves an open purchase's amount to `amount`: an increase holds more across the owner's sources in
    ///         order and counts against the limits; a decrease returns holds from the last source first. A stand-in
    ///         only decreases.
    function adjust(bytes32 ref, uint128 amount) external {
        Purchase memory p = _open(ref);
        bool standIn = p.flags & STANDIN != 0;
        if (amount == 0 || amount > MAX_AMOUNT || amount < p.captured || (standIn && amount > p.amount)) {
            revert InvalidAmount();
        }
        _role(ROLE_AUTHORIZE, amount > p.amount ? amount - p.amount : 0);
        (CardLimits.Card storage c, address owner) = _card(p);
        CardLegs.Funding[] storage order = _funding[owner][p.version];
        uint256 legs = p.flags >> 3;
        if (amount > p.amount) {
            if (c.status != CardLimits.Status.Active) revert CardLimits.CardNotActive();
            // A revoked grant stops increments as it stops new purchases.
            if (!grants[owner].active) revert CardLimits.NoTerms();
            uint256 want = amount - p.amount;
            _spend(c, owner, address(0), amount, want, true);
            legs = CardLegs.grow(order, sourceKind, ref, owner, c.kinds, want, legs, p.expiresAt);
        } else {
            CardLegs.shrink(order, ref, owner, legs, p.amount - amount, amount - p.captured, standIn, p.expiresAt);
            _giveBack(c, owner, p, p.amount - amount);
        }
        _moveHeld(int256(uint256(amount)) - int256(p.amount), standIn);
        p.amount = amount;
        p.flags = (p.flags & 7) | legs << 3;
        _purchases[ref] = _pack(p);
        emit PurchaseAdjusted(ref, amount, legs, _step());
    }

    /// @notice Captures `amount` of an open purchase from its sources' holds in order. What the holds lack comes from
    ///         the owner's first cash leg (else first leg): free funds, then debt within the owner's terms; the issuer
    ///         absorbs the rest. Past the owner's capture tolerance it reverts. `isFinal` releases what is left.
    function capture(bytes32 ref, uint128 amount, bool isFinal) external {
        _role(ROLE_AUTHORIZE, 0);
        Purchase memory p = _open(ref);
        if (amount == 0 && !isFinal) revert InvalidAmount();
        (CardLimits.Card storage c, address owner) = _card(p);
        CardLegs.Funding[] storage order = _funding[owner][p.version];
        uint256 legs = p.flags >> 3;
        uint256 open = p.amount - p.captured;
        bool standIn = p.flags & STANDIN != 0;
        uint256 covered = CardLegs.capture(
            order, sourceKind, ref, owner, legs, [uint256(amount), open, p.amount], isFinal, standIn
        );
        p.captured += amount;
        if (p.captured > MAX_AMOUNT) revert InvalidAmount();
        if (p.captured > p.amount) {
            // A tip within tolerance counts against the limits without being checked.
            _spend(c, owner, address(0), 0, p.captured - p.amount, false);
            p.amount = p.captured;
        }
        if (isFinal) {
            _giveBack(c, owner, p, p.amount - p.captured);
            (p.amount, p.flags) = (p.captured, p.flags & ~OPEN);
        }
        _moveHeld(int256(p.amount - p.captured) - int256(open), standIn);
        // What the issuer absorbed is captured toward the limits but never refunded: refunds stop at what was covered.
        p.refunded += amount - covered;
        _purchases[ref] = _pack(p);
        _ledger.net += int128(int256(covered));
        emit PurchaseCaptured(ref, amount, covered, isFinal, false, _step());
    }

    /// @notice Ends an open purchase, releasing every hold: the authorize role at any time, anyone once it expired.
    function release(bytes32 ref) external {
        Purchase memory p = _unpack(_purchases[ref]);
        if (p.flags & OPEN == 0) revert PurchaseNotOpen();
        // Expiries are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < p.expiresAt) _role(ROLE_AUTHORIZE, 0);
        (CardLimits.Card storage c, address owner) = _card(p);
        CardLegs.release(_funding[owner][p.version], ref, owner, p.flags >> 3);
        uint256 released = p.amount - p.captured;
        _giveBack(c, owner, p, released);
        _moveHeld(-int256(released), p.flags & STANDIN != 0);
        (p.amount, p.flags) = (p.captured, p.flags & ~OPEN);
        _purchases[ref] = _pack(p);
        emit PurchaseReleased(ref, released, _step());
    }

    /// @notice Charges `amount` with no hold: a force post under a new reference, or a late charge on a purchase
    ///         whose hold ended. The owner's cash sources cover what they can, debt included, and the issuer absorbs
    ///         the rest.
    function charge(bytes32 card, bytes32 ref, uint128 amount, address merchant) external {
        _role(ROLE_AUTHORIZE, amount);
        if (amount == 0 || amount > MAX_AMOUNT) revert InvalidAmount();
        uint256 word = _purchases[ref];
        Purchase memory p;
        CardLimits.Card storage c;
        address owner;
        if (word == 0) {
            c = _cards[card];
            owner = _admit(c);
            (uint32 day, uint8 epoch) = _spend(c, owner, merchant, amount, amount, true);
            p = Purchase(c.index, 0, 0, 0, 0, day, epoch, fundingVersion[owner], _state.era, CHARGED);
        } else {
            p = _unpack(word);
            if (p.flags & OPEN != 0) revert PurchaseExists();
            if (p.era != _state.era) revert CardLegs.Unsettled();
            (c, owner) = _card(p);
            _spend(c, owner, address(0), 0, amount, false);
            p.flags |= CHARGED;
        }
        CardLegs.Funding[] storage order = _funding[owner][p.version];
        uint256 legs = p.flags >> 3;
        uint256 covered;
        if (c.kinds & CASH != 0) (covered, legs) = CardLegs.charge(order, sourceKind, ref, owner, amount, legs);
        p.amount += amount;
        p.captured += amount;
        p.refunded += amount - covered;
        if (p.amount > MAX_AMOUNT) revert InvalidAmount();
        p.flags = (p.flags & 7) | legs << 3;
        _purchases[ref] = _pack(p);
        _ledger.net += int128(int256(covered));
        emit PurchaseCaptured(ref, amount, covered, true, true, _step());
    }

    /// @notice Refunds `amount` of a purchase, in the token it was booked in, to its sources: legs that bound what
    ///         they take back (credit) in reverse order first, then the first leg that takes any amount (cash,
    ///         savings) the rest. The caller pays in today's settlement token, approving this contract. Never past
    ///         what the sources covered. Settle role.
    function refund(bytes32 ref, uint128 amount) external {
        _role(ROLE_SETTLE, 0);
        Purchase memory p = _unpack(_purchases[ref]);
        if (amount == 0 || p.refunded + amount > p.captured) revert InvalidAmount();
        (CardLimits.Card storage c, address owner) = _card(p);
        uint256 pay = _today(amount, p.era);
        CardLegs.refund(_funding[owner][p.version], ref, owner, p.flags >> 3, pay, eras[_state.era].token);
        p.refunded += amount;
        _purchases[ref] = _pack(p);
        _giveBack(c, owner, p, amount);
        _ledger.net -= int128(int256(pay));
        emit PurchaseRefunded(ref, amount, pay, _step());
    }

    /// @notice Gives `usage` back to the cardholder's limits and books `net` refunded without moving money,
    ///         after the caller paid the cardholder itself. Settle role.
    function creditBack(bytes32 ref, uint128 usage, uint128 net) external {
        _role(ROLE_SETTLE, 0);
        Purchase memory p = _unpack(_purchases[ref]);
        if (p.index == 0 || p.refunded + net > p.captured) revert InvalidAmount();
        (CardLimits.Card storage c, address owner) = _card(p);
        p.refunded += net;
        _purchases[ref] = _pack(p);
        _giveBack(c, owner, p, usage);
        emit CreditedBack(ref, usage, net);
    }

    /// @notice Books `amount` of a purchase the issuer absorbed as covered after it settled it from a merchant
    ///         reserve, so it can be refunded. Settle role.
    function reserveSettled(bytes32 ref, uint128 amount) external {
        _role(ROLE_SETTLE, 0);
        Purchase memory p = _unpack(_purchases[ref]);
        if (p.index == 0 || p.era != _state.era || amount > p.refunded) revert InvalidAmount();
        p.refunded -= amount;
        _purchases[ref] = _pack(p);
        _ledger.net += int128(int256(uint256(amount)));
        emit ReserveSettled(ref, amount, _step());
    }

    // Views.

    function ISSUER() external view returns (address) {
        return _issuer;
    }

    function settlementToken() external view returns (address) {
        return eras[_state.era].token;
    }

    function grantedOwners() external view returns (uint64) {
        return _state.grantedOwners;
    }

    function hasRoles(address operator, uint8 roles) external view returns (bool) {
        return operator == _issuer || (roles != 0 && _operators[operator].roles & roles == roles);
    }

    /// @notice An operator's roles, cap and what it used of it, in base units.
    function operatorOf(address key) external view returns (Operator memory) {
        return _operators[key];
    }

    /// @notice A card's record, with the status its account's lifecycle gives it: closed once the account closed,
    ///         frozen while the account is an estate.
    function cardOf(bytes32 card) external view returns (CardLimits.Card memory) {
        _return(CardLimits.cardView(_cards[card], lifecycle));
    }

    /// @notice The owner's funding order at `version`, the one purchases placed at that version draw on.
    function fundingOf(address owner, uint8 version) external view returns (CardLegs.Funding[] memory) {
        _return(CardLegs.encode(_funding[owner][version]));
    }

    function purchaseOf(bytes32 ref) external view returns (PurchaseView memory) {
        uint256 word = _purchases[ref];
        Purchase memory p = _unpack(word);
        (CardLimits.Card storage c,) = _card(p);
        _return(CardLegs.purchaseView(word, c.owner, cardAt[p.index], eras[p.era].token));
    }

    function legsOf(bytes32 ref)
        external
        view
        returns (address[] memory sources, bytes32[] memory positions, bytes32[] memory legIds)
    {
        Purchase memory p = _unpack(_purchases[ref]);
        (, address owner) = _card(p);
        _return(CardLegs.legsOf(_funding[owner][p.version], ref, p.flags >> 3));
    }

    function exposure() external view returns (uint256 held, uint256 standIn, uint256 unsettled) {
        CardLegs.State memory s = _state;
        CardLegs.Ledger memory l = _ledger;
        return (s.held, s.standIn, l.net > l.settledNet ? uint256(int256(l.net - l.settledNet)) : 0);
    }

    function ledger() external view returns (uint64 seq, uint64 settledThrough, int128 net, int128 settledNet) {
        CardLegs.Ledger memory l = _ledger;
        return (l.seq, l.settledThrough, l.net, l.settledNet);
    }

    /// @notice The id order entry `i` of purchase `ref` holds under at its source.
    function legId(bytes32 ref, uint256 i) external pure returns (bytes32) {
        return CardLegs.legId(ref, i);
    }

    // Internals.

    function _onlyIssuer() private view {
        if (msg.sender != _issuer) revert NotIssuer();
    }

    /// @dev Requires `role` and counts `value` against an operator's cap.
    function _role(uint8 role, uint256 value) private {
        if (msg.sender == _issuer) return;
        if (_operators[msg.sender].roles & role == 0) revert Unauthorized();
        if (value != 0) _useCap(msg.sender, value);
    }

    function _useCap(address operator, uint256 value) private {
        if (operator == _issuer) return;
        Operator storage k = _operators[operator];
        uint256 used = k.used + _base(value);
        if (k.roles == 0 || used > k.cap) revert OperatorCapExceeded();
        k.used = uint120(used);
    }

    /// @dev Whether the issuer's setting applies now: at once when `immediate` or before any owner granted terms,
    ///      else on the same call SETTINGS_DELAY after the first, which records it and returns false.
    function _settle(bool immediate) private returns (bool) {
        if (immediate || _state.grantedOwners == 0) return true;
        bytes32 id = keccak256(msg.data);
        uint64 eta = pendingSetting[id];
        if (eta == 0) {
            eta = uint64(block.timestamp) + SETTINGS_DELAY;
            pendingSetting[id] = eta;
            emit SettingProposed(id, msg.data, eta);
            return false;
        }
        // Setting delays are days long; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < eta) revert SettingPending(eta);
        delete pendingSetting[id];
        return true;
    }

    function _newIndex(bytes32 card) private returns (uint32 index) {
        index = ++_state.cards;
        cardAt[index] = card;
    }

    /// @dev Checks a card can start a purchase and returns its owner.
    function _admit(CardLimits.Card storage c) private returns (address owner) {
        owner = c.owner;
        CardLimits.admit(c, grants[owner], lifecycle, identityRules);
    }

    /// @dev Counts `amount` toward the owner's and card's limits (checking them on `total` when `enforce`) and a
    ///      merchant's mandate. Returns the owner's local day and grant epoch.
    function _spend(CardLimits.Card storage c, address owner, address merchant, uint256 total, uint256 amount, bool enforce)
        private
        returns (uint32 day, uint8 epoch)
    {
        return CardLimits.use(
            c, grants[owner], usageOf[owner], mandates[owner][merchant], merchant, _base(total), _base(amount), enforce
        );
    }

    function _open(bytes32 ref) private view returns (Purchase memory p) {
        p = _unpack(_purchases[ref]);
        if (p.flags & OPEN == 0) revert PurchaseNotOpen();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= p.expiresAt) revert PurchaseExpired();
    }

    /// @dev The purchase's card after following its replacements, which the purchase moves to when stored.
    function _card(Purchase memory p) private view returns (CardLimits.Card storage c, address owner) {
        bytes32 card = cardAt[p.index];
        bytes32 next = replacedBy[card];
        while (next != bytes32(0)) {
            card = next;
            next = replacedBy[card];
        }
        c = _cards[card];
        p.index = c.index;
        owner = c.owner;
    }

    function _giveBack(CardLimits.Card storage c, address owner, Purchase memory p, uint256 amount) private {
        if (amount == 0) return;
        uint256 base = amount.mulDiv(ONE, eras[p.era].scale);
        CardLimits.Grant storage g = grants[owner];
        // Spend counted under an earlier grant gives back only to the card.
        uint32 epoch = uint8(g.epoch) == p.epoch ? g.epoch : 0;
        CardLimits.giveBackOn(g, usageOf[owner], c.window, epoch, p.day, base);
    }

    /// @dev The card's owner acts through its own key or the keys it listed in the account key registry.
    function _ownedCard(bytes32 card) private view returns (CardLimits.Card storage c) {
        c = _cards[card];
        address owner = c.owner;
        address keys = accountKeys;
        bool signs = keys == address(0) ? owner == msg.sender : AccountKeys(keys).signsFor(owner, msg.sender);
        if (!signs || c.status == CardLimits.Status.None) revert NotCardOwner();
    }

    /// @dev Returns `data`, already ABI-encoded, as this call's return data.
    function _return(bytes memory data) private pure {
        assembly ("memory-safe") {
            return(add(data, 32), mload(data))
        }
    }

    function _moveHeld(int256 delta, bool standIn) private {
        if (delta == 0) return;
        CardLegs.State storage s = _state;
        // Held totals are sums of 48-bit purchase amounts.
        s.held = uint64(uint256(int256(uint256(s.held)) + delta));
        if (standIn) s.standIn = uint64(uint256(int256(uint256(s.standIn)) + delta));
    }

    function _step() private returns (uint64 seq) {
        seq = ++_ledger.seq;
    }

    /// @dev `amount` of today's units in base units.
    function _base(uint256 amount) private view returns (uint256) {
        uint256 scale = eras[_state.era].scale;
        return scale == ONE ? amount : amount.mulDiv(ONE, scale);
    }

    /// @dev `amount` booked in era `era`'s token, in today's settlement token units.
    function _today(uint256 amount, uint8 era) private view returns (uint256) {
        uint8 current = _state.era;
        return era == current ? amount : amount.mulDiv(eras[current].scale, eras[era].scale);
    }

    function _scale() private view returns (uint256) {
        return eras[_state.era].scale;
    }

    function _pack(Purchase memory p) private pure returns (uint256 w) {
        w = uint256(p.index) | p.amount << 32 | p.captured << 80 | p.refunded << 128 | uint256(p.expiresAt) << 176
            | uint256(p.day & 0xffff) << 208 | uint256(p.epoch) << 224 | uint256(p.version) << 232
            | uint256(p.era) << 240 | p.flags << 248;
    }

    function _unpack(uint256 w) private pure returns (Purchase memory p) {
        p.index = uint32(w);
        p.amount = uint48(w >> 32);
        p.captured = uint48(w >> 80);
        p.refunded = uint48(w >> 128);
        p.expiresAt = uint32(w >> 176);
        p.day = uint16(w >> 208);
        p.epoch = uint8(w >> 224);
        p.version = uint8(w >> 232);
        p.era = uint8(w >> 240);
        p.flags = w >> 248;
    }

}
// forge-lint: disable-end(reentrancy-no-eth, calls-loop)
