// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { ILineVenue, ProgramVenue } from "./ProgramVenue.sol";
import { ICardAuth } from "./interfaces/ICardAuth.sol";
import { IExposureGuard } from "./interfaces/IExposureGuard.sol";
import { IReservationCore, MAX_HOLD_DURATION, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";
import { ISettlementTokenGuard } from "./interfaces/ISettlementTokenGuard.sol";

interface IMidRate {
    function mid(address tokenIn, address tokenOut) external view returns (uint256);
}

interface IConvertAtMid {
    function convertAtMid(address tokenIn, address tokenOut, uint256 amountIn, address recipient)
        external
        returns (uint256 out);
}

interface ITIP20Memo {
    function transferFromWithMemo(address from, address to, uint256 amount, bytes32 memo) external returns (bool);
}

/// @title IssuerTreasury
/// @notice The issuer's money beside one card authorization contract (PROGRAM): its own funds that advance payouts
///         when the settlement account runs short (which the account then owes it as core debt), within what those
///         funds must keep behind the program's exposure; the change of settlement token, after the settings delay;
///         and the sponsor collateral the settlement account pledges behind the program's exposure. Every advance
///         comes from funds the issuer put in: a shortfall reverts.
/// @custom:reentrancy-guard _locked
contract IssuerTreasury is IExposureGuard {
    using FixedPointMathLib for uint256;

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    uint256 public constant MAX_PLEDGES = 16;
    /// @notice How long a pledge must still stand to cover exposure: past the longest hold, with a week for the
    ///         sponsor to seize what is still unsettled before it expires.
    uint256 public constant COVER_TERM = MAX_HOLD_DURATION + 7 days;
    /// @dev Settlement-token-in-use reasons this contract reports itself.
    uint8 private constant IN_USE_HOLDS = 1;
    uint8 private constant IN_USE_UNSETTLED = 2;
    uint8 private constant IN_USE_COLLATERAL = 5;
    uint8 private constant IN_USE_HELD = 6;
    uint8 private constant IN_USE_ISSUER_DEBT = 8;
    uint8 private constant PLEDGE = 2;

    ICardAuth public immutable PROGRAM;

    /// @dev What the issuer put in, per token, before what the settlement account owes back.
    mapping(address token => uint256) internal _funds;
    /// @notice Contracts sizing money in the settlement token, asked before it changes.
    address[] public tokenGuards;
    mapping(bytes32 id => uint64 eta) public pendingSetting;
    uint64 internal _charges;

    /// @notice The sponsor collateral: who receives what is seized, the pledged token, its Earn vault (zero for
    ///         plain tokens), and which of the MAX_PLEDGES pledge slots hold posted pledges (bit n-1 for pledgeId(n)).
    struct Collateral {
        address sponsor;
        address token;
        IEarnVault vault;
        uint16 slots;
    }

    Collateral public collateral;
    /// @notice What the sponsor seized and has not yet applied to an acknowledged settlement.
    uint256 public seized;

    bool private transient _locked;

    event IssuerFunded(address indexed from, address indexed token, uint256 amount);
    event IssuerFundsWithdrawn(address indexed token, uint256 amount);
    event IssuerPaid(address indexed to, address indexed token, uint256 amount, uint256 advanced, bytes32 memo);
    event HeldConverted(address indexed token, uint256 amount, uint256 out);
    event IssuerDebtCarried(address indexed from, uint256 owed, address indexed to, uint256 carried);
    event SettingProposed(bytes32 indexed id, bytes data, uint64 eta);
    event SettingCanceled(bytes32 indexed id);
    event SettlementTokenSet(address indexed token, address indexed previous, uint256 scale);
    event TokenGuardsSet(address[] guards);
    event CollateralPosted(address indexed sponsor, bytes32 pledgeId, uint128 units);
    event CollateralReleased(uint256 value, uint256 units);
    event CollateralSeized(address indexed to, uint256 value, uint256 units);
    event SettlementAcknowledged(uint64 throughSeq, uint256 applied);

    error AboveExposure(uint256 value, uint256 room);
    error BelowExposure(uint256 remaining, uint256 exposure);
    error ExposureAboveCollateral(uint256 exposure, uint256 collateral);
    error IssuerFundsShort(uint256 needed, uint256 available);
    error NoConversion();
    error NotIssuer();
    error NotSettlementAccount();
    error NotSponsor();
    error PledgeMissing(bytes32 pledgeId);
    error Reentrancy();
    error SettingPending(uint64 eta);
    error SettlementTokenInUse(uint8 reason);
    error TokenNotAccepted(address token);
    error TooManyPledges();
    error WrongAsset();
    error WrongSponsor();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyIssuer() {
        if (msg.sender != PROGRAM.ISSUER()) revert NotIssuer();
        _;
    }

    constructor(ICardAuth program) {
        PROGRAM = program;
    }

    // Every entry point that moves money holds the transient lock for its whole call; the program and the core it
    // calls are fixed.
    // forge-lint: disable-start(reentrancy-no-eth)

    /// @notice Adds amount of token from the caller to the issuer's funds for advancing payouts.
    function fundIssuerDebt(address token, uint256 amount) external nonReentrant {
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        _funds[token] += amount;
        emit IssuerFunded(msg.sender, token, amount);
    }

    /// @notice Pays amount of the issuer's own token funds to the settlement account, within what it holds less what
    ///         they stand behind (committedIssuerFunds).
    function withdrawIssuerFunds(address token, uint256 amount) external nonReentrant onlyIssuer {
        uint256 held = _min(issuerFunds(token), SafeTransferLib.balanceOf(token, address(this)));
        uint256 committed = committedIssuerFunds(token);
        held = held > committed ? held - committed : 0;
        if (amount > held) revert IssuerFundsShort(amount, held);
        _funds[token] -= amount;
        SafeTransferLib.safeTransfer(token, PROGRAM.SETTLEMENT_ACCOUNT(), amount);
        emit IssuerFundsWithdrawn(token, amount);
    }

    /// @notice Converts what the settlement account holds free of an earlier settlement token (a payee's split
    ///         returned in the token it was paid in) into today's at the reference rates, through the program's
    ///         Conversion. The settlement account or the issuer calls it.
    function convertHeld(address token) external nonReentrant returns (uint256 out) {
        address account = PROGRAM.SETTLEMENT_ACCOUNT();
        if (msg.sender != account && msg.sender != PROGRAM.ISSUER()) revert NotIssuer();
        address current = PROGRAM.settlementToken();
        if (token == current) revert WrongAsset();
        uint256 amount = CORE.available(account, token);
        if (amount == 0) return 0;
        address conversion = PROGRAM.conversion();
        if (conversion == address(0)) revert NoConversion();
        // From the program's own settlement account only, which the issuer or the account itself asked for above.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        SafeTransferLib.safeTransferFrom(token, account, address(this), amount);
        SafeTransferLib.safeApprove(token, conversion, amount);
        out = IConvertAtMid(conversion).convertAtMid(token, current, amount, account);
        emit HeldConverted(token, amount, out);
    }

    /// @notice Pays amount of the settlement token from the settlement account to to with memo. What the account
    ///         lacks, the issuer's funds advance, and the account owes it here as core debt within the cap it set; the
    ///         core repays it first from what the account receives. The settlement account, the issuer or a treasury
    ///         operator (within its cap) calls it.
    function payOut(address to, uint256 amount, bytes32 memo) external nonReentrant returns (uint256 advanced) {
        address account = PROGRAM.SETTLEMENT_ACCOUNT();
        if (msg.sender != account && msg.sender != PROGRAM.ISSUER()) {
            if (!PROGRAM.hasRoles(msg.sender, PROGRAM.ROLE_TREASURY())) revert NotIssuer();
            PROGRAM.useOperatorCap(msg.sender, amount);
        }
        address token = PROGRAM.settlementToken();
        uint256 free = CORE.available(account, token);
        if (amount > free) {
            advanced = amount - free;
            uint256 held = issuerFunds(token);
            if (held < advanced) revert IssuerFundsShort(advanced, held);
            // The account's debt here is forgiven first, so the advance reaches it whole, and charged again below
            // together with the advance: only the advance leaves this contract.
            bytes32 id = _chargeId();
            uint256 before = _forgive(account, token, id);
            SafeTransferLib.safeTransfer(token, account, advanced);
            ITIP20Memo(token).transferFromWithMemo(account, to, amount, memo);
            // forge-lint: disable-next-line(unsafe-typecast)
            CORE.charge(account, token, id, uint128(before + advanced), address(this), false);
        } else {
            ITIP20Memo(token).transferFromWithMemo(account, to, amount, memo);
        }
        emit IssuerPaid(to, token, amount, advanced, memo);
    }

    /// @notice Settles new purchases in token from now on, after the program's settings delay once it granted anyone.
    ///         Refused while anything is still sized in the old token: what a token guard reports, or posted sponsor
    ///         collateral, or issuer debt the settlement account cannot owe in the new token. The program refuses it
    ///         too while its own purchases are open or unsettled. What the account owes the issuer moves into the new
    ///         token at the venue's price, rounded up.
    function setSettlementToken(address token) external nonReentrant onlyIssuer {
        address current = PROGRAM.settlementToken();
        if (token == address(0) || token == current) revert TokenNotAccepted(token);
        _checkUnused();
        address venue = PROGRAM.conversion();
        if (venue == address(0)) revert NoConversion();
        // Units of the new token one old unit is worth at today's reference rates, without conversion cost.
        uint256 scale = IMidRate(venue).mid(current, token);
        // Every check above runs again when the change applies.
        if (!_settle(false)) return;
        _carryIssuerDebt(ILineVenue(venue), current, token);
        PROGRAM.setSettlementToken(token, scale);
        emit SettlementTokenSet(token, current, scale);
    }

    /// @notice Contracts sizing money in the settlement token that a change must wait for. Appending to the current
    ///         list applies at once, since a guard can only hold a change back; anything else waits the delay.
    function setTokenGuards(address[] calldata guards) external onlyIssuer {
        address[] storage current = tokenGuards;
        uint256 n = current.length;
        bool appends = guards.length >= n;
        for (uint256 i; appends && i < n; ++i) {
            appends = guards[i] == current[i];
        }
        if (!_settle(appends)) return;
        tokenGuards = guards;
        emit TokenGuardsSet(guards);
    }

    /// @notice Drops a proposed setting.
    function cancelSetting(bytes32 id) external onlyIssuer {
        delete pendingSetting[id];
        emit SettingCanceled(id);
    }

    /// @notice What the issuer holds of token for advancing payouts: its funds less what the settlement account owes.
    function issuerFunds(address token) public view returns (uint256) {
        uint256 funds = _funds[token];
        if (funds == 0) return 0;
        uint256 owed = _owedTo(PROGRAM.SETTLEMENT_ACCOUNT(), token);
        return funds > owed ? funds - owed : 0;
    }

    /// @notice What the issuer's own funds of token stand behind and keep for, in the settlement token only: stand-in
    ///         approvals open purchases hold beyond the cardholders' funds, and what the settlement account still owes
    ///         the network for captures but cannot pay from its free balance.
    function committedIssuerFunds(address token) public view returns (uint256) {
        if (token != PROGRAM.settlementToken()) return 0;
        (, uint256 standIn, uint256 unsettled) = PROGRAM.exposure();
        uint256 free = CORE.available(PROGRAM.SETTLEMENT_ACCOUNT(), token);
        return standIn + (unsettled > free ? unsettled - free : 0);
    }

    /// @notice What the program may still owe the network: what open purchases hold and unsettled captures. Sponsor
    ///         collateral is released and seized against it.
    function exposure() public view returns (uint256) {
        (uint256 held,, uint256 unsettled) = PROGRAM.exposure();
        return held + unsettled;
    }

    /// @notice Reverts when the program's exposure is past what its live sponsor collateral is worth. The program asks
    ///         it after every step that raises its exposure once the issuer registers this contract as its guard.
    function checkExposure() external view {
        uint256 due = exposure();
        if (due == 0) return;
        uint256 value = valueOf();
        if (due > value) revert ExposureAboveCollateral(due, value);
    }

    function tokenGuardsLength() external view returns (uint256) {
        return tokenGuards.length;
    }

    /// @notice Records the settlement account's pledge of sponsor collateral at pledgeId(n), n from 1 to MAX_PLEDGES:
    ///         a core pledge it placed with this contract as payee, standing at least COVER_TERM, of the settlement
    ///         token or of one Earn vault's shares (vault nonzero). A slot is free again once its pledge ended. The
    ///         asset changes only while no pledge is live, and the sponsor only while nothing is live, seized or
    ///         exposed.
    // forge-lint: disable-next-item(block-timestamp)
    function post(address sponsor, IEarnVault vault, uint256 n) external nonReentrant {
        address account = PROGRAM.SETTLEMENT_ACCOUNT();
        if (msg.sender != account) revert NotSettlementAccount();
        if (n == 0 || n > MAX_PLEDGES) revert TooManyPledges();
        if (sponsor == address(0)) revert WrongSponsor();
        Collateral storage c = collateral;
        address token = address(vault) == address(0) ? PROGRAM.settlementToken() : vault.earnShare();
        if (unitsOf() == 0) {
            if (sponsor != c.sponsor && (c.sponsor != address(0) && (seized != 0 || exposure() != 0))) {
                revert WrongSponsor();
            }
            if (address(vault) != address(0)) _toAssets(vault.asset(), 0);
            (c.sponsor, c.token, c.vault, c.slots) = (sponsor, token, vault, 0);
        } else {
            if (c.token != token || address(c.vault) != address(vault)) revert WrongAsset();
            if (c.sponsor != sponsor) revert WrongSponsor();
        }
        bytes32 id = pledgeId(n);
        IReservationCore.HoldRecord memory h = CORE.getHold(account, account, id);
        if (!_counts(h, token, block.timestamp + COVER_TERM)) revert PledgeMissing(id);
        // A slot already posted holds this same pledge: posting it again changes nothing.
        // forge-lint: disable-next-line(unsafe-typecast)
        c.slots |= uint16(1 << (n - 1));
        emit CollateralPosted(sponsor, id, h.held);
    }

    /// @notice The sponsor releases collateral worth value, never below the program's exposure in what still covers it.
    function release(uint256 value) external nonReentrant {
        Collateral storage c = _sponsored();
        uint256 current = valueOf();
        uint256 remaining = current > value ? current - value : 0;
        uint256 due = exposure();
        if (remaining < due) revert BelowExposure(remaining, due);
        uint256 units = _unitsDown(c, value);
        _take(c, units, false);
        emit CollateralReleased(value, units);
    }

    /// @notice The sponsor seizes collateral worth value in the settlement token, never more than the program's
    ///         exposure less what it seized before and has not applied to an acknowledged settlement.
    function seize(uint256 value) external nonReentrant {
        Collateral storage c = _sponsored();
        uint256 due = exposure();
        uint256 taken = seized;
        if (taken + value > due) revert AboveExposure(value, due > taken ? due - taken : 0);
        seized = taken + value;
        address to = c.sponsor;
        uint256 units = _take(c, _unitsDown(c, value), true);
        address settlement = PROGRAM.settlementToken();
        IEarnVault vault = c.vault;
        address asset = address(vault) == address(0) ? c.token : vault.asset();
        if (address(vault) == address(0) && asset == settlement) {
            SafeTransferLib.safeTransfer(c.token, to, units);
        } else if (address(vault) == address(0)) {
            ProgramVenue.sell(_venue(), asset, settlement, units, to);
        } else {
            ILineVenue venue = asset == settlement ? ILineVenue(address(0)) : _venue();
            ProgramVenue.redeemTo(venue, vault, units, settlement, to);
        }
        emit CollateralSeized(to, value, units);
    }

    /// @notice Acknowledges the program's purchase steps through `throughSeq` as settled, for the sponsor that is owed
    ///         them once collateral is posted (the issuer before). `applied` of what the sponsor seized paid that
    ///         settlement and stops counting as seized: never more than seized, nor than the unsettled exposure this
    ///         acknowledgement clears, so seizures in all never pass what the program came to owe.
    function acknowledgeSettlement(uint64 throughSeq, uint256 applied) external nonReentrant {
        Collateral storage c = collateral;
        if (msg.sender != (c.sponsor == address(0) ? PROGRAM.ISSUER() : c.sponsor)) revert NotSponsor();
        (,, uint256 before) = PROGRAM.exposure();
        PROGRAM.acknowledgeSettlement(throughSeq);
        (,, uint256 left) = PROGRAM.exposure();
        uint256 cleared = before > left ? before - left : 0;
        uint256 room = seized < cleared ? seized : cleared;
        if (applied > room) revert AboveExposure(applied, room);
        seized -= applied;
        emit SettlementAcknowledged(throughSeq, applied);
    }

    /// @notice Records the program's net as of its latest purchase step (at a network cut-off), for a later
    ///         acknowledgement through that step, and returns the step. The sponsor, or the issuer before one.
    function checkpointSettlement() external returns (uint64) {
        address sponsor = collateral.sponsor;
        if (msg.sender != (sponsor == address(0) ? PROGRAM.ISSUER() : sponsor)) revert NotSponsor();
        return PROGRAM.checkpointSettlement();
    }

    /// @notice The core id of the settlement account's nth collateral pledge.
    function pledgeId(uint256 n) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), n));
    }

    /// @notice The posted units still live.
    function unitsOf() public view returns (uint256) {
        return _units(block.timestamp);
    }

    /// @notice What the collateral standing at least COVER_TERM more is worth in the settlement token: what covers
    ///         the program's exposure.
    function valueOf() public view returns (uint256) {
        Collateral storage c = collateral;
        uint256 units = _units(block.timestamp + COVER_TERM);
        if (units == 0) return 0;
        IEarnVault vault = c.vault;
        if (address(vault) == address(0)) return _inSettlement(c.token, units);
        return _inSettlement(vault.asset(), vault.previewRedeem(units));
    }

    /// @notice The units of vault (or of the settlement token, for a zero vault) worth value in the settlement token.
    function unitsFor(IEarnVault vault, uint256 value) external view returns (uint256) {
        if (address(vault) == address(0) || value == 0) return value;
        return vault.previewWithdraw(_toAssets(vault.asset(), value));
    }

    function _sponsored() private view returns (Collateral storage c) {
        c = collateral;
        if (c.sponsor == address(0) || msg.sender != c.sponsor) revert NotSponsor();
    }

    /// @dev The posted units whose pledges stand past `until`.
    // forge-lint: disable-next-item(calls-loop)
    function _units(uint256 until) private view returns (uint256 units) {
        Collateral storage c = collateral;
        (uint256 slots, address token) = (c.slots, c.token);
        address account = PROGRAM.SETTLEMENT_ACCOUNT();
        for (uint256 n = 1; slots >> (n - 1) != 0; ++n) {
            if (slots & (1 << (n - 1)) == 0) continue;
            IReservationCore.HoldRecord memory h = CORE.getHold(account, account, pledgeId(n));
            if (_counts(h, token, until)) units += h.held;
        }
    }

    /// @dev Whether h is a live pledge of token to this contract standing past `until`. A slot's pledge may have
    ///      ended and its id been used again for something else.
    function _counts(IReservationCore.HoldRecord memory h, address token, uint256 until) private view returns (bool) {
        return h.token == token && h.kind == PLEDGE && h.payee == address(this) && h.held != 0 && h.expiresAt > until;
    }

    /// @dev Reverts while a guard, posted collateral or any other hold on the settlement account's balance still sizes
    ///      money in the settlement token. A guard names the reason first, as it explains a held balance.
    // At most the guards the issuer set.
    // forge-lint: disable-next-item(calls-loop)
    function _checkUnused() private view {
        // The program's own holds and unsettled steps, which a proposal checks too, so it refuses rather than waiting.
        (uint256 held,,) = PROGRAM.exposure();
        if (held != 0) revert SettlementTokenInUse(IN_USE_HOLDS);
        (uint64 seq, uint64 settledThrough, int128 net, int128 settledNet) = PROGRAM.ledger();
        if (seq != settledThrough || net != settledNet) revert SettlementTokenInUse(IN_USE_UNSETTLED);
        address[] storage guards = tokenGuards;
        for (uint256 i; i < guards.length; ++i) {
            uint8 reason = ISettlementTokenGuard(guards[i]).settlementTokenInUse(address(PROGRAM));
            if (reason != 0) revert SettlementTokenInUse(reason);
        }
        if (unitsOf() != 0) revert SettlementTokenInUse(IN_USE_COLLATERAL);
        if (CORE.reserved(PROGRAM.SETTLEMENT_ACCOUNT(), PROGRAM.settlementToken()) != 0) {
            revert SettlementTokenInUse(IN_USE_HELD);
        }
    }

    /// @dev Moves what the settlement account owes the issuer in current into next: the units of next that buy it back
    ///      at the venue, rounded up. Reverts when the account cannot owe that in next.
    // forge-lint: disable-next-item(reentrancy-no-eth)
    function _carryIssuerDebt(ILineVenue venue, address current, address next) private {
        address account = PROGRAM.SETTLEMENT_ACCOUNT();
        uint256 owed = _owedTo(account, current);
        if (owed == 0) return;
        uint256 carried = venue.quoteOut(next, current, owed);
        if (carried > type(uint128).max) revert SettlementTokenInUse(IN_USE_ISSUER_DEBT);
        // The debt in current is forgiven, with nothing sent, and charged again in next.
        bytes32 id = _chargeId();
        _forgive(account, current, id);
        // forge-lint: disable-next-line(unsafe-typecast)
        try CORE.charge(account, next, id, uint128(carried), address(this), false) { }
        catch {
            revert SettlementTokenInUse(IN_USE_ISSUER_DEBT);
        }
        // The claim moves to next: the funds in current drop by the forgiven debt, so what this holds there for
        // advancing stays the same.
        _funds[current] -= owed;
        _funds[next] += carried;
        emit IssuerDebtCarried(current, owed, next, carried);
    }

    function _settle(bool immediate) private returns (bool) {
        if (immediate || PROGRAM.grantedOwners() == 0) return true;
        bytes32 id = keccak256(msg.data);
        uint64 eta = pendingSetting[id];
        // A proposal not applied within the program's settings window after its delay lapses and is recorded afresh.
        // forge-lint: disable-next-line(block-timestamp)
        if (eta == 0 || block.timestamp > eta + PROGRAM.SETTINGS_WINDOW()) {
            // forge-lint: disable-next-line(unsafe-typecast)
            eta = uint64(block.timestamp) + PROGRAM.SETTINGS_DELAY();
            pendingSetting[id] = eta;
            emit SettingProposed(id, msg.data, eta);
            return false;
        }
        // Setting delays are days long; validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < eta) revert SettingPending(eta);
        delete pendingSetting[id];
        return true;
    }

    function _chargeId() private returns (bytes32) {
        return keccak256(abi.encode("tempo.cards.issuer-debt", address(this), ++_charges));
    }

    /// @dev Forgives all that account owes this contract in token, through a core refund that pays nothing, and
    ///      returns it.
    function _forgive(address account, address token, bytes32 id) private returns (uint256 owed) {
        owed = _owedTo(account, token);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (owed != 0) CORE.refund(account, token, address(this), id, uint128(owed));
    }

    /// @dev What owner owes this contract in token on the core.
    function _owedTo(address owner, address token) private view returns (uint256) {
        IReservationCore.Debt[] memory debts = CORE.debtOf(owner, token);
        for (uint256 i; i < debts.length; ++i) {
            if (debts[i].creditor == address(this)) return debts[i].amount;
        }
        return 0;
    }

    function _inSettlement(address asset, uint256 amount) private view returns (uint256) {
        address settlement = PROGRAM.settlementToken();
        if (asset == settlement || amount == 0) return amount;
        return ProgramVenue.quoteIn(_venue(), asset, settlement, amount);
    }

    function _toAssets(address asset, uint256 value) private view returns (uint256) {
        address settlement = PROGRAM.settlementToken();
        if (asset == settlement) return value;
        return ProgramVenue.quoteOut(_venue(), asset, settlement, value);
    }

    function _venue() private view returns (ILineVenue venue) {
        venue = ILineVenue(PROGRAM.conversion());
        if (address(venue) == address(0)) revert NoConversion();
    }

    /// @dev The units worth at most value, rounding every conversion down.
    function _unitsDown(Collateral storage c, uint256 value) private view returns (uint256) {
        IEarnVault vault = c.vault;
        address asset = address(vault) == address(0) ? c.token : vault.asset();
        uint256 assets = _toAssets(asset, value);
        if (assets != 0 && assets != value && _inSettlement(asset, assets) > value) --assets;
        if (address(vault) == address(0)) return assets;
        uint256 shares = vault.previewWithdraw(assets);
        if (shares != 0 && vault.previewRedeem(shares) > assets) --shares;
        return shares;
    }

    /// @dev Takes units from the newest live pledges back: seizing captures them to this contract, else releases.
    // forge-lint: disable-next-item(block-timestamp,calls-loop,reentrancy-no-eth,unsafe-typecast)
    function _take(Collateral storage c, uint256 units, bool seizing) private returns (uint256 moved) {
        address account = PROGRAM.SETTLEMENT_ACCOUNT();
        (uint256 slots, address token) = (c.slots, c.token);
        for (uint256 n = MAX_PLEDGES; n > 0 && units != 0; --n) {
            uint256 bit = 1 << (n - 1);
            if (slots & bit == 0) continue;
            bytes32 id = pledgeId(n);
            IReservationCore.HoldRecord memory h = CORE.getHold(account, account, id);
            if (!_counts(h, token, block.timestamp)) continue;
            uint128 amount = h.held;
            uint128 part = units < amount ? uint128(units) : amount;
            // Taking a whole pledge ends it, which frees its slot.
            if (part == amount) slots &= ~bit;
            if (seizing) CORE.capture(account, account, id, part, false);
            else if (part == amount) CORE.release(account, account, id);
            else CORE.adjust(account, account, id, amount - part);
            units -= part;
            moved += part;
        }
        c.slots = uint16(slots);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
    // forge-lint: disable-end(reentrancy-no-eth)
}
