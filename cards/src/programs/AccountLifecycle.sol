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
///         account's debt first, then the payee. The owner closes its own account; the registrar marks estates and
///         remits unclaimed property; the executor settles an estate.
/// @dev An account enrolls with its own key and approves this contract to move its cash and shares. Payouts take
///      only what the reservation core reports available, so holds and liens stay where they are. Debt is repaid
///      the way the core repays it from any credit: the cash first lands on the account itself.
contract AccountLifecycle {
    using SafeTransferLib for address;

    enum Status {
        None,
        Active,
        Dormant,
        Closed,
        Estate
    }

    struct Account {
        Status status;
        uint64 lastActive;
        address executor;
    }

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);

    /// @notice The settlement token whose balances and debt the lifecycle pays out.
    address public immutable TOKEN;
    /// @notice The registrar: marks estates and remits unclaimed property.
    address public immutable REGISTRAR;
    /// @notice The registry of keys that sign for an account; zero lets only the account's own key sign.
    address public immutable ACCOUNT_KEYS;
    /// @notice Seconds without card activity after which anyone may mark an account dormant.
    uint64 public immutable DORMANCY;
    /// @notice Seconds without activity after which a dormant account's money is unclaimed property.
    uint64 public immutable ESCHEAT_AFTER;

    mapping(address account => Account) internal _accounts;
    /// @notice Card programs whose card activity keeps accounts active.
    mapping(address program => bool) public programs;

    event Enrolled(address indexed account);
    event StatusSet(address indexed account, Status status);
    event EstateSet(address indexed account, address indexed executor);
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
    error NotExecutor();
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
        // Timestamps fit 64 bits for billions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.lastActive = uint64(block.timestamp);
        emit Enrolled(msg.sender);
        _setStatus(msg.sender, a, Status.Active);
    }

    /// @notice The registrar counts a card program's activity, or stops counting it.
    function setProgram(address program, bool counted) external onlyRegistrar {
        programs[program] = counted;
        emit ProgramSet(program, counted);
    }

    /// @notice Records card activity on an account and returns its status. Only a registered program counts; any
    ///         other caller reads the status unchanged.
    function noteActivity(address account) external returns (Status) {
        Account storage a = _accounts[account];
        // Timestamps fit 64 bits for billions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (programs[msg.sender]) a.lastActive = uint64(block.timestamp);
        return a.status;
    }

    /// @notice Marks an active account dormant once it has been idle for the dormancy period. Anyone may call it.
    function markDormant(address account) external {
        Account storage a = _accounts[account];
        if (a.status != Status.Active) revert AccountState(a.status);
        // Dormancy is measured in days; a few seconds of validator skew does not change it.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < uint256(a.lastActive) + DORMANCY) revert TooEarly();
        _setStatus(account, a, Status.Dormant);
    }

    /// @notice The owner brings a dormant account back, which counts as activity.
    function reactivate(address account) external {
        _requireOwner(account);
        Account storage a = _accounts[account];
        if (a.status != Status.Dormant) revert AccountState(a.status);
        // Timestamps fit 64 bits for billions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.lastActive = uint64(block.timestamp);
        _setStatus(account, a, Status.Active);
    }

    /// @notice The owner closes its account and pays out what it can release. Later calls pay out what expiries,
    ///         refunds and lien releases freed since. An estate closes only through its executor.
    function closeAccount(address account, address to, address[] calldata vaults) external returns (uint256 paid) {
        _requireOwner(account);
        Account storage a = _accounts[account];
        if (a.status == Status.Estate) revert AccountState(a.status);
        if (a.status != Status.Closed) _setStatus(account, a, Status.Closed);
        return _payOut(account, to, vaults);
    }

    /// @notice The registrar records the account holder's death: new holds stop and only the executor settles it.
    function setEstate(address account, address executor) external onlyRegistrar {
        if (executor == address(0)) revert ZeroAddress();
        Account storage a = _accounts[account];
        if (a.status == Status.Closed) revert AccountState(a.status);
        a.executor = executor;
        emit EstateSet(account, executor);
        _setStatus(account, a, Status.Estate);
    }

    /// @notice The executor settles the estate once no hold is open: the account's debts, then the payee. It closes.
    function settleEstate(address account, address to, address[] calldata vaults) external returns (uint256 paid) {
        Account storage a = _accounts[account];
        if (a.status != Status.Estate) revert AccountState(a.status);
        if (msg.sender != a.executor) revert NotExecutor();
        if (_holding(account, TOKEN)) revert HoldsOpen();
        // The executor names the vaults; each read only checks the estate has no open hold.
        // forge-lint: disable-start(calls-loop)
        for (uint256 i; i < vaults.length; ++i) {
            if (_holding(account, IEarnVault(vaults[i]).earnShare())) revert HoldsOpen();
        }
        // forge-lint: disable-end(calls-loop)
        paid = _payOut(account, to, vaults);
        _setStatus(account, a, Status.Closed);
    }

    /// @notice The registrar remits a dormant account idle past the escheat period to the authority.
    function escheat(address account, address authority, address[] calldata vaults)
        external
        onlyRegistrar
        returns (uint256 paid)
    {
        Account storage a = _accounts[account];
        if (a.status != Status.Dormant) revert AccountState(a.status);
        // Escheat periods are measured in years; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < uint256(a.lastActive) + ESCHEAT_AFTER) revert NotUnclaimed();
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

    function _requireOwner(address account) private view {
        if (msg.sender == account) return;
        address keys = ACCOUNT_KEYS;
        if (keys == address(0) || !AccountKeys(keys).signsFor(account, msg.sender)) revert NotOwner();
    }

    /// @dev Live holds: what the core reserves beyond liens.
    function _holding(address account, address token) private view returns (bool) {
        // Reads of the reservation core, also made once per vault the caller names.
        // forge-lint: disable-next-line(calls-loop)
        return CORE.reserved(account, token) > CORE.liened(account, token);
    }

    /// @dev Whoever calls already chooses the payee, so the vaults they name give them no further reach over the
    ///      account's money. Moves only what the core reports available.
    // Moves from the account it pays out, which approved this contract when it enrolled; every caller is checked.
    // forge-lint: disable-start(arbitrary-send-erc20)
    function _payOut(address account, address to, address[] calldata vaults) private returns (uint256 paid) {
        if (to == address(0) || to == account) revert InvalidPayee();
        address token = TOKEN;
        (, uint128 debt) = CORE.debtOf(account, token);
        (, uint128 toDebt) = CORE.debtOf(to, token);

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
        (, uint128 owed) = CORE.debtOf(account, token);
        uint256 free = CORE.available(account, token);
        if (owed != 0 && free != 0) token.safeTransferFrom(account, account, owed < free ? owed : free);
        paid = CORE.available(account, token);
        if (paid != 0) token.safeTransferFrom(account, to, paid);

        (, uint128 debtAfter) = CORE.debtOf(account, token);
        (, uint128 toDebtAfter) = CORE.debtOf(to, token);
        uint256 repaid = debt > debtAfter ? debt - debtAfter : 0;
        uint256 received = toDebt > toDebtAfter ? toDebt - toDebtAfter : 0;
        if (paid != 0 || repaid != 0 || savings != 0) emit PaidOut(account, to, paid, repaid, received, savings);
    }
    // forge-lint: disable-end(arbitrary-send-erc20)
}
