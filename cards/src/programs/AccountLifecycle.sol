// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { AccountKeys } from "./AccountKeys.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";

/// @title AccountLifecycle
/// @notice An account's standing across every card program on one settlement token: active, dormant, closed or an
///         estate. Programs read it at authorization and report card activity to it. It pays out what an account
///         can release (available cash, plus the available shares of the vaults the caller names, redeemed): the
///         account's debt first, then the payee. The owner closes its own account; the registrar records estates and
///         remits unclaimed property, each only after a notice period the owner can end by acting; the executor
///         settles an estate to itself.
/// @dev An account enrolls with its own key and approves this contract to move its cash and shares. Payouts take
///      only what the reservation core reports available, so holds and liens stay where they are. Debt is repaid
///      the way the core repays it from any credit: the cash first lands on the account itself.
///
///      Owner activity the lifecycle sees, which ends a pending notice: the owner's own calls here (enroll,
///      reactivate, nameExecutor, and closeAccount for a dormant account, signed by the account or a key AccountKeys
///      lists for it). Card
///      activity reported by counted programs (noteActivity) keeps an account from turning dormant and voids an
///      escheat notice given before it; it does not end an estate notice, since programs report issuer-driven events
///      such as merchant authorizations. Other transactions the account sends are not seen: Tempo's protocol nonce
///      cannot be read from a contract.
contract AccountLifecycle {
    using SafeTransferLib for address;

    enum Status {
        None,
        Active,
        Dormant,
        Closed,
        Estate
    }

    /// @param status The account's standing.
    /// @param lastActive When the account last showed activity: enrollment, an owner call or counted card activity.
    /// @param executor The estate's executor, recorded when the registrar starts the estate notice.
    /// @param noticeAt When the pending estate or escheat notice started; zero for none.
    /// @param namedExecutor The executor the owner accepts for its estate while the account is active.
    /// @param authority Where an escheat pays, fixed when the escheat notice started.
    struct Account {
        Status status;
        uint64 lastActive;
        address executor;
        uint64 noticeAt;
        address namedExecutor;
        address authority;
    }

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);

    /// @notice Seconds between the registrar recording an estate and the executor settling it.
    uint64 public constant ESTATE_NOTICE = 30 days;
    /// @notice Seconds between an escheat notice and the remittance it allows.
    uint64 public constant ESCHEAT_NOTICE = 90 days;

    /// @notice The settlement token whose balances and debt the lifecycle pays out.
    address public immutable TOKEN;
    /// @notice The registrar: records estates and remits unclaimed property.
    address public immutable REGISTRAR;
    /// @notice The registry of keys that sign for an account; zero lets only the account's own key sign.
    address public immutable ACCOUNT_KEYS;
    /// @notice Seconds without activity after which anyone may mark an account dormant.
    uint64 public immutable DORMANCY;
    /// @notice Seconds without activity after which a dormant account's money is unclaimed property.
    uint64 public immutable ESCHEAT_AFTER;

    mapping(address account => Account) internal _accounts;
    /// @notice Card programs whose card activity keeps accounts active.
    mapping(address program => bool) public programs;
    /// @notice The unclaimed property authority a dormancy mark names in its escheat notice; zero names none.
    address public escheatAuthority;

    event Enrolled(address indexed account);
    event StatusSet(address indexed account, Status status);
    event ExecutorNamed(address indexed account, address indexed executor);
    /// @notice The registrar recorded an estate; its executor may settle it from settlesAt.
    event EstateSet(address indexed account, address indexed executor, uint64 settlesAt);
    /// @notice An escheat notice naming authority; the account may be remitted from dueAt, once also idle long enough.
    event EscheatNoticed(address indexed account, address indexed authority, uint64 dueAt);
    /// @notice The owner acted, ending the pending estate or escheat notice.
    event NoticeCancelled(address indexed account);
    event EscheatAuthoritySet(address indexed authority);
    event ProgramSet(address indexed program, bool counted);
    /// @notice One payout: repaid of the account's debt, then amount to the payee, which repaid received of its own
    ///         debt on landing. Savings is what the redeemed shares added.
    event PaidOut(
        address indexed account, address indexed to, uint256 amount, uint256 repaid, uint256 received, uint256 savings
    );

    error AccountState(Status status);
    error HoldsOpen();
    error InvalidPayee();
    error InvalidVault(address vault);
    error NoNotice();
    error NotExecutor();
    error NotNamedExecutor();
    error NotOwner();
    error NotRegistrar();
    error NotUnclaimed();
    error TooEarly();
    error ZeroAddress();

    // A zero account-key registry is allowed: only the account's own key then signs for it.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(address token, address registrar, address accountKeys, uint64 dormancy, uint64 escheatAfter) {
        if (token == address(0) || registrar == address(0)) revert ZeroAddress();
        TOKEN = token;
        REGISTRAR = registrar;
        ACCOUNT_KEYS = accountKeys;
        DORMANCY = dormancy;
        ESCHEAT_AFTER = escheatAfter;
    }

    modifier onlyRegistrar() {
        if (msg.sender != REGISTRAR) revert NotRegistrar();
        _;
    }

    // Accounts.

    /// @notice Starts the caller's lifecycle as an active account, which counts as activity.
    function enroll() external {
        Account storage a = _accounts[msg.sender];
        if (a.status != Status.None) revert AccountState(a.status);
        a.lastActive = _now();
        emit Enrolled(msg.sender);
        _setStatus(msg.sender, a, Status.Active);
    }

    /// @notice The registrar counts a card program's activity, or stops counting it.
    function setProgram(address program, bool counted) external onlyRegistrar {
        programs[program] = counted;
        emit ProgramSet(program, counted);
    }

    /// @notice The registrar sets the authority later dormancy marks name in their escheat notice; zero names none.
    // Zero is how the registrar stops naming a default authority.
    // forge-lint: disable-next-line(missing-zero-check)
    function setEscheatAuthority(address authority) external onlyRegistrar {
        escheatAuthority = authority;
        emit EscheatAuthoritySet(authority);
    }

    /// @notice Records card activity on an account and returns its status. Only a registered program counts; any
    ///         other caller reads the status unchanged. Activity after an escheat notice voids that notice.
    function noteActivity(address account) external returns (Status) {
        Account storage a = _accounts[account];
        if (programs[msg.sender]) a.lastActive = _now();
        return a.status;
    }

    /// @notice Marks an active account dormant once it has been idle for the dormancy period, which starts an escheat
    ///         notice naming the registrar's escheat authority. Anyone may call it.
    function markDormant(address account) external {
        Account storage a = _accounts[account];
        if (a.status != Status.Active) revert AccountState(a.status);
        // Dormancy is measured in days; a few seconds of validator skew does not change it.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < uint256(a.lastActive) + DORMANCY) revert TooEarly();
        _setStatus(account, a, Status.Dormant);
        address authority = escheatAuthority;
        if (authority != address(0) && authority != account) _notice(account, a, authority);
    }

    /// @notice The owner brings a dormant account back, or cancels an estate still in its notice period. Either counts
    ///         as activity and ends the pending notice.
    function reactivate(address account) external {
        _requireOwner(account);
        Account storage a = _accounts[account];
        if (a.status != Status.Dormant && a.status != Status.Estate) revert AccountState(a.status);
        _ownerActs(account, a);
        _setStatus(account, a, Status.Active);
    }

    /// @notice The owner names the executor it accepts for its estate, or zero for none. Like any owner call it counts
    ///         as activity: it brings back a dormant account and cancels an estate still in its notice period.
    // Zero is how the owner withdraws its consent.
    // forge-lint: disable-next-line(missing-zero-check)
    function nameExecutor(address account, address executor) external {
        _requireOwner(account);
        if (executor == account) revert InvalidPayee();
        Account storage a = _accounts[account];
        Status was = _ownerActs(account, a);
        a.namedExecutor = executor;
        emit ExecutorNamed(account, executor);
        if (was != Status.Active) _setStatus(account, a, Status.Active);
    }

    /// @notice The owner closes its account and pays out what it can release. Later calls pay out what expiries,
    ///         refunds and lien releases freed since. An estate does not close this way: during its notice period the
    ///         owner first cancels it with reactivate, and after it only the executor settles it.
    function closeAccount(address account, address to, address[] calldata vaults) external returns (uint256 paid) {
        _requireOwner(account);
        Account storage a = _accounts[account];
        Status status = a.status;
        if (status == Status.Estate) revert AccountState(status);
        if (status != Status.Closed) {
            _clearNotice(account, a);
            _setStatus(account, a, Status.Closed);
        }
        return _payOut(account, to, vaults);
    }

    /// @notice The registrar records the account holder's death, naming the executor: the executor the owner named
    ///         for an active account, or anyone for a dormant one. New holds stop at once; the executor settles the
    ///         estate after the notice period, unless the owner acts first.
    function setEstate(address account, address executor) external onlyRegistrar {
        if (executor == address(0)) revert ZeroAddress();
        if (executor == account) revert InvalidPayee();
        Account storage a = _accounts[account];
        if (a.status == Status.Active) {
            if (executor != a.namedExecutor) revert NotNamedExecutor();
        } else if (a.status != Status.Dormant) {
            revert AccountState(a.status);
        }
        uint64 at = _now();
        a.executor = executor;
        a.noticeAt = at;
        a.authority = address(0);
        emit EstateSet(account, executor, at + ESTATE_NOTICE);
        _setStatus(account, a, Status.Estate);
    }

    /// @notice The executor settles the estate to itself once the notice period has passed and no hold is open: the
    ///         account's debts, then the executor. It closes.
    function settleEstate(address account, address[] calldata vaults) external returns (uint256 paid) {
        Account storage a = _accounts[account];
        if (a.status != Status.Estate) revert AccountState(a.status);
        address executor = a.executor;
        if (msg.sender != executor) revert NotExecutor();
        if (_holding(account, TOKEN)) revert HoldsOpen();
        // The executor names the vaults; each read only checks the estate has no open hold.
        // forge-lint: disable-start(calls-loop)
        for (uint256 i; i < vaults.length; ++i) {
            if (_holding(account, IEarnVault(vaults[i]).earnShare())) revert HoldsOpen();
        }
        // forge-lint: disable-end(calls-loop)
        // Notice periods are measured in days; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < uint256(a.noticeAt) + ESTATE_NOTICE) revert TooEarly();
        a.noticeAt = 0;
        paid = _payOut(account, executor, vaults);
        _setStatus(account, a, Status.Closed);
    }

    /// @notice The registrar gives a dormant account an escheat notice naming the authority, replacing any earlier
    ///         notice; the escheat it allows waits the notice period from now.
    function noticeEscheat(address account, address authority) external onlyRegistrar {
        if (authority == address(0)) revert ZeroAddress();
        if (authority == account) revert InvalidPayee();
        Account storage a = _accounts[account];
        if (a.status != Status.Dormant) revert AccountState(a.status);
        _notice(account, a, authority);
    }

    /// @notice The registrar remits a dormant account to the authority its escheat notice named, once the notice
    ///         period has passed and the account has been idle past the escheat period. The notice is used up: a
    ///         later remittance needs a new one.
    function escheat(address account, address[] calldata vaults) external onlyRegistrar returns (uint256 paid) {
        Account storage a = _accounts[account];
        if (a.status != Status.Dormant) revert AccountState(a.status);
        uint64 noticeAt = a.noticeAt;
        address authority = a.authority;
        // Card activity after the notice voids it.
        if (noticeAt == 0 || authority == address(0) || a.lastActive > noticeAt) revert NoNotice();
        // Notice and escheat periods are measured in days and years; a few seconds of validator skew does not change
        // them.
        // forge-lint: disable-start(block-timestamp)
        if (block.timestamp < uint256(noticeAt) + ESCHEAT_NOTICE) revert TooEarly();
        if (block.timestamp < uint256(a.lastActive) + ESCHEAT_AFTER) revert NotUnclaimed();
        // forge-lint: disable-end(block-timestamp)
        a.noticeAt = 0;
        a.authority = address(0);
        return _payOut(account, authority, vaults);
    }

    // Views.

    function accountOf(address account) external view returns (Account memory) {
        return _accounts[account];
    }

    function statusOf(address account) external view returns (Status) {
        return _accounts[account].status;
    }

    // Internals.

    function _setStatus(address account, Account storage a, Status status) private {
        a.status = status;
        emit StatusSet(account, status);
    }

    /// @dev Starts an escheat notice naming authority.
    function _notice(address account, Account storage a, address authority) private {
        uint64 at = _now();
        a.noticeAt = at;
        a.authority = authority;
        emit EscheatNoticed(account, authority, at + ESCHEAT_NOTICE);
    }

    /// @dev The owner acted on an active or dormant account, or an estate still in its notice period: records the
    ///      activity and ends the pending notice. Returns the status it found.
    function _ownerActs(address account, Account storage a) private returns (Status status) {
        status = a.status;
        if (status == Status.Estate) {
            // Notice periods are measured in days; a few seconds of validator skew does not change them.
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp >= uint256(a.noticeAt) + ESTATE_NOTICE) revert AccountState(status);
            a.executor = address(0);
        } else if (status != Status.Active && status != Status.Dormant) {
            revert AccountState(status);
        }
        a.lastActive = _now();
        _clearNotice(account, a);
    }

    function _clearNotice(address account, Account storage a) private {
        if (a.noticeAt == 0) return;
        a.noticeAt = 0;
        a.authority = address(0);
        emit NoticeCancelled(account);
    }

    function _now() private view returns (uint64) {
        // Timestamps fit 64 bits for billions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(block.timestamp);
    }

    function _requireOwner(address account) private view {
        if (msg.sender == account) return;
        address keys = ACCOUNT_KEYS;
        if (keys == address(0) || !AccountKeys(keys).signsFor(account, msg.sender)) revert NotOwner();
    }

    /// @dev Live holds: anything the core reserves, which counts pledges and liens too.
    function _holding(address account, address token) private view returns (bool) {
        // A read of the reservation core, also made once per vault the caller names.
        // forge-lint: disable-next-line(calls-loop)
        return CORE.reserved(account, token) != 0;
    }

    /// @dev The payee is the owner's choice, the recorded executor or the noticed authority, so the vaults the caller
    ///      names give it no further reach over the account's money. Moves only what the core reports available.
    // Moves from the account it pays out, which approved this contract when it enrolled; every caller is checked.
    // forge-lint: disable-start(arbitrary-send-erc20)
    function _payOut(address account, address to, address[] calldata vaults) private returns (uint256 paid) {
        if (to == address(0) || to == account) revert InvalidPayee();
        address token = TOKEN;
        uint256 debt = _totalDebt(account, token);
        uint256 toDebt = _totalDebt(to, token);

        // Shares redeem to the account itself, so the core repays its debt from them as from any credit.
        uint256 savings;
        // The caller names a handful of vaults, and one that reverts only stops its own payout.
        // forge-lint: disable-start(calls-loop)
        for (uint256 i; i < vaults.length; ++i) {
            IEarnVault vault = IEarnVault(vaults[i]);
            if (vault.asset() != token) revert InvalidVault(address(vault));
            address share = vault.earnShare();
            uint256 shares = CORE.available(account, share);
            if (shares == 0) continue;
            share.safeTransferFrom(account, address(this), shares);
            share.safeApprove(address(vault), shares);
            savings += vault.redeem(shares, account, 1);
        }
        // forge-lint: disable-end(calls-loop)

        // Cash moved onto the account itself is a credit the core repays debt from first.
        uint256 owed = _totalDebt(account, token);
        uint256 free = CORE.available(account, token);
        if (owed != 0 && free != 0) token.safeTransferFrom(account, account, owed < free ? owed : free);
        paid = CORE.available(account, token);
        if (paid != 0) token.safeTransferFrom(account, to, paid);

        uint256 debtAfter = _totalDebt(account, token);
        uint256 toDebtAfter = _totalDebt(to, token);
        uint256 repaid = debt > debtAfter ? debt - debtAfter : 0;
        uint256 received = toDebt > toDebtAfter ? toDebt - toDebtAfter : 0;
        if (paid != 0 || repaid != 0 || savings != 0) emit PaidOut(account, to, paid, repaid, received, savings);
    }

    // forge-lint: disable-end(arbitrary-send-erc20)

    /// @dev What `owner` owes every creditor in `token`.
    function _totalDebt(address owner, address token) private view returns (uint256 sum) {
        IReservationCore.Debt[] memory debts = CORE.debtOf(owner, token);
        for (uint256 i; i < debts.length; ++i) {
            sum += debts[i].amount;
        }
    }
}
