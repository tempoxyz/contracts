// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { EarnFeeMath } from "./EarnFeeMath.sol";
import { IEarnFees } from "../../interfaces/earn/IEarnFees.sol";
import { IEarnShare } from "../../interfaces/earn/IEarnShare.sol";
import { IEarnVault } from "../../interfaces/earn/IEarnVault.sol";
import {
    DistributorConfig,
    DistributorFeeUpdate,
    EarnVaultControls,
    EngineMigrationMode
} from "../../interfaces/earn/EarnVaultTypes.sol";
import { FeeConfig, FixedFeeRecipient } from "../../interfaces/earn/EarnFeeTypes.sol";
import { IEarnEngine } from "../../interfaces/earn/engines/IEarnEngine.sol";
import { IEarnEngineAsyncRedeem } from "../../interfaces/earn/engines/IEarnEngineAsyncRedeem.sol";
import { IEarnEngineExactWithdraw } from "../../interfaces/earn/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineFeeValuation } from "../../interfaces/earn/engines/IEarnEngineFeeValuation.sol";
import { IEarnEngineHeldDeposit } from "../../interfaces/earn/engines/IEarnEngineHeldDeposit.sol";
import { IEarnEngineInKindDeposit } from "../../interfaces/earn/engines/IEarnEngineInKindDeposit.sol";
import { IEarnEngineRedeem } from "../../interfaces/earn/engines/IEarnEngineRedeem.sol";
import { IERC20Like } from "../../interfaces/external/IERC20Like.sol";
import { IERC20Allowance } from "../../interfaces/external/IERC20Allowance.sol";
import { IAsyncRedeemReceiver } from "../../interfaces/earn/IAsyncRedeemReceiver.sol";
import { IEarnVaultWithdrawCallback, IEarnWithdrawCallback } from "../../interfaces/earn/IEarnWithdrawCallback.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

/// @notice Persistent issuance, accounting, migration, and async-claim vault for one Earn deployment.
/// @dev The EarnVault is the exclusive EarnShare issuer and the single client of its current engine.
///      Engines hold venue shares; the EarnVault holds only in-flight assets. Its immutable `EarnFees`
///      module owns all fee state and fee EarnShare custody without receiving issuer authority.
///
///      Immediate exits pay receivers directly. An async request burns EarnShare immediately and removes
///      the queued engine shares from active NAV. Finalization forwards the fixed venue payout.
///      Cancellation measures returned backing and mints a fee-aware current-value re-entry to the
///      stored receiver. Contributions and active-pool fees may continue while claims are queued.
///
///      Each deployed EarnVault is a non-upgradeable ERC-1967 proxy pointing to the factory's fixed
///      implementation. The implementation is locked against direct initialization.
/// @dev The `@custom:` specs are checked by solar-verify and state the rules of docs/earn/architecture/system.md
///      and flows.md. Spec arithmetic is over mathematical integers. The `fixed*` ghosts record what
///      `initialize` set, so the invariants below say those fields never change afterwards; `trackedEngine`,
///      `trackedOperator` and `trackedDistributor` move only where the role handoff or migration writes them.
///      `openCount` mirrors every write that opens or closes a pending request (a nonzero `requester` marks it
///      open). `entered` mirrors the transient
///      `_entered` lock flag in ghost state, so invariants that hold only between locked calls can name it.
/// @custom:ghost address fixedAsset
/// @custom:ghost address fixedEarnShare
/// @custom:ghost address fixedEarnFees
/// @custom:ghost uint8 fixedEarnShareDecimals
/// @custom:ghost uint40 fixedDistributorUpdateDelay
/// @custom:ghost bool fixedOperatorMigration
/// @custom:ghost address trackedEngine
/// @custom:ghost address trackedOperator
/// @custom:ghost address trackedDistributor
/// @custom:ghost uint256 openCount
/// @custom:ghost uint256 feeCheckpoints
/// @custom:ghost uint256 baselineEntries
/// @custom:ghost uint256 cappedManagedShares
/// @custom:ghost bool entered
/// @custom:reentrancy-guard initialized && _entered
/// @custom:invariant entered ==> initialized
/// @custom:invariant !initialized ==> openCount == 0 && operator == address(0) && distributor == address(0)
/// @custom:invariant !initialized ==> pendingOperator == address(0) && pendingDistributor == address(0)
/// @custom:invariant !entered ==> _openRedeemRequestCount == openCount
/// @custom:invariant initialized ==> asset == fixedAsset && earnShare == fixedEarnShare && earnFees == fixedEarnFees
/// @custom:invariant initialized ==> _earnShareDecimals == fixedEarnShareDecimals && distributorUpdateDelay == fixedDistributorUpdateDelay
/// @custom:invariant initialized ==> (engineMigrationMode == EngineMigrationMode.OperatorEnabled) == fixedOperatorMigration
/// @custom:invariant initialized ==> engine == trackedEngine && operator == trackedOperator && distributor == trackedDistributor
/// @custom:invariant initialized ==> _anchorEarnShares != 0
/// @custom:invariant initialized ==> rewardRateBaseline() != 0 && _earnShareScale() != 0
/// @custom:invariant initialized ==> operator != address(0)
/// @custom:invariant (distributor == address(0)) == (distributorUpdateDelay == 0)
/// @custom:invariant pendingDistributor != address(0) ==> distributor != address(0)
/// @custom:invariant !_pendingDistributorFeeUpdate.pending ==> _specNoDistributorFeeUpdate()
/// @custom:invariant initialized && !entered ==> _specEmptyAnchor() || _managedEngineShares != 0
/// @custom:invariant forall bytes32 id :: _pending[id].requester != address(0) ==> _specLiveRequest(id)
/// @custom:invariant forall bytes32 id :: _pending[id].requester == address(0) ==> _specClosedRequest(id)
/// @dev Between calls the anchor is the managed engine-share count over the live supply (or the empty-pool
///      anchor), so the supply converts exactly to its managed backing. The anchor stores only its EarnShare side
///      beside the managed count, which is its engine-share side unless the anchor is the empty-pool one. An open
///      request holds a nonzero burned EarnShare amount, and a closed one holds no burned EarnShare, stored receiver
///      or fee-snapshot flag.
///      `feeCheckpoints` counts fee checkpoints, `baselineEntries` principal-entry baseline updates, and
///      `cappedManagedShares` is the managed count at the latest capacity check.
///      Not proved: the anchor's EarnShare side equals the live EarnShare supply between calls; the supply is
///      another contract's state, read only inside calls.
///      Not proved: this vault and EarnFees each keep the EarnShare unit {initialize} mints them, which
///      {_activeSupply} subtracts; balances are EarnShare's state.
///      Not proved: the engine still holds the queued engine shares of every open request and pays each at
///      least what it committed; both are the engine's state, and the vault does not store the queued count.
///      Not proved: fee EarnShare minted in a checkpoint never exceeds the positive accrual it charges; that
///      bound is EarnFees' own contract, which the vault reads only through its interface.
contract EarnVault is IEarnVault {
    uint256 internal constant CONVERSION_BPS = 10_000;
    /// @notice Maximum contribution-funded increase in the normalized engine-share/EarnShare rate.
    uint256 public constant override MAX_REWARD_RATE_MULTIPLIER = 100;
    /// @dev EarnShare base units {initialize} mints this vault and EarnFees each, for good.
    uint256 internal constant SHARE_RESIDUE = 1;
    /// @dev EarnShare base units that never count as supply: this vault's unit and EarnFees' unit.
    uint256 internal constant LOCKED_EARN_SHARES = 2 * SHARE_RESIDUE;
    /// @dev Stored EarnShare side of the empty-pool anchor, whose sides are {rewardRateBaseline} and the EarnShare
    ///      scale. A live anchor's EarnShare side is a supply below it ({_setAnchor}).
    uint256 internal constant EMPTY_ANCHOR = type(uint128).max;
    /// @dev Marks a packed reward-rate baseline that holds no value of its own: the value is in its wide slot.
    uint256 internal constant WIDE_RATE_BASELINE = type(uint96).max;
    uint8 internal constant CAP_REDEEM = 1;
    uint8 internal constant CAP_EXACT_WITHDRAW = 2;
    uint8 internal constant CAP_IN_KIND = 4;
    uint8 internal constant CAP_FEE_VALUATION = 8;
    uint8 internal constant CAP_HELD_DEPOSIT = 16;
    /// @dev The top 96 bits every TIP-20 token address shares; TIP-20 refuses transfers and mints to such addresses.
    uint160 internal constant TIP20_ADDRESS_PREFIX = 0x20C000000000000000000000;

    /// @notice The current yield engine and sole custodian of the venue shares backing this EarnVault's
    ///         EarnShare supply. MUTABLE only through operator-authorized {migrateEngine}.
    address public override engine;
    /// @dev Set once by {initialize}. Packed beside `engine`, which most locked calls read anyway.
    bool private initialized;
    /// @dev Set by the constructor on the implementation, so {initialize} runs only on a proxy.
    bool private isImplementation;
    /// @dev The current engine's fixed ERC-165 capabilities (CAP_* bits), read by {initialize} and {migrateEngine}.
    ///      Async redemption stays a live check: an engine may add or remove its queue.
    uint8 private engineCapabilities;
    /// @dev Mirrors EarnFees' {IEarnFees-feesActive}. Only this vault changes it (initialization, {setFeeConfig},
    ///      a distributor fee update, {disableFees}), and each refreshes this copy, so a checkpoint skips the call
    ///      while fees are off.
    bool private feesActiveCached;
    /// @notice Whether deposits, in-kind entry, contributions, and surplus absorption are paused.
    ///         Exit paths stay open.
    /// @dev Packed beside `engine`, which every entry reads anyway.
    bool public override depositsPaused;
    /// @dev Open async requests, read through {openRedeemRequestCount}. Packed beside the never-zero `engine`,
    ///      so a request into an empty queue writes no slot from zero (Tempo charges 250,000 gas for each). The
    ///      width is out of reach: every request writes at least one new slot.
    uint56 private _openRedeemRequestCount;
    address public override asset;
    /// @dev EarnShare decimals, packed beside `asset`; {_earnShareScale} widens them back.
    uint8 private _earnShareDecimals;
    /// @notice Deployment-fixed whole-pool migration policy. There is intentionally no setter.
    EngineMigrationMode public override engineMigrationMode;
    address public override earnShare;
    /// @dev Read through {maxManagedAssets}. Packed beside `earnShare`, which every checkpoint reads anyway.
    uint96 private _maxManagedAssets;
    address public override earnFees;
    /// @dev Read through {rewardRateBaseline}. Packed beside `earnFees`, which every fee checkpoint reads anyway, so
    ///      initialization writes no slot of its own for it. A value too wide for it stores {WIDE_RATE_BASELINE} here
    ///      and itself in `_wideRewardRateBaseline`.
    uint96 private _rewardRateBaseline;
    /// @notice Current operator seat. Mutable only through its own two-step transfer.
    address public override operator;
    address public override pendingOperator;
    /// @notice Protected fee authority. Mutable only through its own two-step transfer.
    address public override distributor;
    address public override pendingDistributor;
    /// @notice Deployment-fixed delay for prospective distributor fee updates.
    uint40 public override distributorUpdateDelay;
    /// @notice Fast risk-reducing seat. It may pause new exposure but cannot resume it.
    address public override emergencyGuardian;
    /// @notice Narrow liveness seat that may cancel async requests only to their stored receivers.
    address public override asyncJanitor;

    /// @dev Active engine shares recognized as EarnShare backing. Raw shares above this count are
    ///      quarantined until explicitly absorbed through {absorbEngineShareSurplus}. Writes revert past uint128.
    uint128 private _managedEngineShares;
    /// @notice (engine-shares : EarnShare) exchange anchor, read through {_anchor}. `anchorEngineShares` engine
    ///         shares are represented by `anchorEarnShares` EarnShare. Empty pools normalize the engine and
    ///         EarnShare whole-unit scales; live pools are explicitly re-anchored by {migrateEngine},
    ///         permissionless {contribute} funding, fee mints, and ordinary immediate actions that change backing
    ///         or supply.
    /// @dev Only the EarnShare side is stored, beside `_managedEngineShares` in the slot every entry and exit
    ///      reads and rewrites: a live anchor's engine-share side is the managed count it was restated from, and
    ///      {EMPTY_ANCHOR} marks the empty-pool anchor. The slot is never zero once initialized.
    uint128 internal _anchorEarnShares;

    struct PendingRedeem {
        address receiver;
        address requester;
        uint256 burnedEarnShares;
        bool open;
    }

    /// @dev Stored form of {PendingRedeem}; {pendingRedeem} widens it back. The first slot packs the requester,
    ///      the burned EarnShare and whether the request recorded an EarnFees snapshot. A nonzero `requester`
    ///      marks the request open, and closing deletes the record. `receiver` stays zero when it is the
    ///      requester, so a self-paying request writes one new slot; read it through {_receiverOf}. The queued
    ///      engine shares are not stored: the engine holds them, and cancellation measures what it returns.
    struct StoredRedeem {
        address requester;
        uint88 burnedEarnShares;
        bool feeSnapshot;
        address receiver;
    }

    mapping(bytes32 requestId => StoredRedeem) private _pending;

    /// @dev What a fee checkpoint read and left: the active supply after its fee mint, the managed backing it
    ///      reconciled (engineShares() after it), the engine's raw share count, and the fee it charged. With fees
    ///      on, a live supply and a fresh valuation it valued that backing (`valued`, `value`). A nonzero
    ///      `floorScale` says EarnFees priced it, with `baselineFloor` its floor for a principal entry's baselines.
    struct Checkpoint {
        uint256 supply;
        uint256 held;
        uint256 raw;
        uint256 value;
        bool valued;
        uint256 feeAssets;
        uint256 feeEarnShares;
        uint256 baselineFloor;
        uint256 floorScale;
    }

    FixedFeeRecipient private _distributorFee;
    DistributorFeeUpdate private _pendingDistributorFeeUpdate;

    /// @dev Reentrancy lock held for the duration of each locked call. Transient storage writes no slot.
    bool private transient _entered;
    /// @dev {rewardRateBaseline} while it is at least {WIDE_RATE_BASELINE}; read only then.
    uint256 private _wideRewardRateBaseline;

    event Contributed(
        address indexed caller,
        uint256 assets,
        uint256 engineShares,
        uint256 anchorEngineShares,
        uint256 anchorEarnShares
    );
    event RedeemRequested(
        bytes32 indexed requestId, address indexed requester, address indexed receiver, uint256 earnShares
    );
    event RedeemFinalized(
        bytes32 indexed requestId, address indexed receiver, uint256 earnShares, address asset, uint256 assets
    );
    event RedeemCancelled(bytes32 indexed requestId, address indexed receiver, uint256 earnShares);
    /// @notice A deposit restarted a pool whose supply had no backing; the stranded engine shares became surplus.
    event UnbackedPoolRestarted(uint256 unbackedSupply, uint256 strandedEngineShares);
    /// @notice Emitted when {migrateEngine} atomically re-homes custody and re-anchors accounting.
    ///         `totalEarnShares` is unchanged across the swap; `oldEngineShares`/`newEngineShares` are the managed
    ///         backing counts before/after (they differ at the new engine's rate). `assetsMoved` includes assets
    ///         redeemed from both managed backing and raw surplus so no custody remains on the old engine.
    event EngineMigrated(
        address indexed oldEngine,
        address indexed newEngine,
        uint256 oldEngineShares,
        uint256 assetsMoved,
        uint256 newEngineShares,
        uint256 totalEarnShares,
        uint256 anchorEngineShares,
        uint256 anchorEarnShares
    );

    error DepositsPaused();
    error DuplicateRequest(bytes32 requestId);
    error EngineAssetMismatch();
    error EngineCapabilityUnsupported(bytes4 interfaceId);
    error EarnSharesNotReceived();
    /// @notice The callback caller was not credited the quoted EarnShare the burn left.
    error EarnSharesNotReturned();
    /// @notice Engine custody or value changed while the withdraw callback ran.
    error EngineChangedDuringCallback();
    error EngineEarnVaultMismatch();
    error EngineExitUnsupported();
    error ExcessiveConversionLoss(uint256 inputShares, uint256 representedShares);
    error ExcessiveMigrationClassificationError(uint256 expectedManagedAssets, uint256 actualManagedAssets);
    error ExceedsMaxEarnShares();
    error FinalizedAssetMismatch(address finalizedAsset);
    error FeeValuationStale();
    error InitialEarnShareSupplyNotZero();
    error InvalidEngineShareScale();
    error InvalidEarnDecimals();
    error InvalidDistributorConfiguration();
    error InvalidDistributorFeeConfiguration();
    error InvalidReceiver(address receiver);
    error GlobalFeeDisableUnavailable();
    error ActiveSupplyWithoutBacking();
    error InsufficientOutput();
    error MinimumAssetsNotMet(uint256 minimumAssets, uint256 actualAssets);
    error MinimumEarnSharesNotMet(uint256 minimumEarnShares, uint256 actualEarnShares);
    error MinimumEngineSharesNotMet(uint256 minimumEngineShares, uint256 actualEngineShares);
    error MaxManagedAssetsExceeded(uint256 maximum, uint256 actual);
    /// @notice A managed-assets limit wider than its stored 96 bits.
    error MaxManagedAssetsTooLarge(uint256 maximum);
    error InsufficientEngineShareSurplus(uint256 available, uint256 requested);
    error AlreadyInitialized();
    error NoEarnShares();
    error NotEngine();
    error NotEmergencyGuardianOrOperator();
    error NotDistributor();
    error NotPendingDistributor();
    error NotOperator();
    error NotPendingOperator();
    error NotRequesterOrJanitor();
    error OperatorMigrationDisabled();
    error OperatorTransferNotPending();
    error PendingRedeemsOpen();
    error DistributorFeeUpdateNotPending();
    error DistributorFeeUpdateNotReady(uint40 executableAt);
    error DistributorTransferNotPending();
    error ReentrantCall();
    error RequestNotOpen(bytes32 requestId);
    error RewardRateLimitExceeded(uint256 normalizedRate, uint256 baselineRate);
    error ResidualBacking();
    error SameEngine();
    error TokenCallFailed();
    error TokenCallFalse();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroMinimumAssets();
    error ZeroMinimumEarnShares();
    error ZeroMinimumEngineShares();

    /// @dev Locks the standalone implementation: {initialize} reverts on it, and its locked calls revert
    ///      because it is never initialized. Each EarnVault is an ERC-1967 proxy with no upgrade entrypoint,
    ///      initialized atomically by {EarnFactory} against this fixed implementation.
    /// @custom:ensures !initialized && isImplementation
    constructor() {
        isImplementation = true;
    }

    /// @notice A fresh proxy is initialized once with its engine, EarnShare, fees module, roles and controls, and mints
    ///         itself and EarnFees one EarnShare unit each, which {_activeSupply} counts as burned (it needs the
    ///         issuer role first).
    /// @custom:ensures !old(initialized) && !isImplementation && initialized
    /// @custom:ensures engine == engine_ && earnShare == earnShare_ && earnFees == earnFees_ && operator == operator_
    /// @custom:ensures engine_ != address(0) && earnShare_ != address(0) && earnFees_ != address(0) && operator_ != address(0)
    /// @custom:ensures asset != address(0) && distributor == distributorInit_.distributor
    /// @custom:ensures distributorUpdateDelay == distributorInit_.updateDelay && _maxManagedAssets == controlInit_.maxManagedAssets
    /// @custom:ensures emergencyGuardian == controlInit_.emergencyGuardian && asyncJanitor == controlInit_.asyncJanitor
    /// @custom:ensures engineMigrationMode == controlInit_.migrationMode
    /// @custom:ensures _openRedeemRequestCount == 0 && pendingOperator == address(0) && pendingDistributor == address(0)
    /// @custom:ensures rewardRateBaseline() != 0 && _specEmptyAnchor() && _managedEngineShares == 0
    function initialize(
        address engine_,
        address earnShare_,
        address earnFees_,
        address operator_,
        EarnVaultControls memory controlInit_,
        DistributorConfig memory distributorInit_
    ) external {
        if (initialized || isImplementation) revert AlreadyInitialized();
        initialized = true;
        if (engine_ == address(0) || earnShare_ == address(0) || earnFees_ == address(0) || operator_ == address(0)) {
            revert ZeroAddress();
        }
        _requireCapability(engine_, type(IEarnEngine).interfaceId);
        _requireExitCapability(engine_);

        address asset_ = IEarnEngine(engine_).asset();
        if (asset_ == address(0)) revert ZeroAddress();
        if (IEarnShare(earnShare_).totalSupply() != 0) revert InitialEarnShareSupplyNotZero();
        if (IEarnFees(earnFees_).earnVault() != address(this) || IEarnFees(earnFees_).earnShare() != earnShare_) {
            revert ZeroAddress();
        }

        engine = engine_;
        engineCapabilities = _engineCapabilities(engine_);
        asset = asset_;
        earnShare = earnShare_;
        earnFees = earnFees_;
        feesActiveCached = IEarnFees(earnFees_).feesActive();
        operator = operator_;
        distributor = distributorInit_.distributor;
        distributorUpdateDelay = distributorInit_.updateDelay;
        emergencyGuardian = controlInit_.emergencyGuardian;
        asyncJanitor = controlInit_.asyncJanitor;
        _maxManagedAssets = _toMaxManagedAssets(controlInit_.maxManagedAssets);
        engineMigrationMode = controlInit_.migrationMode;

        FeeConfig memory initialFeeConfig = IEarnFees(earnFees_).feeConfig(IEarnFees(earnFees_).currentFeeConfigId());
        if (distributor == address(0)) {
            if (distributorUpdateDelay != 0) revert InvalidDistributorConfiguration();
        } else {
            if (distributorUpdateDelay == 0) {
                revert InvalidDistributorConfiguration();
            }
            if (initialFeeConfig.fixedFeeCount != 0) _distributorFee = initialFeeConfig.fixedFees[0];
        }

        uint8 earnDecimals = IEarnShare(earnShare_).decimals();
        if (earnDecimals > 77) revert InvalidEarnDecimals();
        _earnShareDecimals = earnDecimals;
        // The verifier models 10 ** e with a symbolic exponent as an uninterpreted value, so it can't prove it
        // nonzero; with e <= 77 (checked above) it is at least 1 and below 2 ** 256.
        /// @custom:assume _earnShareScale() > 0
        _resetEmptyAnchor(engine_, 0);
        /// @custom:ghost fixedAsset = asset
        /// @custom:ghost fixedEarnShare = earnShare
        /// @custom:ghost fixedEarnFees = earnFees
        /// @custom:ghost fixedEarnShareDecimals = _earnShareDecimals
        /// @custom:ghost fixedDistributorUpdateDelay = distributorUpdateDelay
        /// @custom:ghost fixedOperatorMigration = engineMigrationMode == EngineMigrationMode.OperatorEnabled
        /// @custom:ghost trackedEngine = engine
        /// @custom:ghost trackedOperator = operator
        /// @custom:ghost trackedDistributor = distributor
        // The vault keeps one EarnShare unit for good and gives EarnFees one. {_activeSupply} counts both as burned,
        // so they never claim backing, and neither balance slot is ever emptied (EarnFees pays out only recorded
        // claims). The caller grants the issuer role first.
        IEarnShare(earnShare_).mint(address(this), SHARE_RESIDUE);
        IEarnShare(earnShare_).mint(earnFees_, SHARE_RESIDUE);
        FixedFeeRecipient memory distributorFee_ = _distributorFee;
        emit EarnVaultInitialized(
            engine,
            earnShare,
            earnFees,
            operator,
            emergencyGuardian,
            asyncJanitor,
            _maxManagedAssets,
            engineMigrationMode,
            distributor,
            distributorUpdateDelay,
            distributorFee_.account,
            distributorFee_.rateBps
        );
    }

    /// @dev Also refuses an uninitialized vault, such as the implementation itself.
    modifier nonReentrant() {
        if (_entered || !initialized) revert ReentrantCall();
        // The verifier takes transient storage as arbitrary when a call starts, so it cannot relate
        // `_entered` to the ghost. Both are written together, so `entered` is false wherever `_entered` is.
        /// @custom:assume !entered
        /// @custom:ghost entered = true
        _entered = true;
        _;
        /// @custom:ghost entered = false
        _entered = false;
    }

    /// @notice Anyone can checkpoint fees whenever no other vault call is running.
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    /// @custom:ensures feeCheckpoints == old(feeCheckpoints) + 1
    /// Not proved: it returns whenever the vault is initialized and unlocked; that depends on the engine, EarnShare and EarnFees calls returning.
    function accrueFees() external override nonReentrant returns (uint256 feeAssets, uint256 feeEarnShares) {
        Checkpoint memory c = _accrueFees();
        return (c.feeAssets, c.feeEarnShares);
    }

    /// @custom:ensures msg.sender == old(operator)
    /// @custom:ensures old(distributor) != address(0) ==> _specProtectsDistributorFee(config, old(_distributorFee))
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    function setFeeConfig(FeeConfig calldata config) external override nonReentrant returns (uint64 configId) {
        if (msg.sender != operator) revert NotOperator();
        _validateOperatorFeeConfig(config);
        _requireFreshFeeValuation();
        _settleFees();
        configId = IEarnFees(earnFees).setFeeConfig(config);
        _refreshFeesActive();
    }

    /// @notice Only the operator of a deployment without a distributor can disable fees globally.
    /// @custom:ensures old(distributor) == address(0) && msg.sender == old(operator)
    function disableFees() external override {
        if (distributor != address(0)) revert GlobalFeeDisableUnavailable();
        if (msg.sender != operator) revert NotOperator();
        IEarnFees(earnFees).disableFees(msg.sender);
        _refreshFeesActive();
    }

    /// @custom:ensures msg.sender == operator && newOperator != address(0) && pendingOperator == newOperator
    function transferOperator(address newOperator) external override {
        if (msg.sender != operator) revert NotOperator();
        if (newOperator == address(0)) revert ZeroAddress();
        pendingOperator = newOperator;
        emit OperatorTransferStarted(operator, newOperator);
    }

    /// @custom:ensures msg.sender == operator && old(pendingOperator) != address(0) && pendingOperator == address(0)
    /// @custom:succeeds-if msg.sender == operator && pendingOperator != address(0)
    function cancelOperatorTransfer() external override {
        if (msg.sender != operator) revert NotOperator();
        address pending = pendingOperator;
        if (pending == address(0)) revert OperatorTransferNotPending();
        delete pendingOperator;
        emit OperatorTransferCancelled(operator, pending);
    }

    /// @custom:ensures msg.sender == old(pendingOperator) && operator == msg.sender && pendingOperator == address(0)
    /// @custom:succeeds-if msg.sender == pendingOperator && pendingOperator != address(0)
    function acceptOperator() external override {
        address pending = pendingOperator;
        if (pending == address(0)) revert OperatorTransferNotPending();
        if (msg.sender != pending) revert NotPendingOperator();

        address previous = operator;
        /// @custom:ghost trackedOperator = pending
        operator = pending;
        delete pendingOperator;
        emit OperatorTransferred(previous, pending);
    }

    function distributorFee() external view override returns (address recipient, uint16 rateBps) {
        FixedFeeRecipient memory fee = _distributorFee;
        return (fee.account, fee.rateBps);
    }

    function pendingDistributorFeeUpdate() external view override returns (DistributorFeeUpdate memory) {
        return _pendingDistributorFeeUpdate;
    }

    /// @notice Schedules a prospective update to the distributor's reserved fixed-fee item.
    /// @dev Scheduling validates both the current operator configuration and the proposed composed
    ///      configuration. A later operator update must preserve this pending configuration's validity.
    /// @custom:ensures distributor != address(0) && msg.sender == distributor && (rateBps == 0) == (recipient == address(0))
    /// @custom:ensures _pendingDistributorFeeUpdate.pending && _pendingDistributorFeeUpdate.recipient == recipient
    /// @custom:ensures _pendingDistributorFeeUpdate.rateBps == rateBps
    /// @custom:ensures _pendingDistributorFeeUpdate.executableAt == block.timestamp + distributorUpdateDelay
    function scheduleDistributorFeeUpdate(address recipient, uint16 rateBps) external override {
        _requireDistributor();
        if ((rateBps == 0) != (recipient == address(0))) revert InvalidDistributorFeeConfiguration();

        FixedFeeRecipient memory nextFee = FixedFeeRecipient({ account: recipient, rateBps: rateBps });
        FeeConfig memory config = _currentFeeConfig();
        FeeConfig memory proposed = _replaceDistributorFee(config, _distributorFee, nextFee);
        IEarnFees(earnFees).validateFeeConfig(proposed);

        uint256 executableAt = block.timestamp + uint256(distributorUpdateDelay);
        if (executableAt > type(uint40).max) revert InvalidDistributorFeeConfiguration();
        // The explicit bound above makes this narrowing conversion lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 executableAt_ = uint40(executableAt);
        _pendingDistributorFeeUpdate = DistributorFeeUpdate({
            recipient: recipient, rateBps: rateBps, executableAt: executableAt_, pending: true
        });
        emit DistributorFeeUpdateScheduled(distributor, recipient, rateBps, executableAt_);
    }

    /// @custom:ensures distributor != address(0) && msg.sender == distributor && old(_pendingDistributorFeeUpdate.pending)
    /// @custom:ensures _specNoDistributorFeeUpdate()
    function cancelDistributorFeeUpdate() external override {
        _requireDistributor();
        if (!_pendingDistributorFeeUpdate.pending) revert DistributorFeeUpdateNotPending();
        delete _pendingDistributorFeeUpdate;
        emit DistributorFeeUpdateCancelled(distributor);
    }

    /// @notice Permissionlessly activates a ready distributor fee update after settling the old terms.
    /// @notice Anyone may activate a scheduled distributor fee once its delay has passed.
    /// @custom:ensures old(_pendingDistributorFeeUpdate.pending) && block.timestamp >= old(_pendingDistributorFeeUpdate.executableAt)
    /// @custom:ensures _distributorFee.account == old(_pendingDistributorFeeUpdate.recipient)
    /// @custom:ensures _distributorFee.rateBps == old(_pendingDistributorFeeUpdate.rateBps)
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    function executeDistributorFeeUpdate() external override nonReentrant returns (uint64 feeConfigId) {
        DistributorFeeUpdate memory pending = _pendingDistributorFeeUpdate;
        if (!pending.pending) revert DistributorFeeUpdateNotPending();
        // Timestamp comparison is the intended enforcement mechanism for this deployment-fixed timelock.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < pending.executableAt) revert DistributorFeeUpdateNotReady(pending.executableAt);

        FixedFeeRecipient memory nextFee = FixedFeeRecipient({ account: pending.recipient, rateBps: pending.rateBps });
        FeeConfig memory proposed = _replaceDistributorFee(_currentFeeConfig(), _distributorFee, nextFee);
        IEarnFees(earnFees).validateFeeConfig(proposed);

        _requireFreshFeeValuation();
        _settleFees();
        _distributorFee = nextFee;
        delete _pendingDistributorFeeUpdate;
        feeConfigId = IEarnFees(earnFees).setFeeConfig(proposed);
        _refreshFeesActive();
        emit DistributorFeeUpdated(nextFee.account, nextFee.rateBps, feeConfigId);
    }

    /// @custom:ensures distributor != address(0) && msg.sender == distributor
    /// @custom:ensures pendingDistributor == newDistributor && newDistributor != address(0) && newDistributor != distributor
    function transferDistributor(address newDistributor) external override {
        _requireDistributor();
        if (newDistributor == address(0) || newDistributor == distributor) revert InvalidDistributorConfiguration();
        pendingDistributor = newDistributor;
        emit DistributorTransferStarted(distributor, newDistributor);
    }

    /// @custom:ensures distributor != address(0) && msg.sender == distributor
    /// @custom:ensures old(pendingDistributor) != address(0) && pendingDistributor == address(0)
    function cancelDistributorTransfer() external override {
        _requireDistributor();
        address pending = pendingDistributor;
        if (pending == address(0)) revert DistributorTransferNotPending();
        delete pendingDistributor;
        emit DistributorTransferCancelled(distributor, pending);
    }

    /// @notice The pending distributor takes the role, and any fee update its predecessor scheduled is cancelled.
    /// @custom:ensures msg.sender == old(pendingDistributor) && distributor == msg.sender && pendingDistributor == address(0)
    /// @custom:ensures _specNoDistributorFeeUpdate()
    /// @custom:succeeds-if msg.sender == pendingDistributor && pendingDistributor != address(0)
    function acceptDistributor() external override {
        address pending = pendingDistributor;
        if (pending == address(0)) revert DistributorTransferNotPending();
        if (msg.sender != pending) revert NotPendingDistributor();

        address previous = distributor;
        /// @custom:ghost trackedDistributor = pending
        distributor = pending;
        delete pendingDistributor;
        if (_pendingDistributorFeeUpdate.pending) {
            delete _pendingDistributorFeeUpdate;
            emit DistributorFeeUpdateCancelled(previous);
        }
        emit DistributorTransferred(previous, pending);
    }

    /// @notice Rotates the fast pause-only and bounded async cancellation seats together.
    /// @dev The operator may preserve either seat by passing its current address.
    /// @custom:ensures msg.sender == operator && emergencyGuardian == newGuardian && asyncJanitor == newJanitor
    function setEmergencyRoles(address newGuardian, address newJanitor) external override {
        if (msg.sender != operator) revert NotOperator();
        emergencyGuardian = newGuardian;
        asyncJanitor = newJanitor;
        emit EmergencyRolesChanged(newGuardian, newJanitor);
    }

    /// @notice Pauses or unpauses deposits, in-kind entry, contributions, and surplus absorption
    ///         without blocking exits.
    /// @dev The guardian may only pause. The operator may pause or unpause.
    /// @notice The operator pauses or unpauses; the guardian can only pause.
    /// @custom:ensures depositsPaused == paused
    /// @custom:ensures msg.sender == operator || (msg.sender == emergencyGuardian && paused)
    /// @custom:succeeds-if msg.sender == operator || (msg.sender == emergencyGuardian && paused)
    function setDepositsPaused(bool paused) external override {
        if (msg.sender != operator) {
            if (msg.sender != emergencyGuardian) revert NotEmergencyGuardianOrOperator();
            if (!paused) revert NotOperator();
        }
        if (depositsPaused == paused) return;
        depositsPaused = paused;
        emit DepositPauseChanged(msg.sender, paused);
    }

    /// @notice Updates the maximum active assets permitted after a voluntary inflow.
    /// @dev Zero disables the limit. Lowering the limit below current managed assets does not force
    ///      an exit; it blocks later voluntary inflows until exits reopen capacity or the limit changes.
    ///      A limit above 2 ** 96 - 1 reverts with {MaxManagedAssetsTooLarge}.
    /// @custom:ensures msg.sender == operator && _maxManagedAssets == newMaxManagedAssets
    function setMaxManagedAssets(uint256 newMaxManagedAssets) external override {
        if (msg.sender != operator) revert NotOperator();
        uint256 previousMaxManagedAssets = _maxManagedAssets;
        _maxManagedAssets = _toMaxManagedAssets(newMaxManagedAssets);
        emit MaxManagedAssetsChanged(previousMaxManagedAssets, newMaxManagedAssets);
    }

    /// @notice Operator-configured maximum active assets after a voluntary inflow. Zero disables the limit.
    function maxManagedAssets() external view override returns (uint256) {
        return _maxManagedAssets;
    }

    /// @custom:ensures result == maximum
    /// @custom:succeeds-if maximum <= type(uint96).max
    function _toMaxManagedAssets(uint256 maximum) internal pure returns (uint96) {
        if (maximum > type(uint96).max) revert MaxManagedAssetsTooLarge(maximum);
        // Bounded above, so the narrowing conversion cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(maximum);
    }

    /// @notice Deposits `assets` of the engine asset pulled from the caller into the engine (which
    ///         holds the resulting venue shares) and mints the rate-converted EarnShare amount to
    ///         `receiver`. The measured engine-share delta is converted at the active anchor, whose
    ///         empty-pool rate normalizes engine and EarnShare precision. `minEarnShares` protects
    ///         the caller from quote drift, and the EarnVault rejects conversion floor loss above one
    ///         basis point even when the caller obtained a quote after the anchor was distorted.
    /// @custom:ensures !old(depositsPaused) && earnShares != 0 && earnShares >= minEarnShares
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    /// @custom:ensures feeCheckpoints == old(feeCheckpoints) + 1
    function deposit(uint256 assets, address receiver, uint256 minEarnShares)
        external
        override
        nonReentrant
        returns (uint256 earnShares)
    {
        return _deposit(assets, receiver, minEarnShares);
    }

    /// @notice Deposits assets from the caller and mints EarnShare only to the caller.
    /// @dev Separate selector for access keys scoped to self-recipient calls.
    /// @custom:ensures !old(depositsPaused) && earnShares != 0 && earnShares >= minEarnShares
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    /// @custom:ensures feeCheckpoints == old(feeCheckpoints) + 1
    function deposit(uint256 assets, uint256 minEarnShares)
        external
        override
        nonReentrant
        returns (uint256 earnShares)
    {
        return _deposit(assets, msg.sender, minEarnShares);
    }

    /// @dev Not proved: after the first entry into an empty pool the fee high-water mark is the entrants' value per
    ///      EarnShare, rounded up; EarnFees.reopenBaselines sets it, which this contract does not observe.
    /// @dev Not proved: the backing value of a live supply is at least its supply times a minimum value per
    ///      EarnShare over the EarnShare scale; the vault requires only nonzero backing value before an entry.
    /// @dev Not proved: with deposits unpaused, a nonzero amount, receiver and minimum, a backed or empty
    ///      pool, an engine that credits the reported shares and a token that moves the assets, a deposit
    ///      within the managed-assets limit and the one-basis-point conversion bound returns normally.
    function _deposit(uint256 assets, address receiver, uint256 minEarnShares) internal returns (uint256 earnShares) {
        if (depositsPaused) revert DepositsPaused();
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (minEarnShares == 0) revert ZeroMinimumEarnShares();

        // The checkpoint mints fee EarnShare only into a nonzero supply, so `currentSupply` is zero exactly when the
        // supply before it was.
        Checkpoint memory c = _accrueFees();
        uint256 currentSupply = c.supply;
        bool restarted = _isUnbackedHeld(currentSupply, c.held, c.value, c.valued);
        uint256 strandedEngineShares;
        if (restarted) strandedEngineShares = _restartEmptyAnchor();
        // Read before the deposit raises the managed count, which a live anchor's engine-share side follows.
        (uint256 rateEngineShares, uint256 rateEarnShares) = _anchor();
        // Fees are checkpointed first, so the entry is priced against the post-fee supply, and an entry into
        // an empty pool is priced at the normalized empty-pool anchor rather than the previous cohort's rate.
        /// @custom:assert feeCheckpoints == old(feeCheckpoints) + 1
        /// @custom:assert rateEarnShares == currentSupply || rateEarnShares == _earnShareScale()
        /// @custom:assert currentSupply == 0 ==> rateEarnShares == _earnShareScale() && rateEngineShares == rewardRateBaseline()

        (uint256 receivedEngineShares, uint256 rawSharesAfter) = _depositToEngine(assets, c.raw);
        // Written once, with the anchor below.
        uint256 managedAfter = _raisedManagedEngineShares(receivedEngineShares);

        earnShares = _toEarnShares(receivedEngineShares, rateEngineShares, rateEarnShares);
        if (earnShares == 0) revert InsufficientOutput();
        if (earnShares < minEarnShares) revert MinimumEarnSharesNotMet(minEarnShares, earnShares);
        _requireAcceptableConversion(receivedEngineShares, earnShares, rateEngineShares, rateEarnShares);
        if (restarted) {
            _requireNegligibleRestart(currentSupply, strandedEngineShares, receivedEngineShares, earnShares);
        }
        /// @custom:assert earnShares == receivedEngineShares * rateEarnShares / rateEngineShares
        IEarnShare(earnShare).mint(receiver, earnShares);
        // The mint is the only supply change since the checkpoint, wherever it lands.
        (uint256 supplyAfter, uint256 heldAfter) = _reanchorAfterEntryRaw(
            rateEngineShares, rateEarnShares, rawSharesAfter, currentSupply + earnShares, managedAfter
        );
        bool reopened = currentSupply == 0 || restarted;
        bool ratchet = c.floorScale != 0 && c.value != 0;
        uint256 heldValue = _entryValue(reopened || ratchet, heldAfter);
        _requireWithinManagedAssetsLimitValue(heldValue);
        // The re-anchor left the managed count at most the raw count just measured, so this is totalAssets().
        /// @custom:assert _maxManagedAssets == 0 || _specManagedValueAt(rawSharesAfter) <= _maxManagedAssets
        if (reopened) {
            /// @custom:ghost baselineEntries = baselineEntries + 1
            _reopenFeeBaselines(supplyAfter, heldValue);
        } else if (ratchet) {
            /// @custom:ghost baselineEntries = baselineEntries + 1
            _ratchetFeeBaselines(supplyAfter, heldValue, c.baselineFloor, c.floorScale);
        }
        // The first entry into an empty pool always updates the fee baselines.
        /// @custom:assert currentSupply == 0 ==> baselineEntries == old(baselineEntries) + 1
        emit Deposited(msg.sender, receiver, assets, earnShares);
    }

    /// @notice Deposits shares of the current engine's venue directly and mints rate-converted
    ///         EarnShare to `receiver`. The caller approves the engine—not this EarnVault—to pull the
    ///         venue shares. Only engines implementing {IEarnEngineInKindDeposit} support this path.
    /// @dev This is a principal-preserving entry path for existing venue shareholders. Fees are
    ///      crystallized before the new backing enters, and the proportional EarnShare mint prevents
    ///      the incoming principal from being treated as positive value accrual. The same one-basis-point
    ///      conversion-loss ceiling as {deposit} applies independently of `minEarnShares`.
    /// @custom:ensures !old(depositsPaused) && earnShares != 0 && earnShares >= minEarnShares
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    /// @custom:ensures feeCheckpoints == old(feeCheckpoints) + 1
    function depositVenueShares(uint256 venueShares, address receiver, uint256 minEarnShares)
        external
        override
        nonReentrant
        returns (uint256 earnShares)
    {
        return _depositVenueShares(venueShares, receiver, minEarnShares);
    }

    /// @notice Deposits venue shares from the caller and mints EarnShare only to the caller.
    /// @dev Separate selector for access keys scoped to self-recipient calls.
    /// @custom:ensures !old(depositsPaused) && earnShares != 0 && earnShares >= minEarnShares
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    /// @custom:ensures feeCheckpoints == old(feeCheckpoints) + 1
    function depositVenueShares(uint256 venueShares, uint256 minEarnShares)
        external
        override
        nonReentrant
        returns (uint256 earnShares)
    {
        return _depositVenueShares(venueShares, msg.sender, minEarnShares);
    }

    function _depositVenueShares(uint256 venueShares, address receiver, uint256 minEarnShares)
        internal
        returns (uint256 earnShares)
    {
        if (depositsPaused) revert DepositsPaused();
        if (venueShares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (minEarnShares == 0) revert ZeroMinimumEarnShares();

        // The checkpoint mints fee EarnShare only into a nonzero supply, so `currentSupply` is zero exactly when the
        // supply before it was.
        Checkpoint memory c = _accrueFees();
        uint256 currentSupply = c.supply;
        bool restarted = _isUnbackedHeld(currentSupply, c.held, c.value, c.valued);
        uint256 strandedEngineShares;
        if (restarted) strandedEngineShares = _restartEmptyAnchor();
        // Read before the entry raises the managed count, as in a deposit.
        (uint256 rateEngineShares, uint256 rateEarnShares) = _anchor();
        // Fees are checkpointed first, so the entry is priced against the post-fee supply, and an entry into
        // an empty pool is priced at the normalized empty-pool anchor rather than the previous cohort's rate.
        /// @custom:assert feeCheckpoints == old(feeCheckpoints) + 1
        /// @custom:assert rateEarnShares == currentSupply || rateEarnShares == _earnShareScale()
        /// @custom:assert currentSupply == 0 ==> rateEarnShares == _earnShareScale() && rateEngineShares == rewardRateBaseline()

        _requireEngineCapability(CAP_IN_KIND, type(IEarnEngineInKindDeposit).interfaceId);
        // Nothing since the checkpoint moved engine shares, so its raw read is the count before the entry.
        uint256 reportedEngineShares = IEarnEngineInKindDeposit(engine).depositInKind(venueShares, msg.sender);
        (uint256 receivedEngineShares, uint256 rawSharesAfter) =
            _measureEngineShareIncrease(c.raw, reportedEngineShares);
        // Written once, with the anchor below.
        uint256 managedAfter = _raisedManagedEngineShares(receivedEngineShares);

        earnShares = _toEarnShares(receivedEngineShares, rateEngineShares, rateEarnShares);
        if (earnShares == 0) revert InsufficientOutput();
        if (earnShares < minEarnShares) revert MinimumEarnSharesNotMet(minEarnShares, earnShares);
        _requireAcceptableConversion(receivedEngineShares, earnShares, rateEngineShares, rateEarnShares);
        if (restarted) {
            _requireNegligibleRestart(currentSupply, strandedEngineShares, receivedEngineShares, earnShares);
        }
        /// @custom:assert earnShares == receivedEngineShares * rateEarnShares / rateEngineShares
        IEarnShare(earnShare).mint(receiver, earnShares);
        // As in a deposit, the mint is the only supply change since the checkpoint.
        (uint256 supplyAfter, uint256 heldAfter) = _reanchorAfterEntryRaw(
            rateEngineShares, rateEarnShares, rawSharesAfter, currentSupply + earnShares, managedAfter
        );
        bool reopened = currentSupply == 0 || restarted;
        bool ratchet = c.floorScale != 0 && c.value != 0;
        uint256 heldValue = _entryValue(reopened || ratchet, heldAfter);
        _requireWithinManagedAssetsLimitValue(heldValue);
        // The re-anchor left the managed count at most the raw count just measured, so this is totalAssets().
        /// @custom:assert _maxManagedAssets == 0 || _specManagedValueAt(rawSharesAfter) <= _maxManagedAssets
        if (reopened) {
            /// @custom:ghost baselineEntries = baselineEntries + 1
            _reopenFeeBaselines(supplyAfter, heldValue);
        } else if (ratchet) {
            /// @custom:ghost baselineEntries = baselineEntries + 1
            _ratchetFeeBaselines(supplyAfter, heldValue, c.baselineFloor, c.floorScale);
        }
        // The first entry into an empty pool always updates the fee baselines.
        /// @custom:assert currentSupply == 0 ==> baselineEntries == old(baselineEntries) + 1
        emit VenueSharesDeposited(msg.sender, receiver, venueShares, receivedEngineShares, earnShares);
    }

    /// @notice Adds backing for current EarnShare holders without minting new EarnShare.
    /// @dev Permissionless and allowance-bound. The assets follow the normal engine deposit path,
    ///      then the conversion anchor is restated against the unchanged EarnShare
    ///      supply. With open async exits, only the active pool participates because queued claims
    ///      have already burned their EarnShare and left active NAV.
    /// @custom:ensures !old(depositsPaused) && assets != 0 && receivedEngineShares != 0
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    /// @custom:ensures feeCheckpoints == old(feeCheckpoints) + 2
    /// @custom:ensures _managedEngineShares <= cappedManagedShares
    /// @custom:ensures _specNormalizedRate(_specAnchorEngine(), _specAnchorEarn()) <= rewardRateBaseline() * MAX_REWARD_RATE_MULTIPLIER
    /// @dev The reward-rate limit holds after the final fee checkpoint, and the managed backing at return is
    ///      at most the count that passed the managed-assets limit.
    ///      Not proved: totalAssets() <= maxManagedAssets at return; the engine valuation is read again after
    ///      the final fee checkpoint.
    ///      Not proved: with deposits unpaused, a nonzero amount, a live supply, an engine that credits the
    ///      reported shares and a token that moves the assets, a contribution within the managed-assets and
    ///      reward-rate limits returns normally.
    function contribute(uint256 assets) external override nonReentrant returns (uint256 receivedEngineShares) {
        if (depositsPaused) revert DepositsPaused();
        if (assets == 0) revert ZeroAmount();

        // The checkpoint mints fee EarnShare only into a nonzero supply, so its supply is zero exactly when the
        // supply before it was. It moves no engine shares, so its raw read prices the contribution.
        Checkpoint memory c = _accrueFees();
        uint256 supply = c.supply;
        if (supply == 0) revert NoEarnShares();

        // Gains up to here are checkpointed before the contribution enters.
        /// @custom:assert feeCheckpoints == old(feeCheckpoints) + 1
        uint256 raw;
        (receivedEngineShares, raw) = _depositToEngine(assets, c.raw);
        _increaseManagedEngineShares(receivedEngineShares);
        /// @custom:ghost cappedManagedShares = _managedEngineShares
        (uint256 value, bool valued) = _requireWithinManagedAssetsLimitAt(raw);
        // `raw` is the engine's share count just measured, so this is totalAssets().
        /// @custom:assert _maxManagedAssets == 0 || _specManagedValueAt(raw) <= _maxManagedAssets

        // The contribution changes no supply, so the checkpoint's supply still holds, and the second checkpoint
        // reuses the raw count and the backing's value the limit just read.
        _reanchorAtRestRaw(raw, supply);
        _accrueFeesAt(raw, supply, value, valued, false);
        _requireRewardRateWithinLimit();

        (uint256 anchorEngine, uint256 anchorEarn) = _anchor();
        emit Contributed(msg.sender, assets, receivedEngineShares, anchorEngine, anchorEarn);
    }

    /// @notice Permissionlessly recognizes pre-transferred engine shares as a reward for current holders.
    /// @dev Raw engine shares are otherwise quarantined: they do not affect active backing, fees, deposits,
    ///      or exits. Absorption is subject to the same pause, capacity, and reward-rate limits as
    ///      an asset contribution.
    /// @custom:ensures !old(depositsPaused) && engineShares_ != 0
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    /// @custom:ensures feeCheckpoints == old(feeCheckpoints) + 2
    /// @custom:ensures _managedEngineShares <= cappedManagedShares
    /// @custom:ensures _specNormalizedRate(_specAnchorEngine(), _specAnchorEarn()) <= rewardRateBaseline() * MAX_REWARD_RATE_MULTIPLIER
    function absorbEngineShareSurplus(uint256 engineShares_) external override nonReentrant {
        if (depositsPaused) revert DepositsPaused();
        if (engineShares_ == 0) revert ZeroAmount();

        // As in {contribute}, the checkpoint's supply is zero exactly when the supply before it was, and its raw
        // read still holds.
        Checkpoint memory c = _accrueFees();
        uint256 supply = c.supply;
        if (supply == 0) revert NoEarnShares();
        uint256 raw = c.raw;

        uint256 managed = _managedEngineShares;
        uint256 available = raw > managed ? raw - managed : 0;
        if (engineShares_ > available) revert InsufficientEngineShareSurplus(available, engineShares_);
        _setManagedEngineShares(managed + engineShares_);
        /// @custom:ghost cappedManagedShares = _managedEngineShares
        (uint256 value, bool valued) = _requireWithinManagedAssetsLimitAt(raw);
        // `raw` is the engine's share count just measured, so this is totalAssets().
        /// @custom:assert _maxManagedAssets == 0 || _specManagedValueAt(raw) <= _maxManagedAssets

        _reanchorAtRestRaw(raw, supply);
        _accrueFeesAt(raw, supply, value, valued, false);
        _requireRewardRateWithinLimit();

        (uint256 anchorEngine, uint256 anchorEarn) = _anchor();
        emit EngineShareSurplusAbsorbed(msg.sender, engineShares_, anchorEngine, anchorEarn);
    }

    /// @notice Burns `earnShares` of EarnShare pulled from the caller and redeems the rate-converted
    ///         engine shares. Proceeds go directly to `receiver`.
    /// @custom:ensures assets != 0 && assets >= minAssets && minAssets != 0 && earnShares != 0
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    /// @custom:ensures _managedEngineShares < old(_managedEngineShares)
    function redeem(uint256 earnShares, address receiver, uint256 minAssets)
        external
        override
        nonReentrant
        returns (uint256 assets)
    {
        return _redeem(earnShares, receiver, minAssets);
    }

    /// @notice Redeems the caller's EarnShare and sends assets only to the caller.
    /// @dev Separate selector for access keys scoped to self-recipient calls.
    /// @custom:ensures assets != 0 && assets >= minAssets && minAssets != 0 && earnShares != 0
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    /// @custom:ensures _managedEngineShares < old(_managedEngineShares)
    function redeem(uint256 earnShares, uint256 minAssets) external override nonReentrant returns (uint256 assets) {
        return _redeem(earnShares, msg.sender, minAssets);
    }

    /// @dev Not proved: with a nonzero amount, receiver and minimum, the caller's EarnShare and allowance,
    ///      and an engine that redeems the converted shares for at least the minimum, a redemption returns
    ///      normally.
    function _redeem(uint256 earnShares, address receiver, uint256 minAssets) internal returns (uint256 assets) {
        if (earnShares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (minAssets == 0) revert ZeroMinimumAssets();
        _requireEngineCapability(CAP_REDEEM, type(IEarnEngineRedeem).interfaceId);

        uint256 supply = _accrueFees().supply;

        _safeTransferFrom(earnShare, msg.sender, address(this), earnShares);
        IEarnShare(earnShare).burn(earnShares);

        uint256 engineSharesToRedeem = _convertToEngineShares(earnShares);
        if (engineSharesToRedeem == 0) revert InsufficientOutput();
        // The burned EarnShare redeems exactly its engine shares at the post-checkpoint anchor.
        /// @custom:assert engineSharesToRedeem == earnShares * _specAnchorEngine() / _specAnchorEarn()
        /// @custom:assert feeCheckpoints == old(feeCheckpoints) + 1
        assets = IEarnEngineRedeem(engine).redeem(engineSharesToRedeem, receiver, minAssets);
        if (assets == 0) revert InsufficientOutput();
        if (assets < minAssets) revert MinimumAssetsNotMet(minAssets, assets);
        uint256 managedAfter = _loweredManagedEngineShares(engineSharesToRedeem);

        // The burn is the only supply change since the checkpoint, and the vault's own balance is back where it was.
        // The lowered managed count is written once, with the anchor.
        _reanchorManaged(rawEngineShares(), supply - earnShares, managedAfter);
        emit Redeemed(msg.sender, receiver, earnShares, assets);
    }

    /// @notice Withdraws an exact `assets` amount directly to `receiver`, burning the EarnShare amount
    ///         actually consumed (pulled from the caller). Reverts if more than `maxEarnShares`
    ///         would be burned.
    /// @dev Used when public requests are denominated in assets. The caller keeps any unused EarnShare.
    /// @custom:ensures earnSharesBurned != 0 && earnSharesBurned <= maxEarnShares && assets != 0
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    function withdrawExact(uint256 assets, address receiver, uint256 maxEarnShares)
        external
        override
        nonReentrant
        returns (uint256 earnSharesBurned)
    {
        return _withdrawExact(assets, receiver, maxEarnShares);
    }

    /// @notice Withdraws exact assets only to the caller, burning the caller's EarnShare.
    /// @dev Separate selector for access keys scoped to self-recipient calls.
    /// @custom:ensures earnSharesBurned != 0 && earnSharesBurned <= maxEarnShares && assets != 0
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    function withdrawExact(uint256 assets, uint256 maxEarnShares)
        external
        override
        nonReentrant
        returns (uint256 earnSharesBurned)
    {
        return _withdrawExact(assets, msg.sender, maxEarnShares);
    }

    /// @notice Withdraws exact `assets` to `receiver` like {withdrawExact}, but asks the caller for the quoted
    ///         EarnShare cost: before paying out, it calls {IEarnWithdrawCallback-earnWithdrawCallback} on the
    ///         caller, which transfers exactly that much EarnShare to this vault, from any account it may spend from.
    /// @dev Saves a separate {previewWithdraw} quote and a transfer through the caller. The burn never exceeds the
    ///      quote; any quoted EarnShare left unburned returns to the caller. The lock keeps the callback out of the vault.
    ///      Views read during the callback are not settled: they may count the transferred EarnShare as burned.
    /// @custom:ensures earnSharesBurned != 0 && earnSharesBurned <= maxEarnShares && assets != 0
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) && engine == old(engine)
    function withdrawExactWithCallback(uint256 assets, address receiver, uint256 maxEarnShares)
        external
        override
        nonReentrant
        returns (uint256 earnSharesBurned)
    {
        return _withdrawExactFrom(assets, receiver, maxEarnShares, true);
    }

    /// @notice ERC-165: this vault has {IEarnVaultWithdrawCallback}.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IEarnVaultWithdrawCallback).interfaceId;
    }

    function _withdrawExact(uint256 assets, address receiver, uint256 maxEarnShares)
        internal
        returns (uint256 earnSharesBurned)
    {
        return _withdrawExactFrom(assets, receiver, maxEarnShares, false);
    }

    function _withdrawExactFrom(uint256 assets, address receiver, uint256 maxEarnShares, bool callback)
        internal
        returns (uint256 earnSharesBurned)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _requireEngineCapability(CAP_EXACT_WITHDRAW, type(IEarnEngineExactWithdraw).interfaceId);

        // The checkpoint's supply and backing are read before the callback. The backing equals engineShares() after
        // the checkpoint, and a checkpoint that valued it already holds its value.
        Checkpoint memory c = _accrueFees();
        uint256 supply = c.supply;
        uint256 engineSharesBefore = c.held;
        // Read before the withdrawal lowers the managed count, which a live anchor's engine-share side follows.
        (uint256 rateEngineShares, uint256 rateEarnShares) = _anchor();
        /// @custom:assert rateEngineShares == _specAnchorEngine() && rateEarnShares == _specAnchorEarn()

        uint256 requiredEngineShares = IEarnEngineExactWithdraw(engine).previewWithdraw(assets);
        if (requiredEngineShares == 0) revert InsufficientOutput();
        uint256 requiredEarnShares = _toEarnSharesUp(requiredEngineShares, rateEngineShares, rateEarnShares);
        if (requiredEarnShares == 0) revert InsufficientOutput();
        if (requiredEarnShares > maxEarnShares) revert ExceedsMaxEarnShares();
        uint256 engineAssetsBefore = c.valued ? c.value : IEarnEngine(engine).valueOf(engineSharesBefore);
        // The callback runs here, while the vault's state is settled, so no caller code ever reads it half-updated.
        if (callback) {
            _collectEarnShares(requiredEarnShares, true);
            // Fees, the anchor and the quote were settled against this engine state; the callback may not move it.
            uint256 engineSharesAfter = engineShares();
            if (
                engineSharesAfter != engineSharesBefore
                    || IEarnEngine(engine).valueOf(engineSharesAfter) != engineAssetsBefore
            ) {
                revert EngineChangedDuringCallback();
            }
        }

        uint256 engineSharesBurned = IEarnEngineExactWithdraw(engine).withdraw(assets, receiver);
        if (engineSharesBurned == 0) revert InsufficientOutput();
        // Written once, with the anchor below.
        uint256 managedAfter = _loweredManagedEngineShares(engineSharesBurned);
        earnSharesBurned = _toEarnSharesUp(engineSharesBurned, rateEngineShares, rateEarnShares);
        if (earnSharesBurned == 0) revert InsufficientOutput();
        if (earnSharesBurned > (callback ? requiredEarnShares : maxEarnShares)) revert ExceedsMaxEarnShares();
        // The burned EarnShare covers the engine shares withdrawn at the pre-withdraw anchor, rounded up, and the
        // managed count falls by exactly those shares.
        /// @custom:assert earnSharesBurned == _specCeilDiv(engineSharesBurned * rateEarnShares, rateEngineShares)
        /// @custom:assert earnSharesBurned * rateEngineShares >= engineSharesBurned * rateEarnShares
        /// @custom:assert managedAfter + engineSharesBurned == _managedEngineShares
        if (engineSharesBurned == engineSharesBefore && assets < engineAssetsBefore) revert ResidualBacking();
        // Only EarnShare moves from here on, so this raw read also serves the re-anchor.
        uint256 rawAfter = rawEngineShares();
        if (earnSharesBurned == supply) {
            if ((rawAfter < managedAfter ? rawAfter : managedAfter) != 0) revert ResidualBacking();
        }

        if (!callback) {
            _collectEarnShares(earnSharesBurned, false);
        } else if (requiredEarnShares != earnSharesBurned) {
            // A receive policy can redirect a successful transfer, so the caller must be credited the full return.
            uint256 unburned = requiredEarnShares - earnSharesBurned;
            uint256 callerHeld = IERC20Like(earnShare).balanceOf(msg.sender);
            _safeTransfer(earnShare, msg.sender, unburned);
            if (IERC20Like(earnShare).balanceOf(msg.sender) != callerHeld + unburned) revert EarnSharesNotReturned();
        }
        IEarnShare(earnShare).burn(earnSharesBurned);

        // As in a redemption, the burn is the only supply change since the checkpoint.
        _reanchorManaged(rawAfter, supply - earnSharesBurned, managedAfter);
        /// @custom:assert _managedEngineShares <= managedAfter
        emit WithdrewExact(msg.sender, receiver, assets, earnSharesBurned);
    }

    /// @notice Files an async redemption, burns `earnShares` immediately, and records a separate
    ///         entitlement while `EarnFees` snapshots any applicable queued-growth fee state.
    /// @dev The queued backing and burned EarnShare leave active accounting atomically. If the engine
    ///      request fails, the entire transaction—including the burn—reverts.
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) + 1 && engine == old(engine)
    /// @custom:ensures _managedEngineShares < old(_managedEngineShares)
    /// @custom:ensures _specRecordedRequest(requestId, msg.sender, receiver, earnShares)
    /// @custom:ensures _specPayableReceiver(receiver)
    function requestRedeem(uint256 earnShares, bytes calldata engineData, address receiver)
        external
        override
        nonReentrant
        returns (bytes32 requestId)
    {
        return _requestRedeem(earnShares, engineData, receiver);
    }

    /// @notice Requests redemption to `receiver`, ordered consistently with other explicit-receiver calls.
    /// @dev Equivalent to the legacy overload with `engineData` before `receiver`.
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) + 1 && engine == old(engine)
    /// @custom:ensures _managedEngineShares < old(_managedEngineShares)
    /// @custom:ensures _specRecordedRequest(requestId, msg.sender, receiver, earnShares)
    /// @custom:ensures _specPayableReceiver(receiver)
    function requestRedeem(uint256 earnShares, address receiver, bytes calldata engineData)
        external
        override
        nonReentrant
        returns (bytes32 requestId)
    {
        return _requestRedeem(earnShares, engineData, receiver);
    }

    /// @notice Requests redemption with the caller as both requester and stored receiver.
    /// @dev Separate selector for access keys scoped to self-recipient calls.
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) + 1 && engine == old(engine)
    /// @custom:ensures _managedEngineShares < old(_managedEngineShares)
    /// @custom:ensures _specRecordedRequest(requestId, msg.sender, msg.sender, earnShares)
    /// @custom:ensures _specPayableReceiver(msg.sender)
    function requestRedeem(uint256 earnShares, bytes calldata engineData)
        external
        override
        nonReentrant
        returns (bytes32 requestId)
    {
        return _requestRedeem(earnShares, engineData, msg.sender);
    }

    /// @dev Not proved: the receiver is paid at least a floor of its choosing; the vault takes no asset floor
    ///      for an async request, and the engine fixes the queued payout that finalization forwards.
    function _requestRedeem(uint256 earnShares, bytes calldata engineData, address receiver)
        internal
        returns (bytes32 requestId)
    {
        if (earnShares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        // The payout and a cancellation's re-entry go only to this receiver, so it must be able to take both.
        address engine_ = engine;
        if (receiver == address(this) || receiver == engine_ || _isTip20Address(receiver)) {
            revert InvalidReceiver(receiver);
        }
        // Async redemption stays a live check, as an engine may add or remove its queue. Installing the engine
        // proved it answers ERC-165 ({initialize}, {migrateEngine}), so only the interface itself is queried.
        if (!ERC165Checker.supportsERC165InterfaceUnchecked(engine_, type(IEarnEngineAsyncRedeem).interfaceId)) {
            revert EngineCapabilityUnsupported(type(IEarnEngineAsyncRedeem).interfaceId);
        }

        Checkpoint memory c = _accrueFees();
        uint256 supply = c.supply;
        // Read before the request lowers the managed count, which a live anchor's engine-share side follows.
        (uint256 rateEngineShares, uint256 rateEarnShares) = _anchor();
        /// @custom:assert rateEngineShares == _specAnchorEngine() && rateEarnShares == _specAnchorEarn()

        uint256 engineSharesToRedeem = _toEngineShares(earnShares, rateEngineShares, rateEarnShares);
        if (engineSharesToRedeem == 0) revert InsufficientOutput();
        _requireAcceptableEarnShareConversion(earnShares, engineSharesToRedeem, rateEngineShares, rateEarnShares);

        _safeTransferFrom(earnShare, msg.sender, address(this), earnShares);
        IEarnShare(earnShare).burn(earnShares);

        requestId = IEarnEngineAsyncRedeem(engine_).requestRedeem(engineSharesToRedeem, engineData);
        // Written once, with the anchor below.
        uint256 managedAfter = _loweredManagedEngineShares(engineSharesToRedeem);

        // The checkpoint valued the pool exactly when fees are on and the valuation is fresh for a live supply,
        // which the burn just proved; EarnFees snapshots the request only then.
        _recordPendingRedeem(requestId, msg.sender, receiver, earnShares, c.valued);
        // The burned EarnShare and the queued engine shares agree at the post-checkpoint anchor, within the
        // one-basis-point conversion bound, and the queued shares left active backing.
        /// @custom:assert _pending[requestId].burnedEarnShares == earnShares
        /// @custom:assert _pending[requestId].receiver == (receiver == msg.sender ? address(0) : receiver)
        /// @custom:assert _pending[requestId].requester == msg.sender
        /// @custom:assert engineSharesToRedeem == earnShares * rateEngineShares / rateEarnShares
        /// @custom:assert _specAcceptableLoss(earnShares, engineSharesToRedeem * rateEarnShares / rateEngineShares)

        _openRedeemRequestCount += 1;
        // As in a redemption, the burn is the only supply change since the checkpoint.
        _reanchorManaged(rawEngineShares(), supply - earnShares, managedAfter);
        emit RedeemRequested(requestId, msg.sender, receiver, earnShares);
    }

    /// @notice ENGINE-ONLY. Forwards a solved queued payout to the stored receiver and closes the
    ///         pending claim. No EarnShare is burned here because it was burned at request time.
    /// @notice Only the engine finalizes, in the vault's asset, an open request, which closes.
    /// @custom:ensures msg.sender == engine && asset_ == asset && old(_pending[requestId].requester) != address(0)
    /// @custom:ensures _pending[requestId].requester == address(0)
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) - 1 && engine == old(engine)
    /// @custom:ensures _specClosedRequest(requestId)
    function finalizeRedeem(bytes32 requestId, address asset_, uint256 amount) external nonReentrant {
        if (msg.sender != engine) revert NotEngine();
        if (asset_ != asset) revert FinalizedAssetMismatch(asset_);
        StoredRedeem storage p = _pending[requestId];
        address requester = p.requester;
        if (requester == address(0)) revert RequestNotOpen(requestId);

        address receiver = _receiverOf(p);
        uint256 earnShares = p.burnedEarnShares;
        bool feeSnapshot = p.feeSnapshot;
        /// @custom:ghost openCount = openCount - 1
        delete _pending[requestId];
        _openRedeemRequestCount -= 1;
        // EarnFees holds a snapshot only for a request that recorded one here, and closing a request without
        // one changes nothing there, so such a request skips the call.
        if (feeSnapshot) IEarnFees(earnFees).closeRedeemRequest(requestId);

        // The engine already sent `amount` of `asset_` here; forward it to the stored receiver.
        if (amount != 0) _safeTransfer(asset_, receiver, amount);

        if (receiver.code.length != 0) {
            try IAsyncRedeemReceiver(receiver).onRedeemFinalized(requestId, asset_, amount) { } catch { }
        }

        emit RedeemFinalized(requestId, receiver, earnShares, asset_, amount);
    }

    /// @notice Cancels a still-open async request. The returned engine shares re-enter at the active
    ///         pool's current price, snapshotted fee terms apply to queued growth, and the resulting
    ///         EarnShare is minted to the same stored receiver used by finalization.
    /// @param minReceiverEarnShares Nonzero minimum EarnShare that the stored receiver must receive.
    /// @notice The requester or the async janitor cancels an open request, which closes.
    /// @custom:ensures msg.sender == old(_pending[requestId].requester) || msg.sender == old(asyncJanitor)
    /// @custom:ensures old(_pending[requestId].requester) != address(0) && _pending[requestId].requester == address(0)
    /// @custom:ensures minReceiverEarnShares != 0
    /// @custom:ensures _openRedeemRequestCount == old(_openRedeemRequestCount) - 1 && engine == old(engine)
    /// @custom:ensures feeCheckpoints == old(feeCheckpoints) + 1 && _specClosedRequest(requestId)
    /// @dev Not proved: when the cancellation reopens an empty pool, the fee baselines restart at the
    ///      re-entry's value; EarnFees sets them when it settles the cancellation.
    ///      Not proved: for an open request, called by its requester or the janitor with a nonzero minimum,
    ///      an engine that returns the queued shares and values them, and a minimum the re-entry meets, a
    ///      cancellation returns normally.
    function cancelRedeem(bytes32 requestId, uint256 minReceiverEarnShares) external override nonReentrant {
        if (minReceiverEarnShares == 0) revert ZeroMinimumEarnShares();
        StoredRedeem storage p = _pending[requestId];
        address requester = p.requester;
        if (requester == address(0)) revert RequestNotOpen(requestId);
        if (msg.sender != requester && msg.sender != asyncJanitor) revert NotRequesterOrJanitor();

        address receiver = _receiverOf(p);
        uint256 burnedEarnShares = p.burnedEarnShares;
        bool feeSnapshot = p.feeSnapshot;

        Checkpoint memory c = _accrueFees();
        // Read before the returned shares raise the managed count, which a live anchor's engine-share side follows.
        (uint256 rateEngineShares, uint256 rateEarnShares) = _anchor();
        // EarnFees holds a snapshot only for a request that recorded one, so only such a request can be charged.
        bool chargePending = feeSnapshot && IEarnFees(earnFees).shouldChargeRedeem(requestId);
        uint256 activeSupply = c.supply;
        // A chargeable snapshot needs fees on and a fresh valuation, so the checkpoint valued the active backing.
        uint256 activeAssets =
            activeSupply == 0 || !chargePending ? 0 : (c.valued ? c.value : IEarnEngine(engine).valueOf(c.held));
        // Nothing since the checkpoint moved engine shares.
        uint256 heldBefore = c.raw;

        IEarnEngineAsyncRedeem(engine).cancelRedeem(requestId);
        uint256 heldAfter = rawEngineShares();
        if (heldAfter <= heldBefore) revert InsufficientOutput();
        uint256 returnedEngineShares = heldAfter - heldBefore;
        _increaseManagedEngineShares(returnedEngineShares);

        /// @custom:ghost openCount = openCount - 1
        delete _pending[requestId];
        _openRedeemRequestCount -= 1;

        uint256 totalReentryEarnShares;
        uint256 returnedValue;
        if (chargePending) {
            returnedValue = IEarnEngine(engine).valueOf(returnedEngineShares);
            if (returnedValue == 0) revert InsufficientOutput();
        }
        if (activeSupply == 0) {
            totalReentryEarnShares = burnedEarnShares;
        } else if (chargePending) {
            if (activeAssets == 0) revert InsufficientOutput();
            uint256 valueBasedReentry = Math.mulDiv(returnedValue, activeSupply, activeAssets);
            uint256 shareBasedReentry = _toEarnShares(returnedEngineShares, rateEngineShares, rateEarnShares);
            totalReentryEarnShares = valueBasedReentry < shareBasedReentry ? valueBasedReentry : shareBasedReentry;
        } else {
            totalReentryEarnShares = _toEarnShares(returnedEngineShares, rateEngineShares, rateEarnShares);
        }
        if (totalReentryEarnShares == 0) revert InsufficientOutput();

        // Without a snapshot EarnFees charges and closes nothing; it then acts only to restart the baselines of an
        // empty pool this re-entry reopens while fees are on, so otherwise the call is skipped.
        uint256 feeEarnShares;
        if (feeSnapshot || (activeSupply == 0 && feesActiveCached)) {
            feeEarnShares = IEarnFees(earnFees)
                .settleCancelledRedeem(
                    requestId, burnedEarnShares, returnedValue, activeSupply, activeAssets, totalReentryEarnShares
                );
            if (feeEarnShares != 0) IEarnShare(earnShare).mint(earnFees, feeEarnShares);
        }
        uint256 receiverEarnShares = totalReentryEarnShares - feeEarnShares;

        if (activeSupply != 0) {
            _requireAcceptableConversion(returnedEngineShares, totalReentryEarnShares, rateEngineShares, rateEarnShares);
        }
        if (receiverEarnShares == 0) revert InsufficientOutput();
        if (receiverEarnShares < minReceiverEarnShares) {
            revert MinimumEarnSharesNotMet(minReceiverEarnShares, receiverEarnShares);
        }
        // Fees are checkpointed before the re-entry is minted, and the fee and receiver shares split it.
        /// @custom:assert feeCheckpoints == old(feeCheckpoints) + 1
        /// @custom:assert receiverEarnShares + feeEarnShares == totalReentryEarnShares && receiverEarnShares >= minReceiverEarnShares
        IEarnShare(earnShare).mint(receiver, receiverEarnShares);
        // The re-entry mints are the only supply change since the checkpoint, wherever they land, and nothing
        // moved engine shares since the cancellation's raw read.
        if (activeSupply == 0) {
            // The full exit already reset the reward baseline. Restoring its position must not
            // turn the returned backing into fresh contribution headroom.
            _reanchorAtRestRaw(heldAfter, totalReentryEarnShares);
        } else {
            (uint256 pooledSupply, uint256 pooledBacking) = _reanchorAfterEntryRaw(
                rateEngineShares, rateEarnShares, heldAfter, activeSupply + totalReentryEarnShares, _managedEngineShares
            );
            // The active pool was just checkpointed and the queued growth was just charged, so the mark may
            // only rise to the pooled value. Otherwise a small active pool, such as a seed unit whose value
            // rounds down, leaves the mark low and the next checkpoint charges the queued growth again.
            // EarnFees ignores the call while fees are off, so the pooled backing is valued only when it counts.
            if (chargePending && feesActiveCached) {
                IEarnFees(earnFees).initializeBaselines(pooledSupply, IEarnEngine(engine).valueOf(pooledBacking));
            }
        }

        if (receiver.code.length != 0) {
            try IAsyncRedeemReceiver(receiver).onRedeemCancelled(requestId, earnShare, receiverEarnShares) { } catch { }
        }

        emit RedeemCancelled(requestId, receiver, receiverEarnShares);
    }

    /// @notice OPERATOR-ONLY when the deployment-fixed policy permits it. Atomically swaps
    ///         the yield engine in ONE tx: redeems ALL raw engine-share custody from the current engine to
    ///         stablecoins on the EarnVault, deposits it into
    ///         `newEngine` (which becomes the sole custodian of the new venue shares), repoints
    ///         `engine`, and RE-ANCHORS accounting so TIP20 totalSupply is UNCHANGED.
    /// @dev ATOMICITY: any failing leg (old-engine redeem, new-engine deposit) reverts the WHOLE tx, so
    ///      a failed migration leaves the pool entirely on the old engine. Requires no open async exits
    ///      (`openRedeemRequestCount == 0`), because in-flight queued shares cannot be re-homed atomically, and
    ///      the new engine's asset must match this EarnVault's single asset.
    /// @dev RE-ANCHOR: TIP20 count is fixed; the old managed/raw classification is mapped proportionally
    ///      into the replacement denomination, rounding at most one replacement share toward managed backing.
    ///      The resulting managed-value error may not exceed one basis point; a coarser incompatible
    ///      denomination reverts. Pre-existing replacement-engine shares and the migrated unrecognized
    ///      fraction remain surplus.
    ///      The restated invariant `engineShares == convertToEngineShares(totalSupply)` holds exactly
    ///      after the swap. NAV per TIP20 is preserved; the share COUNT is not (that is the point).
    /// @dev TRUST: `operator` MUST be a timelock/multisig when migration is enabled because this seat can
    ///      move the entire pool's assets between venues. `UserOnly` permanently disables this path.
    /// @param newEngine Initialized replacement engine using this EarnVault and the same base asset.
    /// @param minNewEngineShares Minimum replacement engine shares accepted. When active backing exists,
    ///        the managed replacement count must independently meet the same floor.
    /// @param minAssetsRetained Minimum base-asset value retained by the replacement position. When active
    ///        backing exists, its managed value must independently meet the same floor.
    /// @notice Only the operator of an operator-migratable deployment, with no open async requests, migrates.
    /// @custom:ensures msg.sender == old(operator) && old(engineMigrationMode) == EngineMigrationMode.OperatorEnabled
    /// @custom:ensures old(_openRedeemRequestCount) == 0 && _openRedeemRequestCount == 0
    /// @custom:ensures engine == newEngine && newEngine != address(0) && newEngine != old(engine)
    /// @custom:ensures feeCheckpoints == old(feeCheckpoints) + 1
    /// @custom:ensures _specEmptyAnchor() || _managedEngineShares != 0
    /// @dev Not proved: for the operator of an operator-migratable deployment with no open requests, a
    ///      replacement engine for this vault and asset, an old engine that redeems all of its shares at once
    ///      and a replacement that takes all of the assets within the stated floors, a migration returns
    ///      normally.
    function migrateEngine(address newEngine, uint256 minNewEngineShares, uint256 minAssetsRetained)
        external
        override
        nonReentrant
        returns (uint256 newEngineShares)
    {
        if (engineMigrationMode != EngineMigrationMode.OperatorEnabled) revert OperatorMigrationDisabled();
        if (msg.sender != operator) revert NotOperator();
        if (newEngine == address(0)) revert ZeroAddress();
        address oldEngine = engine;
        if (newEngine == oldEngine) revert SameEngine();
        if (_openRedeemRequestCount != 0) revert PendingRedeemsOpen();
        _requireCapability(newEngine, type(IEarnEngine).interfaceId);
        _requireExitCapability(newEngine);
        if (IEarnEngine(newEngine).asset() != asset) revert EngineAssetMismatch();
        if (IEarnEngine(newEngine).earnVault() != address(this)) revert EngineEarnVaultMismatch();
        if (IEarnEngine(newEngine).shareScale() == 0) revert InvalidEngineShareScale();

        // The checkpoint's managed backing is engineShares() after it, and nothing since moved engine shares.
        Checkpoint memory c = _accrueFees();
        uint256 supply = c.supply;
        uint256 oldEngineShares = c.held;
        uint256 oldRawEngineShares = c.raw;
        uint256 assetsMoved = 0;
        uint256 receivedNewEngineShares;
        if (oldRawEngineShares != 0) {
            if (minNewEngineShares == 0) revert ZeroMinimumEngineShares();
            if (minAssetsRetained == 0) revert ZeroMinimumAssets();
            _requireEngineCapability(CAP_REDEEM, type(IEarnEngineRedeem).interfaceId);
            // Leg 1 — pull ALL raw custody out of the old engine to the EarnVault. A dry/queue-only venue that
            // cannot honor a full immediate redemption reverts here and the whole migration rolls back.
            uint256 assetBalanceBefore = IERC20Like(asset).balanceOf(address(this));
            uint256 reportedAssetsMoved = IEarnEngineRedeem(oldEngine).redeem(oldRawEngineShares, address(this), 0);
            uint256 assetBalanceAfter = IERC20Like(asset).balanceOf(address(this));
            if (assetBalanceAfter <= assetBalanceBefore) revert InsufficientOutput();
            assetsMoved = assetBalanceAfter - assetBalanceBefore;
            if (reportedAssetsMoved != assetsMoved) revert InsufficientOutput();
            if (IEarnEngine(oldEngine).totalShares() != 0) revert ResidualBacking();

            // Leg 2 — deposit everything into the new engine, which mints and holds the new venue shares.
            _approveEngine(newEngine, assetsMoved);
            uint256 rawSharesBefore = IEarnEngine(newEngine).totalShares();
            uint256 reportedEngineShares = IEarnEngine(newEngine).deposit(assetsMoved);
            // The share delta proves what arrived at the destination, while this balance check proves
            // the replacement consumed the complete measured source redemption. Otherwise an under-pulling
            // engine could leave base assets permanently stranded outside managed NAV.
            if (IERC20Like(asset).balanceOf(address(this)) != assetBalanceBefore) revert InsufficientOutput();
            uint256 rawSharesAfter = IEarnEngine(newEngine).totalShares();
            if (rawSharesAfter <= rawSharesBefore) revert InsufficientOutput();
            receivedNewEngineShares = rawSharesAfter - rawSharesBefore;
            if (receivedNewEngineShares != reportedEngineShares) revert InsufficientOutput();
            if (receivedNewEngineShares < minNewEngineShares) {
                revert MinimumEngineSharesNotMet(minNewEngineShares, receivedNewEngineShares);
            }

            uint256 replacementAssets = IEarnEngine(newEngine).valueOf(receivedNewEngineShares);
            if (replacementAssets < minAssetsRetained) {
                revert MinimumAssetsNotMet(minAssetsRetained, replacementAssets);
            }

            // Preserve the old managed/raw split in the replacement denomination. Rounding favors
            // active backing by at most one replacement share so migration cannot confiscate principal.
            if (oldEngineShares == oldRawEngineShares) {
                newEngineShares = receivedNewEngineShares;
            } else if (oldEngineShares != 0) {
                newEngineShares =
                    Math.mulDiv(receivedNewEngineShares, oldEngineShares, oldRawEngineShares, Math.Rounding.Ceil);
            }
            // Active backing of at most one basis point of the custody, such as a seed unit beside surplus, is
            // dust: the total floors above already protect the move, and the classification error is bounded
            // by one basis point of the whole replacement position instead of the dust's own value.
            bool dustBacking = oldEngineShares <= oldRawEngineShares / CONVERSION_BPS;
            if (oldEngineShares != 0) {
                if (!dustBacking && newEngineShares < minNewEngineShares) {
                    revert MinimumEngineSharesNotMet(minNewEngineShares, newEngineShares);
                }
                uint256 assetsRetained = IEarnEngine(newEngine).valueOf(newEngineShares);
                if (oldEngineShares != oldRawEngineShares) {
                    uint256 expectedManagedAssets = Math.mulDiv(replacementAssets, oldEngineShares, oldRawEngineShares);
                    _requireAcceptableMigrationClassification(
                        expectedManagedAssets, assetsRetained, dustBacking ? replacementAssets : expectedManagedAssets
                    );
                }
                if (!dustBacking && assetsRetained < minAssetsRetained) {
                    revert MinimumAssetsNotMet(minAssetsRetained, assetsRetained);
                }
            }
        }

        // The retired engine keeps no standing allowance over the vault's base asset.
        _safeApprove(asset, oldEngine, 0);
        /// @custom:ghost trackedEngine = newEngine
        engine = newEngine;
        engineCapabilities = _engineCapabilities(newEngine);

        // Re-anchor from the recognized count. Pre-existing replacement shares and the migrated
        // unrecognized fraction both remain surplus on the current, reachable engine.
        uint256 heldNow = newEngineShares;
        if (supply == 0 || heldNow == 0) {
            _resetEmptyAnchor(newEngine, heldNow);
        } else {
            _setAnchor(heldNow, supply);
            // A migration changes raw engine-share denomination. Start a fresh fixed-100x contribution
            // window from the replacement engine's actual post-migration normalized rate.
            _setRewardRateBaseline(_normalizedRate(heldNow, supply));
        }

        (uint256 anchorEngine, uint256 anchorEarn) = _anchor();
        emit EngineMigrated(
            oldEngine, newEngine, oldEngineShares, assetsMoved, newEngineShares, supply, anchorEngine, anchorEarn
        );
    }

    /// @notice Estimates the base assets returned by redeeming `earnShares` of EarnShare through the
    ///         current engine after crystallizing any currently representable Earn-level fees.
    /// @dev Mirrors the fee-share mint and measured-backing reconciliation performed at the start of
    ///      `redeem`, then delegates engine-share valuation to the current engine so applicable venue
    ///      exit fees are reflected. This is a quote only; engine valuation may revert or change
    ///      before execution.
    function previewRedeem(uint256 earnShares) public view override returns (uint256 assets) {
        if (earnShares == 0) return 0;
        _requireEngineCapability(CAP_REDEEM, type(IEarnEngineRedeem).interfaceId);
        (uint256 engineShareAnchor, uint256 supplyAnchor) = _previewConversionAnchor();
        uint256 engineSharesToRedeem = Math.mulDiv(earnShares, engineShareAnchor, supplyAnchor);
        if (engineSharesToRedeem == 0) return 0;
        return IEarnEngineRedeem(engine).previewRedeem(engineSharesToRedeem);
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256 earnShares) {
        _requireEngineCapability(CAP_EXACT_WITHDRAW, type(IEarnEngineExactWithdraw).interfaceId);
        uint256 engineSharesToWithdraw = IEarnEngineExactWithdraw(engine).previewWithdraw(assets);
        (uint256 engineShareAnchor, uint256 supplyAnchor) = _previewConversionAnchor();
        if (engineShareAnchor == 0) revert ActiveSupplyWithoutBacking();
        return Math.mulDiv(engineSharesToWithdraw, supplyAnchor, engineShareAnchor, Math.Rounding.Ceil);
    }

    function engineShares() public view override returns (uint256) {
        uint256 managed = _managedEngineShares;
        uint256 raw = rawEngineShares();
        return raw < managed ? raw : managed;
    }

    /// @notice Engine-share side of the conversion anchor.
    function anchorEngineShares() external view returns (uint256 engineShares_) {
        (engineShares_,) = _anchor();
    }

    /// @notice EarnShare side of the conversion anchor.
    function anchorEarnShares() external view returns (uint256 earnShares) {
        (, earnShares) = _anchor();
    }

    /// @notice Number of open async redeem requests.
    function openRedeemRequestCount() external view override returns (uint256) {
        return _openRedeemRequestCount;
    }

    /// @notice Raw engine-share custody, including quarantined unsolicited shares.
    function rawEngineShares() public view override returns (uint256) {
        return IEarnEngine(engine).totalShares();
    }

    /// @notice Raw engine shares not currently recognized as active EarnShare backing.
    function surplusEngineShares() public view override returns (uint256) {
        uint256 raw = rawEngineShares();
        uint256 managed = _managedEngineShares;
        return raw > managed ? raw - managed : 0;
    }

    /// @notice Base-asset value of active managed backing. Quarantined engine shares are excluded.
    function totalAssets() public view override returns (uint256 assets) {
        return IEarnEngine(engine).valueOf(engineShares());
    }

    /// @notice Whether the current engine's NAV is safe for irreversible Earn-level fee accounting.
    /// @dev Engines without the optional freshness capability are treated as non-expiring. A Veda
    ///      engine advertises the capability and applies its configured Accountant report-age policy.
    function isFeeValuationFresh() public view override returns (bool) {
        address currentEngine = engine;
        if (engineCapabilities & CAP_FEE_VALUATION == 0) return true;
        return IEarnEngineFeeValuation(currentEngine).isFeeValuationFresh();
    }

    /// @notice Additional assets that may enter before reaching the current managed-assets limit.
    /// @dev Returns `type(uint256).max` when no limit is configured. This is a quote, not a reservation;
    ///      venue value and concurrent inflows may change before execution.
    /// @custom:ensures _maxManagedAssets == 0 ==> assets == type(uint256).max
    /// @custom:ensures _maxManagedAssets != 0 ==> assets <= _maxManagedAssets
    function remainingDepositCapacity() external view override returns (uint256 assets) {
        uint256 maximum = _maxManagedAssets;
        if (maximum == 0) return type(uint256).max;
        uint256 managed = totalAssets();
        return managed >= maximum ? 0 : maximum - managed;
    }

    /// @notice Current normalized managed engine shares per whole EarnShare, including pending fee dilution.
    function normalizedRewardRate() public view override returns (uint256) {
        (uint256 engineShareAnchor, uint256 supplyAnchor) = _previewConversionAnchor();
        return _normalizedRate(engineShareAnchor, supplyAnchor);
    }

    /// @dev The unit this vault keeps and the unit it minted EarnFees count as burned, so both balance slots stay
    ///      nonzero across exits. Neither unit ever leaves: this vault never approves a spender of its EarnShare and
    ///      moves out only EarnShare it took in within the same call, and EarnFees pays out only recorded claims,
    ///      which this vault minted to it on top of its unit. EarnShare anyone sends this vault stays supply.
    function _activeSupply() internal view returns (uint256) {
        return IEarnShare(earnShare).totalSupply() - LOCKED_EARN_SHARES;
    }

    function totalEarnShares() public view override returns (uint256) {
        return _activeSupply();
    }

    /// @notice Checks that live EarnShare supply converts exactly to active engine shares at the
    ///         current anchor. Pending async claims are excluded from both sides because their
    ///         EarnShare was burned when their engine shares entered the queue.
    function isAccountingAligned() external view override returns (bool) {
        uint256 supply = totalEarnShares();
        uint256 held = engineShares();
        // The anchor stores active supply, which never counts the minted residue, so no other pair applies.
        return _aligned(supply, held);
    }

    function _aligned(uint256 supply, uint256 held) internal view returns (bool) {
        if (supply == 0 || held == 0) return supply == 0 && held == 0;
        return _convertToEngineShares(supply) == held;
    }

    /// @notice Reads the async request `requestId`: its receiver, requester, burned EarnShare, and whether it is
    ///         open. A closed or unknown request reads as all zero.
    function pendingRedeem(bytes32 requestId) external view returns (PendingRedeem memory) {
        StoredRedeem storage p = _pending[requestId];
        address requester = p.requester;
        return PendingRedeem({
            receiver: _receiverOf(p),
            requester: requester,
            burnedEarnShares: p.burnedEarnShares,
            open: requester != address(0)
        });
    }

    /// @notice Converts an EarnShare amount to engine shares at the current re-anchored rate.
    function convertToEngineShares(uint256 earnShares) external view override returns (uint256 engineShares_) {
        return _convertToEngineShares(earnShares);
    }

    /// @notice Converts an engine-share amount to EarnShare at the current re-anchored rate.
    function convertEngineSharesToEarnShares(uint256 engineShares_)
        external
        view
        override
        returns (uint256 earnShares)
    {
        return _convertEngineSharesToEarnShares(engineShares_);
    }

    /// @dev The conversion anchor. Between calls it is exact; within a call, read it before managed backing changes,
    ///      since a live anchor's engine-share side is the managed count.
    /// @custom:ensures engineShares_ == _specAnchorEngine() && earnShares == _specAnchorEarn()
    /// @custom:succeeds-if _anchorEarnShares != EMPTY_ANCHOR || _earnShareDecimals <= 77
    function _anchor() internal view returns (uint256 engineShares_, uint256 earnShares) {
        earnShares = _anchorEarnShares;
        if (earnShares == EMPTY_ANCHOR) return (rewardRateBaseline(), _earnShareScale());
        engineShares_ = _managedEngineShares;
    }

    /// @custom:ensures result == earnShares * _specAnchorEngine() / _specAnchorEarn()
    function _convertToEngineShares(uint256 earnShares) internal view returns (uint256) {
        (uint256 rateEngineShares, uint256 rateEarnShares) = _anchor();
        return _toEngineShares(earnShares, rateEngineShares, rateEarnShares);
    }

    /// @custom:ensures result == engineShares_ * _specAnchorEarn() / _specAnchorEngine()
    function _convertEngineSharesToEarnShares(uint256 engineShares_) internal view returns (uint256) {
        (uint256 rateEngineShares, uint256 rateEarnShares) = _anchor();
        return _toEarnShares(engineShares_, rateEngineShares, rateEarnShares);
    }

    /// @custom:ensures result == earnShares * rateEngineShares / rateEarnShares
    /// @custom:succeeds-if rateEarnShares != 0 && earnShares * rateEngineShares / rateEarnShares <= type(uint256).max
    function _toEngineShares(uint256 earnShares, uint256 rateEngineShares, uint256 rateEarnShares)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(earnShares, rateEngineShares, rateEarnShares);
    }

    /// @custom:ensures result == engineShares_ * rateEarnShares / rateEngineShares
    /// @custom:succeeds-if rateEngineShares != 0 && engineShares_ * rateEarnShares / rateEngineShares <= type(uint256).max
    function _toEarnShares(uint256 engineShares_, uint256 rateEngineShares, uint256 rateEarnShares)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(engineShares_, rateEarnShares, rateEngineShares);
    }

    /// @custom:ensures result == _specCeilDiv(engineShares_ * rateEarnShares, rateEngineShares)
    function _toEarnSharesUp(uint256 engineShares_, uint256 rateEngineShares, uint256 rateEarnShares)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(engineShares_, rateEarnShares, rateEngineShares, Math.Rounding.Ceil);
    }

    /// @dev Rejects entries whose floor-rounded EarnShare output represents materially less than
    ///      the engine shares that entered. The one-basis-point protocol ceiling protects callers even
    ///      when a tiny active supply makes an already-quoted conversion pathologically coarse. The rate is the
    ///      anchor the entry was priced at.
    /// @custom:ensures _specAcceptableLoss(inputShares, outputTokens * rateEngineShares / rateEarnShares)
    /// @custom:succeeds-if rateEarnShares != 0 && _specAcceptableLoss(inputShares, outputTokens * rateEngineShares / rateEarnShares)
    function _requireAcceptableConversion(
        uint256 inputShares,
        uint256 outputTokens,
        uint256 rateEngineShares,
        uint256 rateEarnShares
    ) internal pure {
        uint256 representedShares = _toEngineShares(outputTokens, rateEngineShares, rateEarnShares);
        _requireAcceptableLoss(inputShares, representedShares);
    }

    /// @custom:ensures _specAcceptableLoss(inputTokens, outputShares * rateEarnShares / rateEngineShares)
    /// @custom:succeeds-if rateEngineShares != 0 && _specAcceptableLoss(inputTokens, outputShares * rateEarnShares / rateEngineShares)
    function _requireAcceptableEarnShareConversion(
        uint256 inputTokens,
        uint256 outputShares,
        uint256 rateEngineShares,
        uint256 rateEarnShares
    ) internal pure {
        uint256 representedTokens = _toEarnShares(outputShares, rateEngineShares, rateEarnShares);
        _requireAcceptableLoss(inputTokens, representedTokens);
    }

    /// @custom:ensures _specAcceptableLoss(inputAmount, representedAmount)
    /// @custom:succeeds-if _specAcceptableLoss(inputAmount, representedAmount)
    function _requireAcceptableLoss(uint256 inputAmount, uint256 representedAmount) internal pure {
        if (representedAmount > inputAmount) revert ExcessiveConversionLoss(inputAmount, representedAmount);
        uint256 maximumLoss = inputAmount / CONVERSION_BPS;
        if (inputAmount - representedAmount > maximumLoss) {
            revert ExcessiveConversionLoss(inputAmount, representedAmount);
        }
    }

    /// @dev A replacement denomination must represent the old managed/raw split without transferring
    ///      economically material value between active backing and quarantined surplus. Share-count
    ///      rounding favors managed backing, but its value error may not exceed one basis point of
    ///      `referenceAssets`: the managed value itself, or the whole replacement position when the managed
    ///      backing is dust.
    /// @custom:ensures _specDistance(actualManagedAssets, expectedManagedAssets) <= referenceAssets / CONVERSION_BPS
    /// @custom:succeeds-if _specDistance(actualManagedAssets, expectedManagedAssets) <= referenceAssets / CONVERSION_BPS
    function _requireAcceptableMigrationClassification(
        uint256 expectedManagedAssets,
        uint256 actualManagedAssets,
        uint256 referenceAssets
    ) internal pure {
        uint256 difference = actualManagedAssets > expectedManagedAssets
            ? actualManagedAssets - expectedManagedAssets
            : expectedManagedAssets - actualManagedAssets;
        if (difference > referenceAssets / CONVERSION_BPS) {
            revert ExcessiveMigrationClassificationError(expectedManagedAssets, actualManagedAssets);
        }
    }

    /// @dev Projects the exact conversion anchor that `_accrueFees` and `_reanchorAtRest` would leave
    ///      in this block, including pending fee-share minting and managed custody shortfall.
    function _previewConversionAnchor() internal view returns (uint256 engineShareAnchor, uint256 supplyAnchor) {
        (engineShareAnchor, supplyAnchor) = _anchor();

        uint256 feeEarnShares = feesActiveCached ? IEarnFees(earnFees).previewAccruedFees().totalFeeEarnShares : 0;
        uint256 projectedSupply = _activeSupply() + feeEarnShares;
        uint256 held = engineShares();
        if (projectedSupply == 0) {
            return (IEarnEngine(engine).shareScale(), _earnShareScale());
        }
        if (held == 0) return (0, projectedSupply);
        if (projectedSupply == supplyAnchor && held == engineShareAnchor) {
            return (engineShareAnchor, supplyAnchor);
        }
        return (held, projectedSupply);
    }

    /// @dev A principal deposit must not recapitalize existing EarnShare after its active engine
    ///      position has zero base-asset value. Instead, such a pool restarts at the empty-pool rate:
    ///      its worthless managed engine shares become surplus, and the entry is then admitted only
    ///      when the restart is negligible to everyone ({_requireNegligibleRestart}).
    ///      Supply that cannot exit, such as a seed unit an ownerless router holds, can therefore never
    ///      block deposits for good. Permissionless `contribute` still restores value without a claim.
    ///      `held` is the managed backing the fee checkpoint just reconciled, which equals engineShares() there,
    ///      and `value` its valuation when the checkpoint read one (`valued`), so neither is read again.
    function _isUnbackedHeld(uint256 supply, uint256 held, uint256 value, bool valued)
        internal
        view
        returns (bool unbacked)
    {
        if (supply == 0) return false;
        if (valued) return value == 0;
        return held == 0 || IEarnEngine(engine).valueOf(held) == 0;
    }

    /// @dev Moves the worthless managed engine shares to surplus and prices the next entry at the
    ///      empty-pool rate.
    /// @custom:ensures strandedEngineShares == old(_managedEngineShares)
    /// @custom:ensures _managedEngineShares == 0 && _specEmptyAnchor() && rewardRateBaseline() != 0
    function _restartEmptyAnchor() internal returns (uint256 strandedEngineShares) {
        strandedEngineShares = _managedEngineShares;
        _resetEmptyAnchor(engine, 0);
    }

    /// @dev A restart must not matter to anyone. The engine shares it moves to surplus must be at most one
    ///      basis point of the entry's, so a position an engine prices at zero only for now (a paused venue)
    ///      keeps deposits closed rather than being written off by one large entry. The entrant's claim after
    ///      the re-anchor, which the unbacked supply shares pro rata, must lose at most one basis point of the
    ///      engine shares it brought, counting rounding and dilution together. The entry must also carry
    ///      backing: engine shares valued at zero, such as an impaired venue's, would only grow the
    ///      unbacked supply. That valuation is the engine's and is not proved here.
    /// @custom:ensures strandedEngineShares <= receivedEngineShares / CONVERSION_BPS
    /// @custom:ensures _specAcceptableLoss(receivedEngineShares, receivedEngineShares * earnShares / (earnShares + unbackedSupply))
    function _requireNegligibleRestart(
        uint256 unbackedSupply,
        uint256 strandedEngineShares,
        uint256 receivedEngineShares,
        uint256 earnShares
    ) internal {
        if (IEarnEngine(engine).valueOf(receivedEngineShares) == 0) {
            revert ActiveSupplyWithoutBacking();
        }
        if (strandedEngineShares > receivedEngineShares / CONVERSION_BPS) {
            revert ActiveSupplyWithoutBacking();
        }
        uint256 claim = Math.mulDiv(receivedEngineShares, earnShares, earnShares + unbackedSupply);
        if (receivedEngineShares - claim > receivedEngineShares / CONVERSION_BPS) revert ActiveSupplyWithoutBacking();
        emit UnbackedPoolRestarted(unbackedSupply, strandedEngineShares);
    }

    /// @dev Applies only to voluntary inflows. Passive yield may exceed the limit, and exit,
    ///      cancellation, and migration paths deliberately remain available. Checks the managed backing
    ///      min(raw, managed) at the raw share count the caller just read, and returns its value when it read one.
    function _requireWithinManagedAssetsLimitAt(uint256 raw) internal view returns (uint256 value, bool valued) {
        uint256 maximum = _maxManagedAssets;
        if (maximum == 0) return (0, false);
        uint256 managed = _managedEngineShares;
        value = IEarnEngine(engine).valueOf(raw < managed ? raw : managed);
        if (value > maximum) revert MaxManagedAssetsExceeded(maximum, value);
        valued = true;
    }

    /// @dev The value of the managed backing `held` an entry just restated, read once for the managed-assets limit
    ///      and, when `baselines` and fees are on, EarnFees' baselines; zero when neither needs it.
    function _entryValue(bool baselines, uint256 held) internal view returns (uint256) {
        if (_maxManagedAssets == 0 && !(baselines && feesActiveCached)) return 0;
        return IEarnEngine(engine).valueOf(held);
    }

    /// @dev {_requireWithinManagedAssetsLimitAt} for an entry: `value` is {_entryValue}, which is read whenever a
    ///      limit is set.
    function _requireWithinManagedAssetsLimitValue(uint256 value) internal view {
        uint256 maximum = _maxManagedAssets;
        if (maximum != 0 && value > maximum) revert MaxManagedAssetsExceeded(maximum, value);
    }

    /// @dev Restates the anchor from exact active backing and supply, given the engine's raw share count and the
    ///      active supply the caller just read. Exact pair equality is required: a floor conversion can map a
    ///      changed supply to the same held count while still preserving a stale pre-fee rate that lets holders
    ///      consume backing allocated to fee EarnShare.
    /// @notice Restates the anchor from exact active backing and supply, capping managed backing at raw custody.
    function _reanchorAtRestRaw(uint256 raw, uint256 supply_) internal returns (uint256 supply, uint256 held) {
        return _reanchorManaged(raw, supply_, _managedEngineShares);
    }

    /// @dev Principal entry must not act as an implicit reward for existing holders. The EarnShare
    ///      minted at the pre-entry anchor represents an exact floor-rounded engine-share count;
    ///      only that count becomes managed backing. Any unrepresented entry remainder stays raw
    ///      surplus and may be absorbed later through the explicit capped reward path. Takes the engine's raw
    ///      share count and the active supply the caller just read.
    function _reanchorAfterEntryRaw(
        uint256 rateEngineShares,
        uint256 rateEarnShares,
        uint256 raw,
        uint256 supply_,
        uint256 managed
    ) internal returns (uint256 supply, uint256 held) {
        uint256 represented = Math.mulDiv(supply_, rateEngineShares, rateEarnShares);
        if (managed > represented) managed = represented;
        return _reanchorManaged(raw, supply_, managed);
    }

    /// @dev Restates the managed count, from `managed` capped at raw custody, and the anchor in their one slot.
    ///      An anchor that is already the empty-pool one keeps its sides: the engine and its share scale have not
    ///      changed since the reset, as only {migrateEngine} changes the engine and it re-anchors.
    /// @custom:requires managed <= type(uint128).max
    /// @custom:ensures held == _managedEngineShares && held <= managed && held <= raw
    /// @custom:ensures (supply != 0 && held != 0) ==> _anchorEarnShares == supply
    /// @custom:ensures (supply == 0 || held == 0) ==> _specEmptyAnchor()
    /// @custom:ensures (old(rewardRateBaseline()) != 0 ==> rewardRateBaseline() != 0) && _earnShareDecimals == old(_earnShareDecimals)
    function _reanchorManaged(uint256 raw, uint256 supply_, uint256 managed)
        internal
        returns (uint256 supply, uint256 held)
    {
        supply = supply_;
        held = managed;
        if (managed > raw) {
            held = raw;
            emit EngineShareShortfallReconciled(engine, managed, raw, managed - raw, supply);
        }
        // No active supply claims managed backing (an exit can empty it), so it becomes surplus.
        if (supply == 0) held = 0;
        uint256 storedManaged = _managedEngineShares;
        uint256 storedEarn = _anchorEarnShares;
        if (supply == 0 || held == 0) {
            if (storedEarn != EMPTY_ANCHOR) _resetEmptyAnchor(engine, 0);
            else if (storedManaged != 0) _managedEngineShares = 0;
            return (supply, held);
        }
        if (storedEarn == supply && storedManaged == held && storedEarn != EMPTY_ANCHOR) return (supply, held);

        _setAnchor(held, supply);
    }

    /// @dev Empty pools use whole-share units instead of a raw-unit 1:1 rate. This keeps the first
    ///      EarnShare mint normalized even when the engine and EarnShare use different decimals. Sets the managed
    ///      count beside it.
    /// @custom:ensures _specEmptyAnchor() && rewardRateBaseline() != 0 && _managedEngineShares == managed
    function _resetEmptyAnchor(address engine_, uint256 managed) internal {
        uint256 engineShareScale = IEarnEngine(engine_).shareScale();
        if (engineShareScale == 0) revert InvalidEngineShareScale();
        _setManagedEngineShares(managed);
        _anchorEarnShares = uint128(EMPTY_ANCHOR);
        _setRewardRateBaseline(engineShareScale);
    }

    /// @dev Writes a live anchor: the managed count and the supply it backs. A count past uint128, or a supply
    ///      reaching {EMPTY_ANCHOR}, reverts rather than truncating.
    /// @custom:ensures _managedEngineShares == engineShares_ && _anchorEarnShares == earnShares_
    /// @custom:ensures _anchorEarnShares != EMPTY_ANCHOR
    function _setAnchor(uint256 engineShares_, uint256 earnShares_) internal {
        if (engineShares_ > type(uint128).max || earnShares_ >= EMPTY_ANCHOR) revert ExceedsMaxEarnShares();
        // Bounded above, so the narrowing conversions cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        _managedEngineShares = uint128(engineShares_);
        // forge-lint: disable-next-line(unsafe-typecast)
        _anchorEarnShares = uint128(earnShares_);
    }

    /// @notice Normalized engine-share units per whole EarnShare at initialization, the latest migration,
    ///         or the latest transition back to an empty pool.
    function rewardRateBaseline() public view override returns (uint256) {
        uint256 baseline = _rewardRateBaseline;
        return baseline == WIDE_RATE_BASELINE ? _wideRewardRateBaseline : baseline;
    }

    /// @dev Writes the baseline beside `earnFees`, sending a value too wide for it to its wide slot.
    function _setRewardRateBaseline(uint256 baseline) internal {
        if (baseline >= WIDE_RATE_BASELINE) {
            _wideRewardRateBaseline = baseline;
            baseline = WIDE_RATE_BASELINE;
        }
        // Below the packed width here, so the narrowing conversion cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        _rewardRateBaseline = uint96(baseline);
    }

    /// @custom:ensures _managedEngineShares == engineShares_
    /// @custom:succeeds-if engineShares_ <= type(uint128).max
    function _setManagedEngineShares(uint256 engineShares_) internal {
        if (engineShares_ > type(uint128).max) revert ExceedsMaxEarnShares();
        // Bounded above, so the narrowing conversion cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        _managedEngineShares = uint128(engineShares_);
    }

    /// @custom:ensures _managedEngineShares == old(_managedEngineShares) + engineShares_
    function _increaseManagedEngineShares(uint256 engineShares_) internal {
        _setManagedEngineShares(uint256(_managedEngineShares) + engineShares_);
    }

    /// @notice Measured custody, not the engine's report, is what becomes managed backing; both must agree. The caller
    ///         records it.
    /// @custom:ensures receivedEngineShares != 0 && receivedEngineShares == reportedEngineShares
    /// @custom:ensures receivedEngineShares == rawSharesAfter - rawSharesBefore
    function _measureEngineShareIncrease(uint256 rawSharesBefore, uint256 reportedEngineShares)
        internal
        returns (uint256 receivedEngineShares, uint256 rawSharesAfter)
    {
        rawSharesAfter = rawEngineShares();
        if (rawSharesAfter <= rawSharesBefore) revert InsufficientOutput();
        receivedEngineShares = rawSharesAfter - rawSharesBefore;
        if (reportedEngineShares != receivedEngineShares) revert InsufficientOutput();
    }

    /// @dev The managed count raised by `engineShares_`, unwritten; past uint128 it reverts as a write would.
    function _raisedManagedEngineShares(uint256 engineShares_) internal view returns (uint256 managed) {
        managed = uint256(_managedEngineShares) + engineShares_;
        if (managed > type(uint128).max) revert ExceedsMaxEarnShares();
    }

    /// @dev The managed count lowered by `engineShares_`, unwritten; more than it holds reverts.
    function _loweredManagedEngineShares(uint256 engineShares_) internal view returns (uint256) {
        uint256 managed = _managedEngineShares;
        if (engineShares_ > managed) revert InsufficientOutput();
        return managed - engineShares_;
    }

    /// @custom:ensures result == _specNormalizedRate(engineShareAnchor, supplyAnchor)
    /// @custom:ensures (engineShareAnchor != 0 && supplyAnchor != 0) ==> result != 0
    /// @custom:succeeds-if engineShareAnchor == 0 || (supplyAnchor != 0 && _earnShareDecimals <= 77 && _specNormalizedRate(engineShareAnchor, supplyAnchor) <= type(uint256).max)
    function _normalizedRate(uint256 engineShareAnchor, uint256 supplyAnchor) internal view returns (uint256) {
        if (engineShareAnchor == 0) return 0;
        return Math.mulDiv(engineShareAnchor, _earnShareScale(), supplyAnchor, Math.Rounding.Ceil);
    }

    /// @notice Contributions may raise the normalized rate to at most MAX_REWARD_RATE_MULTIPLIER times the baseline.
    /// @custom:requires rewardRateBaseline() != 0 && _specAnchorEarn() != 0
    /// @custom:ensures _specNormalizedRate(_specAnchorEngine(), _specAnchorEarn()) <= rewardRateBaseline() * MAX_REWARD_RATE_MULTIPLIER
    /// @custom:succeeds-if _specNormalizedRate(_specAnchorEngine(), _specAnchorEarn()) <= rewardRateBaseline() * MAX_REWARD_RATE_MULTIPLIER && rewardRateBaseline() * MAX_REWARD_RATE_MULTIPLIER <= type(uint256).max && _earnShareDecimals <= 77
    function _requireRewardRateWithinLimit() internal view {
        uint256 baseline = rewardRateBaseline();
        (uint256 anchorEngine, uint256 anchorEarn) = _anchor();
        uint256 current = _normalizedRate(anchorEngine, anchorEarn);
        if (!_isRewardRateWithinLimit(current, baseline)) revert RewardRateLimitExceeded(current, baseline);
    }

    /// @custom:requires baseline != 0
    /// @custom:ensures result == (current <= baseline * MAX_REWARD_RATE_MULTIPLIER)
    /// @custom:succeeds-if true
    function _isRewardRateWithinLimit(uint256 current, uint256 baseline) internal pure returns (bool) {
        uint256 wholeMultiples = current / baseline;
        return !(wholeMultiples > MAX_REWARD_RATE_MULTIPLIER
                || (wholeMultiples == MAX_REWARD_RATE_MULTIPLIER && current % baseline != 0));
    }

    /// @custom:ensures distributor != address(0) && msg.sender == distributor
    /// @custom:succeeds-if distributor != address(0) && msg.sender == distributor
    function _requireDistributor() internal view {
        if (distributor == address(0) || msg.sender != distributor) revert NotDistributor();
    }

    function _currentFeeConfig() internal view returns (FeeConfig memory) {
        IEarnFees fees = IEarnFees(earnFees);
        return fees.feeConfig(fees.currentFeeConfigId());
    }

    /// @notice An operator configuration must keep the distributor's reserved item (fees.md, "Fee policies").
    /// @custom:ensures distributor != address(0) ==> _specProtectsDistributorFee(config, _distributorFee)
    function _validateOperatorFeeConfig(FeeConfig calldata config) internal view {
        IEarnFees(earnFees).validateFeeConfig(config);
        if (distributor == address(0)) return;

        FeeConfig memory candidate = config;
        _requireProtectedDistributorFee(candidate, _distributorFee);

        DistributorFeeUpdate memory pending = _pendingDistributorFeeUpdate;
        if (!pending.pending) return;
        FixedFeeRecipient memory pendingFee =
            FixedFeeRecipient({ account: pending.recipient, rateBps: pending.rateBps });
        IEarnFees(earnFees).validateFeeConfig(_replaceDistributorFee(candidate, _distributorFee, pendingFee));
    }

    /// @notice The distributor's item is fixed fee 0, followed by the operator's items in order; the excess fee is kept.
    /// @custom:ensures _specProtectsDistributorFee(config, currentFee)
    /// @custom:ensures result.fixedFeeCount == _specOperatorFeeCount(config, currentFee) + (nextFee.rateBps != 0 ? 1 : 0)
    /// @custom:ensures nextFee.rateBps != 0 ==> _specSameFee(result.fixedFees[0], nextFee)
    /// @custom:ensures forall uint256 i :: i < _specOperatorFeeCount(config, currentFee) ==> _specOperatorFeeKept(result, config, currentFee, nextFee, i)
    /// @custom:ensures forall uint256 i :: (i >= result.fixedFeeCount && i < MAX_FIXED_FEE_RECIPIENTS) ==> _specEmptyFee(result.fixedFees[i])
    /// @custom:ensures _specSameExcess(result, config)
    function _replaceDistributorFee(
        FeeConfig memory config,
        FixedFeeRecipient memory currentFee,
        FixedFeeRecipient memory nextFee
    ) internal pure returns (FeeConfig memory result) {
        uint8 operatorStart;
        if (currentFee.rateBps != 0) {
            _requireProtectedDistributorFee(config, currentFee);
            operatorStart = 1;
        } else if (config.fixedFeeCount > 3) {
            revert InvalidDistributorFeeConfiguration();
        }

        uint8 operatorCount = config.fixedFeeCount - operatorStart;
        uint8 resultStart;
        if (nextFee.rateBps != 0) {
            result.fixedFees[0] = nextFee;
            resultStart = 1;
        }
        result.fixedFeeCount = operatorCount + resultStart;
        /// @custom:invariant i <= operatorCount && operatorCount == _specOperatorFeeCount(config, currentFee)
        /// @custom:invariant result.fixedFeeCount == operatorCount + resultStart && resultStart == (nextFee.rateBps != 0 ? 1 : 0)
        /// @custom:invariant operatorStart == (currentFee.rateBps != 0 ? 1 : 0) && operatorCount + operatorStart == config.fixedFeeCount
        // Each copy is bounds-checked, so a count above the array's length reverts before the loop ends.
        /// @custom:invariant i == 0 || resultStart + i <= MAX_FIXED_FEE_RECIPIENTS
        /// @custom:invariant nextFee.rateBps != 0 ==> _specSameFee(result.fixedFees[0], nextFee)
        /// @custom:invariant forall uint256 k :: k < i ==> _specOperatorFeeKept(result, config, currentFee, nextFee, k)
        /// @custom:invariant forall uint256 k :: (k >= resultStart + i && k < MAX_FIXED_FEE_RECIPIENTS) ==> _specEmptyFee(result.fixedFees[k])
        /// @custom:invariant _specEmptyExcess(result)
        for (uint8 i = 0; i < operatorCount; i++) {
            result.fixedFees[resultStart + i] = config.fixedFees[operatorStart + i];
        }
        result.excess = config.excess;
    }

    /// @custom:ensures _specProtectsDistributorFee(config, expected)
    /// @custom:succeeds-if _specProtectsDistributorFee(config, expected)
    function _requireProtectedDistributorFee(FeeConfig memory config, FixedFeeRecipient memory expected) internal pure {
        if (expected.rateBps == 0) {
            if (config.fixedFeeCount > 3) revert InvalidDistributorFeeConfiguration();
            return;
        }
        if (
            config.fixedFeeCount == 0 || config.fixedFees[0].account != expected.account
                || config.fixedFees[0].rateBps != expected.rateBps
        ) revert InvalidDistributorFeeConfiguration();
    }

    function _requireFreshFeeValuation() internal view {
        if (!isFeeValuationFresh()) revert FeeValuationStale();
    }

    /// @dev A fee checkpoint. No contract of its own: it calls out mid-update, so the verifier inlines it into each
    ///      caller, which holds the lock and the invariants. _reanchorManaged's contract gives the anchor facts.
    function _accrueFees() internal returns (Checkpoint memory c) {
        // Neither the checkpoint nor the fee mint moves engine shares, so one raw read serves both.
        uint256 raw = rawEngineShares();
        return _accrueFeesAt(raw, _activeSupply(), 0, false, false);
    }

    /// @dev A fee checkpoint that settles the current configuration in full, waiting accrual included, before it is
    ///      replaced, so a new configuration never charges growth earned under the old one.
    function _settleFees() internal returns (Checkpoint memory c) {
        uint256 raw = rawEngineShares();
        return _accrueFeesAt(raw, _activeSupply(), 0, false, true);
    }

    /// @dev {_accrueFees} at the engine's raw share count and the active supply the caller just read. A caller that
    ///      already valued the managed backing min(raw, managed) passes that value as `knownValue` with `known`.
    ///      While fees are off EarnFees would return an empty result, so the call is skipped.
    function _accrueFeesAt(uint256 raw, uint256 supplyBefore, uint256 knownValue, bool known, bool settle)
        internal
        returns (Checkpoint memory c)
    {
        /// @custom:ghost feeCheckpoints = feeCheckpoints + 1
        c.raw = raw;
        uint256 supplyNow = supplyBefore;
        if (feesActiveCached) {
            // EarnFees reads freshness only for a live supply, and the value (totalAssets()) only when also fresh.
            bool fresh = supplyBefore != 0 && isFeeValuationFresh();
            if (fresh) {
                uint256 managed = _managedEngineShares;
                c.value = known ? knownValue : IEarnEngine(engine).valueOf(raw < managed ? raw : managed);
                c.valued = true;
            }
            (c.feeAssets, c.feeEarnShares, c.baselineFloor, c.floorScale) = settle
                ? IEarnFees(earnFees).settleFees(supplyBefore, c.value, fresh)
                : IEarnFees(earnFees).accrueFees(supplyBefore, c.value, fresh);
            if (c.feeEarnShares != 0) {
                IEarnShare(earnShare).mint(earnFees, c.feeEarnShares);
            }
            // The fee mint is the only supply change since the read.
            supplyNow = supplyBefore + c.feeEarnShares;
        }
        // Reconcile the conversion anchor even when no fee shares were minted. Unsolicited positive
        // engine-share drift remains quarantined, while a custody shortfall reduces managed backing.
        (c.supply, c.held) = _reanchorAtRestRaw(raw, supplyNow);
    }

    /// @dev An entry that reopened an empty pool restarts the fee baselines at its own value, since every earlier
    ///      holder has left. EarnFees acts only while fees are active, so the call is skipped otherwise. Takes the
    ///      live supply an entry's reanchor just left and its managed backing's value ({_entryValue}).
    function _reopenFeeBaselines(uint256 supply, uint256 value) internal {
        if (feesActiveCached) IEarnFees(earnFees).reopenBaselines(supply, value);
    }

    /// @dev After an entry whose checkpoint valued the pool, EarnFees raises a baseline only for a value per
    ///      EarnShare (rounded up, at its own scale) above the floor it returned, which nothing lowers within the
    ///      call. At or below it the call would change nothing, so it is skipped.
    function _ratchetFeeBaselines(uint256 supply, uint256 value, uint256 baselineFloor, uint256 floorScale) internal {
        if (!feesActiveCached) return;
        if (supply != 0 && EarnFeeMath.valuePerEarnShareUp(value, floorScale, supply) <= baselineFloor) return;
        IEarnFees(earnFees).initializeBaselines(supply, value);
    }

    /// @dev Moves `assets` from the caller into the engine and measures the engine-share increase; the caller records it.
    ///      An engine with {IEarnEngineHeldDeposit} receives the assets straight from the caller.
    function _depositToEngine(uint256 assets, uint256 rawSharesBefore)
        internal
        returns (uint256 receivedEngineShares, uint256 rawSharesAfter)
    {
        address engine_ = engine;
        uint256 reportedEngineShares;
        if (engineCapabilities & CAP_HELD_DEPOSIT != 0) {
            // The engine deposits from its own balance, so it must be credited exactly `assets`.
            address asset_ = asset;
            uint256 engineHeld = IERC20Like(asset_).balanceOf(engine_);
            _safeTransferFrom(asset_, msg.sender, engine_, assets);
            if (IERC20Like(asset_).balanceOf(engine_) != engineHeld + assets) revert InsufficientOutput();
            reportedEngineShares = IEarnEngineHeldDeposit(engine_).depositHeld(assets);
        } else {
            _safeTransferFrom(asset, msg.sender, address(this), assets);
            _approveEngine(engine_, assets);
            reportedEngineShares = IEarnEngine(engine_).deposit(assets);
        }
        rawSharesAfter = rawEngineShares();
        if (rawSharesAfter <= rawSharesBefore) revert InsufficientOutput();
        receivedEngineShares = rawSharesAfter - rawSharesBefore;
        if (reportedEngineShares != receivedEngineShares) revert InsufficientOutput();
    }

    /// @dev Takes `earnShares` of EarnShare from the caller, through its callback when asked for one.
    function _collectEarnShares(uint256 earnShares, bool callback) internal {
        if (!callback) {
            _safeTransferFrom(earnShare, msg.sender, address(this), earnShares);
            return;
        }
        uint256 heldBefore = IEarnShare(earnShare).balanceOf(address(this));
        IEarnWithdrawCallback(msg.sender).earnWithdrawCallback(earnShares);
        if (IEarnShare(earnShare).balanceOf(address(this)) != heldBefore + earnShares) {
            revert EarnSharesNotReceived();
        }
    }

    /// @dev No contract of its own: it calls out after recording, so the verifier inlines it into each caller,
    ///      which holds the lock and the invariants.
    ///      `feeSnapshot` says whether fees are on and the valuation fresh; EarnFees snapshots the request only then.
    function _recordPendingRedeem(
        bytes32 requestId,
        address requester,
        address receiver,
        uint256 earnShares,
        bool feeSnapshot
    ) internal {
        StoredRedeem storage pending = _pending[requestId];
        if (pending.requester != address(0)) revert DuplicateRequest(requestId);
        // A request too large for the packed record reverts rather than truncating.
        if (earnShares > type(uint88).max) revert ExceedsMaxEarnShares();
        // Stored exactly when EarnFees is asked for a snapshot, so finalization closes only a recorded one.
        // A closed record is all zero, so a self-paying request leaves the receiver slot unwritten;
        // {_receiverOf} reads it back as the requester.
        if (receiver != requester) pending.receiver = receiver;
        // Bounded above, so the downcast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        pending.burnedEarnShares = uint88(earnShares);
        pending.feeSnapshot = feeSnapshot;
        /// @custom:ghost openCount = openCount + 1
        pending.requester = requester;
        if (feeSnapshot) IEarnFees(earnFees).recordRedeemRequest(requestId, earnShares);
    }

    /// @dev One unit of EarnShare in its smallest denomination. Trusted because the verifier models a power with a
    ///      symbolic exponent as an uninterpreted value: a checked power that returns is at least 1, and with the
    ///      decimals {initialize} bounds by 77 it returns.
    /// @custom:trusted
    /// @custom:ensures result == 10 ** uint256(_earnShareDecimals) && result != 0
    /// @custom:succeeds-if _earnShareDecimals <= 77
    function _earnShareScale() internal view returns (uint256) {
        return 10 ** uint256(_earnShareDecimals);
    }

    /// @custom:ensures result == (uint160(account) >> 64 == TIP20_ADDRESS_PREFIX)
    function _isTip20Address(address account) internal pure returns (bool result) {
        return uint160(account) >> 64 == TIP20_ADDRESS_PREFIX;
    }

    function _requireCapability(address candidate, bytes4 interfaceId) internal view {
        if (!ERC165Checker.supportsInterface(candidate, interfaceId)) {
            revert EngineCapabilityUnsupported(interfaceId);
        }
    }

    function _requireEngineCapability(uint8 capability, bytes4 interfaceId) internal view {
        if (engineCapabilities & capability == 0) revert EngineCapabilityUnsupported(interfaceId);
    }

    /// @dev The engine's fixed capabilities as CAP_* bits, so locked calls skip the ERC-165 round trips.
    function _engineCapabilities(address engine_) internal view returns (uint8 capabilities) {
        bytes4[] memory ids = new bytes4[](5);
        ids[0] = type(IEarnEngineRedeem).interfaceId;
        ids[1] = type(IEarnEngineExactWithdraw).interfaceId;
        ids[2] = type(IEarnEngineInKindDeposit).interfaceId;
        ids[3] = type(IEarnEngineFeeValuation).interfaceId;
        ids[4] = type(IEarnEngineHeldDeposit).interfaceId;
        bool[] memory supported = ERC165Checker.getSupportedInterfaces(engine_, ids);
        /// @custom:invariant i <= 5
        for (uint256 i = 0; i < 5; i++) {
            if (supported[i]) capabilities |= uint8(1 << i);
        }
    }

    function _refreshFeesActive() internal {
        feesActiveCached = IEarnFees(earnFees).feesActive();
    }

    function _requireExitCapability(address candidate) internal view {
        if (
            !ERC165Checker.supportsInterface(candidate, type(IEarnEngineRedeem).interfaceId)
                && !ERC165Checker.supportsInterface(candidate, type(IEarnEngineExactWithdraw).interfaceId)
                && !ERC165Checker.supportsInterface(candidate, type(IEarnEngineAsyncRedeem).interfaceId)
        ) revert EngineExitUnsupported();
    }

    /// @dev Keeps a standing maximum allowance for `engine_`. Tempo charges every zero-to-nonzero allowance as a
    ///      new storage slot, so re-approving from zero costs a new slot per deposit. The vault holds base
    ///      assets only within a call, and migration revokes the old engine's allowance.
    function _approveEngine(address engine_, uint256 assets) internal {
        if (IERC20Allowance(asset).allowance(address(this), engine_) < assets) {
            _safeApprove(asset, engine_, type(uint256).max);
        }
    }

    function _safeApprove(address token, address spender, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Like.approve.selector, spender, value));
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Like.transfer.selector, to, value));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Like.transferFrom.selector, from, to, value));
    }

    function _callOptionalReturn(address token, bytes memory data) internal {
        assembly ("memory-safe") {
            let ok := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            if iszero(ok) {
                // TokenCallFailed()
                mstore(0, shl(224, 0x3f409f9a))
                revert(0, 4)
            }
            let returnSize := returndatasize()
            if returnSize {
                if or(lt(returnSize, 32), iszero(eq(mload(0), 1))) {
                    // TokenCallFalse()
                    mstore(0, shl(224, 0xfdcab105))
                    revert(0, 4)
                }
            }
        }
    }

    // ---------------------------------------------------------------- spec helpers, never executed

    /// @custom:spec `ceil(numerator / denominator)`.
    function _specCeilDiv(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return (numerator + denominator - 1) / denominator;
    }

    /// @custom:spec `|a - b|`.
    function _specDistance(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @custom:spec A conversion may round down, but may not lose more than one basis point of its input.
    function _specAcceptableLoss(uint256 inputAmount, uint256 representedAmount) internal pure returns (bool) {
        return representedAmount <= inputAmount && inputAmount - representedAmount <= inputAmount / CONVERSION_BPS;
    }

    /// @custom:spec Normalized engine shares per whole EarnShare, rounded up (0 without backing).
    function _specNormalizedRate(uint256 engineShareAnchor, uint256 supplyAnchor) internal view returns (uint256) {
        return engineShareAnchor == 0 ? 0 : _specCeilDiv(engineShareAnchor * _earnShareScale(), supplyAnchor);
    }

    /// @custom:spec The value of the managed backing, capped at the raw engine-share count `raw`.
    function _specManagedValueAt(uint256 raw) internal view returns (uint256) {
        return IEarnEngine(engine).valueOf(raw < _managedEngineShares ? raw : _managedEngineShares);
    }

    /// @custom:spec The anchor's engine-share side: the managed count, or the reward baseline for the empty anchor.
    function _specAnchorEngine() internal view returns (uint256) {
        return _anchorEarnShares == EMPTY_ANCHOR ? rewardRateBaseline() : _managedEngineShares;
    }

    /// @custom:spec The anchor's EarnShare side: the stored supply, or the EarnShare scale for the empty anchor.
    function _specAnchorEarn() internal view returns (uint256) {
        return _anchorEarnShares == EMPTY_ANCHOR ? _earnShareScale() : _anchorEarnShares;
    }

    /// @dev The receiver of a stored request: its stored receiver, or its requester when that slot is zero.
    function _receiverOf(StoredRedeem storage p) internal view returns (address receiver) {
        receiver = p.receiver;
        if (receiver == address(0)) receiver = p.requester;
    }

    /// @custom:spec The empty-pool anchor: whole engine share (the reward baseline) per whole EarnShare.
    function _specEmptyAnchor() internal view returns (bool) {
        return _anchorEarnShares == EMPTY_ANCHOR;
    }

    /// @custom:spec Request `id` holds a nonzero burned EarnShare amount.
    function _specLiveRequest(bytes32 id) internal view returns (bool) {
        return _pending[id].burnedEarnShares != 0;
    }

    /// @custom:spec Request `id` holds no burned EarnShare, no stored receiver and no fee-snapshot flag.
    function _specClosedRequest(bytes32 id) internal view returns (bool) {
        return _pending[id].burnedEarnShares == 0 && _pending[id].receiver == address(0) && !_pending[id].feeSnapshot;
    }

    /// @custom:spec No distributor fee update is scheduled.
    function _specNoDistributorFeeUpdate() internal view returns (bool) {
        return !_pendingDistributorFeeUpdate.pending && _pendingDistributorFeeUpdate.recipient == address(0)
            && _pendingDistributorFeeUpdate.rateBps == 0 && _pendingDistributorFeeUpdate.executableAt == 0;
    }

    /// @custom:spec A receiver a request can always pay: not zero, this vault, its engine, or a TIP-20 token address.
    function _specPayableReceiver(address receiver) internal view returns (bool) {
        return receiver != address(0) && receiver != address(this) && receiver != engine
            && uint160(receiver) >> 64 != TIP20_ADDRESS_PREFIX;
    }

    /// @custom:spec Request `requestId` is open for `requester`, pays `receiver` and burned `earnShares`.
    function _specRecordedRequest(bytes32 requestId, address requester, address receiver, uint256 earnShares)
        internal
        view
        returns (bool)
    {
        return _pending[requestId].requester == requester
            && _pending[requestId].receiver == (receiver == requester ? address(0) : receiver)
            && _pending[requestId].burnedEarnShares == earnShares;
    }

    /// @custom:spec A configuration keeps the distributor's reserved item as its first fixed fee; without one it
    ///     leaves a slot free for it.
    function _specProtectsDistributorFee(FeeConfig memory config, FixedFeeRecipient memory fee)
        internal
        pure
        returns (bool)
    {
        return fee.rateBps == 0
            ? config.fixedFeeCount < config.fixedFees.length
            : config.fixedFeeCount != 0 && _specSameFee(config.fixedFees[0], fee);
    }

    /// @custom:spec The number of operator fixed fees in `config`, after the distributor's item if it has one.
    function _specOperatorFeeCount(FeeConfig memory config, FixedFeeRecipient memory currentFee)
        internal
        pure
        returns (uint256)
    {
        return config.fixedFeeCount - (currentFee.rateBps != 0 ? 1 : 0);
    }

    /// @custom:spec Operator fee `i` of `config` sits right after the new distributor item in `result`.
    function _specOperatorFeeKept(
        FeeConfig memory result,
        FeeConfig memory config,
        FixedFeeRecipient memory currentFee,
        FixedFeeRecipient memory nextFee,
        uint256 i
    ) internal pure returns (bool) {
        return _specSameFee(
            result.fixedFees[i + (nextFee.rateBps != 0 ? 1 : 0)],
            config.fixedFees[i + (currentFee.rateBps != 0 ? 1 : 0)]
        );
    }

    /// @custom:spec Two fixed fees name the same recipient and rate.
    function _specSameFee(FixedFeeRecipient memory a, FixedFeeRecipient memory b) internal pure returns (bool) {
        return a.account == b.account && a.rateBps == b.rateBps;
    }

    /// @custom:spec An unused fixed-fee slot.
    function _specEmptyFee(FixedFeeRecipient memory fee) internal pure returns (bool) {
        return fee.account == address(0) && fee.rateBps == 0;
    }

    /// @custom:spec `result` carries `config`'s excess fee unchanged.
    function _specSameExcess(FeeConfig memory result, FeeConfig memory config) internal pure returns (bool) {
        return result.excess.enabled == config.excess.enabled && result.excess.account == config.excess.account
            && result.excess.annualTargetRateBps == config.excess.annualTargetRateBps
            && result.excess.excessFeeRateBps == config.excess.excessFeeRateBps;
    }

    /// @custom:spec No excess fee is set yet.
    function _specEmptyExcess(FeeConfig memory result) internal pure returns (bool) {
        return !result.excess.enabled && result.excess.account == address(0) && result.excess.annualTargetRateBps == 0
            && result.excess.excessFeeRateBps == 0;
    }
}
