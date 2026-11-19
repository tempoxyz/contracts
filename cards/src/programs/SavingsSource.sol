// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Conversion } from "./Conversion.sol";
import { ICardAuth } from "./interfaces/ICardAuth.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";
import { CAPTURE_BEYOND, CAPTURE_FINAL, CAPTURE_FREE, ISource } from "./interfaces/ISource.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

/// @title SavingsSource
/// @notice A card program's savings funding source: holds on a cardholder's Tempo Earn shares in the core, placed and
///         captured by this contract, which is also their payee. A capture redeems the shares and pays their value to
///         the settlement account in the same call, converting through the program's Conversion when the vault's asset
///         is not the settlement token. A refund deposits the issuer's cash back into the vault and refunds the shares
///         it mints. Savings never create debt or take charges.
/// @dev Deployed with a fixed vault and funder. When the vault quotes but cannot redeem at once, the float pays the
///      settlement account and the shares wait here for the funder's `redeemHeld`. From that first deferred capture
///      until a redemption works again, new legs hold only what the float can still pay for past what earlier such
///      legs may capture, so the order's later entries hold the rest. `position` is unused. Not upgradeable.
/// @custom:reentrancy-guard _locked
// Calls go to the fixed core, the fixed vault and the program's own Conversion, inside program-driven steps.
// forge-lint: disable-start(reentrancy-no-eth, calls-loop)
contract SavingsSource is ISource {
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);

    /// @notice What the source is: savings.
    uint8 public constant KIND = 2;
    uint256 internal constant BPS = 10_000;
    /// @notice The card authorization contract this source serves.
    ICardAuth public immutable PROGRAM;
    /// @notice Where every capture is paid.
    address public immutable SETTLEMENT_ACCOUNT;
    IEarnVault public immutable VAULT;
    /// @notice The vault's Earn share, the token of this source's holds.
    address public immutable SHARE;
    /// @notice The vault's base asset.
    address public immutable ASSET;
    /// @notice Supplies the float and may withdraw it and redeem shares that deferred redemptions left.
    address public immutable FUNDER;

    /// @notice What a leg captured and was refunded, in settlement units. `placed` is written with the leg's first
    ///         hold, so its captures and refunds write an existing slot. `promisedIn` is the deferral epoch whose
    ///         float the leg may capture against, zero when none.
    struct Leg {
        bool placed;
        uint120 captured;
        uint120 refunded;
        uint8 promisedIn;
    }

    /// @notice Whether captures are deferring onto the float, the epoch of the current or last deferral (never zero
    ///         once one began), and the shares legs placed in it may still capture (their capture limits).
    struct Deferral {
        bool active;
        uint8 epoch;
        uint128 promised;
    }

    /// @notice Shares left here by deferred redemptions and refund surpluses, the only shares the funder may take.
    uint256 public heldShares;
    /// @notice Each leg's captures and refunds, by leg id.
    mapping(bytes32 => Leg) public legs;
    /// @notice The current or last deferral.
    Deferral public deferral;

    bool private transient _locked;

    event Captured(address indexed owner, bytes32 indexed legId, uint256 shares, uint256 paid, bool deferred);
    event Refunded(address indexed owner, bytes32 indexed legId, uint256 assets, uint256 shares);
    event Redeemed(uint256 shares, uint256 assets);
    event DeferralStarted(uint8 epoch);
    event DeferralEnded(uint8 epoch);

    error ExceedsHeldShares(uint256 shares, uint256 held);
    error InsufficientFloat(uint256 assets, uint256 float_);
    error NoQuote();
    error NotFunder();
    error NotProgram();
    error Reentrancy();
    error ZeroAddress();

    modifier onlyProgram() {
        if (msg.sender != address(PROGRAM)) revert NotProgram();
        _lock();
        _;
        _locked = false;
    }

    modifier nonReentrant() {
        _lock();
        _;
        _locked = false;
    }

    constructor(ICardAuth program, IEarnVault vault, address funder) {
        if (address(program) == address(0) || address(vault) == address(0) || funder == address(0)) {
            revert ZeroAddress();
        }
        PROGRAM = program;
        SETTLEMENT_ACCOUNT = program.SETTLEMENT_ACCOUNT();
        VAULT = vault;
        SHARE = vault.earnShare();
        ASSET = vault.asset();
        FUNDER = funder;
        // Standing approvals, so captures and refunds write no allowance slots.
        SafeTransferLib.safeApproveWithRetry(SHARE, address(vault), type(uint256).max);
        SafeTransferLib.safeApproveWithRetry(ASSET, address(vault), type(uint256).max);
    }

    // Views.

    function coverable(address owner, bytes32) external view returns (uint256) {
        return _value(CORE.available(owner, SHARE));
    }

    function held(address owner, bytes32, bytes32 legId) external view returns (uint256) {
        return _value(CORE.getHold(owner, address(this), legId).held);
    }

    function owed(address, bytes32) external pure returns (uint256) {
        return 0;
    }

    function refundable(address, bytes32, bytes32 legId) external view returns (uint256) {
        Leg memory l = legs[legId];
        return l.captured - l.refunded;
    }

    function toleranceBps(address owner, bytes32) external view returns (uint16) {
        return CORE.payeeTerms(owner, address(this), SHARE).toleranceBps;
    }

    // Program.

    function hold(address owner, bytes32, bytes32 legId, uint256 units, uint64 expiresAt, bool)
        external
        onlyProgram
        returns (uint256)
    {
        IReservationCore.HoldRecord memory h = CORE.getHold(owner, address(this), legId);
        bool live = h.token != address(0);
        uint256 most = (live ? h.held : 0) + CORE.available(owner, SHARE);
        Deferral memory d = deferral;
        bool promised;
        if (d.active) {
            // While captures defer, only a new leg or one already promised in this deferral grows, by what the float
            // can still pay for.
            promised = !live || legs[legId].promisedIn == d.epoch;
            uint256 cap = (live ? h.held : 0) + (promised ? _floatRoom(owner, d.promised) : 0);
            if (cap < most) most = cap;
        }
        // No shares to hold: skip pricing them.
        uint256 shares = units == 0 || most == 0 ? 0 : _sharesFor(units);
        if (shares > most) {
            shares = most;
            units = _value(shares);
        }
        if (shares == 0 || units == 0) {
            if (live) {
                CORE.release(owner, address(this), legId);
                if (promised) _repromise(d, h.captureLimit, 0);
            }
            return 0;
        }
        if (!live) {
            Leg storage g = legs[legId];
            if (!g.placed) g.placed = true;
            if (promised) g.promisedIn = d.epoch;
            CORE.holdFrom(
                owner, IReservationCore.HoldRequest(SHARE, legId, shares.toUint128(), expiresAt, address(this), false)
            );
        } else if (shares != h.held) {
            CORE.adjust(owner, address(this), legId, shares.toUint128());
        }
        if (promised) {
            _repromise(d, live ? h.captureLimit : 0, CORE.getHold(owner, address(this), legId).captureLimit);
        }
        return units;
    }

    function capture(address owner, bytes32, bytes32 legId, uint256 units, uint8 flags)
        external
        onlyProgram
        returns (uint256 paid, uint256)
    {
        IReservationCore.HoldRecord memory h = CORE.getHold(owner, address(this), legId);
        if (h.token == address(0)) return (0, 0);
        bool isFinal = flags & CAPTURE_FINAL != 0;
        uint256 shares = units == 0 ? 0 : _sharesFor(units);
        uint256 most = h.held;
        bool free = flags & CAPTURE_FREE != 0;
        if (shares > most && (free || flags & CAPTURE_BEYOND != 0)) {
            most += _budgetRoom(owner, CORE.available(owner, SHARE));
            // CAPTURE_BEYOND stays within the hold's tolerance; CAPTURE_FREE grows the hold to what it takes.
            if (!free && most > h.captureLimit) most = h.captureLimit;
        }
        Leg storage g = legs[legId];
        Deferral memory d = deferral;
        bool promised = d.active && g.promisedIn == d.epoch;
        // While captures defer, one takes at most what the float pays past the other legs' promises; the order's
        // later entries cover the rest.
        uint256 others = promised ? uint256(d.promised).zeroFloorSub(h.captureLimit) : d.promised;
        if (d.active) {
            uint256 room = _floatShares(others);
            if (most > room) most = room;
        }
        if (shares > most) shares = most;
        if (shares == 0 && !isFinal) return (0, 0);
        if (shares > h.captureLimit) CORE.adjust(owner, address(this), legId, shares.toUint128());
        CORE.capture(owner, address(this), legId, shares.toUint128(), isFinal);
        // The leg's promise becomes what it may still capture: nothing after a final capture.
        if (promised) {
            _repromise(d, h.captureLimit, isFinal ? 0 : CORE.getHold(owner, address(this), legId).captureLimit);
        }
        if (shares == 0) return (0, 0);
        paid = _redeem(owner, legId, shares, units, d, others);
        g.captured += paid.toUint120();
        return (paid, paid);
    }

    function charge(address, bytes32, bytes32, uint256, bool) external view onlyProgramView returns (uint256) {
        return 0;
    }

    function release(address owner, bytes32, bytes32 legId) external onlyProgram {
        IReservationCore.HoldRecord memory h = CORE.getHold(owner, address(this), legId);
        if (h.token == address(0)) return;
        CORE.release(owner, address(this), legId);
        Deferral memory d = deferral;
        if (d.active && legs[legId].promisedIn == d.epoch) _repromise(d, h.captureLimit, 0);
    }

    function refund(address owner, bytes32, bytes32 legId, uint256 units) external onlyProgram {
        legs[legId].refunded += units.toUint120();
        address settlement = PROGRAM.settlementToken();
        uint256 assets = units;
        if (settlement != ASSET) {
            Conversion c = Conversion(PROGRAM.conversion());
            SafeTransferLib.safeApprove(settlement, address(c), units);
            assets = c.trusted(address(this))
                ? c.convertAtMid(settlement, ASSET, units, address(this))
                : c.swapExactIn(settlement, ASSET, units, 0, address(this));
        }
        uint256 shares = VAULT.deposit(assets, address(this), 1);
        CORE.refund(owner, SHARE, address(this), legId, shares.toUint128());
        emit Refunded(owner, legId, assets, shares);
    }

    // Funder.

    /// @notice Redeems shares left here into the float.
    function redeemHeld(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        if (msg.sender != FUNDER) revert NotFunder();
        _takeHeld(shares);
        assets = VAULT.redeem(shares, address(this), minAssets);
        emit Redeemed(shares, assets);
        _endDeferral(deferral);
    }

    /// @notice Withdraws float or held shares to `to`.
    function withdraw(address token, address to, uint256 amount) external nonReentrant {
        if (msg.sender != FUNDER) revert NotFunder();
        if (token == SHARE) _takeHeld(amount);
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    // Internals.

    modifier onlyProgramView() {
        if (msg.sender != address(PROGRAM)) revert NotProgram();
        _;
    }

    /// @dev Redeems `shares` and pays the settlement account up to `units` settlement units' worth. Returns the
    ///      settlement units paid. A deferred capture uses only the float that the `others` shares other legs were
    ///      promised in deferral `d` leave, and starts a deferral; a redemption that works ends it.
    function _redeem(address owner, bytes32 legId, uint256 shares, uint256 units, Deferral memory d, uint256 others)
        private
        returns (uint256 paid)
    {
        address settlement = PROGRAM.settlementToken();
        uint256 quote = VAULT.previewRedeem(shares);
        if (quote == 0) revert NoQuote();
        address to = settlement == ASSET ? SETTLEMENT_ACCOUNT : address(this);
        bool deferred;
        uint256 assets;
        try VAULT.redeem(shares, to, quote) returns (uint256 redeemed) {
            assets = redeemed;
            _endDeferral(d);
        } catch {
            // The vault quotes but cannot redeem now: the float pays and the shares wait for the funder.
            uint256 float_ = IERC20Like(ASSET).balanceOf(address(this));
            if (!d.active) {
                d.epoch = d.epoch == type(uint8).max ? 1 : d.epoch + 1;
                deferral = Deferral(true, d.epoch, 0);
                emit DeferralStarted(d.epoch);
            } else if (others != 0) {
                float_ = float_.zeroFloorSub(VAULT.previewRedeem(others));
            }
            if (float_ < quote) revert InsufficientFloat(quote, float_);
            heldShares += shares;
            (assets, deferred) = (quote, true);
            if (to != address(this)) SafeTransferLib.safeTransfer(ASSET, to, quote);
        }
        paid = assets;
        if (settlement != ASSET) {
            Conversion c = Conversion(PROGRAM.conversion());
            SafeTransferLib.safeApprove(ASSET, address(c), assets);
            if (c.quoteOut(ASSET, settlement, units) <= assets) {
                uint256 spent = c.swapExactOut(ASSET, settlement, units, assets, SETTLEMENT_ACCOUNT);
                if (assets > spent) SafeTransferLib.safeTransfer(ASSET, SETTLEMENT_ACCOUNT, assets - spent);
                paid = units;
            } else {
                paid = c.swapExactIn(ASSET, settlement, assets, 0, SETTLEMENT_ACCOUNT);
            }
        }
        // Rounding shares up may redeem a little more than the capture; it goes with the capture.
        if (paid > units) paid = units;
        emit Captured(owner, legId, shares, paid, deferred);
    }

    /// @dev Settlement units `shares` redeem for now.
    function _value(uint256 shares) private view returns (uint256) {
        if (shares == 0) return 0;
        uint256 assets = VAULT.previewRedeem(shares);
        address settlement = PROGRAM.settlementToken();
        if (settlement == ASSET) return assets;
        return Conversion(PROGRAM.conversion()).quoteIn(ASSET, settlement, assets);
    }

    /// @dev Shares that redeem for at least `units` settlement units now.
    function _sharesFor(uint256 units) private view returns (uint256) {
        address settlement = PROGRAM.settlementToken();
        uint256 assets =
            settlement == ASSET ? units : Conversion(PROGRAM.conversion()).quoteOut(ASSET, settlement, units);
        return VAULT.previewWithdraw(assets);
    }

    /// @dev Shares the float pays for past `promised` shares, rounded down.
    function _floatShares(uint256 promised) private view returns (uint256) {
        uint256 float_ = IERC20Like(ASSET).balanceOf(address(this));
        uint256 owedAssets = promised == 0 ? 0 : VAULT.previewRedeem(promised);
        if (float_ <= owedAssets) return 0;
        // Shares that withdraw the free float round up; one fewer redeems for no more than it.
        return VAULT.previewWithdraw(float_ - owedAssets).zeroFloorSub(1);
    }

    /// @dev Shares a promised leg of `owner` may still grow by: what the float pays for past `promised` shares, so
    ///      that its capture limit (the hold plus the owner's tolerance) stays within it.
    function _floatRoom(address owner, uint256 promised) private view returns (uint256) {
        uint16 tol = CORE.payeeTerms(owner, address(this), SHARE).toleranceBps;
        return _floatShares(promised) * BPS / (BPS + tol);
    }

    /// @dev Replaces a promised leg's capture limit `from` with `to` in the current deferral's promises.
    function _repromise(Deferral memory d, uint256 from, uint256 to) private {
        if (from == to) return;
        d.promised = (uint256(d.promised).zeroFloorSub(from) + to).toUint128();
        deferral.promised = d.promised;
    }

    /// @dev Ends deferral `d` if active: its promises lapse and legs hold as usual again.
    function _endDeferral(Deferral memory d) private {
        if (!d.active) return;
        (d.active, d.promised) = (false, 0);
        deferral = Deferral(false, d.epoch, 0);
        emit DeferralEnded(d.epoch);
    }

    function _budgetRoom(address owner, uint256 free) private view returns (uint256) {
        IReservationCore.Budget memory b = CORE.budget(owner, address(this), SHARE);
        uint256 used = uint256(b.spent) + b.outstanding;
        uint256 room = b.limit > used ? b.limit - used : 0;
        return free < room ? free : room;
    }

    function _takeHeld(uint256 shares) private {
        uint256 have = heldShares;
        if (shares > have) revert ExceedsHeldShares(shares, have);
        heldShares = have - shares;
    }

    function _lock() private {
        if (_locked) revert Reentrancy();
        _locked = true;
    }
}
// forge-lint: disable-end(reentrancy-no-eth, calls-loop)
