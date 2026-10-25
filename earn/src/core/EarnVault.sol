// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IEarnFees } from "../interfaces/core/IEarnFees.sol";
import { IEarnShare } from "../interfaces/core/IEarnShare.sol";
import { IEarnVault } from "../interfaces/core/IEarnVault.sol";
import {
    DistributorConfig,
    DistributorFeeUpdate,
    EarnVaultControls,
    EngineMigrationMode
} from "../interfaces/core/EarnVaultTypes.sol";
import { FeeConfig, FeePreview, FixedFeeRecipient } from "../interfaces/core/EarnFeeTypes.sol";
import { IEarnEngine } from "../interfaces/engines/IEarnEngine.sol";
import { IEarnEngineAsyncRedeem } from "../interfaces/engines/IEarnEngineAsyncRedeem.sol";
import { IEarnEngineExactWithdraw } from "../interfaces/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineFeeValuation } from "../interfaces/engines/IEarnEngineFeeValuation.sol";
import { IEarnEngineInKindDeposit } from "../interfaces/engines/IEarnEngineInKindDeposit.sol";
import { IEarnEngineRedeem } from "../interfaces/engines/IEarnEngineRedeem.sol";
import { IERC20Like } from "../interfaces/external/IERC20Like.sol";
import { IAsyncRedeemReceiver } from "../interfaces/core/IAsyncRedeemReceiver.sol";
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
contract EarnVault is IEarnVault {
    uint256 internal constant CONVERSION_BPS = 10_000;
    /// @notice Maximum contribution-funded increase in the normalized engine-share/EarnShare rate.
    uint256 public constant override MAX_REWARD_RATE_MULTIPLIER = 100;

    /// @notice The current yield engine and sole custodian of the venue shares backing this EarnVault's
    ///         EarnShare supply. MUTABLE only through operator-authorized {migrateEngine}.
    address public override engine;
    address public override asset;
    address public override earnShare;
    address public override earnFees;
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
    /// @notice Operator-configured maximum active assets after a voluntary inflow. Zero disables the limit.
    uint256 public override maxManagedAssets;
    /// @notice Deployment-fixed whole-pool migration policy. There is intentionally no setter.
    EngineMigrationMode public override engineMigrationMode;
    uint256 internal earnShareScale;

    /// @notice (engine-shares : EarnShare) exchange anchor. `anchorEngineShares` engine shares are
    ///         represented by `anchorEarnShares` EarnShare. Empty pools normalize the engine and
    ///         EarnShare whole-unit scales;
    ///         live pools are explicitly re-anchored by {migrateEngine}, permissionless {contribute}
    ///         funding, fee mints, and ordinary immediate actions that change backing or supply.
    uint256 public anchorEngineShares;
    uint256 public anchorEarnShares;

    uint256 public override openRedeemRequestCount;
    /// @notice Whether deposits, in-kind entry, contributions, and surplus absorption are paused.
    ///         Exit paths stay open.
    bool public override depositsPaused;

    struct PendingRedeem {
        address receiver;
        address requester;
        uint256 burnedEarnShares;
        uint256 engineShares;
        bool open;
    }

    mapping(bytes32 requestId => PendingRedeem) private _pending;

    FixedFeeRecipient private _distributorFee;
    DistributorFeeUpdate private _pendingDistributorFeeUpdate;

    uint256 private locked;
    bool private initialized;
    /// @dev Active engine shares recognized as EarnShare backing. Raw shares above this count are
    ///      quarantined until explicitly absorbed through {absorbEngineShareSurplus}.
    uint256 private _managedEngineShares;
    /// @notice Normalized engine-share units per whole EarnShare at initialization, the latest migration,
    ///         or the latest transition back to an empty pool.
    uint256 public override rewardRateBaseline;

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
    error GlobalFeeDisableUnavailable();
    error ActiveSupplyWithoutBacking();
    error InsufficientOutput();
    error MinimumAssetsNotMet(uint256 minimumAssets, uint256 actualAssets);
    error MinimumEarnSharesNotMet(uint256 minimumEarnShares, uint256 actualEarnShares);
    error MinimumEngineSharesNotMet(uint256 minimumEngineShares, uint256 actualEngineShares);
    error MaxManagedAssetsExceeded(uint256 maximum, uint256 actual);
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

    /// @dev Locks the standalone implementation. Each EarnVault is an ERC-1967 proxy with no upgrade
    ///      entrypoint, initialized atomically by {EarnFactory} against this fixed implementation.
    constructor() {
        initialized = true;
    }

    function initialize(
        address engine_,
        address earnShare_,
        address earnFees_,
        address operator_,
        EarnVaultControls memory controlInit_,
        DistributorConfig memory distributorInit_
    ) external {
        if (initialized) revert AlreadyInitialized();
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
        asset = asset_;
        earnShare = earnShare_;
        earnFees = earnFees_;
        operator = operator_;
        distributor = distributorInit_.distributor;
        distributorUpdateDelay = distributorInit_.updateDelay;
        emergencyGuardian = controlInit_.emergencyGuardian;
        asyncJanitor = controlInit_.asyncJanitor;
        maxManagedAssets = controlInit_.maxManagedAssets;
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
        earnShareScale = 10 ** earnDecimals;
        _resetEmptyAnchor(engine_);
        rewardRateBaseline = anchorEngineShares;
        locked = 1;

        FixedFeeRecipient memory distributorFee_ = _distributorFee;
        emit EarnVaultInitialized(
            engine,
            earnShare,
            earnFees,
            operator,
            emergencyGuardian,
            asyncJanitor,
            maxManagedAssets,
            engineMigrationMode,
            distributor,
            distributorUpdateDelay,
            distributorFee_.account,
            distributorFee_.rateBps
        );
    }

    modifier nonReentrant() {
        if (locked != 1) revert ReentrantCall();
        locked = 2;
        _;
        locked = 1;
    }

    function accrueFees() external override nonReentrant returns (uint256 feeAssets, uint256 feeEarnShares) {
        (FeePreview memory result,,) = _accrueFees();
        return (result.totalFeeAssets, result.totalFeeEarnShares);
    }

    function setFeeConfig(FeeConfig calldata config) external override nonReentrant returns (uint64 configId) {
        if (msg.sender != operator) revert NotOperator();
        _validateOperatorFeeConfig(config);
        _requireFreshFeeValuation();
        _accrueFees();
        configId = IEarnFees(earnFees).setFeeConfig(config);
    }

    function disableFees() external override {
        if (distributor != address(0)) revert GlobalFeeDisableUnavailable();
        if (msg.sender != operator) revert NotOperator();
        IEarnFees(earnFees).disableFees(msg.sender);
    }

    function transferOperator(address newOperator) external override {
        if (msg.sender != operator) revert NotOperator();
        if (newOperator == address(0)) revert ZeroAddress();
        pendingOperator = newOperator;
        emit OperatorTransferStarted(operator, newOperator);
    }

    function cancelOperatorTransfer() external override {
        if (msg.sender != operator) revert NotOperator();
        address pending = pendingOperator;
        if (pending == address(0)) revert OperatorTransferNotPending();
        delete pendingOperator;
        emit OperatorTransferCancelled(operator, pending);
    }

    function acceptOperator() external override {
        address pending = pendingOperator;
        if (pending == address(0)) revert OperatorTransferNotPending();
        if (msg.sender != pending) revert NotPendingOperator();

        address previous = operator;
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

    function cancelDistributorFeeUpdate() external override {
        _requireDistributor();
        if (!_pendingDistributorFeeUpdate.pending) revert DistributorFeeUpdateNotPending();
        delete _pendingDistributorFeeUpdate;
        emit DistributorFeeUpdateCancelled(distributor);
    }

    /// @notice Permissionlessly activates a ready distributor fee update after settling the old terms.
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
        _accrueFees();
        _distributorFee = nextFee;
        delete _pendingDistributorFeeUpdate;
        feeConfigId = IEarnFees(earnFees).setFeeConfig(proposed);
        emit DistributorFeeUpdated(nextFee.account, nextFee.rateBps, feeConfigId);
    }

    function transferDistributor(address newDistributor) external override {
        _requireDistributor();
        if (newDistributor == address(0) || newDistributor == distributor) revert InvalidDistributorConfiguration();
        pendingDistributor = newDistributor;
        emit DistributorTransferStarted(distributor, newDistributor);
    }

    function cancelDistributorTransfer() external override {
        _requireDistributor();
        address pending = pendingDistributor;
        if (pending == address(0)) revert DistributorTransferNotPending();
        delete pendingDistributor;
        emit DistributorTransferCancelled(distributor, pending);
    }

    function acceptDistributor() external override {
        address pending = pendingDistributor;
        if (pending == address(0)) revert DistributorTransferNotPending();
        if (msg.sender != pending) revert NotPendingDistributor();

        address previous = distributor;
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
    function setEmergencyRoles(address newGuardian, address newJanitor) external override {
        if (msg.sender != operator) revert NotOperator();
        emergencyGuardian = newGuardian;
        asyncJanitor = newJanitor;
        emit EmergencyRolesChanged(newGuardian, newJanitor);
    }

    /// @notice Pauses or unpauses deposits, in-kind entry, contributions, and surplus absorption
    ///         without blocking exits.
    /// @dev The guardian may only pause. The operator may pause or unpause.
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
    function setMaxManagedAssets(uint256 newMaxManagedAssets) external override {
        if (msg.sender != operator) revert NotOperator();
        uint256 previousMaxManagedAssets = maxManagedAssets;
        maxManagedAssets = newMaxManagedAssets;
        emit MaxManagedAssetsChanged(previousMaxManagedAssets, newMaxManagedAssets);
    }

    /// @notice Deposits `assets` of the engine asset pulled from the caller into the engine (which
    ///         holds the resulting venue shares) and mints the rate-converted EarnShare amount to
    ///         `receiver`. The measured engine-share delta is converted at the active anchor, whose
    ///         empty-pool rate normalizes engine and EarnShare precision. `minEarnShares` protects
    ///         the caller from quote drift, and the EarnVault rejects conversion floor loss above one
    ///         basis point even when the caller obtained a quote after the anchor was distorted.
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
    function deposit(uint256 assets, uint256 minEarnShares)
        external
        override
        nonReentrant
        returns (uint256 earnShares)
    {
        return _deposit(assets, msg.sender, minEarnShares);
    }

    function _deposit(uint256 assets, address receiver, uint256 minEarnShares) internal returns (uint256 earnShares) {
        if (depositsPaused) revert DepositsPaused();
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (minEarnShares == 0) revert ZeroMinimumEarnShares();

        uint256 supplyBefore = IEarnShare(earnShare).totalSupply();
        (FeePreview memory accruedFees, uint256 currentSupply,) = _accrueFees();
        _requireDepositBackingAfterAccrual(currentSupply, accruedFees.activeAssets);
        uint256 rateEngineShares = anchorEngineShares;
        uint256 rateEarnShares = anchorEarnShares;

        _safeTransferFrom(asset, msg.sender, address(this), assets);
        _safeApprove(asset, engine, 0);
        _safeApprove(asset, engine, assets);
        uint256 rawSharesBefore = rawEngineShares();
        uint256 reportedEngineShares = IEarnEngine(engine).deposit(assets);
        _safeApprove(asset, engine, 0);
        uint256 receivedEngineShares = _recordEngineShareIncrease(rawSharesBefore, reportedEngineShares);

        earnShares = _convertEngineSharesToEarnShares(receivedEngineShares);
        if (earnShares == 0) revert InsufficientOutput();
        if (earnShares < minEarnShares) revert MinimumEarnSharesNotMet(minEarnShares, earnShares);
        _requireAcceptableConversion(receivedEngineShares, earnShares);

        IEarnShare(earnShare).mint(receiver, earnShares);
        _reanchorAfterEntry(rateEngineShares, rateEarnShares);
        _requireWithinManagedAssetsLimit();
        if (supplyBefore == 0 || accruedFees.activeAssets != 0) {
            IEarnFees(earnFees).initializeBaselines();
        }
        emit Deposited(msg.sender, receiver, assets, earnShares);
    }

    /// @notice Deposits shares of the current engine's venue directly and mints rate-converted
    ///         EarnShare to `receiver`. The caller approves the engine—not this EarnVault—to pull the
    ///         venue shares. Only engines implementing {IEarnEngineInKindDeposit} support this path.
    /// @dev This is a principal-preserving entry path for existing venue shareholders. Fees are
    ///      crystallized before the new backing enters, and the proportional EarnShare mint prevents
    ///      the incoming principal from being treated as positive value accrual. The same one-basis-point
    ///      conversion-loss ceiling as {deposit} applies independently of `minEarnShares`.
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

        uint256 supplyBefore = IEarnShare(earnShare).totalSupply();
        (FeePreview memory accruedFees, uint256 currentSupply,) = _accrueFees();
        _requireDepositBackingAfterAccrual(currentSupply, accruedFees.activeAssets);
        uint256 rateEngineShares = anchorEngineShares;
        uint256 rateEarnShares = anchorEarnShares;

        _requireCapability(engine, type(IEarnEngineInKindDeposit).interfaceId);
        uint256 engineSharesBefore = rawEngineShares();
        uint256 reportedEngineShares = IEarnEngineInKindDeposit(engine).depositInKind(venueShares, msg.sender);
        uint256 receivedEngineShares = _recordEngineShareIncrease(engineSharesBefore, reportedEngineShares);

        earnShares = _convertEngineSharesToEarnShares(receivedEngineShares);
        if (earnShares == 0) revert InsufficientOutput();
        if (earnShares < minEarnShares) revert MinimumEarnSharesNotMet(minEarnShares, earnShares);
        _requireAcceptableConversion(receivedEngineShares, earnShares);

        IEarnShare(earnShare).mint(receiver, earnShares);
        _reanchorAfterEntry(rateEngineShares, rateEarnShares);
        _requireWithinManagedAssetsLimit();
        if (supplyBefore == 0 || accruedFees.activeAssets != 0) {
            IEarnFees(earnFees).initializeBaselines();
        }
        emit VenueSharesDeposited(msg.sender, receiver, venueShares, receivedEngineShares, earnShares);
    }

    /// @notice Adds backing for current EarnShare holders without minting new EarnShare.
    /// @dev Permissionless and allowance-bound. The assets follow the normal engine deposit path,
    ///      then the conversion anchor is restated against the unchanged EarnShare
    ///      supply. With open async exits, only the active pool participates because queued claims
    ///      have already burned their EarnShare and left active NAV.
    function contribute(uint256 assets) external override nonReentrant returns (uint256 receivedEngineShares) {
        if (depositsPaused) revert DepositsPaused();
        if (assets == 0) revert ZeroAmount();

        uint256 supply = IEarnShare(earnShare).totalSupply();
        if (supply == 0) revert NoEarnShares();

        _accrueFees();

        _safeTransferFrom(asset, msg.sender, address(this), assets);
        _safeApprove(asset, engine, 0);
        _safeApprove(asset, engine, assets);
        uint256 rawSharesBefore = rawEngineShares();
        uint256 reportedEngineShares = IEarnEngine(engine).deposit(assets);
        _safeApprove(asset, engine, 0);
        receivedEngineShares = _recordEngineShareIncrease(rawSharesBefore, reportedEngineShares);
        _requireWithinManagedAssetsLimit();

        _reanchorAtRest();
        _accrueFees();
        _requireRewardRateWithinLimit();

        emit Contributed(msg.sender, assets, receivedEngineShares, anchorEngineShares, anchorEarnShares);
    }

    /// @notice Permissionlessly recognizes pre-transferred engine shares as a reward for current holders.
    /// @dev Raw engine shares are otherwise quarantined: they do not affect active backing, fees, deposits,
    ///      or exits. Absorption is subject to the same pause, capacity, and reward-rate limits as
    ///      an asset contribution.
    function absorbEngineShareSurplus(uint256 engineShares_) external override nonReentrant {
        if (depositsPaused) revert DepositsPaused();
        if (engineShares_ == 0) revert ZeroAmount();
        if (IEarnShare(earnShare).totalSupply() == 0) revert NoEarnShares();

        _accrueFees();

        uint256 managed = _managedEngineShares;
        uint256 raw = rawEngineShares();
        uint256 available = raw > managed ? raw - managed : 0;
        if (engineShares_ > available) revert InsufficientEngineShareSurplus(available, engineShares_);
        _managedEngineShares = managed + engineShares_;
        _requireWithinManagedAssetsLimit();

        _reanchorAtRest();
        _accrueFees();
        _requireRewardRateWithinLimit();

        emit EngineShareSurplusAbsorbed(msg.sender, engineShares_, anchorEngineShares, anchorEarnShares);
    }

    /// @notice Burns `earnShares` of EarnShare pulled from the caller and redeems the rate-converted
    ///         engine shares. Proceeds go directly to `receiver`.
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
    function redeem(uint256 earnShares, uint256 minAssets) external override nonReentrant returns (uint256 assets) {
        return _redeem(earnShares, msg.sender, minAssets);
    }

    function _redeem(uint256 earnShares, address receiver, uint256 minAssets) internal returns (uint256 assets) {
        if (earnShares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (minAssets == 0) revert ZeroMinimumAssets();
        _requireCapability(engine, type(IEarnEngineRedeem).interfaceId);

        _accrueFees();

        _safeTransferFrom(earnShare, msg.sender, address(this), earnShares);
        IEarnShare(earnShare).burn(earnShares);

        uint256 engineSharesToRedeem = _convertToEngineShares(earnShares);
        if (engineSharesToRedeem == 0) revert InsufficientOutput();

        assets = IEarnEngineRedeem(engine).redeem(engineSharesToRedeem, receiver, minAssets);
        if (assets == 0) revert InsufficientOutput();
        if (assets < minAssets) revert MinimumAssetsNotMet(minAssets, assets);
        _decreaseManagedEngineShares(engineSharesToRedeem);

        _reanchorAtRest();
        emit Redeemed(msg.sender, receiver, earnShares, assets);
    }

    /// @notice Withdraws an exact `assets` amount directly to `receiver`, burning the EarnShare amount
    ///         actually consumed (pulled from the caller). Reverts if more than `maxEarnShares`
    ///         would be burned.
    /// @dev Used when public requests are denominated in assets. The caller keeps any unused EarnShare.
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
    function withdrawExact(uint256 assets, uint256 maxEarnShares)
        external
        override
        nonReentrant
        returns (uint256 earnSharesBurned)
    {
        return _withdrawExact(assets, msg.sender, maxEarnShares);
    }

    function _withdrawExact(uint256 assets, address receiver, uint256 maxEarnShares)
        internal
        returns (uint256 earnSharesBurned)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _requireCapability(engine, type(IEarnEngineExactWithdraw).interfaceId);

        _accrueFees();

        uint256 engineSharesBefore = engineShares();
        uint256 engineAssetsBefore = totalAssets();
        uint256 requiredEngineShares = IEarnEngineExactWithdraw(engine).previewWithdraw(assets);
        if (requiredEngineShares == 0) revert InsufficientOutput();
        uint256 requiredEarnShares = _convertEngineSharesToEarnSharesUp(requiredEngineShares);
        if (requiredEarnShares == 0) revert InsufficientOutput();
        if (requiredEarnShares > maxEarnShares) revert ExceedsMaxEarnShares();

        uint256 engineSharesBurned = IEarnEngineExactWithdraw(engine).withdraw(assets, receiver);
        if (engineSharesBurned == 0) revert InsufficientOutput();
        _decreaseManagedEngineShares(engineSharesBurned);
        earnSharesBurned = _convertEngineSharesToEarnSharesUp(engineSharesBurned);
        if (earnSharesBurned == 0) revert InsufficientOutput();
        if (earnSharesBurned > maxEarnShares) revert ExceedsMaxEarnShares();
        if (engineSharesBurned == engineSharesBefore && assets < engineAssetsBefore) revert ResidualBacking();
        if (earnSharesBurned == IEarnShare(earnShare).totalSupply() && engineShares() != 0) {
            revert ResidualBacking();
        }

        _safeTransferFrom(earnShare, msg.sender, address(this), earnSharesBurned);
        IEarnShare(earnShare).burn(earnSharesBurned);

        _reanchorAtRest();
        emit WithdrewExact(msg.sender, receiver, assets, earnSharesBurned);
    }

    /// @notice Files an async redemption, burns `earnShares` immediately, and records a separate
    ///         entitlement while `EarnFees` snapshots any applicable queued-growth fee state.
    /// @dev The queued backing and burned EarnShare leave active accounting atomically. If the engine
    ///      request fails, the entire transaction—including the burn—reverts.
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
    function requestRedeem(uint256 earnShares, bytes calldata engineData)
        external
        override
        nonReentrant
        returns (bytes32 requestId)
    {
        return _requestRedeem(earnShares, engineData, msg.sender);
    }

    function _requestRedeem(uint256 earnShares, bytes calldata engineData, address receiver)
        internal
        returns (bytes32 requestId)
    {
        if (earnShares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _requireCapability(engine, type(IEarnEngineAsyncRedeem).interfaceId);

        _accrueFees();

        uint256 engineSharesToRedeem = _convertToEngineShares(earnShares);
        if (engineSharesToRedeem == 0) revert InsufficientOutput();
        _requireAcceptableEarnShareConversion(earnShares, engineSharesToRedeem);

        _safeTransferFrom(earnShare, msg.sender, address(this), earnShares);
        IEarnShare(earnShare).burn(earnShares);

        requestId = IEarnEngineAsyncRedeem(engine).requestRedeem(engineSharesToRedeem, engineData);
        _decreaseManagedEngineShares(engineSharesToRedeem);

        _recordPendingRedeem(requestId, msg.sender, receiver, earnShares, engineSharesToRedeem);

        openRedeemRequestCount += 1;
        _reanchorAtRest();
        emit RedeemRequested(requestId, msg.sender, receiver, earnShares);
    }

    /// @notice ENGINE-ONLY. Forwards a solved queued payout to the stored receiver and closes the
    ///         pending claim. No EarnShare is burned here because it was burned at request time.
    function finalizeRedeem(bytes32 requestId, address asset_, uint256 amount) external nonReentrant {
        if (msg.sender != engine) revert NotEngine();
        if (asset_ != asset) revert FinalizedAssetMismatch(asset_);
        PendingRedeem storage p = _pending[requestId];
        if (!p.open) revert RequestNotOpen(requestId);

        address receiver = p.receiver;
        uint256 earnShares = p.burnedEarnShares;
        delete _pending[requestId];
        openRedeemRequestCount -= 1;
        IEarnFees(earnFees).closeRedeemRequest(requestId);

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
    function cancelRedeem(bytes32 requestId, uint256 minReceiverEarnShares) external override nonReentrant {
        if (minReceiverEarnShares == 0) revert ZeroMinimumEarnShares();
        PendingRedeem storage p = _pending[requestId];
        if (!p.open) revert RequestNotOpen(requestId);
        if (msg.sender != p.requester && msg.sender != asyncJanitor) revert NotRequesterOrJanitor();

        address receiver = p.receiver;
        uint256 burnedEarnShares = p.burnedEarnShares;

        _accrueFees();
        uint256 rateEngineShares = anchorEngineShares;
        uint256 rateEarnShares = anchorEarnShares;
        bool chargePending = IEarnFees(earnFees).shouldChargeRedeem(requestId);
        uint256 activeSupply = IEarnShare(earnShare).totalSupply();
        uint256 activeAssets = activeSupply == 0 || !chargePending ? 0 : totalAssets();
        uint256 heldBefore = rawEngineShares();

        IEarnEngineAsyncRedeem(engine).cancelRedeem(requestId);
        uint256 heldAfter = rawEngineShares();
        if (heldAfter <= heldBefore) revert InsufficientOutput();
        uint256 returnedEngineShares = heldAfter - heldBefore;
        _managedEngineShares += returnedEngineShares;

        delete _pending[requestId];
        openRedeemRequestCount -= 1;

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
            uint256 shareBasedReentry = _convertEngineSharesToEarnShares(returnedEngineShares);
            totalReentryEarnShares = valueBasedReentry < shareBasedReentry ? valueBasedReentry : shareBasedReentry;
        } else {
            totalReentryEarnShares = _convertEngineSharesToEarnShares(returnedEngineShares);
        }
        if (totalReentryEarnShares == 0) revert InsufficientOutput();

        uint256 feeEarnShares = IEarnFees(earnFees)
            .settleCancelledRedeem(requestId, returnedValue, activeSupply, activeAssets, totalReentryEarnShares);
        if (feeEarnShares != 0) IEarnShare(earnShare).mint(earnFees, feeEarnShares);
        uint256 receiverEarnShares = totalReentryEarnShares - feeEarnShares;

        if (activeSupply != 0) _requireAcceptableConversion(returnedEngineShares, totalReentryEarnShares);
        if (receiverEarnShares == 0) revert InsufficientOutput();
        if (receiverEarnShares < minReceiverEarnShares) {
            revert MinimumEarnSharesNotMet(minReceiverEarnShares, receiverEarnShares);
        }
        IEarnShare(earnShare).mint(receiver, receiverEarnShares);
        if (activeSupply == 0) {
            // The full exit already reset the reward baseline. Restoring its position must not
            // turn the returned backing into fresh contribution headroom.
            _reanchorAtRest();
        } else {
            _reanchorAfterEntry(rateEngineShares, rateEarnShares);
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
        if (openRedeemRequestCount != 0) revert PendingRedeemsOpen();
        _requireCapability(newEngine, type(IEarnEngine).interfaceId);
        _requireExitCapability(newEngine);
        if (IEarnEngine(newEngine).asset() != asset) revert EngineAssetMismatch();
        if (IEarnEngine(newEngine).earnVault() != address(this)) revert EngineEarnVaultMismatch();
        if (IEarnEngine(newEngine).shareScale() == 0) revert InvalidEngineShareScale();

        _accrueFees();

        uint256 supply = IEarnShare(earnShare).totalSupply();
        uint256 oldEngineShares = engineShares();
        uint256 oldRawEngineShares = rawEngineShares();
        uint256 assetsMoved = 0;
        uint256 receivedNewEngineShares;
        if (oldRawEngineShares != 0) {
            if (minNewEngineShares == 0) revert ZeroMinimumEngineShares();
            if (minAssetsRetained == 0) revert ZeroMinimumAssets();
            _requireCapability(oldEngine, type(IEarnEngineRedeem).interfaceId);
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
            _safeApprove(asset, newEngine, 0);
            _safeApprove(asset, newEngine, assetsMoved);
            uint256 rawSharesBefore = IEarnEngine(newEngine).totalShares();
            uint256 reportedEngineShares = IEarnEngine(newEngine).deposit(assetsMoved);
            _safeApprove(asset, newEngine, 0);
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
            if (oldEngineShares != 0) {
                if (newEngineShares < minNewEngineShares) {
                    revert MinimumEngineSharesNotMet(minNewEngineShares, newEngineShares);
                }
                uint256 assetsRetained = IEarnEngine(newEngine).valueOf(newEngineShares);
                if (oldEngineShares != oldRawEngineShares) {
                    uint256 expectedManagedAssets = Math.mulDiv(replacementAssets, oldEngineShares, oldRawEngineShares);
                    _requireAcceptableMigrationClassification(expectedManagedAssets, assetsRetained);
                }
                if (assetsRetained < minAssetsRetained) {
                    revert MinimumAssetsNotMet(minAssetsRetained, assetsRetained);
                }
            }
        }

        engine = newEngine;
        _managedEngineShares = newEngineShares;

        // Re-anchor from the recognized count. Pre-existing replacement shares and the migrated
        // unrecognized fraction both remain surplus on the current, reachable engine.
        uint256 heldNow = newEngineShares;
        if (supply == 0 || heldNow == 0) {
            _resetEmptyAnchor(newEngine);
        } else {
            anchorEngineShares = heldNow;
            anchorEarnShares = supply;
            // A migration changes raw engine-share denomination. Start a fresh fixed-100x contribution
            // window from the replacement engine's actual post-migration normalized rate.
            rewardRateBaseline = _normalizedRate(anchorEngineShares, anchorEarnShares);
        }

        emit EngineMigrated(
            oldEngine,
            newEngine,
            oldEngineShares,
            assetsMoved,
            newEngineShares,
            supply,
            anchorEngineShares,
            anchorEarnShares
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
        _requireCapability(engine, type(IEarnEngineRedeem).interfaceId);
        (uint256 engineShareAnchor, uint256 supplyAnchor) = _previewConversionAnchor();
        uint256 engineSharesToRedeem = Math.mulDiv(earnShares, engineShareAnchor, supplyAnchor);
        if (engineSharesToRedeem == 0) return 0;
        return IEarnEngineRedeem(engine).previewRedeem(engineSharesToRedeem);
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256 earnShares) {
        _requireCapability(engine, type(IEarnEngineExactWithdraw).interfaceId);
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
        if (!ERC165Checker.supportsInterface(currentEngine, type(IEarnEngineFeeValuation).interfaceId)) return true;
        return IEarnEngineFeeValuation(currentEngine).isFeeValuationFresh();
    }

    /// @notice Additional assets that may enter before reaching the current managed-assets limit.
    /// @dev Returns `type(uint256).max` when no limit is configured. This is a quote, not a reservation;
    ///      venue value and concurrent inflows may change before execution.
    function remainingDepositCapacity() external view override returns (uint256 assets) {
        uint256 maximum = maxManagedAssets;
        if (maximum == 0) return type(uint256).max;
        uint256 managed = totalAssets();
        return managed >= maximum ? 0 : maximum - managed;
    }

    /// @notice Current normalized managed engine shares per whole EarnShare, including pending fee dilution.
    function normalizedRewardRate() public view override returns (uint256) {
        (uint256 engineShareAnchor, uint256 supplyAnchor) = _previewConversionAnchor();
        return _normalizedRate(engineShareAnchor, supplyAnchor);
    }

    function totalEarnShares() public view override returns (uint256) {
        return IEarnShare(earnShare).totalSupply();
    }

    /// @notice Checks that live EarnShare supply converts exactly to active engine shares at the
    ///         current anchor. Pending async claims are excluded from both sides because their
    ///         EarnShare was burned when their engine shares entered the queue.
    function isAccountingAligned() external view override returns (bool) {
        uint256 supply = totalEarnShares();
        uint256 held = engineShares();
        if (supply == 0 || held == 0) return supply == 0 && held == 0;
        return _convertToEngineShares(supply) == held;
    }

    /// @notice Reads the stored fields of the pending async request `requestId`.
    function pendingRedeem(bytes32 requestId) external view returns (PendingRedeem memory) {
        return _pending[requestId];
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

    function _convertToEngineShares(uint256 earnShares) internal view returns (uint256) {
        return Math.mulDiv(earnShares, anchorEngineShares, anchorEarnShares);
    }

    function _convertEngineSharesToEarnShares(uint256 engineShares_) internal view returns (uint256) {
        return Math.mulDiv(engineShares_, anchorEarnShares, anchorEngineShares);
    }

    function _convertEngineSharesToEarnSharesUp(uint256 engineShares_) internal view returns (uint256) {
        return Math.mulDiv(engineShares_, anchorEarnShares, anchorEngineShares, Math.Rounding.Ceil);
    }

    /// @dev Rejects entries whose floor-rounded EarnShare output represents materially less than
    ///      the engine shares that entered. The one-basis-point protocol ceiling protects callers even
    ///      when a tiny active supply makes an already-quoted conversion pathologically coarse.
    function _requireAcceptableConversion(uint256 inputShares, uint256 outputTokens) internal view {
        uint256 representedShares = _convertToEngineShares(outputTokens);
        _requireAcceptableLoss(inputShares, representedShares);
    }

    function _requireAcceptableEarnShareConversion(uint256 inputTokens, uint256 outputShares) internal view {
        uint256 representedTokens = _convertEngineSharesToEarnShares(outputShares);
        _requireAcceptableLoss(inputTokens, representedTokens);
    }

    function _requireAcceptableLoss(uint256 inputAmount, uint256 representedAmount) internal pure {
        if (representedAmount > inputAmount) revert ExcessiveConversionLoss(inputAmount, representedAmount);
        uint256 maximumLoss = inputAmount / CONVERSION_BPS;
        if (inputAmount - representedAmount > maximumLoss) {
            revert ExcessiveConversionLoss(inputAmount, representedAmount);
        }
    }

    /// @dev A replacement denomination must represent the old managed/raw split without transferring
    ///      economically material value between active backing and quarantined surplus. Share-count
    ///      rounding favors managed backing, but its value error may not exceed one basis point.
    function _requireAcceptableMigrationClassification(uint256 expectedManagedAssets, uint256 actualManagedAssets)
        internal
        pure
    {
        uint256 difference = actualManagedAssets > expectedManagedAssets
            ? actualManagedAssets - expectedManagedAssets
            : expectedManagedAssets - actualManagedAssets;
        if (difference > expectedManagedAssets / CONVERSION_BPS) {
            revert ExcessiveMigrationClassificationError(expectedManagedAssets, actualManagedAssets);
        }
    }

    /// @dev Projects the exact conversion anchor that `_accrueFees` and `_reanchorAtRest` would leave
    ///      in this block, including pending fee-share minting and managed custody shortfall.
    function _previewConversionAnchor() internal view returns (uint256 engineShareAnchor, uint256 supplyAnchor) {
        engineShareAnchor = anchorEngineShares;
        supplyAnchor = anchorEarnShares;

        uint256 feeEarnShares = IEarnFees(earnFees).previewAccruedFees().totalFeeEarnShares;
        uint256 projectedSupply = IEarnShare(earnShare).totalSupply() + feeEarnShares;
        uint256 held = engineShares();
        if (projectedSupply == 0) {
            return (IEarnEngine(engine).shareScale(), earnShareScale);
        }
        if (held == 0) return (0, projectedSupply);
        if (projectedSupply == supplyAnchor && held == engineShareAnchor) {
            return (engineShareAnchor, supplyAnchor);
        }
        return (held, projectedSupply);
    }

    /// @dev A principal deposit must not recapitalize existing EarnShare after its active engine
    ///      position has zero base-asset value, even when raw engine shares remain. Permissionless
    ///      `contribute` is the explicit path for deliberately restoring value without issuing a claim.
    function _requireDepositBacking(uint256 supply, uint256 backingAssets) internal pure {
        if (supply != 0 && backingAssets == 0) revert ActiveSupplyWithoutBacking();
    }

    /// @dev Active fee checkpoints already read managed assets. Reuse that verified value rather
    ///      than calling through the engine again; inactive fees retain the original backing read.
    function _requireDepositBackingAfterAccrual(uint256 supply, uint256 accruedActiveAssets) internal view {
        _requireDepositBacking(supply, accruedActiveAssets == 0 ? totalAssets() : accruedActiveAssets);
    }

    /// @dev Applies only to voluntary inflows. Passive yield may exceed the limit, and exit,
    ///      cancellation, and migration paths deliberately remain available.
    function _requireWithinManagedAssetsLimit() internal view {
        uint256 maximum = maxManagedAssets;
        if (maximum == 0) return;
        uint256 managed = totalAssets();
        if (managed > maximum) revert MaxManagedAssetsExceeded(maximum, managed);
    }

    /// @dev Restates the anchor from exact active backing and supply. Exact pair equality is required:
    ///      a floor conversion can map a changed supply to the same held count while still preserving
    ///      a stale pre-fee rate that lets holders consume backing allocated to fee EarnShare.
    function _reanchorAtRest() internal returns (uint256 supply, uint256 held) {
        supply = IEarnShare(earnShare).totalSupply();
        uint256 raw = rawEngineShares();
        uint256 managed = _managedEngineShares;
        if (managed > raw) {
            _managedEngineShares = raw;
            emit EngineShareShortfallReconciled(engine, managed, raw, managed - raw, supply);
        }
        held = _managedEngineShares;
        if (supply == 0 || held == 0) {
            _resetEmptyAnchor(engine);
            return (supply, held);
        }
        if (anchorEarnShares == supply && anchorEngineShares == held) return (supply, held);

        anchorEngineShares = held;
        anchorEarnShares = supply;
    }

    /// @dev Principal entry must not act as an implicit reward for existing holders. The EarnShare
    ///      minted at the pre-entry anchor represents an exact floor-rounded engine-share count;
    ///      only that count becomes managed backing. Any unrepresented entry remainder stays raw
    ///      surplus and may be absorbed later through the explicit capped reward path.
    function _reanchorAfterEntry(uint256 rateEngineShares, uint256 rateEarnShares)
        internal
        returns (uint256 supply, uint256 held)
    {
        supply = IEarnShare(earnShare).totalSupply();
        uint256 represented = Math.mulDiv(supply, rateEngineShares, rateEarnShares);
        if (_managedEngineShares > represented) _managedEngineShares = represented;
        return _reanchorAtRest();
    }

    /// @dev Empty pools use whole-share units instead of a raw-unit 1:1 rate. This keeps the first
    ///      EarnShare mint normalized even when the engine and EarnShare use different decimals.
    function _resetEmptyAnchor(address engine_) internal {
        anchorEngineShares = IEarnEngine(engine_).shareScale();
        if (anchorEngineShares == 0) revert InvalidEngineShareScale();
        anchorEarnShares = earnShareScale;
        rewardRateBaseline = anchorEngineShares;
    }

    function _recordEngineShareIncrease(uint256 rawSharesBefore, uint256 reportedEngineShares)
        internal
        returns (uint256 receivedEngineShares)
    {
        uint256 rawSharesAfter = rawEngineShares();
        if (rawSharesAfter <= rawSharesBefore) revert InsufficientOutput();
        receivedEngineShares = rawSharesAfter - rawSharesBefore;
        if (reportedEngineShares != receivedEngineShares) revert InsufficientOutput();
        _managedEngineShares += receivedEngineShares;
    }

    function _decreaseManagedEngineShares(uint256 engineShares_) internal {
        uint256 managed = _managedEngineShares;
        if (engineShares_ > managed) revert InsufficientOutput();
        _managedEngineShares = managed - engineShares_;
    }

    function _normalizedRate(uint256 engineShareAnchor, uint256 supplyAnchor) internal view returns (uint256) {
        if (engineShareAnchor == 0) return 0;
        return Math.mulDiv(engineShareAnchor, earnShareScale, supplyAnchor, Math.Rounding.Ceil);
    }

    function _requireRewardRateWithinLimit() internal view {
        uint256 baseline = rewardRateBaseline;
        uint256 current = _normalizedRate(anchorEngineShares, anchorEarnShares);
        if (!_isRewardRateWithinLimit(current)) revert RewardRateLimitExceeded(current, baseline);
    }

    function _isRewardRateWithinLimit(uint256 current) internal view returns (bool) {
        uint256 baseline = rewardRateBaseline;
        uint256 wholeMultiples = current / baseline;
        return !(wholeMultiples > MAX_REWARD_RATE_MULTIPLIER
                || (wholeMultiples == MAX_REWARD_RATE_MULTIPLIER && current % baseline != 0));
    }

    function _requireDistributor() internal view {
        if (distributor == address(0) || msg.sender != distributor) revert NotDistributor();
    }

    function _currentFeeConfig() internal view returns (FeeConfig memory) {
        IEarnFees fees = IEarnFees(earnFees);
        return fees.feeConfig(fees.currentFeeConfigId());
    }

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
        for (uint8 i = 0; i < operatorCount; i++) {
            result.fixedFees[resultStart + i] = config.fixedFees[operatorStart + i];
        }
        result.excess = config.excess;
    }

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

    function _accrueFees() internal returns (FeePreview memory result, uint256 supply, uint256 backing) {
        result = IEarnFees(earnFees).accrueFees();
        if (result.totalFeeEarnShares != 0) {
            IEarnShare(earnShare).mint(earnFees, result.totalFeeEarnShares);
        }
        // Reconcile the conversion anchor even when no fee shares were minted. Unsolicited positive
        // engine-share drift remains quarantined, while a custody shortfall reduces managed backing.
        (supply, backing) = _reanchorAtRest();
    }

    function _recordPendingRedeem(
        bytes32 requestId,
        address requester,
        address receiver,
        uint256 earnShares,
        uint256 engineShares_
    ) internal {
        PendingRedeem storage pending = _pending[requestId];
        if (pending.open) revert DuplicateRequest(requestId);
        pending.receiver = receiver;
        pending.requester = requester;
        pending.burnedEarnShares = earnShares;
        pending.engineShares = engineShares_;
        pending.open = true;
        if (IEarnFees(earnFees).feesActive() && isFeeValuationFresh()) {
            uint256 requestValue = IEarnEngine(engine).valueOf(engineShares_);
            IEarnFees(earnFees).recordRedeemRequest(requestId, earnShares, requestValue);
        }
    }

    function _requireCapability(address candidate, bytes4 interfaceId) internal view {
        if (!ERC165Checker.supportsInterface(candidate, interfaceId)) {
            revert EngineCapabilityUnsupported(interfaceId);
        }
    }

    function _requireExitCapability(address candidate) internal view {
        if (
            !ERC165Checker.supportsInterface(candidate, type(IEarnEngineRedeem).interfaceId)
                && !ERC165Checker.supportsInterface(candidate, type(IEarnEngineExactWithdraw).interfaceId)
                && !ERC165Checker.supportsInterface(candidate, type(IEarnEngineAsyncRedeem).interfaceId)
        ) revert EngineExitUnsupported();
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
}
