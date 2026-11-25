// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { EarnFeeMath } from "./EarnFeeMath.sol";
import {
    BPS_DENOMINATOR,
    ExcessReturnFee,
    FeeConfig,
    FeePreview,
    FixedFeeRecipient,
    MAX_FIXED_FEE_RECIPIENTS
} from "../../interfaces/earn/EarnFeeTypes.sol";
import { IEarnFees } from "../../interfaces/earn/IEarnFees.sol";
import { IEarnShare } from "../../interfaces/earn/IEarnShare.sol";
import { IERC20Like } from "../../interfaces/external/IERC20Like.sol";

/// @dev The EarnVault's request record, read by {EarnFees.pendingFeeSnapshot} for the burned EarnShare it no longer stores.
interface IEarnVaultPendingRedeem {
    function pendingRedeem(bytes32 requestId)
        external
        view
        returns (address receiver, address requester, uint256 burnedEarnShares, bool open);
}

interface IEarnVaultFeeContext {
    function totalAssets() external view returns (uint256);
    function isFeeValuationFresh() external view returns (bool);
}

/// @title EarnFees
/// @notice Ownerless fee state machine and fee-EarnShare custodian for one immutable EarnVault.
/// @dev Only the paired EarnVault mutates accounting. The EarnVault remains the sole EarnShare issuer and
///      atomically mints exactly the amount returned by a checkpoint to this contract.
/// @dev The `@custom:` specs are checked by solar-verify and state the rules of
///      docs/earn/architecture/fees.md. The spec helpers at the end are never executed.
/// @custom:ghost uint256 sumClaimable
/// @custom:ghost uint256 checkpointSupply
/// @custom:invariant totalClaimableEarnShares() == sumClaimable
/// @custom:invariant _totalClaimableEarnShares == 0 || _totalClaimableEarnShares == sumClaimable + 1
/// @custom:invariant _totalClaimableEarnShares == 0 ==> (sumClaimable == 0 && forall address a :: _claimableEarnShares[a] == 0)
/// @dev Solvency: recorded fee EarnShare grows only by what the vault mints or re-enters here (`accrueFees`,
///      `settleCancelledRedeem`) and shrinks only by what `claim` transfers out.
///      Not proved: `totalClaimableEarnShares` is at most this contract's EarnShare balance; it rests on the vault
///      minting exactly each checkpoint's `totalFeeEarnShares` and each cancelled request's re-entry EarnShare
///      here, which this contract cannot observe.
///      Not proved: each recipient's `claimableEarnShares` is at most `totalClaimableEarnShares` (a sum over the
///      mapping, which only the `sumClaimable` ghost tracks).
/// @custom:invariant !initialized ==> (_currentFeeConfigId == 0 && earnVault == address(0))
/// @custom:invariant earnVault != address(0) ==> (_currentFeeConfigId >= 1 && initialized)
/// @custom:invariant _specWithinFeeBounds(_currentFeeConfigId)
/// @custom:invariant forall uint64 c :: _feeConfigs[c].excess.fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
/// @custom:invariant forall uint64 c, uint256 k :: c > _currentFeeConfigId ==> _feeConfigs[c].fixedFees[k].account == address(0) && _feeConfigs[c].fixedFees[k].rateBps == 0
/// @custom:invariant forall bytes32 r :: _pendingFeeSnapshots[r].feeConfigId != 0 ==> _specInstalled(_pendingFeeSnapshots[r].feeConfigId)
/// @custom:reentrancy-guard initialized && _entered
contract EarnFees is IEarnFees {
    address public earnVault;
    /// @dev Set by the constructor on the implementation and by {initialize} on a clone. Packed beside
    ///      `earnVault`, which {initialize} writes in the same call.
    bool private initialized;
    /// @dev Everything a checkpoint reads here shares `earnVault`'s slot, which `onlyEarnVault` has already read.
    ///      Read through {currentFeeConfigId}; {setFeeConfig} reverts past its width.
    uint24 private _currentFeeConfigId;
    bool public feesDisabled;
    /// @notice Whether an empty active pool was reopened while fee valuation was stale.
    /// @dev The next fresh checkpoint initializes baselines without charging the returned principal.
    bool public feeBaselinesPending;
    uint40 public targetStartedAt;
    /// @dev EarnShare decimals; {earnShareScale} and {_valueScale} widen them back.
    uint8 private _earnShareDecimals;
    address public earnShare;
    /// @dev When fees were last disabled. A request snapshot recorded at or before it is void, so a disable and
    ///      re-enable within one second also voids requests recorded after the re-enable, in their favour.
    uint40 private _lastDisabledAt;

    /// @dev The high-water mark and target base, which every charging checkpoint reads together, share one slot.
    ///      A value too wide for its half stores {WIDE_BASELINE} there and itself in its wide slot below, so every
    ///      value is kept whole; read them through {highWaterMark}, {targetBase} or {_baselines}.
    uint128 private _highWaterMark;
    uint128 private _targetBase;

    /// @dev Stored form of {ExcessReturnFee}, also carrying the fixed-fee count and the open request count in the
    ///      same slot, so one read answers whether a configuration charges any fee.
    struct StoredExcessFee {
        bool enabled;
        address account;
        uint16 annualTargetRateBps;
        uint16 excessFeeRateBps;
        uint8 fixedFeeCount;
        /// @dev Open request snapshots recorded under this configuration. A snapshot is recorded only while its
        ///      configuration charges a fee, so `enabled` or `fixedFeeCount` already keeps this slot nonzero and
        ///      counting writes no slot from zero.
        uint48 openRequests;
    }

    /// @dev Stored form of {FeeConfig} in five slots; {feeConfig} widens it back.
    struct StoredFeeConfig {
        FixedFeeRecipient[4] fixedFees;
        StoredExcessFee excess;
    }

    mapping(uint64 configId => StoredFeeConfig config) private _feeConfigs;
    /// @dev Five remainders per configuration in one slot, {REMAINDER_BITS} each: fixed recipients 0 to 3, then
    ///      the excess fee. {REMAINDERS_MARKER} is set with the first carried remainder and keeps the slot nonzero
    ///      while the configuration can still accrue; waiving clears it, since a waived configuration never accrues.
    mapping(uint64 configId => uint256 packed) private _feeRemainders;

    /// @dev Stored form of {PendingFeeSnapshot} in one slot. A nonzero `feeConfigId` marks it open (installed
    ///      configuration ids start at 1). The burned EarnShare stays in the EarnVault's request record, which
    ///      passes it back on cancellation.
    struct StoredFeeSnapshot {
        uint96 highWaterValue;
        uint96 targetValue;
        uint24 feeConfigId;
        uint40 requestedAt;
    }

    mapping(bytes32 requestId => StoredFeeSnapshot snapshot) private _pendingFeeSnapshots;
    /// @dev Each recipient's claimable EarnShare plus one once it has been credited, and the same for the total, so a
    ///      full claim leaves the slot nonzero and the next credit rewrites it instead of creating it again.
    mapping(address recipient => uint256 storedEarnShares) private _claimableEarnShares;
    uint256 private _totalClaimableEarnShares;
    /// @dev The high-water mark and target base while they are at least {WIDE_BASELINE}; read only then.
    uint256 private _wideHighWaterMark;
    uint256 private _wideTargetBase;

    /// @dev Marks a baseline half that holds no value of its own: the value is in its wide slot.
    uint256 private constant WIDE_BASELINE = type(uint128).max;
    uint256 private constant REMAINDER_BITS = 48;
    uint256 private constant REMAINDER_MASK = (1 << REMAINDER_BITS) - 1;
    uint256 private constant REMAINDERS_MARKER = 1 << 255;
    /// @dev EarnShare units that never count as supply: one the EarnVault keeps and one it mints here, so neither
    ///      balance slot is ever emptied. Mirrors the EarnVault's {_activeSupply}.
    uint256 private constant LOCKED_EARN_SHARES = 2;
    /// @dev Values per EarnShare (baselines, previews, events) carry this factor on top of the EarnShare scale, so a
    ///      baseline moves by what a checkpoint charged to within far less than one asset unit. It is also the
    ///      smallest rise above the high-water mark a checkpoint charges: one asset unit per whole EarnShare.
    uint256 private constant VALUE_PRECISION = 1e18;

    /// @dev Reentrancy lock held for the duration of each locked call. Transient storage writes no slot.
    bool private transient _entered;

    event FeesAccrued(
        uint64 indexed configId,
        uint256 activeAssets,
        uint256 positiveAccrualAssets,
        uint256 feeAssets,
        uint256 feeEarnShares,
        uint256 highWaterMark,
        uint256 targetValuePerEarnShare
    );
    event FeeEarnSharesAllocated(
        uint64 indexed configId, address indexed recipient, uint256 feeAssets, uint256 feeEarnShares
    );
    event FeeEarnSharesClaimed(address indexed recipient, address indexed to, uint256 earnShares);
    event FeeConfigurationSet(uint64 indexed configId, bytes32 indexed configHash, bool reactivated);
    event FeeDustWaived(uint64 indexed configId, uint8 indexed slot, uint256 remainder);
    event FeesDisabled(address indexed operator);
    event FeeBaselinesInitialized(uint256 highWaterMark, uint256 targetBase, uint40 targetStartedAt);

    error AlreadyInitialized();
    error InsufficientClaimableEarnShares();
    error InvalidFeeClaimReceiver();
    error InvalidFeeConfiguration();
    error NotEarnVault();
    error ReentrantCall();
    error ZeroAddress();
    error ZeroAmount();

    /// @custom:ensures initialized && earnVault == address(0) && _currentFeeConfigId == 0
    constructor() {
        initialized = true;
    }

    modifier onlyEarnVault() {
        if (msg.sender != earnVault) revert NotEarnVault();
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    /// @notice A fresh clone is initialized once, paired with one vault and EarnShare, under configuration 1.
    /// @custom:ensures !old(initialized) && initialized
    /// @custom:ensures earnVault == earnVault_ && earnShare == earnShare_ && earnVault_ != address(0) && earnShare_ != address(0)
    /// @custom:ensures _currentFeeConfigId == 1 && _specStored(1, initialConfig) && _specValidConfig(initialConfig)
    /// @custom:ensures totalClaimableEarnShares() == old(totalClaimableEarnShares())
    /// Not proved: the verifier does not finish this function within its time limit.
    function initialize(address earnVault_, address earnShare_, FeeConfig calldata initialConfig) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        if (earnVault_ == address(0) || earnShare_ == address(0)) revert ZeroAddress();

        earnVault = earnVault_;
        earnShare = earnShare_;

        uint8 decimals = IEarnShare(earnShare_).decimals();
        // Keeps the value scale, 10 ** decimals * VALUE_PRECISION, at most 10 ** 54, far inside uint256: a value
        // per EarnShare, and a snapshot rebuilt from one (at most one scale above it), fit with room to spare.
        if (decimals > 36) revert InvalidFeeConfiguration();
        _earnShareDecimals = decimals;

        _validateFeeConfig(initialConfig);
        _currentFeeConfigId = 1;
        _storeFeeConfig(1, initialConfig);
        emit FeeConfigurationSet(1, keccak256(abi.encode(initialConfig)), false);
    }

    /// @notice EarnShare `recipient` may claim.
    function claimableEarnShares(address recipient) public view returns (uint256 earnShares) {
        uint256 stored = _claimableEarnShares[recipient];
        return stored == 0 ? 0 : stored - 1;
    }

    /// @notice EarnShare all recipients may claim together.
    function totalClaimableEarnShares() public view returns (uint256) {
        uint256 stored = _totalClaimableEarnShares;
        return stored == 0 ? 0 : stored - 1;
    }

    /// @notice The high-water mark: the value per EarnShare above which fees charge, in asset units per
    ///         {earnShareScale} EarnShare units, times 10 ** 18.
    function highWaterMark() public view returns (uint256) {
        uint256 mark = _highWaterMark;
        return mark == WIDE_BASELINE ? _wideHighWaterMark : mark;
    }

    /// @notice The excess-return target's value per EarnShare when it last restarted, at {targetStartedAt}, scaled
    ///         as {highWaterMark}.
    function targetBase() public view returns (uint256) {
        uint256 base = _targetBase;
        return base == WIDE_BASELINE ? _wideTargetBase : base;
    }

    /// @notice The id of the configuration in force; installed ids count up from 1.
    function currentFeeConfigId() external view returns (uint64) {
        return _currentFeeConfigId;
    }

    function feeConfig(uint64 configId) external view returns (FeeConfig memory) {
        return _loadFeeConfig(_feeConfigs[configId]);
    }

    function feeRemainder(uint64 configId, uint8 slot) external view returns (uint256) {
        if (slot > MAX_FIXED_FEE_RECIPIENTS) return 0;
        return _remainderAt(_feeRemainders[configId], slot);
    }

    /// @notice One unit of EarnShare in its smallest denomination.
    /// @dev Zero until {initialize} binds an EarnShare, so an unbound instance never reports a zero-decimal scale.
    function earnShareScale() external view returns (uint256) {
        if (earnShare == address(0)) return 0;
        return 10 ** uint256(_earnShareDecimals);
    }

    function feesActive() external view returns (bool) {
        return _feesActive();
    }

    function pendingFeeSnapshot(bytes32 requestId) external view returns (PendingFeeSnapshot memory) {
        StoredFeeSnapshot storage pending = _pendingFeeSnapshots[requestId];
        bool open = pending.feeConfigId != 0;
        return PendingFeeSnapshot({
            burnedEarnShares: open ? _vaultBurnedEarnShares(requestId) : 0,
            highWaterValue: pending.highWaterValue,
            targetValue: pending.targetValue,
            feeConfigId: pending.feeConfigId,
            requestedAt: pending.requestedAt,
            open: open
        });
    }

    function _vaultBurnedEarnShares(bytes32 requestId) internal view returns (uint256 burnedEarnShares) {
        (,, burnedEarnShares,) = IEarnVaultPendingRedeem(earnVault).pendingRedeem(requestId);
    }

    /// @custom:ensures result ==> _specChargesPending(requestId)
    function shouldChargeRedeem(bytes32 requestId) external view returns (bool) {
        StoredFeeSnapshot storage pending = _pendingFeeSnapshots[requestId];
        uint64 configId = pending.feeConfigId;
        return configId != 0 && _lastDisabledAt < pending.requestedAt && !feesDisabled
            && _storedConfigHasFees(_feeConfigs[configId]) && _feeValuationFresh();
    }

    /// @custom:ensures (!_specFeesActive() || feeBaselinesPending) ==> EarnFeeMath.chargesNothing(result) && result.activeAssets == 0
    /// @custom:ensures result.totalFeeAssets <= result.positiveAccrualAssets
    /// @custom:ensures result.totalFeeEarnShares == EarnFeeMath.allocatedFeeEarnShares(result)
    function previewAccruedFees() public view returns (FeePreview memory result) {
        if (!_feesActive()) return result;
        if (feeBaselinesPending || !_feeValuationFresh()) return result;
        uint256 earnShareSupply = _activeSupply();
        if (earnShareSupply == 0) return result;

        uint64 configId = _currentFeeConfigId;
        StoredFeeConfig storage storedConfig = _feeConfigs[configId];
        uint256 activeAssets = _activeAssets();
        uint256 scale = _valueScale();
        (uint256 mark, uint256 base) = _baselines();
        // A checkpoint charges nothing while accrual is still waiting ({_chargeableAccrual}), so neither does this.
        uint256 value = EarnFeeMath.valuePerEarnShare(activeAssets, scale, earnShareSupply);
        if (_chargeableAccrual(value, mark, earnShareSupply, scale) == 0 && value > mark) mark = value;
        (result,) = EarnFeeMath.preview(
            EarnFeeMath.Input({
                activeAssets: activeAssets,
                earnShareSupply: earnShareSupply,
                earnShareScale: scale,
                highWaterMark: mark,
                targetBase: base,
                targetStartedAt: targetStartedAt,
                timestamp: block.timestamp
            }),
            _loadFeeConfig(storedConfig),
            _remainders(configId, storedConfig)
        );
    }

    /// @notice Charges fees above the high-water mark; the vault mints exactly the returned fee EarnShare here.
    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && _valueScale() == old(_valueScale())
    /// @custom:ensures totalClaimableEarnShares() == old(totalClaimableEarnShares()) + feeEarnShares
    /// @custom:ensures sumClaimable == old(sumClaimable) + feeEarnShares
    /// @custom:ensures forall address a :: claimableEarnShares(a) >= old(claimableEarnShares(a))
    /// @dev The vault passes its active EarnShare supply, active assets and valuation freshness; only the vault
    ///      reaches this, so the values carry the same trust as reading them back from it. `activeAssets` is read
    ///      only for a nonzero supply and a fresh valuation. For a checkpoint that valued the pool, `scale` is the
    ///      value scale ({_valueScale}) and `baselineFloor` the highest value per EarnShare at that scale, rounded up,
    ///      at which a principal entry would leave `initializeBaselines` nothing to raise ({_entryFloor}).
    ///      Both are zero otherwise, so a nonzero `scale` tells the vault the checkpoint valued `activeAssets`.
    ///      `_accrueFees` states each recipient's credit.
    function accrueFees(uint256 activeSupply, uint256 activeAssets, bool valuationFresh)
        external
        onlyEarnVault
        returns (uint256 feeAssets, uint256 feeEarnShares, uint256 baselineFloor, uint256 scale)
    {
        // Destructured into a fresh declaration, so no unused FeePreview is allocated before the call.
        (FeePreview memory result, uint256 floor_, uint256 scale_) =
            _accrueFees(activeSupply, activeAssets, valuationFresh);
        return (result.totalFeeAssets, result.totalFeeEarnShares, floor_, scale_);
    }

    /// @notice Installs a valid configuration under the next id and re-enables fees (fees.md, "Configuration and authority").
    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && _valueScale() == old(_valueScale())
    /// @custom:ensures _specValidConfig(config) && configId == old(_currentFeeConfigId) + 1 && _currentFeeConfigId == configId
    /// @custom:ensures _specStored(configId, config) && !feesDisabled
    /// @custom:ensures totalClaimableEarnShares() == old(totalClaimableEarnShares())
    /// @custom:ensures !_configHasFees(config) ==> _specBaselines(old(highWaterMark()), old(targetBase()), old(targetStartedAt))
    /// @custom:ensures (_configHasFees(config) && !config.excess.enabled) ==> targetBase() == 0 && targetStartedAt == 0
    /// @custom:ensures (_configHasFees(config) && old(_specFeesActive())) ==> highWaterMark() >= old(highWaterMark())
    /// @custom:ensures (old(_specFeesActive()) || !_configHasFees(config)) ==> feeBaselinesPending == old(feeBaselinesPending)
    /// @custom:ensures (config.excess.enabled && old(_specFeesActive())) ==> targetStartedAt == uint40(block.timestamp)
    /// @custom:ensures (config.excess.enabled && old(_specFeesActive() && _feeConfigs[_currentFeeConfigId].excess.enabled)) ==> targetBase() == old(_specTargetNow())
    /// @custom:ensures (old(feesDisabled) || old(_feeConfigs[_currentFeeConfigId].excess.openRequests) == 0) ==> _specRemaindersWaived(old(_currentFeeConfigId))
    /// @custom:ensures forall address a :: claimableEarnShares(a) == old(claimableEarnShares(a))
    /// @custom:ensures _lastDisabledAt == old(_lastDisabledAt)
    /// @custom:ensures forall bytes32 r :: _pendingFeeSnapshots[r].feeConfigId == old(_pendingFeeSnapshots[r].feeConfigId) && _pendingFeeSnapshots[r].requestedAt == old(_pendingFeeSnapshots[r].requestedAt)
    /// @custom:ensures forall bytes32 r :: _pendingFeeSnapshots[r].highWaterValue == old(_pendingFeeSnapshots[r].highWaterValue) && _pendingFeeSnapshots[r].targetValue == old(_pendingFeeSnapshots[r].targetValue)
    /// @custom:ensures forall uint64 c :: c != configId ==> _feeConfigs[c].excess.fixedFeeCount == old(_feeConfigs[c].excess.fixedFeeCount) && _feeConfigs[c].excess.enabled == old(_feeConfigs[c].excess.enabled) && _feeConfigs[c].excess.account == old(_feeConfigs[c].excess.account)
    /// @custom:ensures forall uint64 c :: c != configId ==> _feeConfigs[c].excess.annualTargetRateBps == old(_feeConfigs[c].excess.annualTargetRateBps) && _feeConfigs[c].excess.excessFeeRateBps == old(_feeConfigs[c].excess.excessFeeRateBps)
    /// @custom:ensures forall uint64 c, uint256 k :: (c != configId && k < MAX_FIXED_FEE_RECIPIENTS) ==> _feeConfigs[c].fixedFees[k].account == old(_feeConfigs[c].fixedFees[k].account) && _feeConfigs[c].fixedFees[k].rateBps == old(_feeConfigs[c].fixedFees[k].rateBps)
    /// @dev A change never rewrites what is already owed: recorded claims, open requests' snapshots and the
    ///      configurations they settle under stay as they were. Not proved: yield earned before the change is
    ///      charged under the old configuration; the paired vault checkpoints (`accrueFees`) in the same call
    ///      before installing a configuration, which this contract cannot observe.
    function setFeeConfig(FeeConfig calldata config) external onlyEarnVault returns (uint64 configId) {
        _validateFeeConfig(config);

        bool reactivated = feesDisabled;
        bool wasActive = _feesActive();
        StoredExcessFee memory oldExcess = _feeConfigs[_currentFeeConfigId].excess;
        uint256 oldTargetNow = oldExcess.enabled
            ? EarnFeeMath.targetAt(targetBase(), oldExcess.annualTargetRateBps, targetStartedAt, block.timestamp)
            : 0;
        _waiveCurrentRemainders();

        configId = uint64(_currentFeeConfigId) + 1;
        if (configId > type(uint24).max) revert InvalidFeeConfiguration();
        // Bounded above, so the narrowing cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        _currentFeeConfigId = uint24(configId);
        _storeFeeConfig(configId, config);
        feesDisabled = false;

        if (_configHasFees(config)) {
            if (!wasActive || reactivated) {
                uint256 earnShareSupply = _activeSupply();
                _initializeFeeBaselines(earnShareSupply, earnShareSupply == 0 ? 0 : _activeAssets());
            } else if (config.excess.enabled) {
                _forfeitWaitingAccrual();
                if (oldExcess.enabled) {
                    _setTargetBase(oldTargetNow);
                    targetStartedAt = uint40(block.timestamp);
                } else {
                    uint256 earnShareSupply = _activeSupply();
                    _setTargetBase(
                        earnShareSupply == 0
                            ? 0
                            : EarnFeeMath.valuePerEarnShareUp(_activeAssets(), _valueScale(), earnShareSupply)
                    );
                    targetStartedAt = uint40(block.timestamp);
                }
            } else {
                _forfeitWaitingAccrual();
                _setTargetBase(0);
                targetStartedAt = 0;
            }
        }

        emit FeeConfigurationSet(configId, keccak256(abi.encode(config)), reactivated);
    }

    /// @notice On a change between fee configurations, raises the high-water mark over accrual the outgoing
    ///         configuration left waiting below one step, so the incoming one never charges growth earned before it.
    /// @dev The vault checkpoints in the same call first, so what waits is less than one step; the outgoing
    ///      recipients forgo it rather than the incoming ones collecting it. A stale valuation leaves the mark.
    /// @custom:ensures highWaterMark() >= old(highWaterMark()) && targetBase() == old(targetBase())
    function _forfeitWaitingAccrual() internal {
        uint256 supply = _activeSupply();
        if (supply == 0 || !_feeValuationFresh()) return;
        uint256 value = EarnFeeMath.valuePerEarnShareUp(_activeAssets(), _valueScale(), supply);
        if (value > highWaterMark()) _setHighWaterMark(value);
    }

    /// @notice Reverts unless `config` satisfies the same structural rules as an installed configuration.
    /// @dev Used by the paired EarnVault to validate timelocked distributor updates before scheduling them.
    /// @custom:ensures _specValidConfig(config)
    /// @custom:succeeds-if _specValidConfig(config)
    function validateFeeConfig(FeeConfig calldata config) external view {
        _validateFeeConfig(config);
    }

    /// @notice Disabling stops charging, voids open request snapshots' charges and waives current remainders.
    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && _valueScale() == old(_valueScale())
    /// @custom:ensures _currentFeeConfigId == old(_currentFeeConfigId) && totalClaimableEarnShares() == old(totalClaimableEarnShares())
    /// @custom:ensures feesDisabled && _specBaselines(old(highWaterMark()), old(targetBase()), old(targetStartedAt))
    /// @custom:ensures !old(feesDisabled) ==> !feeBaselinesPending && _lastDisabledAt == uint40(block.timestamp)
    /// @custom:ensures !old(feesDisabled) ==> _specRemaindersWaived(_currentFeeConfigId)
    /// @custom:ensures old(feesDisabled) ==> feeBaselinesPending == old(feeBaselinesPending) && _lastDisabledAt == old(_lastDisabledAt)
    /// @custom:ensures old(feesDisabled) ==> forall uint64 c :: _feeRemainders[c] == old(_feeRemainders[c])
    function disableFees(address operator) external onlyEarnVault {
        if (feesDisabled) return;
        feesDisabled = true;
        feeBaselinesPending = false;
        // Every snapshot recorded up to now is void ({_specChargesPending}); a uint40 timestamp never truncates.
        _lastDisabledAt = uint40(block.timestamp);
        _waiveCurrentRemainders();
        emit FeesDisabled(operator);
    }

    /// @notice Ratchets fee baselines after principal enters without treating principal as yield.
    /// @dev Only the paired EarnVault calls this after minting proportional EarnShare. Rounding and
    ///      any valuation precision recovered by pooling favor holders through an upward-only ratchet. A rise of
    ///      less than one {VALUE_PRECISION} step may be accrual still waiting above the mark, so it stays there.
    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && _valueScale() == old(_valueScale())
    /// @custom:ensures _currentFeeConfigId == old(_currentFeeConfigId) && totalClaimableEarnShares() == old(totalClaimableEarnShares())
    /// @custom:ensures highWaterMark() >= old(highWaterMark())
    /// @custom:ensures targetBase() != old(targetBase()) ==> targetBase() > old(_specTargetNow()) && targetStartedAt == uint40(block.timestamp)
    /// @custom:ensures !old(_specFeesActive()) ==> _specBaselines(old(highWaterMark()), old(targetBase()), old(targetStartedAt))
    /// @custom:ensures !_feeConfigs[_currentFeeConfigId].excess.enabled ==> targetBase() == old(targetBase()) && targetStartedAt == old(targetStartedAt)
    /// @dev The vault passes its active EarnShare supply and active assets after the entry, as for `accrueFees`.
    function initializeBaselines(uint256 activeSupply, uint256 activeAssets) external onlyEarnVault {
        if (_feesActive()) _updateBaselinesAfterPrincipalEntry(activeSupply, activeAssets);
    }

    /// @notice Restarts fee baselines at the value of a principal entry that reopened an empty pool.
    /// @dev Every earlier holder has left, so no earlier baseline protects anyone in the pool. While the valuation
    ///      is stale it sets `feeBaselinesPending` instead, as a stale cancellation into an empty pool does. The vault
    ///      passes its active EarnShare supply and active assets after the entry, as for `initializeBaselines`.
    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && _valueScale() == old(_valueScale())
    /// @custom:ensures _currentFeeConfigId == old(_currentFeeConfigId) && totalClaimableEarnShares() == old(totalClaimableEarnShares())
    /// @custom:ensures !old(_specFeesActive()) ==> _specBaselines(old(highWaterMark()), old(targetBase()), old(targetStartedAt)) && feeBaselinesPending == old(feeBaselinesPending)
    /// @custom:ensures feeBaselinesPending ==> _specBaselines(old(highWaterMark()), old(targetBase()), old(targetStartedAt))
    /// @custom:ensures (old(_specFeesActive()) && !feeBaselinesPending && activeSupply != 0) ==> highWaterMark() == EarnFeeMath.ceilDiv(activeAssets * _valueScale(), activeSupply)
    /// @custom:ensures (old(_specFeesActive()) && !feeBaselinesPending && _feeConfigs[_currentFeeConfigId].excess.enabled) ==> targetBase() == highWaterMark()
    function reopenBaselines(uint256 activeSupply, uint256 activeAssets) external onlyEarnVault {
        if (!_feesActive()) return;
        if (!_feeValuationFresh()) {
            feeBaselinesPending = true;
            return;
        }
        if (feeBaselinesPending) feeBaselinesPending = false;
        _initializeFeeBaselines(activeSupply, activeAssets);
    }

    /// @notice Snapshots a fee-active request's high-water value and target value for its burned EarnShare.
    /// @dev The vault asks only while its valuation is fresh, as for `accrueFees`, so freshness is not read again. The
    ///      high-water value is the mark's: accrual still waiting below one step stays chargeable, so a cancellation
    ///      charges it with the growth while queued, and a finalized request takes it uncharged, as any exit does.
    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && _valueScale() == old(_valueScale())
    /// @custom:ensures _currentFeeConfigId == old(_currentFeeConfigId) && totalClaimableEarnShares() == old(totalClaimableEarnShares())
    /// @custom:ensures _specBaselines(old(highWaterMark()), old(targetBase()), old(targetStartedAt))
    /// @custom:ensures !old(_specFeesActive()) ==> _pendingFeeSnapshots[requestId].feeConfigId == old(_pendingFeeSnapshots[requestId].feeConfigId)
    /// @custom:ensures old(_pendingFeeSnapshots[requestId].feeConfigId) != 0 ==> _pendingFeeSnapshots[requestId].feeConfigId != 0
    /// @custom:ensures _pendingFeeSnapshots[requestId].feeConfigId == old(_pendingFeeSnapshots[requestId].feeConfigId) ==> _feeConfigs[_currentFeeConfigId].excess.openRequests == old(_feeConfigs[_currentFeeConfigId].excess.openRequests)
    /// @custom:ensures _pendingFeeSnapshots[requestId].feeConfigId != old(_pendingFeeSnapshots[requestId].feeConfigId) ==> _specRecorded(requestId, burnedEarnShares)
    /// @custom:ensures _pendingFeeSnapshots[requestId].feeConfigId != old(_pendingFeeSnapshots[requestId].feeConfigId) ==> _feeConfigs[_currentFeeConfigId].excess.openRequests == old(_feeConfigs[_currentFeeConfigId].excess.openRequests) + 1
    function recordRedeemRequest(bytes32 requestId, uint256 burnedEarnShares) external onlyEarnVault {
        if (!_feesActive()) return;
        StoredFeeSnapshot storage pending = _pendingFeeSnapshots[requestId];
        if (pending.feeConfigId != 0) revert InvalidFeeConfiguration();

        uint24 configId = _currentFeeConfigId;
        uint256 scale = _valueScale();
        (uint256 mark, uint256 base) = _baselines();
        uint256 highWaterValue = Math.mulDiv(mark, burnedEarnShares, scale, Math.Rounding.Ceil);
        uint256 targetValue;
        StoredExcessFee memory excess = _feeConfigs[configId].excess;
        if (excess.enabled) {
            uint256 currentTarget =
                EarnFeeMath.targetAt(base, excess.annualTargetRateBps, targetStartedAt, block.timestamp);
            targetValue = Math.mulDiv(currentTarget, burnedEarnShares, scale, Math.Rounding.Ceil);
        }
        // A snapshot too large for the packed record reverts rather than truncating.
        if (burnedEarnShares > type(uint128).max || highWaterValue > type(uint96).max || targetValue > type(uint96).max)
        {
            revert InvalidFeeConfiguration();
        }
        // Bounded above, so the narrowing conversions cannot truncate; a uint40 timestamp never truncates.
        // forge-lint: disable-next-line(unsafe-typecast)
        pending.highWaterValue = uint96(highWaterValue);
        // forge-lint: disable-next-line(unsafe-typecast)
        pending.targetValue = uint96(targetValue);
        pending.feeConfigId = configId;
        pending.requestedAt = uint40(block.timestamp);
        _feeConfigs[configId].excess.openRequests += 1;
    }

    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && _valueScale() == old(_valueScale())
    /// @custom:ensures _currentFeeConfigId == old(_currentFeeConfigId) && totalClaimableEarnShares() == old(totalClaimableEarnShares())
    /// @custom:ensures _pendingFeeSnapshots[requestId].feeConfigId == 0
    /// @custom:ensures old(_pendingFeeSnapshots[requestId].feeConfigId) != 0 ==> _specClosed(requestId, old(_pendingFeeSnapshots[requestId].feeConfigId), old(_feeConfigs[_pendingFeeSnapshots[requestId].feeConfigId].excess.openRequests))
    /// @custom:ensures old(_pendingFeeSnapshots[requestId].feeConfigId) == 0 ==> _pendingFeeSnapshots[requestId].requestedAt == old(_pendingFeeSnapshots[requestId].requestedAt)
    function closeRedeemRequest(bytes32 requestId) external onlyEarnVault {
        StoredFeeSnapshot storage pending = _pendingFeeSnapshots[requestId];
        uint64 configId = pending.feeConfigId;
        if (configId == 0) return;
        delete _pendingFeeSnapshots[requestId];
        _feeConfigs[configId].excess.openRequests -= 1;
        _waiveClosedHistoricalRemainders(configId);
    }

    /// @notice Charges a cancelled request's snapshot on the value it returns, crediting at most the re-entry EarnShare.
    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && _valueScale() == old(_valueScale())
    /// @custom:ensures _currentFeeConfigId == old(_currentFeeConfigId)
    /// @custom:ensures totalClaimableEarnShares() == old(totalClaimableEarnShares()) + feeEarnShares
    /// @custom:ensures feeEarnShares <= totalReentryEarnShares && _pendingFeeSnapshots[requestId].feeConfigId == 0
    /// @custom:ensures !old(_specChargesPending(requestId)) ==> feeEarnShares == 0
    /// @custom:ensures old(_pendingFeeSnapshots[requestId].feeConfigId) != 0 ==> _specClosed(requestId, old(_pendingFeeSnapshots[requestId].feeConfigId), old(_feeConfigs[_pendingFeeSnapshots[requestId].feeConfigId].excess.openRequests))
    /// @custom:ensures feeEarnShares != 0 ==> (activeSupply == 0 || activeAssets != 0)
    /// @custom:ensures activeSupply != 0 ==> targetBase() == old(targetBase()) && targetStartedAt == old(targetStartedAt) && feeBaselinesPending == old(feeBaselinesPending)
    /// @custom:ensures activeSupply != 0 ==> highWaterMark() >= old(highWaterMark())
    /// @custom:ensures (activeSupply != 0 && highWaterMark() != old(highWaterMark())) ==> old(_specChargesPending(requestId)) && old(_specFeesActive())
    /// @custom:ensures (activeSupply != 0 && highWaterMark() != old(highWaterMark())) ==> _specCoversReentry(old(highWaterMark()), activeSupply, returnedValue, totalReentryEarnShares)
    /// @custom:ensures feeBaselinesPending != old(feeBaselinesPending) ==> feeBaselinesPending
    /// @dev A charged cancellation into a live pool raises the high-water mark to cover the returned value
    ///      ({_coverChargedReentry}), so the queued growth it charged is never charged again.
    /// Not proved: the verifier does not finish this function within its time limit.
    function settleCancelledRedeem(
        bytes32 requestId,
        uint256 burnedEarnShares,
        uint256 returnedValue,
        uint256 activeSupply,
        uint256 activeAssets,
        uint256 totalReentryEarnShares
    ) external onlyEarnVault returns (uint256 feeEarnShares) {
        StoredFeeSnapshot storage pending = _pendingFeeSnapshots[requestId];
        uint64 configId = pending.feeConfigId;
        bool pendingOpen = configId != 0;
        bool feesActive_ = _feesActive();
        bool valuationFresh = _feeValuationFresh();

        bool chargePending = pendingOpen && _lastDisabledAt < pending.requestedAt && !feesDisabled
            && _storedConfigHasFees(_feeConfigs[configId]) && valuationFresh;
        if (chargePending) {
            (FeePreview memory pendingFees, uint256[5] memory nextRemainders) =
                _previewPendingFees(pending, burnedEarnShares, returnedValue);
            _storeRemainders(configId, _feeConfigs[configId], nextRemainders);

            feeEarnShares =
                returnedValue == 0 ? 0 : Math.mulDiv(totalReentryEarnShares, pendingFees.totalFeeAssets, returnedValue);
            if (feeEarnShares > totalReentryEarnShares) feeEarnShares = totalReentryEarnShares;
            _creditAllocatedFeeEarnShares(configId, pendingFees, feeEarnShares);

            if (activeSupply != 0 && activeAssets == 0) {
                revert InvalidFeeConfiguration();
            }
            if (activeSupply != 0 && feesActive_) {
                _coverChargedReentry(activeSupply, returnedValue, totalReentryEarnShares);
            }
        }

        if (activeSupply == 0 && feesActive_) {
            if (!valuationFresh) {
                feeBaselinesPending = true;
            } else if (chargePending) {
                _restoreReopenedBaselines(pending, burnedEarnShares, totalReentryEarnShares);
            } else {
                _initializeReopenedBaselines(totalReentryEarnShares);
            }
        }

        if (!pendingOpen) return 0;
        delete _pendingFeeSnapshots[requestId];
        _feeConfigs[configId].excess.openRequests -= 1;
        _waiveClosedHistoricalRemainders(configId);
    }

    /// @notice A recipient claims its own recorded fee EarnShare to any receiver but zero, this contract or the vault.
    /// @custom:ensures to != address(0) && to != address(this) && to != old(earnVault) && earnShares != 0
    /// @custom:ensures !old(_entered) && !_entered
    function claim(address to, uint256 earnShares) external nonReentrant {
        if (to == address(0) || to == address(this) || to == earnVault) revert InvalidFeeClaimReceiver();
        if (earnShares == 0) revert ZeroAmount();
        uint256 stored = _claimableEarnShares[msg.sender];
        // A recipient never credited stores zero and claims nothing; a credited one stores its claim plus one.
        if (stored == 0 || earnShares > stored - 1) revert InsufficientClaimableEarnShares();

        _claimableEarnShares[msg.sender] = stored - earnShares;
        /// @custom:ghost sumClaimable = sumClaimable - earnShares
        _totalClaimableEarnShares -= earnShares;
        /// @custom:assert claimableEarnShares(msg.sender) == old(claimableEarnShares(msg.sender)) - earnShares
        /// @custom:assert forall address a :: a != msg.sender ==> claimableEarnShares(a) == old(claimableEarnShares(a))
        /// @custom:assert totalClaimableEarnShares() == old(totalClaimableEarnShares()) - earnShares
        /// @custom:assert earnVault == old(earnVault) && earnShare == old(earnShare) && _currentFeeConfigId == old(_currentFeeConfigId)
        _safeTransfer(earnShare, to, earnShares);
        emit FeeEarnSharesClaimed(msg.sender, to, earnShares);
    }

    /// @custom:ensures _currentFeeConfigId == old(_currentFeeConfigId) && feesDisabled == old(feesDisabled)
    /// @custom:ensures totalClaimableEarnShares() == old(totalClaimableEarnShares()) + result.totalFeeEarnShares
    /// @custom:ensures sumClaimable == old(sumClaimable) + result.totalFeeEarnShares
    /// @custom:ensures forall address a :: claimableEarnShares(a) == old(claimableEarnShares(a)) + _specCreditedTo(result, a)
    /// @custom:ensures result.totalFeeEarnShares == EarnFeeMath.allocatedFeeEarnShares(result)
    /// @custom:ensures result.totalFeeAssets <= result.positiveAccrualAssets
    /// @custom:ensures !old(_specFeesActive()) ==> EarnFeeMath.chargesNothing(result) && result.activeAssets == 0
    /// @custom:ensures !old(_specFeesActive()) ==> _specBaselines(old(highWaterMark()), old(targetBase()), old(targetStartedAt))
    /// @custom:ensures feeBaselinesPending ==> old(feeBaselinesPending)
    /// @custom:ensures (old(feeBaselinesPending) && !feeBaselinesPending) ==> EarnFeeMath.chargesNothing(result)
    /// @custom:ensures (feeBaselinesPending == old(feeBaselinesPending) && result.preFeeValuePerEarnShare < old(highWaterMark()) + VALUE_PRECISION) ==> result.positiveAccrualAssets == 0
    /// @custom:ensures (feeBaselinesPending == old(feeBaselinesPending) && result.positiveAccrualAssets == 0) ==> highWaterMark() == old(highWaterMark()) && result.totalFeeEarnShares == 0
    /// @custom:ensures (feeBaselinesPending == old(feeBaselinesPending) && _specTargetRatchets(result)) ==> _specTargetRestartedAt(_specSettled(result.postFeeValuePerEarnShare, highWaterMark()))
    /// @custom:ensures (feeBaselinesPending == old(feeBaselinesPending) && !_specTargetRatchets(result)) ==> targetBase() == old(targetBase()) && targetStartedAt == old(targetStartedAt)
    /// @custom:ensures _specChargingCheckpoint(result, old(feeBaselinesPending)) ==> highWaterMark() <= _specPostFeeValue(result, checkpointSupply)
    /// @custom:ensures _specChargingCheckpoint(result, old(feeBaselinesPending)) ==> _specCoversCharged(result, old(highWaterMark()), checkpointSupply)
    /// @custom:ensures _specChargingCheckpoint(result, old(feeBaselinesPending)) ==> _specLeavesUncharged(result, old(highWaterMark()), checkpointSupply)
    /// @custom:ensures _specChargingCheckpoint(result, old(feeBaselinesPending)) ==> _specAccrualWithinGrowth(result, old(highWaterMark()), checkpointSupply)
    /// @custom:ensures _specChargingCheckpoint(result, old(feeBaselinesPending)) ==> _specLemmaFeeEarnSharesHolds(result.totalFeeAssets, result.activeAssets, checkpointSupply)
    /// @custom:requires _feeConfigs[_currentFeeConfigId].excess.fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
    /// @dev A checkpoint charges only accrual of at least one asset unit, with value per EarnShare at least one
    ///      {VALUE_PRECISION} step above the high-water mark; before then it leaves the mark where it is, so the
    ///      accrual waits for a later checkpoint. A charging checkpoint moves the mark by the accrual it charged: the
    ///      mark then values the supply after the mint at no less than the old mark's value plus that accrual, and
    ///      at less than that plus two value units per EarnShare, and never above the post-fee value, for any
    ///      nonzero supply, dust included. The fee base never exceeds the assets above the old mark's value. Chained,
    ///      two charging checkpoints charge on at most the base of one checkpoint over both periods, and on less
    ///      than one asset unit and three value units per EarnShare below it (`_specLemmaCadence`).
    ///      The fee EarnShare minted are worth the fee assets within one EarnShare's value; a fee that would take
    ///      every active asset mints none, since no finite mint represents all of the backing.
    ///      Not proved: the fee assets of consecutive checkpoints are at most those of one checkpoint over both
    ///      periods plus one unit per configured fee. It needs each slot's carried remainder,
    ///      `feeAssets * BPS_DENOMINATOR + remainder == accrual * rateBps + previous remainder`, from
    ///      `EarnFeeMath.preview`, whose contract does not state it.
    ///      Not proved: with fees active, valuation fresh, nonzero supply and value per EarnShare above the
    ///      high-water mark, `totalFeeAssets` is at least the smaller of `positiveAccrualAssets` and the sum of
    ///      each fixed rate's floor of `positiveAccrualAssets`, plus the excess rate's floor of its base;
    ///      `EarnFeeMath.preview`'s contract bounds the fee only from above.
    /// Not proved: two of its target-ratchet postconditions; the solver gives no answer for them.
    function _accrueFees(uint256 earnShareSupply, uint256 activeAssets, bool valuationFresh)
        internal
        returns (FeePreview memory result, uint256 baselineFloor, uint256 scale)
    {
        if (feesDisabled) return (result, 0, 0);
        StoredFeeConfig storage storedConfig = _feeConfigs[_currentFeeConfigId];
        StoredExcessFee memory excess = storedConfig.excess;
        if (excess.fixedFeeCount == 0 && !excess.enabled) return (result, 0, 0);
        if (earnShareSupply == 0) return (result, 0, 0);
        if (!valuationFresh) return (result, 0, 0);
        if (feeBaselinesPending) {
            feeBaselinesPending = false;
            _initializeFeeBaselines(earnShareSupply, activeAssets);
            return (result, 0, 0);
        }

        /// @custom:ghost checkpointSupply = earnShareSupply
        result.activeAssets = activeAssets;
        scale = _valueScale();
        result.preFeeValuePerEarnShare = EarnFeeMath.valuePerEarnShare(activeAssets, scale, earnShareSupply);
        // Accrual waits above the high-water mark until it is chargeable ({_chargeableAccrual}). A checkpoint
        // before then charges nothing and leaves the mark where it is, so the accrual is charged later rather than
        // dropped, and it skips the config copy, remainder reads/writes, and allocation loop. It preserves the target
        // ratchet and the observable preview fields.
        (uint256 mark, uint256 base) = _baselines();
        if (_chargeableAccrual(result.preFeeValuePerEarnShare, mark, earnShareSupply, scale) == 0) {
            result.postFeeValuePerEarnShare = EarnFeeMath.valuePerEarnShareUp(activeAssets, scale, earnShareSupply);
            uint256 targetNow;
            if (excess.enabled) {
                result.targetValuePerEarnShare =
                    EarnFeeMath.targetAt(base, excess.annualTargetRateBps, targetStartedAt, block.timestamp);
                targetNow = result.targetValuePerEarnShare;
                // Only a value above the grown target restarts it; the rounded-up value exceeds a whole target
                // exactly when the value itself does.
                if (result.postFeeValuePerEarnShare > targetNow) {
                    uint256 settled = _settledValue(result.postFeeValuePerEarnShare, mark);
                    if (settled > targetNow) {
                        _setTargetBase(settled);
                        targetStartedAt = uint40(block.timestamp);
                        targetNow = settled;
                    }
                }
            }
            emit FeesAccrued(_currentFeeConfigId, result.activeAssets, 0, 0, 0, mark, result.targetValuePerEarnShare);
            return (result, _entryFloor(mark, targetNow, excess.enabled), scale);
        }

        // Declared by destructuring, so no unused remainder array is allocated before the call.
        (FeePreview memory previewed, uint256[5] memory nextRemainders) = EarnFeeMath.preview(
            EarnFeeMath.Input({
                activeAssets: activeAssets,
                earnShareSupply: earnShareSupply,
                earnShareScale: scale,
                highWaterMark: mark,
                targetBase: base,
                targetStartedAt: targetStartedAt,
                timestamp: block.timestamp
            }),
            _loadFeeConfig(storedConfig),
            _remainders(_currentFeeConfigId, storedConfig)
        );
        result = previewed;
        /// @custom:use _specLemmaAccrualWithinGrowth(activeAssets, earnShareSupply, _valueScale(), highWaterMark())
        /// @custom:use _specLemmaFeeEarnShares(result.totalFeeAssets, activeAssets, earnShareSupply)
        /// @custom:use _specLemmaCeilCovers(activeAssets * _valueScale(), earnShareSupply + result.totalFeeEarnShares)
        _storeRemainders(_currentFeeConfigId, storedConfig, nextRemainders);

        if (result.totalFeeEarnShares != 0) {
            _creditCalculatedAllocations(_currentFeeConfigId, result);
        }
        mark = _chargedMark(
            mark,
            earnShareSupply,
            result.positiveAccrualAssets,
            result.totalFeeEarnShares,
            scale,
            result.postFeeValuePerEarnShare
        );
        // The new mark is the value the pool has settled fees to, so a target below it restarts there.
        if (excess.enabled && mark > result.targetValuePerEarnShare) {
            base = mark;
            targetStartedAt = uint40(block.timestamp);
        }
        // Both baselines share a slot, so the moved mark and any restarted target are written together.
        _setBaselines(mark, base);

        emit FeesAccrued(
            _currentFeeConfigId,
            result.activeAssets,
            result.positiveAccrualAssets,
            result.totalFeeAssets,
            result.totalFeeEarnShares,
            mark,
            result.targetValuePerEarnShare
        );
        // The target, when enabled, is now at least the new mark.
        return (result, _entryFloor(mark, mark, false), scale);
    }

    /// @notice The accrual a checkpoint charges at `value` per EarnShare above `mark`: none while value is less than
    ///         one {VALUE_PRECISION} step (one asset unit per whole EarnShare) above the mark or the accrual is less
    ///         than one asset unit, otherwise the positive accrual `EarnFeeMath.preview` computes (fees.md, "High-water
    ///         mark and target").
    /// @custom:ensures (value > mark && value - mark >= VALUE_PRECISION) ==> result == (value - mark) * supply / scale
    /// @custom:ensures !(value > mark && value - mark >= VALUE_PRECISION) ==> result == 0
    function _chargeableAccrual(uint256 value, uint256 mark, uint256 supply, uint256 scale)
        internal
        pure
        returns (uint256)
    {
        if (value <= mark || value - mark < VALUE_PRECISION) return 0;
        return Math.mulDiv(value - mark, supply, scale);
    }

    /// @notice A charging checkpoint moves the high-water mark by the accrual it charged: the old mark's value of
    ///         `supply` plus `accrual`, over the supply after the fee mint, rounded up and at most the post-fee value.
    ///         Accrual the checkpoint left uncharged (less than one asset unit) stays above it.
    /// @custom:requires supply != 0 && scale != 0
    /// @custom:ensures result <= postFeeValue
    /// @custom:ensures result * (supply + feeEarnShares) >= mark * supply + accrual * scale || result == postFeeValue
    /// @custom:ensures result * (supply + feeEarnShares) < mark * supply + accrual * scale + 2 * (supply + feeEarnShares)
    function _chargedMark(
        uint256 mark,
        uint256 supply,
        uint256 accrual,
        uint256 feeEarnShares,
        uint256 scale,
        uint256 postFeeValue
    ) internal pure returns (uint256 result) {
        uint256 supplyAfter = supply + feeEarnShares;
        result = Math.mulDiv(mark, supply, supplyAfter, Math.Rounding.Ceil)
            + Math.mulDiv(accrual, scale, supplyAfter, Math.Rounding.Ceil);
        if (result > postFeeValue) result = postFeeValue;
    }

    /// @notice After a charged cancellation into a live pool, raises the high-water mark so it values the pooled
    ///         supply at no less than the active pool's mark plus the returned value, which the cancellation charged
    ///         above its snapshot. Queued growth it charged is never charged again, and accrual still waiting in the
    ///         active pool stays above the mark (fees.md, "Queued withdrawals").
    /// @custom:requires activeSupply != 0 && _valueScale() != 0
    /// @custom:ensures highWaterMark() >= old(highWaterMark()) && targetBase() == old(targetBase())
    /// @custom:ensures _specCoversReentry(old(highWaterMark()), activeSupply, returnedValue, reentry)
    function _coverChargedReentry(uint256 activeSupply, uint256 returnedValue, uint256 reentry) internal {
        uint256 mark = highWaterMark();
        // The returned value enters like charged accrual on top of the active pool's mark, over the pooled supply.
        uint256 covered = _chargedMark(mark, activeSupply, returnedValue, reentry, _valueScale(), type(uint256).max);
        if (covered > mark) _setHighWaterMark(covered);
    }

    /// @notice The value per EarnShare the pool has settled fees to, which an excess target may restart at: `value`
    ///         rounded up to a whole {VALUE_PRECISION} step, at most the high-water mark, so a target never passes
    ///         accrual that is still waiting.
    /// @custom:ensures result == _specSettled(value, mark)
    function _settledValue(uint256 value, uint256 mark) internal pure returns (uint256) {
        if (value >= mark) return mark;
        uint256 stepped = value - value % VALUE_PRECISION;
        if (stepped == value) return value;
        return mark - stepped <= VALUE_PRECISION ? mark : stepped + VALUE_PRECISION;
    }

    /// @notice The highest value per EarnShare, rounded up, at which a principal entry leaves
    ///         `_updateBaselinesAfterPrincipalEntry` nothing to raise, given the mark and the target grown to now.
    /// @dev The mark rises only to a value at least one step above it. A target below the mark restarts only for a
    ///      value above it, so it is the floor itself.
    /// @custom:ensures (excessEnabled && targetNow < mark) ==> result == targetNow
    /// @custom:ensures !(excessEnabled && targetNow < mark) ==> result == EarnFeeMath.min(mark + (VALUE_PRECISION - 1), type(uint256).max)
    function _entryFloor(uint256 mark, uint256 targetNow, bool excessEnabled) internal pure returns (uint256) {
        if (excessEnabled && targetNow < mark) return targetNow;
        return mark > type(uint256).max - (VALUE_PRECISION - 1) ? type(uint256).max : mark + (VALUE_PRECISION - 1);
    }

    /// @custom:ensures result.allocationCount <= MAX_FIXED_FEE_RECIPIENTS + 1
    /// @custom:ensures result.totalFeeAssets <= EarnFeeMath.allocatedFeeAssets(result)
    /// @custom:ensures result.totalFeeAssets <= result.positiveAccrualAssets && result.activeAssets == returnedValue
    /// @custom:ensures result.positiveAccrualAssets <= returnedValue
    /// @custom:requires _feeConfigs[pending.feeConfigId].excess.fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
    function _previewPendingFees(StoredFeeSnapshot storage pending, uint256 burnedEarnShares, uint256 returnedValue)
        internal
        view
        returns (FeePreview memory result, uint256[5] memory nextRemainders)
    {
        uint64 configId = pending.feeConfigId;
        StoredFeeConfig storage storedConfig = _feeConfigs[configId];
        uint256 scale = _valueScale();
        uint256 pendingHighWater = burnedEarnShares == 0
            ? 0
            : Math.mulDiv(pending.highWaterValue, scale, burnedEarnShares, Math.Rounding.Ceil);
        uint256 pendingTarget =
            burnedEarnShares == 0 ? 0 : Math.mulDiv(pending.targetValue, scale, burnedEarnShares, Math.Rounding.Ceil);
        /// @custom:use _specLemmaAccrualWithinGrowth(returnedValue, burnedEarnShares, _valueScale(), pendingHighWater)
        return EarnFeeMath.preview(
            EarnFeeMath.Input({
                activeAssets: returnedValue,
                earnShareSupply: burnedEarnShares,
                earnShareScale: scale,
                highWaterMark: pendingHighWater,
                targetBase: pendingTarget,
                targetStartedAt: pending.requestedAt,
                timestamp: block.timestamp
            }),
            _loadFeeConfig(storedConfig),
            _remainders(configId, storedConfig)
        );
    }

    /// @custom:requires fees.allocationCount <= MAX_FIXED_FEE_RECIPIENTS + 1
    /// @custom:requires fees.totalFeeEarnShares == EarnFeeMath.allocatedFeeEarnShares(fees)
    /// @custom:ensures totalClaimableEarnShares() == old(totalClaimableEarnShares()) + EarnFeeMath.allocatedFeeEarnShares(fees)
    /// @custom:ensures sumClaimable == old(sumClaimable) + EarnFeeMath.allocatedFeeEarnShares(fees)
    /// @custom:ensures forall address a :: claimableEarnShares(a) == old(claimableEarnShares(a)) + _specCreditedTo(fees, a)
    function _creditCalculatedAllocations(uint64 configId, FeePreview memory fees) internal {
        /// @custom:invariant i <= fees.allocationCount
        /// @custom:invariant totalClaimableEarnShares() == old(totalClaimableEarnShares()) && sumClaimable == old(sumClaimable)
        /// @custom:invariant forall address a :: claimableEarnShares(a) == old(claimableEarnShares(a)) + _specCreditedToFirst(fees, a, i)
        for (uint256 i = 0; i < fees.allocationCount; i++) {
            uint256 earnShares = fees.allocations[i].feeEarnShares;
            if (earnShares != 0) {
                _creditFeeEarnShares(configId, fees.allocations[i].account, fees.allocations[i].feeAssets, earnShares);
            }
        }
        // The allocations sum to the total, so the total is written once.
        _creditTotalClaimable(fees.totalFeeEarnShares);
    }

    /// @custom:requires fees.allocationCount <= MAX_FIXED_FEE_RECIPIENTS + 1
    /// @custom:requires fees.totalFeeAssets <= EarnFeeMath.allocatedFeeAssets(fees)
    /// @custom:ensures totalClaimableEarnShares() == old(totalClaimableEarnShares()) + _specCharged(fees, feeEarnShares)
    /// @custom:ensures sumClaimable == old(sumClaimable) + _specCharged(fees, feeEarnShares)
    /// @custom:ensures forall address a :: claimableEarnShares(a) >= old(claimableEarnShares(a))
    /// @custom:ensures forall address a :: !_specIsRecipient(fees, a) ==> claimableEarnShares(a) == old(claimableEarnShares(a))
    function _creditAllocatedFeeEarnShares(uint64 configId, FeePreview memory fees, uint256 feeEarnShares) internal {
        if (feeEarnShares == 0 || fees.totalFeeAssets == 0) return;
        uint256 assigned;
        uint256 last = type(uint256).max;
        /// @custom:invariant i <= fees.allocationCount
        /// @custom:invariant last == type(uint256).max || (last < i && fees.allocations[last].feeAssets != 0)
        /// @custom:invariant forall uint256 k :: (k < i && (last == type(uint256).max || k > last)) ==> fees.allocations[k].feeAssets == 0
        for (uint256 i = 0; i < fees.allocationCount; i++) {
            if (fees.allocations[i].feeAssets != 0) last = i;
        }
        /// @custom:assert last != type(uint256).max
        /// @custom:invariant i <= fees.allocationCount && last < fees.allocationCount && fees.allocations[last].feeAssets != 0
        /// @custom:invariant forall uint256 k :: (k < fees.allocationCount && k > last) ==> fees.allocations[k].feeAssets == 0
        /// @custom:invariant totalClaimableEarnShares() == old(totalClaimableEarnShares()) && sumClaimable == old(sumClaimable)
        /// @custom:invariant forall address a :: claimableEarnShares(a) >= old(claimableEarnShares(a))
        /// @custom:invariant forall address a :: !_specIsRecipient(fees, a) ==> claimableEarnShares(a) == old(claimableEarnShares(a))
        for (uint256 i = 0; i < fees.allocationCount; i++) {
            uint256 earnShares;
            if (i == last) {
                earnShares = feeEarnShares - assigned;
            } else if (fees.allocations[i].feeAssets != 0) {
                earnShares = Math.mulDiv(feeEarnShares, fees.allocations[i].feeAssets, fees.totalFeeAssets);
                assigned += earnShares;
            }
            if (earnShares != 0) {
                _creditFeeEarnShares(configId, fees.allocations[i].account, fees.allocations[i].feeAssets, earnShares);
            }
        }
        // The last nonzero allocation takes what the others left, so the credits sum to `feeEarnShares`.
        _creditTotalClaimable(feeEarnShares);
    }

    /// @dev Credits one recipient; the caller adds the credits of a whole allocation to the total once.
    /// @custom:ensures claimableEarnShares(account) == old(claimableEarnShares(account)) + earnShares
    /// @custom:ensures forall address a :: a != account ==> claimableEarnShares(a) == old(claimableEarnShares(a))
    /// @custom:ensures totalClaimableEarnShares() == old(totalClaimableEarnShares()) && sumClaimable == old(sumClaimable)
    function _creditFeeEarnShares(uint64 configId, address account, uint256 feeAssets, uint256 earnShares) internal {
        uint256 stored = _claimableEarnShares[account];
        _claimableEarnShares[account] = (stored == 0 ? 1 : stored) + earnShares;
        emit FeeEarnSharesAllocated(configId, account, feeAssets, earnShares);
    }

    /// @custom:ensures totalClaimableEarnShares() == old(totalClaimableEarnShares()) + earnShares
    /// @custom:ensures sumClaimable == old(sumClaimable) + earnShares
    /// @custom:ensures forall address a :: claimableEarnShares(a) == old(claimableEarnShares(a))
    function _creditTotalClaimable(uint256 earnShares) internal {
        if (earnShares == 0) return;
        /// @custom:ghost sumClaimable = sumClaimable + earnShares
        uint256 storedTotal = _totalClaimableEarnShares;
        _totalClaimableEarnShares = (storedTotal == 0 ? 1 : storedTotal) + earnShares;
    }

    /// @notice A charged reopening restores the snapshot's high-water mark and grown target when they are higher.
    /// @custom:ensures normalization == 0 ==> _specBaselines(old(highWaterMark()), old(targetBase()), old(targetStartedAt))
    /// @custom:ensures normalization != 0 ==> highWaterMark() >= _specSnapshotHighWater(pending, burnedEarnShares)
    /// @custom:ensures !_feeConfigs[_currentFeeConfigId].excess.enabled ==> targetBase() == old(targetBase()) && targetStartedAt == old(targetStartedAt)
    /// @custom:ensures (normalization != 0 && _feeConfigs[_currentFeeConfigId].excess.enabled) ==> targetStartedAt == uint40(block.timestamp)
    /// @custom:ensures (normalization != 0 && _feeConfigs[_currentFeeConfigId].excess.enabled) ==> targetBase() >= _specSnapshotTargetNow(pending, burnedEarnShares)
    function _restoreReopenedBaselines(
        StoredFeeSnapshot storage pending,
        uint256 burnedEarnShares,
        uint256 normalization
    ) internal {
        if (normalization == 0) return;
        uint256 scale = _valueScale();
        uint256 currentValue = EarnFeeMath.valuePerEarnShareUp(_activeAssets(), scale, normalization);
        uint256 pendingHighWater = Math.mulDiv(pending.highWaterValue, scale, burnedEarnShares, Math.Rounding.Ceil);
        _setHighWaterMark(currentValue > pendingHighWater ? currentValue : pendingHighWater);

        if (_feeConfigs[_currentFeeConfigId].excess.enabled) {
            uint256 pendingTarget = Math.mulDiv(pending.targetValue, scale, burnedEarnShares, Math.Rounding.Ceil);
            uint256 grownTarget = EarnFeeMath.targetAt(
                pendingTarget,
                _feeConfigs[pending.feeConfigId].excess.annualTargetRateBps,
                pending.requestedAt,
                block.timestamp
            );
            _setTargetBase(currentValue > grownTarget ? currentValue : grownTarget);
            targetStartedAt = uint40(block.timestamp);
        }
    }

    /// @custom:ensures normalization == 0 ==> _specBaselines(old(highWaterMark()), old(targetBase()), old(targetStartedAt))
    /// @custom:ensures (normalization != 0 && _feeConfigs[_currentFeeConfigId].excess.enabled) ==> _specTargetRestarted()
    /// @custom:ensures (normalization != 0 && !_feeConfigs[_currentFeeConfigId].excess.enabled) ==> targetBase() == 0 && targetStartedAt == 0
    function _initializeReopenedBaselines(uint256 normalization) internal {
        if (normalization == 0) return;
        uint256 currentValue = EarnFeeMath.valuePerEarnShareUp(_activeAssets(), _valueScale(), normalization);
        uint256 base;
        if (_feeConfigs[_currentFeeConfigId].excess.enabled) {
            base = currentValue;
            targetStartedAt = uint40(block.timestamp);
        } else {
            targetStartedAt = 0;
        }
        _setBaselines(currentValue, base);
        emit FeeBaselinesInitialized(currentValue, base, targetStartedAt);
    }

    /// @custom:ensures _feeConfigs[_currentFeeConfigId].excess.enabled ==> targetBase() == highWaterMark()
    /// @custom:ensures !_feeConfigs[_currentFeeConfigId].excess.enabled ==> targetBase() == 0 && targetStartedAt == 0
    /// @custom:ensures earnShareSupply != 0 ==> highWaterMark() == EarnFeeMath.ceilDiv(activeAssets * _valueScale(), earnShareSupply)
    /// @custom:ensures targetStartedAt == 0 || targetStartedAt == uint40(block.timestamp)
    /// @custom:ensures highWaterMark() == 0 || targetBase() == 0 || targetStartedAt == uint40(block.timestamp)
    function _initializeFeeBaselines(uint256 earnShareSupply, uint256 activeAssets) internal {
        if (earnShareSupply == 0) {
            _setBaselines(0, 0);
            targetStartedAt = 0;
            return;
        }
        uint256 valuePerShare = EarnFeeMath.valuePerEarnShareUp(activeAssets, _valueScale(), earnShareSupply);
        uint256 base;
        if (_feeConfigs[_currentFeeConfigId].excess.enabled) {
            base = valuePerShare;
            targetStartedAt = uint40(block.timestamp);
        } else {
            targetStartedAt = 0;
        }
        _setBaselines(valuePerShare, base);
        emit FeeBaselinesInitialized(valuePerShare, base, targetStartedAt);
    }

    /// @notice Principal entry ratchets the baselines up only: it never charges or lowers them (fees.md).
    /// @custom:ensures highWaterMark() >= old(highWaterMark())
    /// @custom:ensures targetBase() != old(targetBase()) ==> targetBase() > old(_specTargetNow()) && targetStartedAt == uint40(block.timestamp)
    /// @custom:ensures targetBase() != old(targetBase()) ==> EarnFeeMath.ceilDiv(activeAssets * _valueScale(), earnShareSupply) > old(_specTargetNow())
    /// @custom:ensures targetBase() == old(targetBase()) ==> targetStartedAt == old(targetStartedAt)
    /// @custom:ensures !_feeConfigs[_currentFeeConfigId].excess.enabled ==> targetBase() == old(targetBase())
    function _updateBaselinesAfterPrincipalEntry(uint256 earnShareSupply, uint256 activeAssets) internal {
        if (earnShareSupply == 0) return;

        uint256 valuePerShare = EarnFeeMath.valuePerEarnShareUp(activeAssets, _valueScale(), earnShareSupply);
        (uint256 mark, uint256 base) = _baselines();
        // A rise of less than one step may be accrual still waiting above the mark ({_chargeableAccrual}), so only a
        // larger one is principal.
        if (valuePerShare > mark && valuePerShare - mark >= VALUE_PRECISION) mark = valuePerShare;

        StoredExcessFee memory excess = _feeConfigs[_currentFeeConfigId].excess;
        if (excess.enabled) {
            uint256 currentTarget =
                EarnFeeMath.targetAt(base, excess.annualTargetRateBps, targetStartedAt, block.timestamp);
            // Only a value above the grown target restarts it, as at a checkpoint.
            if (valuePerShare > currentTarget) {
                uint256 settled = _settledValue(valuePerShare, mark);
                if (settled > currentTarget) {
                    base = settled;
                    targetStartedAt = uint40(block.timestamp);
                }
            }
        }
        _setBaselines(mark, base);
        emit FeeBaselinesInitialized(mark, base, targetStartedAt);
    }

    /// @dev Both baselines, from their shared slot.
    /// @custom:ensures mark == highWaterMark() && base == targetBase()
    function _baselines() internal view returns (uint256 mark, uint256 base) {
        mark = _highWaterMark;
        base = _targetBase;
        if (mark == WIDE_BASELINE) mark = _wideHighWaterMark;
        if (base == WIDE_BASELINE) base = _wideTargetBase;
    }

    /// @dev Writes both baselines in their shared slot, sending a value too wide for its half to its wide slot.
    /// @custom:ensures highWaterMark() == mark && targetBase() == base
    function _setBaselines(uint256 mark, uint256 base) internal {
        uint128 markHalf = _baselineHalf(mark);
        uint128 baseHalf = _baselineHalf(base);
        if (markHalf == WIDE_BASELINE) _wideHighWaterMark = mark;
        if (baseHalf == WIDE_BASELINE) _wideTargetBase = base;
        _highWaterMark = markHalf;
        _targetBase = baseHalf;
    }

    /// @custom:ensures highWaterMark() == mark && targetBase() == old(targetBase())
    function _setHighWaterMark(uint256 mark) internal {
        uint128 markHalf = _baselineHalf(mark);
        if (markHalf == WIDE_BASELINE) _wideHighWaterMark = mark;
        _highWaterMark = markHalf;
    }

    /// @custom:ensures targetBase() == base && highWaterMark() == old(highWaterMark())
    function _setTargetBase(uint256 base) internal {
        uint128 baseHalf = _baselineHalf(base);
        if (baseHalf == WIDE_BASELINE) _wideTargetBase = base;
        _targetBase = baseHalf;
    }

    /// @dev A baseline's half of the shared slot: the value itself, or {WIDE_BASELINE} when it needs its wide slot.
    /// @custom:ensures value < WIDE_BASELINE ? result == value : result == WIDE_BASELINE
    function _baselineHalf(uint256 value) internal pure returns (uint128 result) {
        if (value >= WIDE_BASELINE) return uint128(WIDE_BASELINE);
        // Below 2 ** 128 - 1 here, so the narrowing conversion cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    /// @custom:ensures result == _specFeesActive()
    function _feesActive() internal view returns (bool) {
        if (feesDisabled) return false;
        return _storedConfigHasFees(_feeConfigs[_currentFeeConfigId]);
    }

    /// @custom:ensures result == (config.excess.fixedFeeCount != 0 || config.excess.enabled)
    function _storedConfigHasFees(StoredFeeConfig storage config) internal view returns (bool) {
        StoredExcessFee memory excess = config.excess;
        return excess.fixedFeeCount != 0 || excess.enabled;
    }

    /// @notice Widens a stored configuration, reading only its configured fixed-fee recipients.
    /// @custom:ensures result.fixedFeeCount == config.excess.fixedFeeCount && result.excess.enabled == config.excess.enabled
    function _loadFeeConfig(StoredFeeConfig storage config) internal view returns (FeeConfig memory result) {
        StoredExcessFee memory excess = config.excess;
        result.fixedFeeCount = excess.fixedFeeCount;
        /// @custom:invariant i <= excess.fixedFeeCount
        for (uint256 i = 0; i < excess.fixedFeeCount; i++) {
            result.fixedFees[i] = config.fixedFees[i];
        }
        result.excess = ExcessReturnFee({
            account: excess.account,
            annualTargetRateBps: excess.annualTargetRateBps,
            enabled: excess.enabled,
            excessFeeRateBps: excess.excessFeeRateBps
        });
    }

    /// @custom:ensures result == (config.fixedFeeCount != 0 || config.excess.enabled)
    function _configHasFees(FeeConfig memory config) internal pure returns (bool) {
        return config.fixedFeeCount != 0 || config.excess.enabled;
    }

    /// @notice The structural rules of fees.md, "Configuration and authority".
    /// @custom:ensures _specValidConfig(config)
    /// @custom:succeeds-if _specValidConfig(config)
    function _validateFeeConfig(FeeConfig memory config) internal view {
        if (config.fixedFeeCount > MAX_FIXED_FEE_RECIPIENTS) revert InvalidFeeConfiguration();
        uint256 totalFixed;
        /// @custom:invariant i <= config.fixedFeeCount && config.fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
        /// @custom:invariant totalFixed == _specFirstRates(config, i)
        /// @custom:invariant forall uint256 k :: k < i ==> _specValidFixedFee(config, k)
        /// @custom:invariant forall uint256 k, uint256 m :: (m < k && k < i) ==> config.fixedFees[m].account != config.fixedFees[k].account
        for (uint256 i = 0; i < config.fixedFeeCount; i++) {
            address account = config.fixedFees[i].account;
            uint256 rateBps = config.fixedFees[i].rateBps;
            if (_invalidRecipient(account) || rateBps == 0) revert InvalidFeeConfiguration();
            /// @custom:invariant j <= i
            /// @custom:invariant forall uint256 m :: m < j ==> config.fixedFees[m].account != account
            for (uint256 j = 0; j < i; j++) {
                if (config.fixedFees[j].account == account) revert InvalidFeeConfiguration();
            }
            totalFixed += rateBps;
        }
        /// @custom:invariant config.fixedFeeCount <= i && i <= MAX_FIXED_FEE_RECIPIENTS
        /// @custom:invariant forall uint256 k :: k < config.fixedFeeCount ==> _specValidFixedFee(config, k)
        /// @custom:invariant forall uint256 k :: k < i ==> _specValidFixedFee(config, k)
        /// @custom:invariant forall uint256 k, uint256 m :: (m < k && k < config.fixedFeeCount) ==> config.fixedFees[m].account != config.fixedFees[k].account
        /// @custom:invariant totalFixed == _specFirstRates(config, config.fixedFeeCount)
        for (uint256 i = config.fixedFeeCount; i < MAX_FIXED_FEE_RECIPIENTS; i++) {
            if (config.fixedFees[i].account != address(0) || config.fixedFees[i].rateBps != 0) {
                revert InvalidFeeConfiguration();
            }
        }
        if (totalFixed > BPS_DENOMINATOR) revert InvalidFeeConfiguration();

        if (config.excess.enabled) {
            if (
                _invalidRecipient(config.excess.account) || config.excess.excessFeeRateBps == 0
                    || config.excess.excessFeeRateBps > BPS_DENOMINATOR
                    || config.excess.annualTargetRateBps > BPS_DENOMINATOR
            ) revert InvalidFeeConfiguration();
        } else if (
            config.excess.account != address(0) || config.excess.annualTargetRateBps != 0
                || config.excess.excessFeeRateBps != 0
        ) {
            revert InvalidFeeConfiguration();
        }
    }

    /// @custom:ensures result == (account == address(0) || account == address(this) || account == earnVault)
    /// @custom:succeeds-if true
    function _invalidRecipient(address account) internal view returns (bool) {
        return account == address(0) || account == address(this) || account == earnVault;
    }

    /// @custom:requires _specValidConfig(config)
    /// @custom:requires forall uint256 k :: k < MAX_FIXED_FEE_RECIPIENTS ==> _feeConfigs[configId].fixedFees[k].account == address(0) && _feeConfigs[configId].fixedFees[k].rateBps == 0
    /// @custom:ensures _specStored(configId, config)
    /// @custom:ensures forall uint64 c :: c != configId ==> _feeConfigs[c].excess.fixedFeeCount == old(_feeConfigs[c].excess.fixedFeeCount) && _feeConfigs[c].excess.enabled == old(_feeConfigs[c].excess.enabled) && _feeConfigs[c].excess.account == old(_feeConfigs[c].excess.account)
    /// @custom:ensures forall uint64 c :: c != configId ==> _feeConfigs[c].excess.annualTargetRateBps == old(_feeConfigs[c].excess.annualTargetRateBps) && _feeConfigs[c].excess.excessFeeRateBps == old(_feeConfigs[c].excess.excessFeeRateBps)
    /// @custom:ensures forall uint64 c, uint256 k :: c != configId ==> _feeConfigs[c].fixedFees[k].account == old(_feeConfigs[c].fixedFees[k].account) && _feeConfigs[c].fixedFees[k].rateBps == old(_feeConfigs[c].fixedFees[k].rateBps)
    function _storeFeeConfig(uint64 configId, FeeConfig memory config) internal {
        StoredFeeConfig storage stored = _feeConfigs[configId];
        // Configuration ids are never reused and validation zeroes unused recipients, so their slots stay zero.
        /// @custom:invariant i <= config.fixedFeeCount && config.fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
        /// @custom:invariant forall uint256 k :: k < i ==> _specStoredFixedFee(configId, config, k)
        /// @custom:invariant forall uint64 c, uint256 k :: c != configId ==> _feeConfigs[c].fixedFees[k].account == old(_feeConfigs[c].fixedFees[k].account) && _feeConfigs[c].fixedFees[k].rateBps == old(_feeConfigs[c].fixedFees[k].rateBps)
        for (uint256 i = 0; i < config.fixedFeeCount; i++) {
            stored.fixedFees[i] = config.fixedFees[i];
        }
        stored.excess = StoredExcessFee({
            account: config.excess.account,
            annualTargetRateBps: config.excess.annualTargetRateBps,
            enabled: config.excess.enabled,
            excessFeeRateBps: config.excess.excessFeeRateBps,
            fixedFeeCount: config.fixedFeeCount,
            openRequests: stored.excess.openRequests
        });
    }

    /// @custom:requires config.excess.fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
    /// @custom:ensures forall uint8 k :: k < MAX_FIXED_FEE_RECIPIENTS ==> remainders[k] == (k < config.excess.fixedFeeCount ? _specRemainder(configId, k) : 0)
    /// @custom:ensures remainders[MAX_FIXED_FEE_RECIPIENTS] == (config.excess.enabled ? _specRemainder(configId, 4) : 0)
    function _remainders(uint64 configId, StoredFeeConfig storage config)
        internal
        view
        returns (uint256[5] memory remainders)
    {
        StoredExcessFee memory excess = config.excess;
        uint256 packed = _feeRemainders[configId];
        /// @custom:invariant i <= excess.fixedFeeCount
        /// @custom:invariant forall uint8 k :: k < MAX_FIXED_FEE_RECIPIENTS ==> remainders[k] == (k < i ? _specRemainder(configId, k) : 0)
        /// @custom:invariant remainders[MAX_FIXED_FEE_RECIPIENTS] == 0
        for (uint256 i = 0; i < excess.fixedFeeCount; i++) {
            remainders[i] = _remainderAt(packed, i);
        }
        if (excess.enabled) remainders[4] = _remainderAt(packed, 4);
    }

    /// @notice Stores the configured remainders; one too wide for its packed field reverts rather than truncating.
    /// @custom:requires config.excess.fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
    /// @custom:ensures forall uint8 k :: k < config.excess.fixedFeeCount ==> _specRemainder(configId, k) == remainders[k]
    /// @custom:ensures config.excess.enabled ==> _specRemainder(configId, 4) == remainders[4]
    /// @custom:ensures !config.excess.enabled ==> _specRemainder(configId, 4) == old(_specRemainder(configId, 4))
    /// @custom:ensures forall uint64 c, uint8 k :: (c != configId || (k >= config.excess.fixedFeeCount && k != 4)) ==> _specRemainder(c, k) == old(_specRemainder(c, k))
    function _storeRemainders(uint64 configId, StoredFeeConfig storage config, uint256[5] memory remainders) internal {
        StoredExcessFee memory excess = config.excess;
        uint256 stored = _feeRemainders[configId];
        uint256 packed = stored;
        /// @custom:invariant i <= excess.fixedFeeCount
        for (uint256 i = 0; i < excess.fixedFeeCount; i++) {
            packed = _withPackedRemainder(packed, i, remainders[i]);
        }
        if (excess.enabled) packed = _withPackedRemainder(packed, 4, remainders[4]);
        // Mark the slot only once a remainder is carried, so all-zero remainders never write it.
        if (packed != 0) packed |= REMAINDERS_MARKER;
        if (packed != stored) _feeRemainders[configId] = packed;
    }

    /// @custom:ensures result == ((packed >> (slot * REMAINDER_BITS)) & REMAINDER_MASK)
    function _remainderAt(uint256 packed, uint256 slot) internal pure returns (uint256) {
        return (packed >> (slot * REMAINDER_BITS)) & REMAINDER_MASK;
    }

    /// @custom:requires slot <= MAX_FIXED_FEE_RECIPIENTS
    /// @custom:ensures _remainderAt(result, slot) == remainder
    /// @custom:succeeds-if remainder <= REMAINDER_MASK
    function _withPackedRemainder(uint256 packed, uint256 slot, uint256 remainder) internal pure returns (uint256) {
        if (remainder > REMAINDER_MASK) revert InvalidFeeConfiguration();
        uint256 shift = slot * REMAINDER_BITS;
        return (packed & ~(REMAINDER_MASK << shift)) | (remainder << shift);
    }

    /// @custom:ensures (feesDisabled || _feeConfigs[_currentFeeConfigId].excess.openRequests == 0) ==> _specRemaindersWaived(_currentFeeConfigId)
    /// @custom:ensures !(feesDisabled || _feeConfigs[_currentFeeConfigId].excess.openRequests == 0) ==> forall uint64 c, uint8 k :: _specRemainder(c, k) == old(_specRemainder(c, k))
    function _waiveCurrentRemainders() internal {
        if (!feesDisabled && _feeConfigs[_currentFeeConfigId].excess.openRequests != 0) return;
        _waiveRemainders(_currentFeeConfigId);
    }

    /// @notice A historical configuration's remainders are waived when its last open request closes.
    /// @custom:ensures _specHistoricalAndClosed(configId) ==> _specRemaindersWaived(configId)
    /// @custom:ensures !_specHistoricalAndClosed(configId) ==> forall uint64 c, uint8 k :: _specRemainder(c, k) == old(_specRemainder(c, k))
    function _waiveClosedHistoricalRemainders(uint64 configId) internal {
        if (configId == 0 || configId == _currentFeeConfigId || _feeConfigs[configId].excess.openRequests != 0) return;
        _waiveRemainders(configId);
    }

    /// @custom:ensures _specRemaindersWaived(configId)
    /// @custom:ensures forall uint64 c, uint8 k :: (c != configId || k > MAX_FIXED_FEE_RECIPIENTS) ==> _specRemainder(c, k) == old(_specRemainder(c, k))
    /// @custom:succeeds-if true
    function _waiveRemainders(uint64 configId) internal {
        uint256 packed = _feeRemainders[configId];
        // A marker-only word still holds the slot, so only an empty word skips the delete.
        if (packed == 0) return;
        /// @custom:invariant i <= MAX_FIXED_FEE_RECIPIENTS + 1
        for (uint256 i = 0; i <= MAX_FIXED_FEE_RECIPIENTS; i++) {
            uint256 remainder = _remainderAt(packed, i);
            // forge-lint: disable-next-line(unsafe-typecast) i is at most MAX_FIXED_FEE_RECIPIENTS.
            if (remainder != 0) emit FeeDustWaived(configId, uint8(i), remainder);
        }
        // Every caller waives a configuration that can no longer accrue, so its slot is cleared rather than kept warm.
        delete _feeRemainders[configId];
    }

    /// @dev The scale of a value per EarnShare: one EarnShare in its smallest units, times {VALUE_PRECISION}.
    function _valueScale() internal view returns (uint256) {
        return 10 ** uint256(_earnShareDecimals) * VALUE_PRECISION;
    }

    function _activeAssets() internal view returns (uint256) {
        return IEarnVaultFeeContext(earnVault).totalAssets();
    }

    function _feeValuationFresh() internal view returns (bool) {
        return IEarnVaultFeeContext(earnVault).isFeeValuationFresh();
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool ok, bytes memory result) = token.call(abi.encodeCall(IERC20Like.transfer, (to, value)));
        if (!ok || (result.length != 0 && !abi.decode(result, (bool)))) revert InvalidFeeClaimReceiver();
    }

    // ---------------------------------------------------------------- spec helpers, never executed

    /// @custom:spec Whether fees are enabled and the current configuration charges any fee.
    function _specFeesActive() internal view returns (bool) {
        return !feesDisabled && _specCharges(_currentFeeConfigId);
    }

    /// @custom:spec Whether the configuration installed under `configId` charges any fee.
    function _specCharges(uint64 configId) internal view returns (bool) {
        return _feeConfigs[configId].excess.fixedFeeCount != 0 || _feeConfigs[configId].excess.enabled;
    }

    /// @custom:spec Whether `configId` names a configuration that was installed.
    function _specInstalled(uint64 configId) internal view returns (bool) {
        return configId >= 1 && configId <= _currentFeeConfigId;
    }

    /// @custom:spec The structural bounds of fees.md: at most four fixed fees, fixed rates summing to at most
    ///     100%, and excess and target rates of at most 100% each.
    function _specWithinFeeBounds(uint64 configId) internal view returns (bool) {
        return _feeConfigs[configId].excess.fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
            && _specStoredRateTotal(configId) <= BPS_DENOMINATOR
            && _feeConfigs[configId].excess.excessFeeRateBps <= BPS_DENOMINATOR
            && _feeConfigs[configId].excess.annualTargetRateBps <= BPS_DENOMINATOR;
    }

    /// @custom:spec Sum of the stored configuration's four fixed rates.
    function _specStoredRateTotal(uint64 configId) internal view returns (uint256) {
        return uint256(_feeConfigs[configId].fixedFees[0].rateBps) + _feeConfigs[configId].fixedFees[1].rateBps
            + _feeConfigs[configId].fixedFees[2].rateBps + _feeConfigs[configId].fixedFees[3].rateBps;
    }

    /// @custom:spec Every rule `_validateFeeConfig` enforces (fees.md, "Configuration and authority").
    function _specValidConfig(FeeConfig memory config) internal view returns (bool) {
        return config.fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS && _specValidFixedFee(config, 0)
            && _specValidFixedFee(config, 1) && _specValidFixedFee(config, 2) && _specValidFixedFee(config, 3)
            && _specDistinctFixedFees(config) && _specFirstRates(config, MAX_FIXED_FEE_RECIPIENTS) <= BPS_DENOMINATOR
            && (config.excess.enabled ? _specValidExcessFee(config) : _specExcessUnset(config));
    }

    /// @custom:spec A configured fixed fee has a valid recipient and a nonzero rate; an unused slot is empty.
    function _specValidFixedFee(FeeConfig memory config, uint256 i) internal view returns (bool) {
        return i < config.fixedFeeCount
            ? !_invalidRecipient(config.fixedFees[i].account) && config.fixedFees[i].rateBps != 0
            : config.fixedFees[i].account == address(0) && config.fixedFees[i].rateBps == 0;
    }

    /// @custom:spec No two configured fixed fees share a recipient.
    function _specDistinctFixedFees(FeeConfig memory config) internal pure returns (bool) {
        return _specDistinct(config, 0, 1) && _specDistinct(config, 0, 2) && _specDistinct(config, 0, 3)
            && _specDistinct(config, 1, 2) && _specDistinct(config, 1, 3) && _specDistinct(config, 2, 3);
    }

    /// @custom:spec Fixed fees `i < j` have different recipients when both are configured.
    function _specDistinct(FeeConfig memory config, uint256 i, uint256 j) internal pure returns (bool) {
        return j >= config.fixedFeeCount || config.fixedFees[i].account != config.fixedFees[j].account;
    }

    /// @custom:spec Sum of the first `count` fixed rates.
    function _specFirstRates(FeeConfig memory config, uint256 count) internal pure returns (uint256) {
        return (count > 0 ? uint256(config.fixedFees[0].rateBps) : 0)
            + (count > 1 ? uint256(config.fixedFees[1].rateBps) : 0)
            + (count > 2 ? uint256(config.fixedFees[2].rateBps) : 0)
            + (count > 3 ? uint256(config.fixedFees[3].rateBps) : 0);
    }

    /// @custom:spec An enabled excess fee has a valid recipient, a nonzero rate, and rates of at most 100%.
    function _specValidExcessFee(FeeConfig memory config) internal view returns (bool) {
        return !_invalidRecipient(config.excess.account) && config.excess.excessFeeRateBps != 0
            && config.excess.excessFeeRateBps <= BPS_DENOMINATOR && config.excess.annualTargetRateBps <= BPS_DENOMINATOR;
    }

    /// @custom:spec A disabled excess fee names no recipient and no rates.
    function _specExcessUnset(FeeConfig memory config) internal pure returns (bool) {
        return config.excess.account == address(0) && config.excess.annualTargetRateBps == 0
            && config.excess.excessFeeRateBps == 0;
    }

    /// @custom:spec Configuration `configId` holds exactly `config`.
    function _specStored(uint64 configId, FeeConfig memory config) internal view returns (bool) {
        return _feeConfigs[configId].excess.fixedFeeCount == config.fixedFeeCount
            && _specStoredFixedFee(configId, config, 0) && _specStoredFixedFee(configId, config, 1)
            && _specStoredFixedFee(configId, config, 2) && _specStoredFixedFee(configId, config, 3)
            && _feeConfigs[configId].excess.enabled == config.excess.enabled
            && _feeConfigs[configId].excess.account == config.excess.account
            && _feeConfigs[configId].excess.annualTargetRateBps == config.excess.annualTargetRateBps
            && _feeConfigs[configId].excess.excessFeeRateBps == config.excess.excessFeeRateBps;
    }

    /// @custom:spec Fixed fee `i` of configuration `configId` equals `config`'s.
    function _specStoredFixedFee(uint64 configId, FeeConfig memory config, uint256 i) internal view returns (bool) {
        return _feeConfigs[configId].fixedFees[i].account == config.fixedFees[i].account
            && _feeConfigs[configId].fixedFees[i].rateBps == config.fixedFees[i].rateBps;
    }

    /// @custom:spec The high-water mark and target are `(highWater, base, startedAt)`.
    function _specBaselines(uint256 highWater, uint256 base, uint40 startedAt) internal view returns (bool) {
        return highWaterMark() == highWater && targetBase() == base && targetStartedAt == startedAt;
    }

    /// @custom:spec The current configuration's target, grown to now.
    function _specTargetNow() internal view returns (uint256) {
        return EarnFeeMath.targetFrom(
            targetBase(), _feeConfigs[_currentFeeConfigId].excess.annualTargetRateBps, targetStartedAt, block.timestamp
        );
    }

    /// @custom:spec The target restarts now at the high-water mark.
    function _specTargetRestarted() internal view returns (bool) {
        return targetBase() == highWaterMark() && targetStartedAt == uint40(block.timestamp);
    }

    /// @custom:spec The value per EarnShare a target may restart at: `value` rounded up to a whole step, at most
    ///     `mark` ({_settledValue}).
    function _specSettled(uint256 value, uint256 mark) internal pure returns (uint256) {
        return value >= mark
            ? mark
            : EarnFeeMath.min(
                value % VALUE_PRECISION == 0 ? value : value - value % VALUE_PRECISION + VALUE_PRECISION, mark
            );
    }

    /// @custom:spec A checkpoint restarts an excess target that both the value and the value it settled fees to
    ///     exceed: the new mark after a charge, otherwise the value rounded up to a whole step and at most the mark
    ///     (fees.md, "High-water mark and target").
    function _specTargetRatchets(FeePreview memory fees) internal view returns (bool) {
        return _feeConfigs[_currentFeeConfigId].excess.enabled
            && fees.postFeeValuePerEarnShare > fees.targetValuePerEarnShare
            && _specSettled(fees.postFeeValuePerEarnShare, highWaterMark()) > fees.targetValuePerEarnShare;
    }

    /// @custom:spec The target restarts now at `value`.
    function _specTargetRestartedAt(uint256 value) internal view returns (bool) {
        return targetBase() == value && targetStartedAt == uint40(block.timestamp);
    }

    /// @custom:spec Whether a request's snapshot is still charged when it settles: open, recorded after fees were
    ///     last disabled, fees enabled, and its configuration charging a fee.
    function _specChargesPending(bytes32 requestId) internal view returns (bool) {
        return _pendingFeeSnapshots[requestId].feeConfigId != 0
            && _lastDisabledAt < _pendingFeeSnapshots[requestId].requestedAt && !feesDisabled
            && _specCharges(_pendingFeeSnapshots[requestId].feeConfigId);
    }

    /// @custom:spec The request's snapshot was just recorded from the current fee state (fees.md, "Queued withdrawals").
    function _specRecorded(bytes32 requestId, uint256 burnedEarnShares) internal view returns (bool) {
        return _pendingFeeSnapshots[requestId].feeConfigId == _currentFeeConfigId
            && _pendingFeeSnapshots[requestId].requestedAt == uint40(block.timestamp)
            && _pendingFeeSnapshots[requestId].highWaterValue
                == EarnFeeMath.ceilDiv(highWaterMark() * burnedEarnShares, _valueScale())
            && (!_feeConfigs[_currentFeeConfigId].excess.enabled
                || _pendingFeeSnapshots[requestId].targetValue
                    == EarnFeeMath.ceilDiv(_specTargetNow() * burnedEarnShares, _valueScale()));
    }

    /// @custom:spec The request's snapshot is deleted and its configuration has one open request fewer; a
    ///     historical configuration left without open requests has its remainders waived.
    function _specClosed(bytes32 requestId, uint64 configId, uint256 openBefore) internal view returns (bool) {
        return _pendingFeeSnapshots[requestId].feeConfigId == 0 && _pendingFeeSnapshots[requestId].requestedAt == 0
            && _pendingFeeSnapshots[requestId].highWaterValue == 0 && _pendingFeeSnapshots[requestId].targetValue == 0
            && _feeConfigs[configId].excess.openRequests == openBefore - 1
            && (!_specHistoricalAndClosed(configId) || _specRemaindersWaived(configId));
    }

    /// @custom:spec Whether `configId` is a replaced configuration that no open request references.
    function _specHistoricalAndClosed(uint64 configId) internal view returns (bool) {
        return configId != 0 && configId != _currentFeeConfigId && _feeConfigs[configId].excess.openRequests == 0;
    }

    /// @custom:spec The snapshot's high-water mark per EarnShare, rounded up.
    function _specSnapshotHighWater(StoredFeeSnapshot storage pending, uint256 burnedEarnShares)
        internal
        view
        returns (uint256)
    {
        return EarnFeeMath.ceilDiv(pending.highWaterValue * _valueScale(), burnedEarnShares);
    }

    /// @custom:spec The snapshot's target per EarnShare, grown from the request time to now.
    function _specSnapshotTargetNow(StoredFeeSnapshot storage pending, uint256 burnedEarnShares)
        internal
        view
        returns (uint256)
    {
        return EarnFeeMath.targetFrom(
            EarnFeeMath.ceilDiv(pending.targetValue * _valueScale(), burnedEarnShares),
            _feeConfigs[pending.feeConfigId].excess.annualTargetRateBps,
            pending.requestedAt,
            block.timestamp
        );
    }

    /// @custom:spec Every remainder slot of configuration `configId` is zero.
    function _specRemaindersWaived(uint64 configId) internal view returns (bool) {
        return _feeRemainders[configId] & ~REMAINDERS_MARKER == 0;
    }

    /// @custom:spec Remainder slot `k` of configuration `configId`; zero past the excess slot.
    function _specRemainder(uint64 configId, uint256 k) internal view returns (uint256) {
        return k > MAX_FIXED_FEE_RECIPIENTS ? 0 : _remainderAt(_feeRemainders[configId], k);
    }

    /// @custom:spec Fee EarnShare credited by settling `fees` with `feeEarnShares`.
    function _specCharged(FeePreview memory fees, uint256 feeEarnShares) internal pure returns (uint256) {
        return (feeEarnShares == 0 || fees.totalFeeAssets == 0) ? 0 : feeEarnShares;
    }

    /// @custom:spec Whether `account` receives any of `fees`' allocations.
    function _specIsRecipient(FeePreview memory fees, address account) internal pure returns (bool) {
        return (fees.allocationCount > 0 && fees.allocations[0].account == account)
            || (fees.allocationCount > 1 && fees.allocations[1].account == account)
            || (fees.allocationCount > 2 && fees.allocations[2].account == account)
            || (fees.allocationCount > 3 && fees.allocations[3].account == account)
            || (fees.allocationCount > 4 && fees.allocations[4].account == account);
    }

    /// @custom:spec Fee EarnShare that `fees`' allocations credit to `account`.
    function _specCreditedTo(FeePreview memory fees, address account) internal pure returns (uint256) {
        return _specCreditedToFirst(fees, account, fees.allocationCount);
    }

    /// @custom:spec Fee EarnShare that the first `count` allocations credit to `account`.
    function _specCreditedToFirst(FeePreview memory fees, address account, uint256 count)
        internal
        pure
        returns (uint256)
    {
        return _specCreditOf(fees, account, count, 0) + _specCreditOf(fees, account, count, 1)
            + _specCreditOf(fees, account, count, 2) + _specCreditOf(fees, account, count, 3)
            + _specCreditOf(fees, account, count, 4);
    }

    /// @custom:spec Allocation `k`'s fee EarnShare if it is among the first `count` and pays `account`.
    function _specCreditOf(FeePreview memory fees, address account, uint256 count, uint256 k)
        internal
        pure
        returns (uint256)
    {
        return (k < count && fees.allocations[k].account == account) ? fees.allocations[k].feeEarnShares : 0;
    }

    /// @custom:spec A checkpoint that charged accrual, with no pending baselines restarted.
    function _specChargingCheckpoint(FeePreview memory fees, bool oldBaselinesPending) internal view returns (bool) {
        return feeBaselinesPending == oldBaselinesPending && fees.positiveAccrualAssets != 0;
    }

    /// @custom:spec Value per EarnShare of the checkpointed assets over `supply` plus the fee mint, rounded up.
    function _specPostFeeValue(FeePreview memory fees, uint256 supply) internal view returns (uint256) {
        return EarnFeeMath.ceilDiv(fees.activeAssets * _valueScale(), supply + fees.totalFeeEarnShares);
    }

    /// @custom:spec The high-water mark values `supply` plus the fee mint at no less than the old mark's value of
    ///     `supply` plus the charged accrual, so no charged value is charged again.
    function _specCoversCharged(FeePreview memory fees, uint256 oldHighWater, uint256 supply)
        internal
        view
        returns (bool)
    {
        return highWaterMark() * (supply + fees.totalFeeEarnShares)
            >= oldHighWater * supply + fees.positiveAccrualAssets * _valueScale();
    }

    /// @custom:spec The high-water mark values `supply` plus the fee mint at less than the old mark's value of
    ///     `supply` plus the charged accrual and two value units per EarnShare, so what the checkpoint left
    ///     uncharged stays above it.
    function _specLeavesUncharged(FeePreview memory fees, uint256 oldHighWater, uint256 supply)
        internal
        view
        returns (bool)
    {
        return highWaterMark() * (supply + fees.totalFeeEarnShares)
            < oldHighWater * supply + fees.positiveAccrualAssets * _valueScale() + 2
                * (supply + fees.totalFeeEarnShares);
    }

    /// @custom:spec The high-water mark values the active supply plus the re-entry at no less than the old mark's
    ///     value of the active supply plus the returned value, so no value a cancellation charged is charged again.
    function _specCoversReentry(uint256 oldHighWater, uint256 activeSupply, uint256 returnedValue, uint256 reentry)
        internal
        view
        returns (bool)
    {
        return highWaterMark() == type(uint256).max
            || highWaterMark() * (activeSupply + reentry) >= oldHighWater * activeSupply + returnedValue * _valueScale();
    }

    /// @custom:spec The fee base is at most the checkpointed assets above the old high-water mark's value of
    ///     `supply`.
    function _specAccrualWithinGrowth(FeePreview memory fees, uint256 oldHighWater, uint256 supply)
        internal
        view
        returns (bool)
    {
        return fees.positiveAccrualAssets * _valueScale() + oldHighWater * supply <= fees.activeAssets * _valueScale();
    }

    /// @custom:spec The fee EarnShare minted for `feeAssets` out of `assets` at `supply` are worth at most the fee
    ///     after the mint, and less than one EarnShare's value below it.
    function _specLemmaFeeEarnSharesHolds(uint256 feeAssets, uint256 assets, uint256 supply)
        internal
        pure
        returns (bool)
    {
        // The fee mint is rounded down before it is valued: that rounding is the bound being stated.
        // forge-lint: disable-start(divide-before-multiply)
        return (feeAssets == 0 || feeAssets >= assets)
            || (feeAssets * supply / (assets - feeAssets) * assets
                    <= feeAssets * (supply + feeAssets * supply / (assets - feeAssets))
                && feeAssets * supply / (assets - feeAssets) * assets + assets
                    > feeAssets * (supply + feeAssets * supply / (assets - feeAssets)));
        // forge-lint: disable-end(divide-before-multiply)
    }

    /// @custom:spec The positive accrual of `assets` at `supply` above `highWater`, as `EarnFeeMath.preview`
    ///     computes it.
    function _specAccrualOf(uint256 assets, uint256 supply, uint256 scale, uint256 highWater)
        internal
        pure
        returns (uint256)
    {
        return assets * scale / supply > highWater ? (assets * scale / supply - highWater) * supply / scale : 0;
    }

    // ---------------------------------------------------------------- lemmas, never executed

    /// @notice Rounding up covers: `ceil(x / d) * d >= x`.
    /// @custom:requires d != 0
    /// @custom:ensures EarnFeeMath.ceilDiv(x, d) * d >= x
    function _specLemmaCeilCovers(uint256 x, uint256 d) internal pure {
        x;
        d;
    }

    /// @notice A floor is within one divisor: `floor(x / d) * d <= x < (floor(x / d) + 1) * d`.
    /// @custom:ensures d != 0 ==> (x / d) * d <= x && x < (x / d + 1) * d
    function _specLemmaFloor(uint256 x, uint256 d) internal pure {
        x;
        d;
    }

    /// @notice A checkpoint's fee base is at most its assets above the old high-water mark's value.
    /// @custom:ensures (supply != 0 && scale != 0 && assets * scale / supply > highWater) ==> _specAccrualOf(assets, supply, scale, highWater) * scale + highWater * supply <= assets * scale
    /// @custom:ensures (supply != 0 && scale != 0) ==> _specAccrualOf(assets, supply, scale, highWater) <= assets
    function _specLemmaAccrualWithinGrowth(uint256 assets, uint256 supply, uint256 scale, uint256 highWater)
        internal
        pure
    {
        /// @custom:use _specLemmaFloor(assets * scale, supply)
        assets;
        /// @custom:use _specLemmaFloor((assets * scale / supply - highWater) * supply, scale)
        highWater;
        supply;
        scale;
    }

    /// @notice The fee EarnShare minted for a fee are worth it within one EarnShare's value.
    /// @custom:ensures _specLemmaFeeEarnSharesHolds(feeAssets, assets, supply)
    function _specLemmaFeeEarnShares(uint256 feeAssets, uint256 assets, uint256 supply) internal pure {
        /// @custom:use _specLemmaFloor(feeAssets * supply, assets - feeAssets)
        feeAssets;
        assets;
        supply;
    }

    /// @notice Checkpoint cadence: two consecutive charging checkpoints, the second at the supply the first left
    ///     and from the mark it set, charge on at most the base of one checkpoint over both periods, and on less than
    ///     one asset unit and three value units per EarnShare below it. `firstAccrual` and `secondAccrual` are the
    ///     checkpoints' fee bases (`_specAccrualWithinGrowth`), `firstMark` the mark the first set
    ///     (`_specCoversCharged`, `_specLeavesUncharged`) and `firstFeeEarnShares` its mint.
    /// @custom:requires supply != 0 && scale != 0
    /// @custom:requires firstAccrual * scale + highWater * supply <= firstAssets * scale
    /// @custom:requires firstMark * (supply + firstFeeEarnShares) >= highWater * supply + firstAccrual * scale
    /// @custom:requires firstMark * (supply + firstFeeEarnShares) < highWater * supply + firstAccrual * scale + 2 * (supply + firstFeeEarnShares)
    /// @custom:requires secondAccrual == _specAccrualOf(secondAssets, supply + firstFeeEarnShares, scale, firstMark)
    /// @custom:requires secondAssets * scale / (supply + firstFeeEarnShares) > firstMark
    /// @custom:ensures (firstAccrual + secondAccrual) * scale + highWater * supply <= secondAssets * scale
    /// @custom:ensures secondAssets * scale < (firstAccrual + secondAccrual + 1) * scale + highWater * supply + 3 * (supply + firstFeeEarnShares)
    function _specLemmaCadence(
        uint256 scale,
        uint256 supply,
        uint256 highWater,
        uint256 firstAssets,
        uint256 firstFeeEarnShares,
        uint256 firstAccrual,
        uint256 firstMark,
        uint256 secondAssets,
        uint256 secondAccrual
    ) internal pure {
        /// @custom:use _specLemmaAccrualWithinGrowth(secondAssets, supply + firstFeeEarnShares, scale, firstMark)
        firstAccrual;
        /// @custom:use _specLemmaFloor(secondAssets * scale, supply + firstFeeEarnShares)
        secondAccrual;
        /// @custom:use _specLemmaFloor((secondAssets * scale / (supply + firstFeeEarnShares) - firstMark) * (supply + firstFeeEarnShares), scale)
        highWater;
        firstFeeEarnShares;
        firstMark;
        scale;
        supply;
        firstAssets;
        secondAssets;
    }

    /// @notice The excess fee's target rounds down: never above exact simple interest on the base, and below it
    ///     by less than one value unit plus one per year of elapsed time and basis point of rate denominator.
    /// @custom:requires startedAt <= timestamp
    /// @custom:ensures EarnFeeMath.targetFrom(base, annualRateBps, startedAt, timestamp) * BPS_DENOMINATOR * EarnFeeMath.YEAR <= base * BPS_DENOMINATOR * EarnFeeMath.YEAR + base * annualRateBps * (timestamp - startedAt)
    /// @custom:ensures (EarnFeeMath.targetFrom(base, annualRateBps, startedAt, timestamp) + 1) * BPS_DENOMINATOR * EarnFeeMath.YEAR + BPS_DENOMINATOR * (timestamp - startedAt) > base * BPS_DENOMINATOR * EarnFeeMath.YEAR + base * annualRateBps * (timestamp - startedAt)
    function _specLemmaTargetRoundsDown(uint256 base, uint256 annualRateBps, uint256 startedAt, uint256 timestamp)
        internal
        pure
    {
        /// @custom:use _specLemmaFloor(base * annualRateBps, BPS_DENOMINATOR)
        base;
        /// @custom:use _specLemmaFloor(EarnFeeMath.yearlyGrowth(base, annualRateBps) * (timestamp - startedAt), EarnFeeMath.YEAR)
        annualRateBps;
        startedAt;
        timestamp;
    }

    /// @dev Matches EarnVault: the unit the vault keeps and the unit this contract keeps count as burned. Neither
    ///      ever leaves: the vault moves out only EarnShare it took in within the same call, and {claim} pays out
    ///      only recorded claims, which the vault minted here on top of this contract's unit.
    function _activeSupply() internal view returns (uint256) {
        return IEarnShare(earnShare).totalSupply() - LOCKED_EARN_SHARES;
    }
}
