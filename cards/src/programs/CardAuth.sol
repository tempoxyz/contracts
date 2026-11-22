// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuthAdmin } from "./CardAuthAdmin.sol";
import { CardAuthBase } from "./CardAuthBase.sol";
import { CardLegs } from "./CardLegs.sol";
import { CardLimits } from "./CardLimits.sol";
import { ICardAuth } from "./interfaces/ICardAuth.sol";
import { IExposureGuard } from "./interfaces/IExposureGuard.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

/// @title CardAuth
/// @notice A card program's authorization contract: its cards, the owners' grants and limits, merchant mandates,
///         operator roles and caps, and every purchase. A purchase is funded by a waterfall over the funding sources
///         its owner listed, in the owner's order; each source holds, captures, releases and refunds its own part.
///         A purchase is one storage slot, never deleted, so a reference never repeats.
/// @dev Not upgradeable. Amounts are settlement-token units; limits and operator caps are kept in base units (the
///      program's first settlement token) so they survive a change of settlement token.
// Sources are contracts the issuer approved; each call into one runs inside a role-gated purchase step.
// Amounts are checked against MAX_AMOUNT (48 bits) on entry, packed fields are read at their stored widths, and base
// units are checked to fit before they are cast.
// forge-lint: disable-start(reentrancy-no-eth, calls-loop, unsafe-typecast)
contract CardAuth is CardAuthBase, ICardAuth {
    using FixedPointMathLib for uint256;

    /// @notice The settings and cardholder code this contract runs by delegatecall: a CardAuthAdmin deployed on its
    ///         own and shared by every program on the chain, never replaced.
    address public immutable ADMIN;
    /// @notice Where captures and payments for the program land.
    address public immutable SETTLEMENT_ACCOUNT;

    /// @notice `admin` does not hold exactly CardAuthAdmin's code.
    error InvalidAdmin();

    /// @param issuer The program's issuer.
    /// @param settlementAccount Where the sources pay what they take.
    /// @param settlementToken The token the program settles in first, which sets its base units.
    /// @param admin A deployed CardAuthAdmin. Zones refuse contract creation from contracts, so the program never
    ///        deploys it itself.
    // The code hash check below refuses address(0), which holds no code.
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(address issuer, address settlementAccount, address settlementToken, address admin) {
        if (issuer == address(0) || settlementAccount == address(0) || settlementToken == address(0)) {
            revert InvalidAmount();
        }
        // The admin runs over this contract's storage, so it must be CardAuthAdmin's code and nothing else.
        if (admin.codehash != keccak256(type(CardAuthAdmin).runtimeCode)) revert InvalidAdmin();
        _issuer = issuer;
        ADMIN = admin;
        SETTLEMENT_ACCOUNT = settlementAccount;
        eras[0] = CardLegs.Era(settlementToken, uint96(ONE));
    }

    // Settings, card management and cardholder calls, run by ADMIN over this contract's storage.

    function issueCard(bytes32, address, uint40, CardLimits.Limits calldata, uint8) external {
        _delegate();
    }

    /// @notice Replaces `oldCard` with `newCard`; open purchases follow the replacement.
    function replaceCard(bytes32, bytes32, uint40) external {
        _delegate();
    }

    /// @notice Sets a card's spending cap in units, expiry, or status (as CardLimits.set reads `what`).
    function setCard(bytes32, uint8, uint256) external {
        _delegate();
    }

    /// @notice Carries an owner's usage counted on another instance of the program: `data` is the ABI encoding of
    ///         (Usage usage, bytes32[] cards, Window[] windows, address[] merchants, Mandate[] spent), as CardLimits.carry
    ///         reads it.
    function carryUsage(address, bytes calldata) external {
        _delegate();
    }

    /// @notice Gives `key` the role bits `roles` and a cumulative cap of `cap` units; zero roles removes it.
    function setOperator(address, uint8, uint256) external {
        _delegate();
    }

    /// @notice Approves `source` as a funding source after the settings delay, or stops it at once. A stopped
    ///         source still settles the purchases it holds.
    function setSource(address, bool) external {
        _delegate();
    }

    /// @notice The cash sources the issuer approved, a stopped one kept while it may hold converted tokens.
    function cashSources() external returns (address[] memory) {
        _delegate();
    }

    /// @notice Registers a companion contract (treasury, desk, reserves) after the settings delay, or removes one at
    ///         once.
    function setCompanion(address, bool) external {
        _delegate();
    }

    /// @notice Sets the account key registry, identity rules, account lifecycle and conversion the program follows.
    function setCompanions(address, address, address, address) external {
        _delegate();
    }

    /// @notice Sets the guard asked after every step that raises the program's exposure (zero for none): the issuer
    ///         after the settings delay while none is set, then only the guard itself.
    function setExposureGuard(address) external {
        _delegate();
    }

    function cancelSetting(bytes32) external {
        _delegate();
    }

    function transferIssuer(address) external {
        _delegate();
    }

    function acceptIssuer() external {
        _delegate();
    }

    /// @notice Acknowledges purchase steps through `throughSeq` as settled off chain.
    function acknowledgeSettlement(uint64) external {
        _delegate();
    }

    function checkpointSettlement() external returns (uint64) {
        _delegate();
    }

    function useOperatorCap(address, uint256) external {
        _delegate();
    }

    function setSettlementToken(address, uint256) external {
        _delegate();
    }

    /// @notice Freezes (1), unfreezes (2) or closes (3) the caller's card.
    function setOwnStatus(bytes32, uint8) external {
        _delegate();
    }

    /// @notice Sets a card's limits: `how` 0 the issuer raises them within the ceiling the owner allows, 1 the owner
    ///         lowers them (and the ceiling with them), 2 the owner sets the ceiling.
    function setLimits(bytes32, CardLimits.Limits calldata, uint8) external {
        _delegate();
    }

    function setMandate(address, bool, uint96) external {
        _delegate();
    }

    /// @notice Lists the approved sources the caller's purchases draw on, in order. Open purchases keep the order
    ///         they were placed under. Versions count modulo 256.
    function setFunding(CardLegs.Funding[] calldata) external {
        _delegate();
    }

    /// @notice Grants the program `given` terms across the caller's cards, starting their usage afresh.
    function grant(CardLimits.Terms calldata) external {
        _delegate();
    }

    function revoke() external {
        _delegate();
    }

    // Purchases.

    /// @notice Authorizes `amount` on `card` under the new reference `ref`, holding it across the owner's
    ///         sources in order. With PARTIAL it approves what the sources hold. Returns what it approved. A purchase
    ///         the network approved without asking (a stand-in) is no authorization: the issuer books it later with
    ///         charge, as a force post or a late charge.
    function authorize(bytes32 card, bytes32 ref, uint128 amount, address merchant, uint64 expiresAt, uint8 flags)
        external
        returns (uint256 approved)
    {
        _role(ROLE_AUTHORIZE, amount);
        if (_purchases[ref] != 0) revert PurchaseExists();
        if (amount == 0 || amount > MAX_AMOUNT || expiresAt > type(uint32).max) revert InvalidAmount();
        _checkSettlementAccount();
        CardLimits.Card storage c = _cards[card];
        address owner = _admit(c);
        uint8 version = fundingVersion[owner];
        CardLegs.Funding[] storage order = _funding[owner][version];
        uint256 legs;
        (approved, legs) = CardLegs.place(order, sourceKind, ref, owner, c.kinds, amount, expiresAt);
        if (approved == 0 || (approved < amount && flags & PARTIAL == 0)) revert InsufficientAvailable();
        (uint32 day, uint8 epoch) = _spend(c, owner, merchant, approved, approved, true);
        _track(ref, owner, merchant);
        _purchases[ref] = _pack(
            Purchase(c.index, approved, 0, 0, expiresAt, day, epoch, version, _state.era, OPEN | legs << LEGS_SHIFT)
        );
        _moveHeld(int256(approved));
        emit PurchaseAuthorized(ref, card, owner, approved, legs, _step());
        _checkExposure();
    }

    /// @notice Moves an open purchase's amount to `amount`: an increase holds more across the owner's sources in
    ///         order and counts against the limits; a decrease returns cash legs first, then the other legs from the
    ///         last. Once captures passed the authorized amount (a tip), it no longer moves:
    ///         only a final capture or a release ends the purchase.
    function adjust(bytes32 ref, uint128 amount) external {
        Purchase memory p = _open(ref);
        // The authorized amount bounds the captures with the owner's tolerance, so tolerance a tip used never becomes
        // part of a later bound.
        if (amount == 0 || amount > MAX_AMOUNT || amount < p.captured || p.captured > p.amount) revert InvalidAmount();
        _role(ROLE_AUTHORIZE, amount > p.amount ? amount - p.amount : 0);
        (CardLimits.Card storage c, address owner) = _card(p);
        CardLegs.Funding[] storage order = _funding[owner][p.version];
        uint256 legs = p.flags >> LEGS_SHIFT;
        bool up = amount > p.amount;
        if (up) {
            if (c.status != CardLimits.Status.Active) revert CardLimits.CardNotActive();
            // A revoked grant stops increments as it stops new purchases.
            if (!grants[owner].active) revert CardLimits.NoTerms();
            _checkSettlementAccount();
            uint256 want = amount - p.amount;
            _spend(c, owner, mandateMerchant[ref], amount, want, true);
            legs = CardLegs.grow(order, sourceKind, ref, owner, c.kinds, want, legs, p.expiresAt);
        } else {
            CardLegs.shrink(order, sourceKind, ref, owner, legs, amount - p.captured, p.expiresAt);
            _giveBack(c, owner, ref, p, p.amount - amount);
        }
        _moveHeld(int256(uint256(amount)) - int256(p.amount));
        p.amount = amount;
        p.flags = (p.flags & (OPEN | CHARGED)) | legs << LEGS_SHIFT;
        _purchases[ref] = _pack(p);
        emit PurchaseAdjusted(ref, amount, legs, _step());
        // A decrease is never refused, even while the program is past what its guard allows.
        if (up) _checkExposure();
    }

    /// @notice Captures `amount` of an open purchase walking the owner's funding order: each source covers what it
    ///         holds and can still cover from the owner's free funds; the issuer absorbs the rest. Its captures in all stay within the authorized amount
    ///         plus the owner's capture tolerance on it, and what passes the hold counts against the operator's cap and
    ///         is checked by the exposure guard. All of it is owed to the network, absorbed or not, so all of it counts
    ///         toward settlement. `isFinal` releases what is left.
    function capture(bytes32 ref, uint128 amount, bool isFinal) external {
        Purchase memory p = _open(ref);
        uint256 open = p.amount > p.captured ? p.amount - p.captured : 0;
        _role(ROLE_AUTHORIZE, amount > open ? amount - open : 0);
        if (amount == 0 && !isFinal) revert InvalidAmount();
        (CardLimits.Card storage c, address owner) = _card(p);
        CardLegs.Funding[] storage order = _funding[owner][p.version];
        uint256 legs = p.flags >> LEGS_SHIFT;
        uint256 covered;
        (covered, legs) = CardLegs.capture(
            order,
            sourceKind,
            ref,
            owner,
            legs,
            [uint256(amount), open, p.amount, c.kinds, p.expiresAt, p.captured + open - p.amount],
            isFinal
        );
        p.flags = (p.flags & (OPEN | CHARGED)) | legs << LEGS_SHIFT;
        p.captured += amount;
        if (p.captured > MAX_AMOUNT) revert InvalidAmount();
        // A tip within tolerance counts against the limits without being checked. The authorized amount stays as it
        // was, the bound for later captures.
        if (amount > open) _spend(c, owner, mandateMerchant[ref], 0, amount - open, false);
        uint256 left = p.amount > p.captured ? p.amount - p.captured : 0;
        if (isFinal) {
            _giveBack(c, owner, ref, p, left);
            (p.amount, p.flags, left) = (p.captured, p.flags & ~OPEN, 0);
        }
        _moveHeld(int256(left) - int256(open));
        // What the issuer absorbed is captured toward the limits but never refunded: refunds stop at what was covered.
        p.refunded += amount - covered;
        _purchases[ref] = _pack(p);
        // The network settles the whole capture; the issuer owes what the sources did not cover.
        _ledger.net += int128(int256(uint256(amount)));
        emit PurchaseCaptured(ref, amount, covered, isFinal, false, _step());
        // Within the hold, exposure only moves from held to unsettled; past it, it grows.
        if (amount > open) _checkExposure();
    }

    /// @notice Ends an open purchase, releasing every hold: the authorize role at any time, anyone once it expired.
    function release(bytes32 ref) external {
        Purchase memory p = _unpack(_purchases[ref]);
        if (p.flags & OPEN == 0) revert PurchaseNotOpen();
        // Expiries are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < p.expiresAt) _role(ROLE_AUTHORIZE, 0);
        (CardLimits.Card storage c, address owner) = _card(p);
        CardLegs.release(_funding[owner][p.version], ref, owner, p.flags >> LEGS_SHIFT);
        uint256 released = p.amount > p.captured ? p.amount - p.captured : 0;
        _giveBack(c, owner, ref, p, released);
        _moveHeld(-int256(released));
        (p.amount, p.flags) = (p.captured, p.flags & ~OPEN);
        _purchases[ref] = _pack(p);
        emit PurchaseReleased(ref, released, _step());
    }

    /// @notice Charges `amount` with no hold: a force post under a new reference, or a late charge on a purchase
    ///         whose hold ended, such as a purchase the network approved without asking. The owner's cash sources cover
    ///         what the owner has free, and the issuer absorbs the rest; all of it counts toward settlement. A late charge counts toward the limits without being
    ///         refused by them, but a merchant the owner revoked refuses it.
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
            _track(ref, owner, merchant);
            p = Purchase(c.index, 0, 0, 0, 0, day, epoch, fundingVersion[owner], _state.era, CHARGED);
        } else {
            p = _unpack(word);
            // An open purchase captures instead, and a reference charges at most once.
            if (p.flags & (OPEN | CHARGED) != 0) revert PurchaseExists();
            if (p.era != _state.era) revert CardLegs.Unsettled();
            (c, owner) = _card(p);
            if (mandates[owner][merchant].revoked) revert CardLimits.MerchantRevoked();
            _spend(c, owner, mandateMerchant[ref], amount, amount, false);
            p.flags |= CHARGED;
        }
        CardLegs.Funding[] storage order = _funding[owner][p.version];
        uint256 legs = p.flags >> LEGS_SHIFT;
        uint256 covered;
        if (c.kinds & CASH != 0) (covered, legs) = CardLegs.charge(order, sourceKind, ref, owner, amount, legs);
        p.amount += amount;
        p.captured += amount;
        p.refunded += amount - covered;
        if (p.amount > MAX_AMOUNT) revert InvalidAmount();
        p.flags = (p.flags & (OPEN | CHARGED)) | legs << LEGS_SHIFT;
        _purchases[ref] = _pack(p);
        _ledger.net += int128(int256(uint256(amount)));
        emit PurchaseCaptured(ref, amount, covered, true, true, _step());
        _checkExposure();
    }

    /// @notice Refunds `amount` of a purchase, in the token it was booked in, to its legs in reverse order, each at
    ///         most what it still nets, and the first cash leg the rest. The caller pays in today's settlement token,
    ///         approving this contract. Never past what the sources covered. Settle role.
    function refund(bytes32 ref, uint128 amount) external {
        _role(ROLE_SETTLE, 0);
        Purchase memory p = _unpack(_purchases[ref]);
        if (amount == 0 || p.refunded + amount > p.captured) revert InvalidAmount();
        (CardLimits.Card storage c, address owner) = _card(p);
        uint256 pay = _today(amount, p.era);
        CardLegs.refund(
            _funding[owner][p.version],
            ref,
            owner,
            p.flags >> LEGS_SHIFT,
            pay,
            _today(p.captured - p.refunded, p.era),
            eras[_state.era].token
        );
        p.refunded += amount;
        _purchases[ref] = _pack(p);
        _giveBack(c, owner, ref, p, amount);
        _ledger.net -= int128(int256(pay));
        emit PurchaseRefunded(ref, amount, pay, _step());
    }

    /// @notice Gives `amount` back to the cardholder's limits and books it refunded without moving money, after the
    ///         caller paid the cardholder itself. Settlement counts `settles` of it as a refund: at most `amount`, and
    ///         negative (the caller recovered more elsewhere than the network charges back) by at most what the
    ///         purchase has refunded, across all its credit backs. Registered companions only.
    function creditBack(bytes32 ref, uint128 amount, int128 settles) external {
        if (!isCompanion[msg.sender]) revert NotCompanion();
        Purchase memory p = _unpack(_purchases[ref]);
        p.refunded += amount;
        uint256 reversed = _reversed[ref];
        if (settles < 0) reversed += uint256(int256(-settles));
        if (p.index == 0 || p.refunded > p.captured || settles > int256(uint256(amount)) || reversed > p.refunded) {
            revert InvalidAmount();
        }
        if (settles < 0) _reversed[ref] = reversed;
        (CardLimits.Card storage c, address owner) = _card(p);
        _purchases[ref] = _pack(p);
        _giveBack(c, owner, ref, p, amount);
        emit CreditedBack(ref, amount, CardLegs.creditBack(eras, _state, _ledger, p.era, settles), _step());
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
        Operator storage k = _operators[operator];
        return operator == _issuer || (roles != 0 && k.roles & roles == roles && _current(k));
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
        _return(CardLegs.legsOf(_funding[owner][p.version], ref, p.flags >> LEGS_SHIFT));
    }

    function exposure() external view returns (uint256 held, uint256 unsettled) {
        CardLegs.Ledger memory l = _ledger;
        return (_state.held, l.net > l.settledNet ? uint256(int256(l.net - l.settledNet)) : 0);
    }

    function ledger() external view returns (uint64 seq, uint64 settledThrough, int128 net, int128 settledNet) {
        CardLegs.Ledger memory l = _ledger;
        return (l.seq, l.settledThrough, l.net, l.settledNet);
    }

    function settlementCheckpoint(uint256 back) external view returns (uint64 seq, int128 net) {
        uint256 n = _ledger.checkpoints;
        if (back >= n || back >= CardLegs.CHECKPOINTS) return (0, 0);
        CardLegs.Checkpoint memory c = _checkpoints[(n - 1 - back) % CardLegs.CHECKPOINTS];
        return (c.seq, c.net);
    }

    /// @notice The id order entry `i` of purchase `ref` holds under at its source.
    function legId(bytes32 ref, uint256 i) external pure returns (bytes32) {
        return CardLegs.legId(ref, i);
    }

    // Internals.

    /// @dev Refuses a new hold while the settlement token's TIP-403 policy keeps the settlement account from receiving
    ///      it: the purchase could never capture.
    /// @dev keccak256 of the Zone registry's refusal, OnlyPrecompiles().
    bytes32 private constant ONLY_PRECOMPILES = keccak256(abi.encodeWithSignature("OnlyPrecompiles()"));

    function _checkSettlementAccount() private view {
        address token = eras[_state.era].token;
        uint64 policy = ITIP20(token).transferPolicyId();
        // Policy 1 authorizes every account.
        if (policy == 1) return;
        (bool ok, bytes memory out) = address(StdPrecompiles.TIP403_REGISTRY)
            .staticcall(abi.encodeCall(ITIP403Registry.isAuthorizedRecipient, (policy, SETTLEMENT_ACCOUNT)));
        if (ok) {
            if (!abi.decode(out, (bool))) revert SettlementAccountBlocked();
            return;
        }
        // Zones refuse registry calls from contracts (OnlyPrecompiles()); their token transfers still apply the
        // policy when the purchase captures.
        if (keccak256(out) != ONLY_PRECOMPILES) {
            assembly ("memory-safe") {
                revert(add(out, 32), mload(out))
            }
        }
    }

    function _checkExposure() private view {
        address guard = exposureGuard;
        if (guard != address(0)) IExposureGuard(guard).checkExposure();
    }

    /// @dev Requires `role` and counts `value` against an operator's cap.
    function _role(uint8 role, uint256 value) private {
        if (msg.sender == _issuer) return;
        Operator storage k = _operators[msg.sender];
        if (k.roles & role == 0 || !_current(k)) revert Unauthorized();
        if (value != 0) _useCap(msg.sender, value);
    }

    /// @dev Checks a card can start a purchase and returns its owner.
    function _admit(CardLimits.Card storage c) private returns (address owner) {
        owner = c.owner;
        CardLimits.admit(c, grants[owner], lifecycle, identityRules);
    }

    /// @dev Counts `amount` toward the owner's and card's limits (checking them on `total` when `enforce`) and a
    ///      merchant's mandate. Returns the owner's local day and grant epoch.
    function _spend(
        CardLimits.Card storage c,
        address owner,
        address merchant,
        uint256 total,
        uint256 amount,
        bool enforce
    ) private returns (uint32 day, uint8 epoch) {
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

    function _giveBack(CardLimits.Card storage c, address owner, bytes32 ref, Purchase memory p, uint256 amount)
        private
    {
        if (amount == 0) return;
        uint256 base = amount.mulDiv(ONE, eras[p.era].scale);
        CardLimits.Grant storage g = grants[owner];
        // Spend counted under an earlier grant gives back only to the card.
        uint32 epoch = uint8(g.epoch) == p.epoch ? g.epoch : 0;
        CardLimits.giveBackOn(g, usageOf[owner], c.window, mandates[owner][mandateMerchant[ref]], epoch, p.day, base);
    }

    /// @dev Every new purchase names its merchant. Only purchases its mandate counted keep it, so the rest add no
    ///      storage; their later increments, tips, late charges and give-backs then count toward that mandate too.
    function _track(bytes32 ref, address owner, address merchant) private {
        if (merchant == address(0)) revert NoMerchant();
        if (mandates[owner][merchant].month != 0) mandateMerchant[ref] = merchant;
    }

    /// @dev Returns `data`, already ABI-encoded, as this call's return data.
    function _return(bytes memory data) private pure {
        assembly ("memory-safe") {
            return(add(data, 32), mload(data))
        }
    }

    function _moveHeld(int256 delta) private {
        if (delta == 0) return;
        CardLegs.State storage s = _state;
        // Held totals are sums of 48-bit purchase amounts, accounting rather than access control.
        // forge-lint: disable-next-line(missing-events-access-control)
        s.held = uint64(uint256(int256(uint256(s.held)) + delta));
    }

    function _step() private returns (uint64 seq) {
        seq = ++_ledger.seq;
    }

    /// @dev `amount` booked in era `era`'s token, in today's settlement token units.
    // A refund of an earlier era's purchase rounds up, in the cardholder's favour.
    function _today(uint256 amount, uint8 era) private view returns (uint256) {
        uint8 current = _state.era;
        return era == current ? amount : amount.mulDivUp(eras[current].scale, eras[era].scale);
    }

    function _pack(Purchase memory p) private pure returns (uint256 w) {
        w = uint256(p.index) | p.amount << 32 | p.captured << 80 | p.refunded << 128 | uint256(p.expiresAt) << 176
            | uint256(p.day & 0xffff) << 208 | uint256(p.epoch) << 224 | uint256(p.version) << 232 | uint256(p.era)
            << 240 | p.flags << 248;
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

    /// @dev Runs this call's CardAuthAdmin code over this contract's storage and returns or reverts with its result.
    function _delegate() private {
        address admin = ADMIN;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), admin, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
// forge-lint: disable-end(reentrancy-no-eth, calls-loop, unsafe-typecast)
