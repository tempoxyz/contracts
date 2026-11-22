// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CreditSource } from "./CreditSource.sol";
import { IMidRate, IssuerTreasury } from "./IssuerTreasury.sol";
import { ICardAuth } from "./interfaces/ICardAuth.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";
import { ISettlementTokenGuard } from "./interfaces/ISettlementTokenGuard.sol";

/// @title IssuerDesk
/// @notice The issuer's dispute desk for one card authorization contract (PROGRAM): provisional credit from the
///         settlement account while a dispute runs, and its recovery when the merchant wins. Provisional credit on a
///         purchase a credit line paid repays that line, tied to the purchase so a merchant win draws it again; the
///         rest lands as cash. A refund while a dispute runs settles provisional credit first, so the cardholder is
///         never paid twice. Fees, splits and rewards are netted off chain from the program's events.
/// @dev Dispute amounts are in the units the purchase was booked in; what the desk pays moves in today's settlement
///      token at the program's reference rate.
/// @custom:reentrancy-guard _locked
contract IssuerDesk is ISettlementTokenGuard {
    using FixedPointMathLib for uint256;

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    uint8 public constant OPENED = 1;
    uint8 public constant PROVISIONAL_CREDIT = 2;
    uint8 public constant REPRESENTMENT = 3;
    uint8 public constant PRE_ARBITRATION = 4;
    uint8 public constant ARBITRATION = 5;
    uint8 public constant WON = 6;
    uint8 public constant LOST = 7;
    uint256 private constant RATE_ONE = 1e18;
    /// @dev The settlement-token-in-use reason for an open dispute.
    uint8 private constant IN_USE_DISPUTES = 4;

    ICardAuth public immutable PROGRAM;
    /// @notice The program's credit lines, whose draws provisional credit repays.
    CreditSource public immutable CREDIT;
    /// @notice Advances what the settlement account lacks.
    IssuerTreasury public immutable TREASURY;
    /// @notice The Earn vault whose free shares a merchant win takes back after the cardholder's cash.
    IEarnVault public immutable SAVINGS;

    /// @notice A dispute on one purchase, in its booked units. lineRepaid and lineLanded are the credit leg's share of
    ///         provisional credit so far: what repaid its line, and what landed as cash past what the line owed.
    struct Dispute {
        address owner;
        uint8 state;
        uint128 amount;
        uint128 provisional;
        uint128 collected;
        uint128 lineRepaid;
        uint128 lineLanded;
        bytes32 creditLeg;
    }

    mapping(bytes32 ref => Dispute) internal _disputes;
    /// @notice What a cardholder still owes the settlement account, in a token, from merchant wins the desk could not
    ///         take back because the cardholder revoked the desk or lacked free funds.
    mapping(address owner => mapping(address token => uint256)) public receivables;
    uint256 public openDisputes;
    uint64 internal _charges;

    bool private transient _locked;

    event DisputeOpened(bytes32 indexed ref, address indexed owner, uint128 amount, bytes evidence);
    /// @notice A step: the provisional credit it gave, and what of it repaid a credit line.
    event DisputeStepped(
        bytes32 indexed ref, uint8 state, uint128 provisional, uint128 onLine, bytes evidence, bool byMerchant
    );
    /// @notice An end: the refund a cardholder win paid, or minus the provisional credit a merchant win took back, the
    ///         part of it a credit line drew again, what the cardholder still owes as a receivable, and the network
    ///         chargeback.
    event DisputeResolved(
        bytes32 indexed ref, bool cardholderWins, int256 credit, uint128 redrawn, uint128 receivable, uint128 chargeback
    );
    /// @notice A refund while the dispute ran settled this much provisional credit instead of paying it again.
    event DisputeSettled(bytes32 indexed ref, uint128 settled);
    event ReserveCollectedFor(bytes32 indexed ref, uint128 amount);
    /// @notice A merchant win left this much owed by the cardholder, for the desk to collect later.
    event ReceivableRecorded(bytes32 indexed ref, address indexed owner, address token, uint256 amount);
    event ReceivableCollected(address indexed owner, address token, uint256 amount);

    error DisputeExists();
    error DisputeTooLarge();
    error InvalidDisputeStep();
    error NoDispute();
    error NotOperator();
    error Reentrancy();
    error ReserveTooLarge();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(ICardAuth program, CreditSource credit, IssuerTreasury treasury, IEarnVault savings) {
        (PROGRAM, CREDIT, TREASURY, SAVINGS) = (program, credit, treasury, savings);
    }

    // Every entry point that moves money holds the transient lock for its whole call; the program and the core it
    // calls are fixed.
    // forge-lint: disable-start(reentrancy-no-eth)

    /// @notice Opens a dispute on a captured purchase for at most what it captured and has not refunded.
    function openDispute(bytes32 ref, uint128 amount, bytes calldata evidence) external nonReentrant {
        _operator(0);
        Dispute storage d = _disputes[ref];
        if (d.state != 0) revert DisputeExists();
        (uint128 open, address owner) = _open(ref);
        if (amount == 0 || amount > open) revert DisputeTooLarge();
        (d.owner, d.state, d.amount, d.creditLeg) = (owner, OPENED, amount, _creditLeg(ref));
        ++openDisputes;
        emit DisputeOpened(ref, owner, amount, evidence);
    }

    /// @notice Moves a dispute forward with evidence, giving provisional credit from the settlement account. Refunds
    ///         and provisional credit together never return more than the purchase, nor provisional credit more than
    ///         the dispute. The credit leg's share repays its line; the rest lands as cash.
    function disputeStep(bytes32 ref, uint8 state, uint128 provisional, bytes calldata evidence, bool byMerchant)
        external
        nonReentrant
    {
        _operator(provisional);
        Dispute storage d = _live(ref);
        if (state <= d.state || state < PROVISIONAL_CREDIT || state > ARBITRATION) revert InvalidDisputeStep();
        (uint128 open,) = _open(ref);
        uint128 cap = d.amount < open ? d.amount : open;
        if (d.provisional + provisional > cap) revert DisputeTooLarge();
        d.state = state;
        uint128 onLine;
        if (provisional != 0) {
            onLine = _repayLine(ref, d, provisional, open);
            d.provisional += provisional;
            uint128 cash = provisional - onLine;
            if (cash != 0) _credit(ref, d.owner, cash);
        }
        emit DisputeStepped(ref, state, provisional, onLine, evidence, byMerchant);
    }

    /// @notice Ends a dispute. A merchant win takes the provisional credit back: the line draws again what it repaid,
    ///         then the cardholder's free settlement token, then its free savings shares, and the rest stays owed to the
    ///         settlement account as a receivable, without a fee. A cardholder win counts as a refund of the dispute: the program
    ///         refunds what provisional credit did not cover through the purchase's sources, the credit kept counts as
    ///         refunded, and the network is charged back all of it but what merchant reserves already paid.
    function resolveDispute(bytes32 ref, bool cardholderWins) external nonReentrant {
        Dispute storage d = _live(ref);
        uint128 provisional = d.provisional;
        --openDisputes;
        if (!cardholderWins) {
            _operator(provisional);
            d.state = LOST;
            uint128 redrawn = _redrawLine(ref, d);
            uint128 owed = provisional > redrawn ? _recover(ref, d.owner, provisional - redrawn) : 0;
            emit DisputeResolved(ref, false, -int256(uint256(provisional)), redrawn, owed, 0);
            return;
        }
        d.state = WON;
        // What provisional credit repaid on the line stays repaid: nothing draws it again.
        if (d.lineRepaid != 0) CREDIT.limitRedraw(CREDIT.legOf(d.owner, d.creditLeg).lineId, ref, 0);
        (uint128 open,) = _open(ref);
        uint128 credited = d.amount < open ? d.amount : open;
        uint128 rest = credited > provisional ? credited - provisional : 0;
        _operator(rest);
        uint128 recovered = credited > d.collected ? d.collected : credited;
        uint128 chargeback = credited - recovered;
        if (rest != 0) _refund(ref, rest);
        // The credit the cardholder keeps counts as refunded too: it frees usage and settles the refund cap. Settlement
        // nets only the chargeback, since what merchant reserves paid the issuer never comes back through the network.
        uint128 kept = credited - rest;
        // Both are at most the dispute's amount, which a uint64 purchase bounds, so both fit int128.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (kept != 0 || recovered != 0) PROGRAM.creditBack(ref, kept, int128(kept) - int128(recovered));
        emit DisputeResolved(ref, true, int256(uint256(rest)), 0, 0, chargeback);
    }

    /// @notice Refunds units of a purchase (corrections of overcharges too). While a dispute on it runs, the part past
    ///         what the purchase still nets once provisional credit counts settles that credit, which the cardholder
    ///         already holds, so it moves no money and the program still counts it as refunded.
    function refund(bytes32 ref, uint128 units) external nonReentrant {
        _operator(units);
        uint128 settled;
        Dispute storage d = _disputes[ref];
        if (d.state != 0 && d.state < WON && d.provisional != 0) {
            (uint128 open,) = _open(ref);
            uint256 over = uint256(units) + d.provisional;
            if (over > open) {
                // At most units + provisional; capped at both below.
                // forge-lint: disable-next-line(unsafe-typecast)
                settled = uint128(over - open);
                if (settled > d.provisional) settled = d.provisional;
                if (settled > units) settled = units;
                d.provisional -= settled;
                // A line share that settles stays repaid, so a merchant win never draws it again.
                if (d.lineRepaid > d.provisional) {
                    d.lineRepaid = d.provisional;
                    CREDIT.limitRedraw(CREDIT.legOf(d.owner, d.creditLeg).lineId, ref, d.provisional);
                }
                emit DisputeSettled(ref, settled);
            }
        }
        if (units > settled) _refund(ref, units - settled);
        // At most the provisional credit, which a uint64 purchase bounds.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (settled != 0) PROGRAM.creditBack(ref, settled, int128(settled));
    }

    /// @notice Records what the issuer collected from merchant reserves toward an open dispute, which a cardholder win
    ///         leaves out of the chargeback: never more for one dispute than the dispute, nor than the purchase still
    ///         has unrefunded.
    function collectedReserve(bytes32 ref, uint128 amount) external {
        _operator(amount);
        Dispute storage d = _live(ref);
        (uint128 open,) = _open(ref);
        uint256 collected = uint256(d.collected) + amount;
        if (collected > d.amount || collected > open) revert ReserveTooLarge();
        // At most the dispute's amount, a uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        d.collected = uint128(collected);
        emit ReserveCollectedFor(ref, amount);
    }

    /// @notice Collects up to amount of what owner owes the settlement account in token, from its free funds only.
    ///         Issuer or settle operators. Returns what it collected.
    function collectReceivable(address owner, address token, uint128 amount) external nonReentrant returns (uint128) {
        _operator(0);
        uint256 owed = receivables[owner][token];
        uint256 free = CORE.available(owner, token);
        // Below amount, so it fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (amount > owed) amount = uint128(owed);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (amount > free) amount = uint128(free);
        if (amount == 0) return 0;
        receivables[owner][token] = owed - amount;
        CORE.charge(owner, token, _chargeId(), amount, PROGRAM.SETTLEMENT_ACCOUNT());
        emit ReceivableCollected(owner, token, amount);
        return amount;
    }

    function disputeOf(bytes32 ref) external view returns (Dispute memory) {
        return _disputes[ref];
    }

    /// @notice What a cardholder win would refund now, past the provisional credit.
    function winRefund(bytes32 ref) external view returns (uint128) {
        Dispute storage d = _disputes[ref];
        (uint128 open,) = _open(ref);
        uint128 credited = d.amount < open ? d.amount : open;
        return credited > d.provisional ? credited - d.provisional : 0;
    }

    /// @notice An open dispute is sized in the settlement token, so the token waits for it to resolve (reason 4).
    function settlementTokenInUse(address) external view returns (uint8) {
        return openDisputes != 0 ? IN_USE_DISPUTES : 0;
    }

    /// @dev The caller must be the issuer or a settle operator, which counts value against its cap.
    function _operator(uint256 value) private {
        if (msg.sender == PROGRAM.ISSUER()) return;
        if (!PROGRAM.hasRoles(msg.sender, PROGRAM.ROLE_SETTLE())) revert NotOperator();
        if (value != 0) PROGRAM.useOperatorCap(msg.sender, value);
    }

    function _live(bytes32 ref) private view returns (Dispute storage d) {
        d = _disputes[ref];
        if (d.state == 0 || d.state >= WON) revert NoDispute();
    }

    function _open(bytes32 ref) private view returns (uint128 open, address owner) {
        ICardAuth.PurchaseView memory p = PROGRAM.purchaseOf(ref);
        owner = p.owner;
        open = p.captured > p.refunded ? p.captured - p.refunded : 0;
    }

    /// @dev The purchase's leg on this desk's credit lines, if one paid part of it.
    function _creditLeg(bytes32 ref) private view returns (bytes32) {
        (address[] memory sources,, bytes32[] memory legIds) = PROGRAM.legsOf(ref);
        for (uint256 i; i < sources.length; ++i) {
            if (sources[i] == address(CREDIT)) return legIds[i];
        }
        return bytes32(0);
    }

    /// @dev Booked units of ref in today's settlement token at the reference rate, rounded up, and that token.
    function _today(bytes32 ref, uint256 units) private view returns (uint256, address token) {
        token = PROGRAM.settlementToken();
        address booked = PROGRAM.purchaseOf(ref).token;
        if (booked == token || booked == address(0)) return (units, token);
        return (units.mulDivUp(IMidRate(PROGRAM.conversion()).mid(booked, token), RATE_ONE), token);
    }

    /// @dev Gives the credit leg its share of all provisional credit so far, less what earlier steps gave it, so steps
    ///      add up to one split. Only what the line owes repays it, tied to the purchase; the rest of the share lands
    ///      as cash and still counts toward it. Returns what repaid the line.
    function _repayLine(bytes32 ref, Dispute storage d, uint128 amount, uint128 open) private returns (uint128 pay) {
        if (d.creditLeg == bytes32(0) || open == 0) return 0;
        CreditSource.Leg memory leg = CREDIT.legOf(d.owner, d.creditLeg);
        CreditSource.Line memory line = CREDIT.lineOf(leg.lineId);
        address token = PROGRAM.settlementToken();
        // A line in an earlier settlement token takes its share as cash.
        if (line.token != token || PROGRAM.purchaseOf(ref).token != token) return 0;
        uint256 drawn = leg.gross;
        uint256 given = uint256(d.lineRepaid) + d.lineLanded;
        if (drawn <= given) return 0;
        uint256 target = (uint256(d.provisional) + amount) * drawn / open;
        if (target <= given) return 0;
        uint256 share = _min(_min(target - given, drawn - given), amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        pay = uint128(_min(share, line.owed));
        // Both at most amount, a uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        (d.lineRepaid, d.lineLanded) = (d.lineRepaid + pay, d.lineLanded + uint128(share - pay));
        if (pay == 0) return 0;
        _fromSettlement(token, address(this), pay);
        SafeTransferLib.safeApprove(token, address(CREDIT), pay);
        CREDIT.repayFor(leg.lineId, pay, ref);
    }

    /// @dev On a merchant win, draws the line again for what provisional credit repaid on it, as far as its lender can
    ///      fund it, the lender paying the settlement account.
    function _redrawLine(bytes32 ref, Dispute storage d) private returns (uint128 drawn) {
        uint128 want = d.lineRepaid;
        if (want == 0) return 0;
        d.lineRepaid = 0;
        uint64 lineId = CREDIT.legOf(d.owner, d.creditLeg).lineId;
        uint256 left = CREDIT.redrawable(lineId, ref);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (left < want) want = uint128(left);
        // A redraw the lender refuses (its budget, funds or commitment) leaves the line repaid; the cardholder owes the
        // rest like any other recovery, so the merchant's win always closes.
        if (want != 0) {
            try CREDIT.redraw(lineId, want, ref) returns (uint128 redrawn) {
                drawn = redrawn;
            } catch { }
        }
        // What the merchant's win did not draw again stays repaid.
        CREDIT.limitRedraw(lineId, ref, 0);
    }

    /// @dev Pays units of ref in today's token to owner from the settlement account (the treasury advancing what it
    ///      lacks).
    function _credit(bytes32 ref, address owner, uint128 units) private {
        (uint256 amount, address token) = _today(ref, units);
        _fromSettlement(token, owner, amount);
    }

    /// @dev Refunds units of ref through the program, which takes today's token from this desk, funded by the
    ///      settlement account; what the program leaves goes back to it.
    function _refund(bytes32 ref, uint128 units) private {
        (uint256 amount, address token) = _today(ref, units);
        _fromSettlement(token, address(this), amount);
        SafeTransferLib.safeApprove(token, address(PROGRAM), amount);
        PROGRAM.refund(ref, units);
        SafeTransferLib.safeApprove(token, address(PROGRAM), 0);
        uint256 left = SafeTransferLib.balanceOf(token, address(this));
        if (left != 0) SafeTransferLib.safeTransfer(token, PROGRAM.SETTLEMENT_ACCOUNT(), left);
    }

    // Takes only from the program's settlement account, which approved this desk to pay provisional credit and refunds.
    // forge-lint: disable-next-item(arbitrary-send-erc20)
    function _fromSettlement(address token, address to, uint256 amount) private {
        address account = PROGRAM.SETTLEMENT_ACCOUNT();
        if (amount <= CORE.available(account, token)) SafeTransferLib.safeTransferFrom(token, account, to, amount);
        else TREASURY.payOut(to, amount, bytes32(0));
    }

    /// @dev Takes units of ref back from owner in today's token: its free cash, then its free savings shares redeemed
    ///      to the settlement account, never a credit line. What that leaves, or what the core refuses (the owner
    ///      revoked the desk), stays owed as a receivable, so the dispute still closes. Returns what remains owed.
    // forge-lint: disable-next-item(unsafe-typecast)
    function _recover(bytes32 ref, address owner, uint128 units) private returns (uint128) {
        (uint256 amount, address token) = _today(ref, units);
        uint256 free = CORE.available(owner, token);
        uint256 cash = free < amount ? free : amount;
        uint256 rest = amount - cash;
        if (rest != 0 && address(SAVINGS) != address(0) && SAVINGS.asset() == token) rest -= _takeShares(owner, rest);
        if (cash != 0) {
            try CORE.charge(owner, token, _chargeId(), uint128(cash), PROGRAM.SETTLEMENT_ACCOUNT()) { }
            catch {
                rest += cash;
            }
        }
        if (rest == 0) return 0;
        receivables[owner][token] += rest;
        emit ReceivableRecorded(ref, owner, token, rest);
        return uint128(rest);
    }

    /// @dev Takes up to need's worth of owner's free savings shares and redeems them to the settlement account.
    // forge-lint: disable-next-item(reentrancy-no-eth,unsafe-typecast)
    function _takeShares(address owner, uint256 need) private returns (uint256 taken) {
        IEarnVault vault = SAVINGS;
        address share = vault.earnShare();
        uint256 shares = CORE.available(owner, share);
        if (shares == 0) return 0;
        uint256 value = vault.previewRedeem(shares);
        if (value > need) {
            uint256 wanted = vault.previewWithdraw(need);
            if (wanted < shares) (shares, value) = (wanted, vault.previewRedeem(wanted));
        }
        if (shares == 0 || value == 0) return 0;
        // The owner may have revoked the desk for its shares; then its cash or a receivable covers the rest.
        try CORE.charge(owner, share, _chargeId(), uint128(shares), address(this)) { }
        catch {
            return 0;
        }
        SafeTransferLib.safeApprove(share, address(vault), shares);
        value = vault.redeem(shares, PROGRAM.SETTLEMENT_ACCOUNT(), value);
        taken = value < need ? value : need;
    }

    function _chargeId() private returns (bytes32) {
        return keccak256(abi.encode("tempo.cards.desk", address(this), ++_charges));
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
    // forge-lint: disable-end(reentrancy-no-eth)
}
