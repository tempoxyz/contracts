// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { AccountKeys } from "./AccountKeys.sol";
import { CardLegs } from "./CardLegs.sol";
import { CardLimits } from "./CardLimits.sol";
import { ICardAuthState } from "./interfaces/ICardAuth.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @title CardAuthBase
/// @notice The storage, constants, events and errors CardAuth and CardAuthAdmin share, and the helpers both use.
///         CardAuth runs CardAuthAdmin's code by delegatecall over its own storage, so both must lay it out alike:
///         declare state only here. No immutables here either: one CardAuthAdmin serves every program, so its code
///         holds nothing of any one program's.
// forge-lint: disable-start(unsafe-typecast)
abstract contract CardAuthBase is ICardAuthState {
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
    /// @notice How long after its delay a proposed setting may still apply; past it the proposal lapses.
    uint64 public constant SETTINGS_WINDOW = 7 days;
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
    /// @notice Asked after every step that raises the program's exposure; zero for none.
    address public exposureGuard;
    /// @notice The merchant of a purchase authorized under one of its owner's mandate limits, whose later increments,
    ///         tips and late charges count toward that mandate too.
    mapping(bytes32 ref => address merchant) public mandateMerchant;

    event PurchaseAuthorized(
        bytes32 indexed ref, bytes32 indexed card, address indexed owner, uint256 amount, uint256 legs, uint64 seq
    );
    event PurchaseAdjusted(bytes32 indexed ref, uint256 amount, uint256 legs, uint64 seq);
    /// @notice `amount` was captured or charged; the sources covered `covered` and the issuer absorbed the rest.
    event PurchaseCaptured(
        bytes32 indexed ref, uint256 amount, uint256 covered, bool isFinal, bool charged, uint64 seq
    );
    event PurchaseReleased(bytes32 indexed ref, uint256 released, uint64 seq);
    /// @notice `amount` was refunded in the purchase's token, `paid` in today's settlement token.
    event PurchaseRefunded(bytes32 indexed ref, uint256 amount, uint256 paid, uint64 seq);
    /// @notice `net` was booked refunded without moving money; settlement counts `paid`, in today's settlement token.
    event CreditedBack(bytes32 indexed ref, uint256 net, int256 paid, uint64 seq);
    event Revoked(address indexed owner);
    event OperatorSet(address indexed key, uint8 roles, uint256 cap);
    event SourceSet(address indexed source, uint8 kind);
    event CompanionSet(address indexed account, bool active);
    event CompanionsSet(address accountKeys, address identityRules, address lifecycle, address conversion);
    event ExposureGuardSet(address guard);
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
    error NoMerchant();
    error NotIssuer();
    error OperatorCapExceeded();
    error PurchaseExists();
    error PurchaseExpired();
    error PurchaseNotOpen();
    error SettingPending(uint64 eta);
    error Unauthorized();

    function _onlyIssuer() internal view {
        if (msg.sender != _issuer) revert NotIssuer();
    }

    /// @dev Whether the issuer's setting applies now: at once when `immediate` or before any owner granted terms,
    ///      else on the same call between SETTINGS_DELAY and SETTINGS_WINDOW after it, after the first records it and
    ///      returns false. A call after the window records it afresh.
    function _settle(bool immediate) internal returns (bool) {
        if (immediate || _state.grantedOwners == 0) return true;
        bytes32 id = keccak256(msg.data);
        uint64 eta = pendingSetting[id];
        // forge-lint: disable-next-line(block-timestamp)
        if (eta == 0 || block.timestamp > eta + SETTINGS_WINDOW) {
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

    function _newIndex(bytes32 card) internal returns (uint32 index) {
        index = ++_state.cards;
        cardAt[index] = card;
    }

    /// @dev The card's owner acts through its own key or the keys it listed in the account key registry.
    function _ownedCard(bytes32 card) internal view returns (CardLimits.Card storage c) {
        c = _cards[card];
        address owner = c.owner;
        address keys = accountKeys;
        bool signs = keys == address(0) ? owner == msg.sender : AccountKeys(keys).signsFor(owner, msg.sender);
        if (!signs || c.status == CardLimits.Status.None) revert NotCardOwner();
    }

    /// @dev `amount` of today's units in base units.
    function _base(uint256 amount) internal view returns (uint256) {
        uint256 scale = eras[_state.era].scale;
        return scale == ONE ? amount : amount.mulDiv(ONE, scale);
    }

    function _scale() internal view returns (uint256) {
        return eras[_state.era].scale;
    }

    function _useCap(address operator, uint256 value) internal {
        if (operator == _issuer) return;
        Operator storage k = _operators[operator];
        uint256 used = k.used + _base(value);
        if (k.roles == 0 || used > k.cap) revert OperatorCapExceeded();
        k.used = uint120(used);
    }
}
// forge-lint: disable-end(unsafe-typecast)
