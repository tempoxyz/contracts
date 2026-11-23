// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "../../interfaces/earn/IEarnVault.sol";

import { ILineVenue, ProgramVenue } from "./ProgramVenue.sol";
import { ICardAuth } from "../../interfaces/spend/programs/ICardAuth.sol";
import { IExposureGuard } from "../../interfaces/spend/programs/IExposureGuard.sol";
import {
    IReservationCore,
    MAX_HOLD_DURATION,
    RESERVATION_CORE_ADDRESS
} from "../../interfaces/spend/programs/IReservationCore.sol";
import { ISettlementTokenGuard } from "../../interfaces/spend/programs/ISettlementTokenGuard.sol";

interface IMidRate {
    function mid(address tokenIn, address tokenOut) external view returns (uint256);
}

interface IConvertAtMid {
    function convertAtMid(address tokenIn, address tokenOut, uint256 amountIn, address recipient)
        external
        returns (uint256 out);
}

/// @dev A cash source's open converted holds, per converted token.
interface IConvertedTokens {
    function convertedTokens() external view returns (address[] memory tokens, uint256[] memory open);
}

/// @dev The program's approved cash sources, a stopped one kept while it may hold converted tokens.
interface ICashSources {
    function cashSources() external view returns (address[] memory);
    function sourceKind(address source) external view returns (uint8);
}

/// @dev The program's exposure guard, which only the current guard replaces or clears once one is set.
interface IGuardSetting {
    function setExposureGuard(address guard) external;
}

interface ITIP20Memo {
    function transferWithMemo(address to, uint256 amount, bytes32 memo) external;
}

interface ITIP20MemoFrom {
    function transferFromWithMemo(address from, address to, uint256 amount, bytes32 memo) external returns (bool);
}

/// @title IssuerTreasury
/// @notice The issuer's money beside one card authorization contract (PROGRAM): its own funds that advance payouts
///         when the settlement account runs short, which the account then owes back here as a receivable
///         (advanceOf) until it repays it (repayAdvance), within what those funds must keep behind the program's
///         exposure; the change of settlement token, after the settings delay; and the sponsor collateral the
///         settlement account pledges behind the program's exposure. Every advance comes from funds the issuer put in:
///         a shortfall reverts.
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
    uint8 private constant PLEDGE = 2;
    uint256 private constant BPS = 10_000;
    /// @notice The share of a converted token's open holds (their settlement value) the collateral must also cover,
    ///         for a move of that token before they capture, while the issuer set no figure for it (fxStressOf).
    uint256 public constant DEFAULT_FX_STRESS_BPS = 1000;
    /// @notice How long a named sponsor may go without acting here (acknowledging, checkpointing, seizing or
    ///         releasing) before the issuer may hand the guard on while the program is still exposed or something is
    ///         seized, once no collateral is live: past the dispute horizon (about 120 days) and a pledge's COVER_TERM.
    uint256 public constant SPONSOR_SILENCE = 180 days;

    ICardAuth public immutable PROGRAM;

    /// @dev What the issuer put in, per token, before what the settlement account owes back.
    mapping(address token => uint256) internal _funds;
    /// @notice What the settlement account owes the issuer's funds, per token, for payouts they advanced.
    mapping(address token => uint256) public advanceOf;
    /// @notice Contracts sizing money in the settlement token, asked before it changes.
    address[] public tokenGuards;
    mapping(bytes32 id => uint64 eta) public pendingSetting;
    /// @dev The stress figure the issuer set per converted token, in bps; zero for none (DEFAULT_FX_STRESS_BPS).
    mapping(address token => uint256) internal _fxStress;

    /// @notice The sponsor collateral: who receives what is seized, the pledged token, its Earn vault (zero for
    ///         plain tokens), which of the MAX_PLEDGES pledge slots hold posted pledges (bit n-1 for pledgeId(n)), and
    ///         when the sponsor last acted here or was named, which SPONSOR_SILENCE counts from.
    struct Collateral {
        address sponsor;
        address token;
        IEarnVault vault;
        uint16 slots;
        uint64 seenAt;
    }

    Collateral public collateral;
    /// @notice The Earn vault each sponsor accepts as collateral; collateral in the settlement token needs none.
    mapping(address sponsor => IEarnVault) public acceptedVault;
    /// @notice What the sponsor seized and has not yet applied to an acknowledged settlement.
    uint256 public seized;

    bool private transient _locked;

    event IssuerFunded(address indexed from, address indexed token, uint256 amount);
    event IssuerFundsWithdrawn(address indexed token, uint256 amount);
    event IssuerPaid(address indexed to, address indexed token, uint256 amount, uint256 advanced, bytes32 memo);
    event HeldConverted(address indexed token, uint256 amount, uint256 out);
    /// @notice The settlement account repaid `amount` of what the issuer's funds advanced it in `token`.
    event AdvanceRepaid(address indexed token, uint256 amount);
    /// @notice A change of settlement token moved what the account owes the issuer, `owed` in `from`, into `carried`
    ///         of `to`.
    event IssuerDebtCarried(address indexed from, uint256 owed, address indexed to, uint256 carried);
    event SettingProposed(bytes32 indexed id, bytes data, uint64 eta);
    event SettingCanceled(bytes32 indexed id);
    event SettlementTokenSet(address indexed token, address indexed previous, uint256 scale);
    event TokenGuardsSet(address[] guards);
    event FxStressSet(address indexed token, uint256 bps);
    event CollateralAccepted(address indexed sponsor, IEarnVault vault);
    event CollateralPosted(address indexed sponsor, bytes32 pledgeId, uint128 units);
    event CollateralReleased(uint256 value, uint256 units);
    event CollateralSeized(address indexed to, uint256 value, uint256 units);
    event SettlementAcknowledged(uint64 throughSeq, uint256 applied);
    /// @notice The issuer handed the guard on from a silent sponsor, which still counted `applied` as seized: it is
    ///         taken as paid toward the program's settlement, so it no longer counts.
    event SeizedApplied(uint256 applied);

    error AboveExposure(uint256 value, uint256 room);
    error BelowExposure(uint256 remaining, uint256 exposure);
    error ExposureAboveCollateral(uint256 exposure, uint256 collateral);
    error InvalidFxStress(uint256 bps);
    error GuardInUse();
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
    ///         lacks, the issuer's funds advance: the account's free balance comes here and this contract pays the whole
    ///         amount, and the advance joins what the account owes back here (advanceOf). The settlement account, the
    ///         issuer or a treasury operator (within its cap) calls it.
    function payOut(address to, uint256 amount, bytes32 memo) external nonReentrant returns (uint256 advanced) {
        address account = _treasuryCaller(amount);
        address token = PROGRAM.settlementToken();
        uint256 free = CORE.available(account, token);
        if (amount > free) {
            advanced = amount - free;
            uint256 held = issuerFunds(token);
            if (held < advanced) revert IssuerFundsShort(advanced, held);
            advanceOf[token] += advanced;
            // From the program's own settlement account, which the caller is or acts for above.
            // forge-lint: disable-next-line(arbitrary-send-erc20)
            if (free != 0) SafeTransferLib.safeTransferFrom(token, account, address(this), free);
            ITIP20Memo(token).transferWithMemo(to, amount, memo);
        } else {
            // From the program's own settlement account, which the caller is or acts for above.
            // forge-lint: disable-next-line(arbitrary-send-erc20)
            ITIP20MemoFrom(token).transferFromWithMemo(account, to, amount, memo);
        }
        emit IssuerPaid(to, token, amount, advanced, memo);
    }

    /// @notice Repays up to amount of what the settlement account owes the issuer's funds in token, from the account's
    ///         free balance. The settlement account, the issuer or a treasury operator calls it. Returns what it repaid.
    function repayAdvance(address token, uint256 amount) external nonReentrant returns (uint256 repaid) {
        address account = _treasuryCaller(0);
        repaid = _min(_min(amount, advanceOf[token]), CORE.available(account, token));
        if (repaid == 0) return 0;
        advanceOf[token] -= repaid;
        // From the program's own settlement account, which the caller is or acts for above, back to the issuer's funds.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        SafeTransferLib.safeTransferFrom(token, account, address(this), repaid);
        emit AdvanceRepaid(token, repaid);
    }

    /// @notice Settles new purchases in token from now on, after the program's settings delay once it granted anyone.
    ///         Refused while anything is still sized in the old token: what a token guard reports, or posted sponsor
    ///         collateral. The program refuses it too while its own purchases are open or unsettled. What the account
    ///         owes the issuer moves into the new token at the venue's price, rounded up.
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

    /// @notice Sets the share of `token`'s open converted holds the collateral must also cover, in bps (above zero, at
    ///         most 10,000). Raising it applies at once, since it only makes the exposure guard stricter; lowering it
    ///         waits the program's settings delay once it granted anyone.
    function setFxStress(address token, uint256 bps) external onlyIssuer {
        if (bps == 0 || bps > BPS) revert InvalidFxStress(bps);
        if (!_settle(bps >= fxStressOf(token))) return;
        _fxStress[token] = bps;
        emit FxStressSet(token, bps);
    }

    /// @notice The share of `token`'s open converted holds the collateral must also cover, in bps:
    ///         DEFAULT_FX_STRESS_BPS until the issuer sets one.
    function fxStressOf(address token) public view returns (uint256 bps) {
        bps = _fxStress[token];
        if (bps == 0) bps = DEFAULT_FX_STRESS_BPS;
    }

    /// @notice Drops a proposed setting.
    function cancelSetting(bytes32 id) external onlyIssuer {
        delete pendingSetting[id];
        emit SettingCanceled(id);
    }

    /// @notice What the issuer holds of token for advancing payouts: its funds less what the settlement account owes.
    function issuerFunds(address token) public view returns (uint256) {
        uint256 funds = _funds[token];
        uint256 owed = advanceOf[token];
        return funds > owed ? funds - owed : 0;
    }

    /// @notice What the issuer's own funds of token stand behind and keep for, in the settlement token only: what the
    ///         settlement account still owes the network for captures but cannot pay from its free balance.
    function committedIssuerFunds(address token) public view returns (uint256) {
        if (token != PROGRAM.settlementToken()) return 0;
        (, uint256 unsettled) = PROGRAM.exposure();
        uint256 free = CORE.available(PROGRAM.SETTLEMENT_ACCOUNT(), token);
        return unsettled > free ? unsettled - free : 0;
    }

    /// @notice What the program may still owe the network: what open purchases hold and unsettled captures. Sponsor
    ///         collateral is released and seized against it.
    function exposure() public view returns (uint256) {
        (uint256 held, uint256 unsettled) = PROGRAM.exposure();
        return held + unsettled;
    }

    /// @notice The exposure the collateral must cover: exposure() plus, for every cash source the program approved
    ///         and every converted token it holds, that token's fxStressOf share of what its open holds are worth in
    ///         the settlement token at the rates they locked (each total capped at 2^128). An approved source that
    ///         does not answer makes it revert, so the guard refuses until the issuer stops that source.
    // The program keeps at most eight cash sources, and each source at most eight converted tokens.
    // forge-lint: disable-next-item(calls-loop)
    function stressedExposure() public view returns (uint256 due) {
        due = exposure();
        ICashSources program = ICashSources(address(PROGRAM));
        address[] memory sources = program.cashSources();
        uint256 weighted;
        for (uint256 i; i < sources.length; ++i) {
            address[] memory tokens;
            uint256[] memory open;
            try IConvertedTokens(sources[i]).convertedTokens() returns (address[] memory t, uint256[] memory o) {
                (tokens, open) = (t, o);
            } catch (bytes memory reason) {
                // A stopped source that stopped answering no longer counts; an approved one keeps the guard refusing.
                if (program.sourceKind(sources[i]) == 0) continue;
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
            for (uint256 j; j < tokens.length; ++j) {
                if (open[j] != 0) weighted += _min(open[j], type(uint128).max) * fxStressOf(tokens[j]);
            }
        }
        if (weighted != 0) due += weighted.divUp(BPS);
    }

    /// @notice Reverts when the program's stressed exposure is past what its live sponsor collateral is worth. The
    ///         program asks it after every step that raises its exposure once the issuer registers this contract as
    ///         its guard.
    function checkExposure() external view {
        uint256 due = stressedExposure();
        if (due == 0) return;
        uint256 value = valueOf();
        if (due > value) revert ExposureAboveCollateral(due, value);
    }

    function tokenGuardsLength() external view returns (uint256) {
        return tokenGuards.length;
    }

    /// @notice The caller accepts vault's shares as the collateral it is sponsor of (zero for none): the settlement
    ///         account posts a vault only for a sponsor that accepts it.
    function acceptCollateral(IEarnVault vault) external {
        acceptedVault[msg.sender] = vault;
        emit CollateralAccepted(msg.sender, vault);
    }

    /// @notice Records the settlement account's pledge of sponsor collateral at pledgeId(n), n from 1 to MAX_PLEDGES:
    ///         a core pledge it placed with this contract as payee, standing at least COVER_TERM, of the settlement
    ///         token or of one Earn vault's shares (vault nonzero) that the sponsor accepts. A slot is free again once
    ///         its pledge ended. The sponsor and the asset change only while no pledge is live and nothing is seized
    ///         or exposed.
    // forge-lint: disable-next-item(block-timestamp)
    function post(address sponsor, IEarnVault vault, uint256 n) external nonReentrant {
        address account = PROGRAM.SETTLEMENT_ACCOUNT();
        if (msg.sender != account) revert NotSettlementAccount();
        if (n == 0 || n > MAX_PLEDGES) revert TooManyPledges();
        if (sponsor == address(0)) revert WrongSponsor();
        Collateral storage c = collateral;
        // A vault's value is what the vault reports, so it counts only for a sponsor that accepts it.
        if (address(vault) != address(0) && acceptedVault[sponsor] != vault) revert WrongAsset();
        address token = address(vault) == address(0) ? PROGRAM.settlementToken() : vault.earnShare();
        if (unitsOf() == 0) {
            // The sponsor and the asset stay while the sponsor is still owed, so what it seizes is what it accepted.
            if (c.sponsor != address(0) && (seized != 0 || stressedExposure() != 0)) {
                if (sponsor != c.sponsor) revert WrongSponsor();
                if (token != c.token || vault != c.vault) revert WrongAsset();
            }
            if (address(vault) != address(0)) _toAssets(vault.asset(), 0);
            // A newly named sponsor's silence counts from now.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (sponsor != c.sponsor) c.seenAt = uint64(block.timestamp);
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

    /// @notice The sponsor releases collateral worth value, never below the program's stressed exposure in what still
    ///         covers it.
    function release(uint256 value) external nonReentrant {
        Collateral storage c = _sponsored();
        _seen(c);
        uint256 current = valueOf();
        uint256 remaining = current > value ? current - value : 0;
        uint256 due = stressedExposure();
        if (remaining < due) revert BelowExposure(remaining, due);
        uint256 units = _unitsDown(c, value);
        _take(c, units, false);
        emit CollateralReleased(value, units);
    }

    /// @notice The sponsor seizes collateral worth value in the settlement token, never more than the program's
    ///         exposure less what it seized before and has not applied to an acknowledged settlement.
    function seize(uint256 value) external nonReentrant {
        Collateral storage c = _sponsored();
        _seen(c);
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
        _seen(c);
        (, uint256 before) = PROGRAM.exposure();
        PROGRAM.acknowledgeSettlement(throughSeq);
        (, uint256 left) = PROGRAM.exposure();
        uint256 cleared = before > left ? before - left : 0;
        uint256 room = seized < cleared ? seized : cleared;
        if (applied > room) revert AboveExposure(applied, room);
        seized -= applied;
        emit SettlementAcknowledged(throughSeq, applied);
    }

    /// @notice Hands the program's exposure guard from this contract to next (zero for none). The sponsor may at any
    ///         time, as the party the exposure is owed to; the issuer before a sponsor is named, or once no collateral
    ///         is live and either nothing is seized or exposed, or the sponsor has not acted here for SPONSOR_SILENCE.
    ///         A silent sponsor's seizures are then applied (SeizedApplied). The next guard (or, with none, the issuer)
    ///         then acknowledges the program's settlement.
    function handOffGuard(address next) external nonReentrant {
        Collateral storage c = collateral;
        address sponsor = c.sponsor;
        if (msg.sender != sponsor) {
            if (msg.sender != PROGRAM.ISSUER()) revert NotSponsor();
            if (sponsor != address(0)) {
                // Silence is counted in days; validator skew does not change it.
                // forge-lint: disable-next-line(block-timestamp)
                bool silent = block.timestamp >= uint256(c.seenAt) + SPONSOR_SILENCE;
                uint256 taken = seized;
                if (unitsOf() != 0 || (!silent && (taken != 0 || stressedExposure() != 0))) revert GuardInUse();
                // What the silent sponsor seized already paid it that much of the program's exposure: count it as
                // applied, so the next guard settles the rest and the settlement account may name another sponsor.
                if (taken != 0) {
                    seized = 0;
                    emit SeizedApplied(taken);
                }
            }
        }
        IGuardSetting(address(PROGRAM)).setExposureGuard(next);
    }

    /// @notice Records the program's net as of its latest purchase step (at a network cut-off), for a later
    ///         acknowledgement through that step, and returns the step. The sponsor, or the issuer before one. Like
    ///         every sponsor step here it restarts SPONSOR_SILENCE, so a sponsor with nothing to settle calls it.
    function checkpointSettlement() external returns (uint64) {
        Collateral storage c = collateral;
        address sponsor = c.sponsor;
        if (msg.sender != (sponsor == address(0) ? PROGRAM.ISSUER() : sponsor)) revert NotSponsor();
        _seen(c);
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

    /// @dev Records that the named sponsor acted here now.
    function _seen(Collateral storage c) private {
        // forge-lint: disable-next-line(unsafe-typecast)
        if (c.sponsor != address(0)) c.seenAt = uint64(block.timestamp);
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
        (uint256 held,) = PROGRAM.exposure();
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
    ///      at the venue, rounded up. Nothing moves: the claim in current is dropped with the funds it stood for, so
    ///      issuerFunds stays the same in both tokens.
    function _carryIssuerDebt(ILineVenue venue, address current, address next) private {
        uint256 owed = advanceOf[current];
        if (owed == 0) return;
        uint256 carried = venue.quoteOut(next, current, owed);
        advanceOf[current] = 0;
        _funds[current] -= owed;
        advanceOf[next] += carried;
        _funds[next] += carried;
        emit IssuerDebtCarried(current, owed, next, carried);
    }

    /// @dev Requires the settlement account, the issuer or a treasury operator, counting value against the operator's
    ///      cap, and returns the settlement account.
    function _treasuryCaller(uint256 value) private returns (address account) {
        account = PROGRAM.SETTLEMENT_ACCOUNT();
        if (msg.sender == account || msg.sender == PROGRAM.ISSUER()) return account;
        if (!PROGRAM.hasRoles(msg.sender, PROGRAM.ROLE_TREASURY())) revert NotIssuer();
        if (value != 0) PROGRAM.useOperatorCap(msg.sender, value);
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
