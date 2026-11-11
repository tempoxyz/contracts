// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { EarnFeeMath } from "./EarnFeeMath.sol";
import { BPS_DENOMINATOR, FeeConfig, FeePreview, MAX_FIXED_FEE_RECIPIENTS } from "../interfaces/core/EarnFeeTypes.sol";
import { IEarnFees } from "../interfaces/core/IEarnFees.sol";
import { IEarnShare } from "../interfaces/core/IEarnShare.sol";
import { IERC20Like } from "../interfaces/external/IERC20Like.sol";

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
/// @custom:invariant totalClaimableEarnShares == sumClaimable
/// @custom:invariant !initialized ==> (currentFeeConfigId == 0 && earnVault == address(0) && locked == 0)
/// @custom:invariant earnVault != address(0) ==> (currentFeeConfigId >= 1 && locked != 0)
/// @custom:invariant locked == 0 || locked == 1 || locked == 2
/// @custom:invariant _specWithinFeeBounds(currentFeeConfigId)
/// @custom:invariant forall uint64 c :: _feeConfigs[c].fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
/// @custom:invariant forall bytes32 r :: _pendingFeeSnapshots[r].open ==> _specInstalled(_pendingFeeSnapshots[r].feeConfigId)
/// @custom:reentrancy-guard initialized && locked == 2
contract EarnFees is IEarnFees {
    address public earnVault;
    address public earnShare;
    uint256 public earnShareScale;

    uint64 public currentFeeConfigId;
    uint256 public highWaterMark;
    uint256 public targetBase;
    uint40 public targetStartedAt;
    bool public feesDisabled;

    mapping(uint64 configId => FeeConfig config) private _feeConfigs;
    mapping(uint64 configId => mapping(uint8 slot => uint256 remainder)) private _feeRemainders;
    mapping(uint64 configId => uint256 count) private _openRequestsByFeeConfig;
    mapping(bytes32 requestId => PendingFeeSnapshot snapshot) private _pendingFeeSnapshots;
    mapping(bytes32 requestId => uint256 disableEpoch) private _requestDisableEpoch;
    mapping(address recipient => uint256 earnShares) public claimableEarnShares;
    uint256 public totalClaimableEarnShares;
    /// @notice Whether an empty active pool was reopened while fee valuation was stale.
    /// @dev The next fresh checkpoint initializes baselines without charging the returned principal.
    bool public feeBaselinesPending;
    uint256 private _disableEpoch;

    uint256 private locked;
    bool private initialized;

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

    /// @custom:ensures initialized && earnVault == address(0) && currentFeeConfigId == 0
    constructor() {
        initialized = true;
    }

    modifier onlyEarnVault() {
        if (msg.sender != earnVault) revert NotEarnVault();
        _;
    }

    modifier nonReentrant() {
        if (locked != 1) revert ReentrantCall();
        locked = 2;
        _;
        locked = 1;
    }

    /// @notice A fresh clone is initialized once, paired with one vault and EarnShare, under configuration 1.
    /// @custom:ensures !old(initialized) && initialized && locked == 1
    /// @custom:ensures earnVault == earnVault_ && earnShare == earnShare_ && earnVault_ != address(0) && earnShare_ != address(0)
    /// @custom:ensures currentFeeConfigId == 1 && _specStored(1, initialConfig) && _specValidConfig(initialConfig)
    /// @custom:ensures totalClaimableEarnShares == old(totalClaimableEarnShares)
    function initialize(address earnVault_, address earnShare_, FeeConfig calldata initialConfig) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        if (earnVault_ == address(0) || earnShare_ == address(0)) revert ZeroAddress();

        earnVault = earnVault_;
        earnShare = earnShare_;

        uint8 decimals = IEarnShare(earnShare_).decimals();
        if (decimals > 77) revert InvalidFeeConfiguration();
        earnShareScale = 10 ** uint256(decimals);

        _validateFeeConfig(initialConfig);
        currentFeeConfigId = 1;
        _storeFeeConfig(1, initialConfig);
        locked = 1;
        emit FeeConfigurationSet(1, keccak256(abi.encode(initialConfig)), false);
    }

    function feeConfig(uint64 configId) external view returns (FeeConfig memory) {
        return _feeConfigs[configId];
    }

    function feeRemainder(uint64 configId, uint8 slot) external view returns (uint256) {
        return _feeRemainders[configId][slot];
    }

    function feesActive() external view returns (bool) {
        return _feesActive();
    }

    function pendingFeeSnapshot(bytes32 requestId) external view returns (PendingFeeSnapshot memory) {
        return _pendingFeeSnapshots[requestId];
    }

    /// @custom:ensures result ==> _specChargesPending(requestId)
    function shouldChargeRedeem(bytes32 requestId) external view returns (bool) {
        PendingFeeSnapshot storage pending = _pendingFeeSnapshots[requestId];
        return pending.open && _requestDisableEpoch[requestId] == _disableEpoch && !feesDisabled
            && _configHasFees(_feeConfigs[pending.feeConfigId]) && _feeValuationFresh();
    }

    /// @custom:ensures (!_specFeesActive() || feeBaselinesPending) ==> EarnFeeMath.chargesNothing(result) && result.activeAssets == 0
    /// @custom:ensures result.totalFeeAssets <= result.positiveAccrualAssets
    /// @custom:ensures result.totalFeeEarnShares == EarnFeeMath.allocatedFeeEarnShares(result)
    function previewAccruedFees() public view returns (FeePreview memory result) {
        if (!_feesActive()) return result;
        if (feeBaselinesPending || !_feeValuationFresh()) return result;
        uint256 earnShareSupply = IEarnShare(earnShare).totalSupply();
        if (earnShareSupply == 0) return result;

        uint64 configId = currentFeeConfigId;
        FeeConfig storage storedConfig = _feeConfigs[configId];
        (result,) = EarnFeeMath.preview(
            EarnFeeMath.Input({
                activeAssets: _activeAssets(),
                earnShareSupply: earnShareSupply,
                earnShareScale: earnShareScale,
                highWaterMark: highWaterMark,
                targetBase: targetBase,
                targetStartedAt: targetStartedAt,
                timestamp: block.timestamp
            }),
            storedConfig,
            _remainders(configId, storedConfig)
        );
    }

    /// @notice Charges fees above the high-water mark; the vault mints exactly the returned fee EarnShare here.
    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && earnShareScale == old(earnShareScale)
    function accrueFees() external onlyEarnVault returns (FeePreview memory result) {
        result = _accrueFees();
    }

    /// @notice Installs a valid configuration under the next id and re-enables fees (fees.md, "Configuration changes").
    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && earnShareScale == old(earnShareScale)
    /// @custom:ensures _specValidConfig(config) && configId == old(currentFeeConfigId) + 1 && currentFeeConfigId == configId
    /// @custom:ensures _specStored(configId, config) && !feesDisabled
    /// @custom:ensures totalClaimableEarnShares == old(totalClaimableEarnShares)
    /// @custom:ensures !_configHasFees(config) ==> _specBaselines(old(highWaterMark), old(targetBase), old(targetStartedAt))
    /// @custom:ensures (_configHasFees(config) && !config.excess.enabled) ==> targetBase == 0 && targetStartedAt == 0
    /// @custom:ensures (_configHasFees(config) && old(_specFeesActive())) ==> highWaterMark == old(highWaterMark)
    /// @custom:ensures (old(_specFeesActive()) || !_configHasFees(config)) ==> feeBaselinesPending == old(feeBaselinesPending)
    /// @custom:ensures (config.excess.enabled && old(_specFeesActive())) ==> targetStartedAt == uint40(block.timestamp)
    /// @custom:ensures (config.excess.enabled && old(_specFeesActive() && _feeConfigs[currentFeeConfigId].excess.enabled)) ==> targetBase == old(_specTargetNow())
    /// @custom:ensures (old(feesDisabled) || old(_openRequestsByFeeConfig[currentFeeConfigId]) == 0) ==> _specRemaindersWaived(old(currentFeeConfigId))
    function setFeeConfig(FeeConfig calldata config) external onlyEarnVault returns (uint64 configId) {
        _validateFeeConfig(config);

        bool reactivated = feesDisabled;
        bool wasActive = _feesActive();
        FeeConfig memory oldConfig = _feeConfigs[currentFeeConfigId];
        uint256 oldTargetNow = oldConfig.excess.enabled
            ? EarnFeeMath.targetAt(targetBase, oldConfig.excess.annualTargetRateBps, targetStartedAt, block.timestamp)
            : 0;
        _waiveCurrentRemainders();

        configId = currentFeeConfigId + 1;
        currentFeeConfigId = configId;
        _storeFeeConfig(configId, config);
        feesDisabled = false;

        if (_configHasFees(config)) {
            if (!wasActive || reactivated) {
                _initializeFeeBaselines();
            } else if (config.excess.enabled) {
                if (oldConfig.excess.enabled) {
                    targetBase = oldTargetNow;
                    targetStartedAt = uint40(block.timestamp);
                } else {
                    uint256 earnShareSupply = IEarnShare(earnShare).totalSupply();
                    targetBase = earnShareSupply == 0
                        ? 0
                        : EarnFeeMath.valuePerEarnShareUp(_activeAssets(), earnShareScale, earnShareSupply);
                    targetStartedAt = uint40(block.timestamp);
                }
            } else {
                targetBase = 0;
                targetStartedAt = 0;
            }
        }

        emit FeeConfigurationSet(configId, keccak256(abi.encode(config)), reactivated);
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
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && earnShareScale == old(earnShareScale)
    /// @custom:ensures currentFeeConfigId == old(currentFeeConfigId) && totalClaimableEarnShares == old(totalClaimableEarnShares)
    /// @custom:ensures feesDisabled && _specBaselines(old(highWaterMark), old(targetBase), old(targetStartedAt))
    /// @custom:ensures !old(feesDisabled) ==> !feeBaselinesPending && _disableEpoch == old(_disableEpoch) + 1
    /// @custom:ensures !old(feesDisabled) ==> _specRemaindersWaived(currentFeeConfigId)
    /// @custom:ensures old(feesDisabled) ==> feeBaselinesPending == old(feeBaselinesPending) && _disableEpoch == old(_disableEpoch)
    /// @custom:ensures old(feesDisabled) ==> forall uint64 c, uint8 k :: _feeRemainders[c][k] == old(_feeRemainders[c][k])
    function disableFees(address operator) external onlyEarnVault {
        if (feesDisabled) return;
        feesDisabled = true;
        feeBaselinesPending = false;
        _disableEpoch += 1;
        _waiveCurrentRemainders();
        emit FeesDisabled(operator);
    }

    /// @notice Ratchets fee baselines after principal enters without treating principal as yield.
    /// @dev Only the paired EarnVault calls this after minting proportional EarnShare. Rounding and
    ///      any valuation precision recovered by pooling favor holders through an upward-only ratchet.
    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && earnShareScale == old(earnShareScale)
    /// @custom:ensures currentFeeConfigId == old(currentFeeConfigId) && totalClaimableEarnShares == old(totalClaimableEarnShares)
    /// @custom:ensures highWaterMark >= old(highWaterMark)
    /// @custom:ensures targetBase != old(targetBase) ==> targetBase > old(_specTargetNow()) && targetStartedAt == uint40(block.timestamp)
    /// @custom:ensures !old(_specFeesActive()) ==> _specBaselines(old(highWaterMark), old(targetBase), old(targetStartedAt))
    /// @custom:ensures !_feeConfigs[currentFeeConfigId].excess.enabled ==> targetBase == old(targetBase) && targetStartedAt == old(targetStartedAt)
    function initializeBaselines() external onlyEarnVault {
        if (_feesActive()) _updateBaselinesAfterPrincipalEntry();
    }

    /// @notice Snapshots a fee-active request's burned EarnShare, value, high-water value and target value.
    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && earnShareScale == old(earnShareScale)
    /// @custom:ensures currentFeeConfigId == old(currentFeeConfigId) && totalClaimableEarnShares == old(totalClaimableEarnShares)
    /// @custom:ensures _specBaselines(old(highWaterMark), old(targetBase), old(targetStartedAt))
    /// @custom:ensures !old(_specFeesActive()) ==> _pendingFeeSnapshots[requestId].open == old(_pendingFeeSnapshots[requestId].open)
    /// @custom:ensures old(_pendingFeeSnapshots[requestId].open) ==> _pendingFeeSnapshots[requestId].open
    /// @custom:ensures _pendingFeeSnapshots[requestId].open == old(_pendingFeeSnapshots[requestId].open) ==> _openRequestsByFeeConfig[currentFeeConfigId] == old(_openRequestsByFeeConfig[currentFeeConfigId])
    /// @custom:ensures _pendingFeeSnapshots[requestId].open != old(_pendingFeeSnapshots[requestId].open) ==> _specRecorded(requestId, burnedEarnShares, requestValue)
    /// @custom:ensures _pendingFeeSnapshots[requestId].open != old(_pendingFeeSnapshots[requestId].open) ==> _openRequestsByFeeConfig[currentFeeConfigId] == old(_openRequestsByFeeConfig[currentFeeConfigId]) + 1
    function recordRedeemRequest(bytes32 requestId, uint256 burnedEarnShares, uint256 requestValue)
        external
        onlyEarnVault
    {
        if (!_feesActive() || !_feeValuationFresh()) return;
        PendingFeeSnapshot storage pending = _pendingFeeSnapshots[requestId];
        if (pending.open) revert InvalidFeeConfiguration();

        pending.burnedEarnShares = burnedEarnShares;
        pending.requestValue = requestValue;
        pending.highWaterValue = Math.mulDiv(highWaterMark, burnedEarnShares, earnShareScale, Math.Rounding.Ceil);
        FeeConfig memory config = _feeConfigs[currentFeeConfigId];
        if (config.excess.enabled) {
            uint256 currentTarget =
                EarnFeeMath.targetAt(targetBase, config.excess.annualTargetRateBps, targetStartedAt, block.timestamp);
            pending.targetValue = Math.mulDiv(currentTarget, burnedEarnShares, earnShareScale, Math.Rounding.Ceil);
        }
        pending.feeConfigId = currentFeeConfigId;
        pending.requestedAt = uint40(block.timestamp);
        pending.open = true;
        _requestDisableEpoch[requestId] = _disableEpoch;
        _openRequestsByFeeConfig[currentFeeConfigId] += 1;
    }

    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && earnShareScale == old(earnShareScale)
    /// @custom:ensures currentFeeConfigId == old(currentFeeConfigId) && totalClaimableEarnShares == old(totalClaimableEarnShares)
    /// @custom:ensures !_pendingFeeSnapshots[requestId].open
    /// @custom:ensures old(_pendingFeeSnapshots[requestId].open) ==> _specClosed(requestId, old(_pendingFeeSnapshots[requestId].feeConfigId), old(_openRequestsByFeeConfig[_pendingFeeSnapshots[requestId].feeConfigId]))
    /// @custom:ensures !old(_pendingFeeSnapshots[requestId].open) ==> _requestDisableEpoch[requestId] == old(_requestDisableEpoch[requestId])
    function closeRedeemRequest(bytes32 requestId) external onlyEarnVault {
        PendingFeeSnapshot storage pending = _pendingFeeSnapshots[requestId];
        if (!pending.open) return;
        uint64 configId = pending.feeConfigId;
        delete _pendingFeeSnapshots[requestId];
        delete _requestDisableEpoch[requestId];
        _openRequestsByFeeConfig[configId] -= 1;
        _waiveClosedHistoricalRemainders(configId);
    }

    /// @notice Charges a cancelled request's snapshot on the value it returns, crediting at most the re-entry EarnShare.
    /// @custom:ensures msg.sender == earnVault
    /// @custom:ensures earnVault == old(earnVault) && earnShare == old(earnShare) && earnShareScale == old(earnShareScale)
    /// @custom:ensures currentFeeConfigId == old(currentFeeConfigId)
    /// @custom:ensures totalClaimableEarnShares == old(totalClaimableEarnShares) + feeEarnShares
    /// @custom:ensures feeEarnShares <= totalReentryEarnShares && !_pendingFeeSnapshots[requestId].open
    /// @custom:ensures !old(_specChargesPending(requestId)) ==> feeEarnShares == 0
    /// @custom:ensures old(_pendingFeeSnapshots[requestId].open) ==> _specClosed(requestId, old(_pendingFeeSnapshots[requestId].feeConfigId), old(_openRequestsByFeeConfig[_pendingFeeSnapshots[requestId].feeConfigId]))
    /// @custom:ensures feeEarnShares != 0 ==> (activeSupply == 0 || activeAssets != 0)
    /// @custom:ensures activeSupply != 0 ==> _specBaselines(old(highWaterMark), old(targetBase), old(targetStartedAt)) && feeBaselinesPending == old(feeBaselinesPending)
    /// @custom:ensures feeBaselinesPending != old(feeBaselinesPending) ==> feeBaselinesPending
    function settleCancelledRedeem(
        bytes32 requestId,
        uint256 returnedValue,
        uint256 activeSupply,
        uint256 activeAssets,
        uint256 totalReentryEarnShares
    ) external onlyEarnVault returns (uint256 feeEarnShares) {
        PendingFeeSnapshot storage pending = _pendingFeeSnapshots[requestId];
        bool pendingOpen = pending.open;
        uint64 configId = pendingOpen ? pending.feeConfigId : 0;
        bool feesActive_ = _feesActive();
        bool valuationFresh = _feeValuationFresh();

        bool chargePending = pendingOpen && _requestDisableEpoch[requestId] == _disableEpoch && !feesDisabled
            && _configHasFees(_feeConfigs[configId]) && valuationFresh;
        if (chargePending) {
            (FeePreview memory pendingFees, uint256[5] memory nextRemainders) =
                _previewPendingFees(pending, returnedValue);
            _storeRemainders(configId, _feeConfigs[configId], nextRemainders);

            feeEarnShares =
                returnedValue == 0 ? 0 : Math.mulDiv(totalReentryEarnShares, pendingFees.totalFeeAssets, returnedValue);
            if (feeEarnShares > totalReentryEarnShares) feeEarnShares = totalReentryEarnShares;
            _creditAllocatedFeeEarnShares(configId, pendingFees, feeEarnShares);

            if (activeSupply != 0 && activeAssets == 0) {
                revert InvalidFeeConfiguration();
            }
        }

        if (activeSupply == 0 && feesActive_) {
            if (!valuationFresh) {
                feeBaselinesPending = true;
            } else if (chargePending) {
                _restoreReopenedBaselines(pending, totalReentryEarnShares);
            } else {
                _initializeReopenedBaselines(totalReentryEarnShares);
            }
        }

        if (!pendingOpen) return 0;
        delete _pendingFeeSnapshots[requestId];
        delete _requestDisableEpoch[requestId];
        _openRequestsByFeeConfig[configId] -= 1;
        _waiveClosedHistoricalRemainders(configId);
    }

    /// @notice A recipient claims its own recorded fee EarnShare to any receiver but zero, this contract or the vault.
    /// @custom:ensures to != address(0) && to != address(this) && to != old(earnVault) && earnShares != 0
    /// @custom:ensures old(locked) == 1 && locked == 1
    function claim(address to, uint256 earnShares) external nonReentrant {
        if (to == address(0) || to == address(this) || to == earnVault) revert InvalidFeeClaimReceiver();
        if (earnShares == 0) revert ZeroAmount();
        uint256 claimable = claimableEarnShares[msg.sender];
        if (earnShares > claimable) revert InsufficientClaimableEarnShares();

        claimableEarnShares[msg.sender] = claimable - earnShares;
        /// @custom:ghost sumClaimable = sumClaimable - earnShares
        totalClaimableEarnShares -= earnShares;
        /// @custom:assert claimableEarnShares[msg.sender] == old(claimableEarnShares[msg.sender]) - earnShares
        /// @custom:assert forall address a :: a != msg.sender ==> claimableEarnShares[a] == old(claimableEarnShares[a])
        /// @custom:assert totalClaimableEarnShares == old(totalClaimableEarnShares) - earnShares
        /// @custom:assert earnVault == old(earnVault) && earnShare == old(earnShare) && currentFeeConfigId == old(currentFeeConfigId)
        _safeTransfer(earnShare, to, earnShares);
        emit FeeEarnSharesClaimed(msg.sender, to, earnShares);
    }

    /// @custom:ensures currentFeeConfigId == old(currentFeeConfigId) && feesDisabled == old(feesDisabled)
    /// @custom:ensures totalClaimableEarnShares == old(totalClaimableEarnShares) + result.totalFeeEarnShares
    /// @custom:ensures forall address a :: claimableEarnShares[a] == old(claimableEarnShares[a]) + _specCreditedTo(result, a)
    /// @custom:ensures result.totalFeeEarnShares == EarnFeeMath.allocatedFeeEarnShares(result)
    /// @custom:ensures result.totalFeeAssets <= result.positiveAccrualAssets
    /// @custom:ensures !old(_specFeesActive()) ==> EarnFeeMath.chargesNothing(result) && result.activeAssets == 0
    /// @custom:ensures !old(_specFeesActive()) ==> _specBaselines(old(highWaterMark), old(targetBase), old(targetStartedAt))
    /// @custom:ensures feeBaselinesPending ==> old(feeBaselinesPending)
    /// @custom:ensures (old(feeBaselinesPending) && !feeBaselinesPending) ==> EarnFeeMath.chargesNothing(result)
    /// @custom:ensures feeBaselinesPending == old(feeBaselinesPending) ==> _specHighWaterCheckpointed(result, old(highWaterMark))
    /// @custom:ensures (feeBaselinesPending == old(feeBaselinesPending) && _specTargetRatchets(result)) ==> _specTargetRestartedAt(result.postFeeValuePerEarnShare)
    /// @custom:ensures (feeBaselinesPending == old(feeBaselinesPending) && !_specTargetRatchets(result)) ==> targetBase == old(targetBase) && targetStartedAt == old(targetStartedAt)
    /// @custom:requires _feeConfigs[currentFeeConfigId].fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
    function _accrueFees() internal returns (FeePreview memory result) {
        if (feesDisabled) return result;
        FeeConfig storage storedConfig = _feeConfigs[currentFeeConfigId];
        if (storedConfig.fixedFeeCount == 0 && !storedConfig.excess.enabled) return result;
        uint256 earnShareSupply = IEarnShare(earnShare).totalSupply();
        if (earnShareSupply == 0) return result;
        if (!_feeValuationFresh()) return result;
        if (feeBaselinesPending) {
            feeBaselinesPending = false;
            _initializeFeeBaselines();
            return result;
        }

        uint256 activeAssets = _activeAssets();
        result.activeAssets = activeAssets;
        result.preFeeValuePerEarnShare = EarnFeeMath.valuePerEarnShare(activeAssets, earnShareScale, earnShareSupply);
        // With no value above the high-water mark, fee allocation cannot change any remainder or
        // the high-water mark. Preserve the target ratchet and observable preview fields while
        // avoiding the full config copy, remainder reads/writes, and allocation loop on the common
        // no-new-yield path.
        if (result.preFeeValuePerEarnShare <= highWaterMark) {
            result.postFeeValuePerEarnShare =
                EarnFeeMath.valuePerEarnShareUp(activeAssets, earnShareScale, earnShareSupply);
            if (storedConfig.excess.enabled) {
                result.targetValuePerEarnShare = EarnFeeMath.targetAt(
                    targetBase, storedConfig.excess.annualTargetRateBps, targetStartedAt, block.timestamp
                );
                if (result.postFeeValuePerEarnShare > result.targetValuePerEarnShare) {
                    targetBase = result.postFeeValuePerEarnShare;
                    targetStartedAt = uint40(block.timestamp);
                }
            }
            emit FeesAccrued(
                currentFeeConfigId, result.activeAssets, 0, 0, 0, highWaterMark, result.targetValuePerEarnShare
            );
            return result;
        }

        FeeConfig memory config = storedConfig;
        uint256[5] memory nextRemainders;
        (result, nextRemainders) = EarnFeeMath.preview(
            EarnFeeMath.Input({
                activeAssets: activeAssets,
                earnShareSupply: earnShareSupply,
                earnShareScale: earnShareScale,
                highWaterMark: highWaterMark,
                targetBase: targetBase,
                targetStartedAt: targetStartedAt,
                timestamp: block.timestamp
            }),
            config,
            _remainders(currentFeeConfigId, storedConfig)
        );
        _storeRemainders(currentFeeConfigId, storedConfig, nextRemainders);

        if (result.totalFeeEarnShares != 0) {
            _creditCalculatedAllocations(currentFeeConfigId, result);
        }
        if (result.preFeeValuePerEarnShare > highWaterMark) highWaterMark = result.postFeeValuePerEarnShare;

        if (config.excess.enabled && result.postFeeValuePerEarnShare > result.targetValuePerEarnShare) {
            targetBase = result.postFeeValuePerEarnShare;
            targetStartedAt = uint40(block.timestamp);
        }

        emit FeesAccrued(
            currentFeeConfigId,
            result.activeAssets,
            result.positiveAccrualAssets,
            result.totalFeeAssets,
            result.totalFeeEarnShares,
            highWaterMark,
            result.targetValuePerEarnShare
        );
    }

    /// @custom:ensures result.allocationCount <= MAX_FIXED_FEE_RECIPIENTS + 1
    /// @custom:ensures result.totalFeeAssets <= EarnFeeMath.allocatedFeeAssets(result)
    /// @custom:ensures result.totalFeeAssets <= result.positiveAccrualAssets && result.activeAssets == returnedValue
    /// @custom:requires _feeConfigs[pending.feeConfigId].fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
    function _previewPendingFees(PendingFeeSnapshot storage pending, uint256 returnedValue)
        internal
        view
        returns (FeePreview memory result, uint256[5] memory nextRemainders)
    {
        uint64 configId = pending.feeConfigId;
        FeeConfig storage storedConfig = _feeConfigs[configId];
        uint256 pendingHighWater = pending.burnedEarnShares == 0
            ? 0
            : Math.mulDiv(pending.highWaterValue, earnShareScale, pending.burnedEarnShares, Math.Rounding.Ceil);
        uint256 pendingTarget = pending.burnedEarnShares == 0
            ? 0
            : Math.mulDiv(pending.targetValue, earnShareScale, pending.burnedEarnShares, Math.Rounding.Ceil);
        return EarnFeeMath.preview(
            EarnFeeMath.Input({
                activeAssets: returnedValue,
                earnShareSupply: pending.burnedEarnShares,
                earnShareScale: earnShareScale,
                highWaterMark: pendingHighWater,
                targetBase: pendingTarget,
                targetStartedAt: pending.requestedAt,
                timestamp: block.timestamp
            }),
            storedConfig,
            _remainders(configId, storedConfig)
        );
    }

    /// @custom:requires fees.allocationCount <= MAX_FIXED_FEE_RECIPIENTS + 1
    /// @custom:ensures totalClaimableEarnShares == old(totalClaimableEarnShares) + EarnFeeMath.allocatedFeeEarnShares(fees)
    /// @custom:ensures sumClaimable == old(sumClaimable) + EarnFeeMath.allocatedFeeEarnShares(fees)
    /// @custom:ensures forall address a :: claimableEarnShares[a] == old(claimableEarnShares[a]) + _specCreditedTo(fees, a)
    function _creditCalculatedAllocations(uint64 configId, FeePreview memory fees) internal {
        /// @custom:invariant i <= fees.allocationCount
        /// @custom:invariant totalClaimableEarnShares == old(totalClaimableEarnShares) + EarnFeeMath.sumFeeEarnShares(fees, i)
        /// @custom:invariant sumClaimable == old(sumClaimable) + EarnFeeMath.sumFeeEarnShares(fees, i)
        /// @custom:invariant forall address a :: claimableEarnShares[a] == old(claimableEarnShares[a]) + _specCreditedToFirst(fees, a, i)
        for (uint256 i = 0; i < fees.allocationCount; i++) {
            uint256 earnShares = fees.allocations[i].feeEarnShares;
            if (earnShares != 0) {
                _creditFeeEarnShares(configId, fees.allocations[i].account, fees.allocations[i].feeAssets, earnShares);
            }
        }
    }

    /// @custom:requires fees.allocationCount <= MAX_FIXED_FEE_RECIPIENTS + 1
    /// @custom:requires fees.totalFeeAssets <= EarnFeeMath.allocatedFeeAssets(fees)
    /// @custom:ensures totalClaimableEarnShares == old(totalClaimableEarnShares) + _specCharged(fees, feeEarnShares)
    /// @custom:ensures sumClaimable == old(sumClaimable) + _specCharged(fees, feeEarnShares)
    /// @custom:ensures forall address a :: claimableEarnShares[a] >= old(claimableEarnShares[a])
    /// @custom:ensures forall address a :: !_specIsRecipient(fees, a) ==> claimableEarnShares[a] == old(claimableEarnShares[a])
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
        /// @custom:invariant i <= last ==> totalClaimableEarnShares == old(totalClaimableEarnShares) + assigned
        /// @custom:invariant i > last ==> totalClaimableEarnShares == old(totalClaimableEarnShares) + feeEarnShares
        /// @custom:invariant totalClaimableEarnShares - old(totalClaimableEarnShares) == sumClaimable - old(sumClaimable)
        /// @custom:invariant forall address a :: claimableEarnShares[a] >= old(claimableEarnShares[a])
        /// @custom:invariant forall address a :: !_specIsRecipient(fees, a) ==> claimableEarnShares[a] == old(claimableEarnShares[a])
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
    }

    /// @custom:ensures claimableEarnShares[account] == old(claimableEarnShares[account]) + earnShares
    /// @custom:ensures forall address a :: a != account ==> claimableEarnShares[a] == old(claimableEarnShares[a])
    /// @custom:ensures totalClaimableEarnShares == old(totalClaimableEarnShares) + earnShares
    /// @custom:ensures sumClaimable == old(sumClaimable) + earnShares
    function _creditFeeEarnShares(uint64 configId, address account, uint256 feeAssets, uint256 earnShares) internal {
        claimableEarnShares[account] += earnShares;
        /// @custom:ghost sumClaimable = sumClaimable + earnShares
        totalClaimableEarnShares += earnShares;
        emit FeeEarnSharesAllocated(configId, account, feeAssets, earnShares);
    }

    /// @notice A charged reopening restores the snapshot's high-water mark and grown target when they are higher.
    /// @custom:ensures normalization == 0 ==> _specBaselines(old(highWaterMark), old(targetBase), old(targetStartedAt))
    /// @custom:ensures normalization != 0 ==> highWaterMark >= _specSnapshotHighWater(pending)
    /// @custom:ensures !_feeConfigs[currentFeeConfigId].excess.enabled ==> targetBase == old(targetBase) && targetStartedAt == old(targetStartedAt)
    /// @custom:ensures (normalization != 0 && _feeConfigs[currentFeeConfigId].excess.enabled) ==> targetStartedAt == uint40(block.timestamp)
    /// @custom:ensures (normalization != 0 && _feeConfigs[currentFeeConfigId].excess.enabled) ==> targetBase >= _specSnapshotTargetNow(pending)
    function _restoreReopenedBaselines(PendingFeeSnapshot storage pending, uint256 normalization) internal {
        if (normalization == 0) return;
        uint256 currentValue = EarnFeeMath.valuePerEarnShareUp(_activeAssets(), earnShareScale, normalization);
        uint256 pendingHighWater =
            Math.mulDiv(pending.highWaterValue, earnShareScale, pending.burnedEarnShares, Math.Rounding.Ceil);
        highWaterMark = currentValue > pendingHighWater ? currentValue : pendingHighWater;

        FeeConfig memory pendingConfig = _feeConfigs[pending.feeConfigId];
        FeeConfig memory activeConfig = _feeConfigs[currentFeeConfigId];
        if (activeConfig.excess.enabled) {
            uint256 pendingTarget =
                Math.mulDiv(pending.targetValue, earnShareScale, pending.burnedEarnShares, Math.Rounding.Ceil);
            uint256 grownTarget = EarnFeeMath.targetAt(
                pendingTarget, pendingConfig.excess.annualTargetRateBps, pending.requestedAt, block.timestamp
            );
            targetBase = currentValue > grownTarget ? currentValue : grownTarget;
            targetStartedAt = uint40(block.timestamp);
        }
    }

    /// @custom:ensures normalization == 0 ==> _specBaselines(old(highWaterMark), old(targetBase), old(targetStartedAt))
    /// @custom:ensures (normalization != 0 && _feeConfigs[currentFeeConfigId].excess.enabled) ==> _specTargetRestarted()
    /// @custom:ensures (normalization != 0 && !_feeConfigs[currentFeeConfigId].excess.enabled) ==> targetBase == 0 && targetStartedAt == 0
    function _initializeReopenedBaselines(uint256 normalization) internal {
        if (normalization == 0) return;
        uint256 currentValue = EarnFeeMath.valuePerEarnShareUp(_activeAssets(), earnShareScale, normalization);
        highWaterMark = currentValue;

        FeeConfig memory activeConfig = _feeConfigs[currentFeeConfigId];
        if (activeConfig.excess.enabled) {
            targetBase = currentValue;
            targetStartedAt = uint40(block.timestamp);
        } else {
            targetBase = 0;
            targetStartedAt = 0;
        }
        emit FeeBaselinesInitialized(highWaterMark, targetBase, targetStartedAt);
    }

    /// @custom:ensures _feeConfigs[currentFeeConfigId].excess.enabled ==> targetBase == highWaterMark
    /// @custom:ensures !_feeConfigs[currentFeeConfigId].excess.enabled ==> targetBase == 0 && targetStartedAt == 0
    /// @custom:ensures targetStartedAt == 0 || targetStartedAt == uint40(block.timestamp)
    /// @custom:ensures highWaterMark == 0 || targetBase == 0 || targetStartedAt == uint40(block.timestamp)
    function _initializeFeeBaselines() internal {
        uint256 earnShareSupply = IEarnShare(earnShare).totalSupply();
        if (earnShareSupply == 0) {
            highWaterMark = 0;
            targetBase = 0;
            targetStartedAt = 0;
            return;
        }
        uint256 valuePerShare = EarnFeeMath.valuePerEarnShareUp(_activeAssets(), earnShareScale, earnShareSupply);
        highWaterMark = valuePerShare;
        if (_feeConfigs[currentFeeConfigId].excess.enabled) {
            targetBase = valuePerShare;
            targetStartedAt = uint40(block.timestamp);
        } else {
            targetBase = 0;
            targetStartedAt = 0;
        }
        emit FeeBaselinesInitialized(highWaterMark, targetBase, targetStartedAt);
    }

    /// @notice Principal entry ratchets the baselines up only: it never charges or lowers them (fees.md).
    /// @custom:ensures highWaterMark >= old(highWaterMark)
    /// @custom:ensures targetBase != old(targetBase) ==> targetBase > old(_specTargetNow()) && targetStartedAt == uint40(block.timestamp)
    /// @custom:ensures targetBase == old(targetBase) ==> targetStartedAt == old(targetStartedAt)
    /// @custom:ensures !_feeConfigs[currentFeeConfigId].excess.enabled ==> targetBase == old(targetBase)
    function _updateBaselinesAfterPrincipalEntry() internal {
        uint256 earnShareSupply = IEarnShare(earnShare).totalSupply();
        if (earnShareSupply == 0) return;

        uint256 valuePerShare = EarnFeeMath.valuePerEarnShareUp(_activeAssets(), earnShareScale, earnShareSupply);
        if (valuePerShare > highWaterMark) highWaterMark = valuePerShare;

        FeeConfig memory config = _feeConfigs[currentFeeConfigId];
        if (config.excess.enabled) {
            uint256 currentTarget =
                EarnFeeMath.targetAt(targetBase, config.excess.annualTargetRateBps, targetStartedAt, block.timestamp);
            if (valuePerShare > currentTarget) {
                targetBase = valuePerShare;
                targetStartedAt = uint40(block.timestamp);
            }
        }
        emit FeeBaselinesInitialized(highWaterMark, targetBase, targetStartedAt);
    }

    /// @custom:ensures result == _specFeesActive()
    function _feesActive() internal view returns (bool) {
        if (feesDisabled) return false;
        FeeConfig storage config = _feeConfigs[currentFeeConfigId];
        return config.fixedFeeCount != 0 || config.excess.enabled;
    }

    /// @custom:ensures result == (config.fixedFeeCount != 0 || config.excess.enabled)
    function _configHasFees(FeeConfig memory config) internal pure returns (bool) {
        return config.fixedFeeCount != 0 || config.excess.enabled;
    }

    /// @notice The structural rules of fees.md, "Configuration".
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
    function _invalidRecipient(address account) internal view returns (bool) {
        return account == address(0) || account == address(this) || account == earnVault;
    }

    /// @custom:ensures _specStored(configId, config)
    function _storeFeeConfig(uint64 configId, FeeConfig memory config) internal {
        FeeConfig storage stored = _feeConfigs[configId];
        stored.fixedFeeCount = config.fixedFeeCount;
        /// @custom:invariant i <= MAX_FIXED_FEE_RECIPIENTS && _feeConfigs[configId].fixedFeeCount == config.fixedFeeCount
        /// @custom:invariant forall uint256 k :: k < i ==> _specStoredFixedFee(configId, config, k)
        for (uint256 i = 0; i < MAX_FIXED_FEE_RECIPIENTS; i++) {
            stored.fixedFees[i] = config.fixedFees[i];
        }
        stored.excess = config.excess;
    }

    /// @custom:requires config.fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
    /// @custom:ensures forall uint8 k :: k < MAX_FIXED_FEE_RECIPIENTS ==> remainders[k] == (k < config.fixedFeeCount ? _feeRemainders[configId][k] : 0)
    /// @custom:ensures remainders[MAX_FIXED_FEE_RECIPIENTS] == (config.excess.enabled ? _feeRemainders[configId][4] : 0)
    function _remainders(uint64 configId, FeeConfig storage config)
        internal
        view
        returns (uint256[5] memory remainders)
    {
        /// @custom:invariant i <= config.fixedFeeCount
        /// @custom:invariant forall uint8 k :: k < MAX_FIXED_FEE_RECIPIENTS ==> remainders[k] == (k < i ? _feeRemainders[configId][k] : 0)
        /// @custom:invariant remainders[MAX_FIXED_FEE_RECIPIENTS] == 0
        for (uint8 i = 0; i < config.fixedFeeCount; i++) {
            remainders[i] = _feeRemainders[configId][i];
        }
        if (config.excess.enabled) remainders[4] = _feeRemainders[configId][4];
    }

    /// @custom:requires config.fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
    /// @custom:ensures forall uint8 k :: k < config.fixedFeeCount ==> _feeRemainders[configId][k] == remainders[k]
    /// @custom:ensures config.excess.enabled ==> _feeRemainders[configId][4] == remainders[4]
    /// @custom:ensures !config.excess.enabled ==> _feeRemainders[configId][4] == old(_feeRemainders[configId][4])
    /// @custom:ensures forall uint64 c, uint8 k :: (c != configId || (k >= config.fixedFeeCount && k != 4)) ==> _feeRemainders[c][k] == old(_feeRemainders[c][k])
    function _storeRemainders(uint64 configId, FeeConfig storage config, uint256[5] memory remainders) internal {
        /// @custom:invariant i <= config.fixedFeeCount
        /// @custom:invariant forall uint8 k :: k < i ==> _feeRemainders[configId][k] == remainders[k]
        /// @custom:invariant forall uint64 c, uint8 k :: (c != configId || k >= i) ==> _feeRemainders[c][k] == old(_feeRemainders[c][k])
        for (uint8 i = 0; i < config.fixedFeeCount; i++) {
            _feeRemainders[configId][i] = remainders[i];
        }
        if (config.excess.enabled) _feeRemainders[configId][4] = remainders[4];
    }

    /// @custom:ensures (feesDisabled || _openRequestsByFeeConfig[currentFeeConfigId] == 0) ==> _specRemaindersWaived(currentFeeConfigId)
    /// @custom:ensures !(feesDisabled || _openRequestsByFeeConfig[currentFeeConfigId] == 0) ==> forall uint64 c, uint8 k :: _feeRemainders[c][k] == old(_feeRemainders[c][k])
    function _waiveCurrentRemainders() internal {
        if (!feesDisabled && _openRequestsByFeeConfig[currentFeeConfigId] != 0) return;
        _waiveRemainders(currentFeeConfigId);
    }

    /// @notice A historical configuration's remainders are waived when its last open request closes.
    /// @custom:ensures _specHistoricalAndClosed(configId) ==> _specRemaindersWaived(configId)
    /// @custom:ensures !_specHistoricalAndClosed(configId) ==> forall uint64 c, uint8 k :: _feeRemainders[c][k] == old(_feeRemainders[c][k])
    function _waiveClosedHistoricalRemainders(uint64 configId) internal {
        if (configId == 0 || configId == currentFeeConfigId || _openRequestsByFeeConfig[configId] != 0) return;
        _waiveRemainders(configId);
    }

    /// @custom:ensures _specRemaindersWaived(configId)
    /// @custom:ensures forall uint64 c, uint8 k :: (c != configId || k > MAX_FIXED_FEE_RECIPIENTS) ==> _feeRemainders[c][k] == old(_feeRemainders[c][k])
    /// @custom:succeeds-if true
    function _waiveRemainders(uint64 configId) internal {
        /// @custom:invariant i <= MAX_FIXED_FEE_RECIPIENTS + 1
        /// @custom:invariant forall uint8 k :: k < i ==> _feeRemainders[configId][k] == 0
        /// @custom:invariant forall uint64 c, uint8 k :: (c != configId || k >= i) ==> _feeRemainders[c][k] == old(_feeRemainders[c][k])
        for (uint8 i = 0; i < 5; i++) {
            uint256 remainder = _feeRemainders[configId][i];
            if (remainder == 0) continue;
            delete _feeRemainders[configId][i];
            emit FeeDustWaived(configId, i, remainder);
        }
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
        return !feesDisabled && _specCharges(currentFeeConfigId);
    }

    /// @custom:spec Whether the configuration installed under `configId` charges any fee.
    function _specCharges(uint64 configId) internal view returns (bool) {
        return _feeConfigs[configId].fixedFeeCount != 0 || _feeConfigs[configId].excess.enabled;
    }

    /// @custom:spec Whether `configId` names a configuration that was installed.
    function _specInstalled(uint64 configId) internal view returns (bool) {
        return configId >= 1 && configId <= currentFeeConfigId;
    }

    /// @custom:spec The structural bounds of fees.md: at most four fixed fees, fixed rates summing to at most
    ///     100%, and excess and target rates of at most 100% each.
    function _specWithinFeeBounds(uint64 configId) internal view returns (bool) {
        return _feeConfigs[configId].fixedFeeCount <= MAX_FIXED_FEE_RECIPIENTS
            && _specStoredRateTotal(configId) <= BPS_DENOMINATOR
            && _feeConfigs[configId].excess.excessFeeRateBps <= BPS_DENOMINATOR
            && _feeConfigs[configId].excess.annualTargetRateBps <= BPS_DENOMINATOR;
    }

    /// @custom:spec Sum of the stored configuration's four fixed rates.
    function _specStoredRateTotal(uint64 configId) internal view returns (uint256) {
        return uint256(_feeConfigs[configId].fixedFees[0].rateBps) + _feeConfigs[configId].fixedFees[1].rateBps
            + _feeConfigs[configId].fixedFees[2].rateBps + _feeConfigs[configId].fixedFees[3].rateBps;
    }

    /// @custom:spec Every rule `_validateFeeConfig` enforces (fees.md, "Configuration").
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
        return _feeConfigs[configId].fixedFeeCount == config.fixedFeeCount && _specStoredFixedFee(configId, config, 0)
            && _specStoredFixedFee(configId, config, 1) && _specStoredFixedFee(configId, config, 2)
            && _specStoredFixedFee(configId, config, 3) && _feeConfigs[configId].excess.enabled == config.excess.enabled
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
        return highWaterMark == highWater && targetBase == base && targetStartedAt == startedAt;
    }

    /// @custom:spec The current configuration's target, grown to now.
    function _specTargetNow() internal view returns (uint256) {
        return EarnFeeMath.targetFrom(
            targetBase, _feeConfigs[currentFeeConfigId].excess.annualTargetRateBps, targetStartedAt, block.timestamp
        );
    }

    /// @custom:spec The target restarts now at the high-water mark.
    function _specTargetRestarted() internal view returns (bool) {
        return targetBase == highWaterMark && targetStartedAt == uint40(block.timestamp);
    }

    /// @custom:spec A checkpoint moves the high-water mark to the post-fee value when value rose above it (fees.md,
    ///     "High-water mark and target").
    function _specHighWaterCheckpointed(FeePreview memory fees, uint256 oldHighWater) internal view returns (bool) {
        return
            highWaterMark
                == (fees.preFeeValuePerEarnShare > oldHighWater ? fees.postFeeValuePerEarnShare : oldHighWater);
    }

    /// @custom:spec A checkpoint restarts an excess target that the post-fee value exceeds.
    function _specTargetRatchets(FeePreview memory fees) internal view returns (bool) {
        return
            _feeConfigs[currentFeeConfigId].excess.enabled
                && fees.postFeeValuePerEarnShare > fees.targetValuePerEarnShare;
    }

    /// @custom:spec The target restarts now at `value`.
    function _specTargetRestartedAt(uint256 value) internal view returns (bool) {
        return targetBase == value && targetStartedAt == uint40(block.timestamp);
    }

    /// @custom:spec Whether a request's snapshot is still charged when it settles: open, recorded since fees were
    ///     last disabled, fees enabled, and its configuration charging a fee.
    function _specChargesPending(bytes32 requestId) internal view returns (bool) {
        return _pendingFeeSnapshots[requestId].open && _requestDisableEpoch[requestId] == _disableEpoch && !feesDisabled
            && _specCharges(_pendingFeeSnapshots[requestId].feeConfigId);
    }

    /// @custom:spec The request's snapshot was just recorded from the current fee state (fees.md, "Async exits").
    function _specRecorded(bytes32 requestId, uint256 burnedEarnShares, uint256 requestValue)
        internal
        view
        returns (bool)
    {
        return _pendingFeeSnapshots[requestId].open && _pendingFeeSnapshots[requestId].feeConfigId == currentFeeConfigId
            && _requestDisableEpoch[requestId] == _disableEpoch
            && _pendingFeeSnapshots[requestId].burnedEarnShares == burnedEarnShares
            && _pendingFeeSnapshots[requestId].requestValue == requestValue
            && _pendingFeeSnapshots[requestId].requestedAt == uint40(block.timestamp)
            && _pendingFeeSnapshots[requestId].highWaterValue
                == EarnFeeMath.ceilDiv(highWaterMark * burnedEarnShares, earnShareScale)
            && (!_feeConfigs[currentFeeConfigId].excess.enabled
                || _pendingFeeSnapshots[requestId].targetValue
                    == EarnFeeMath.ceilDiv(_specTargetNow() * burnedEarnShares, earnShareScale));
    }

    /// @custom:spec The request's snapshot is deleted and its configuration has one open request fewer; a
    ///     historical configuration left without open requests has its remainders waived.
    function _specClosed(bytes32 requestId, uint64 configId, uint256 openBefore) internal view returns (bool) {
        return !_pendingFeeSnapshots[requestId].open && _pendingFeeSnapshots[requestId].burnedEarnShares == 0
            && _pendingFeeSnapshots[requestId].highWaterValue == 0 && _pendingFeeSnapshots[requestId].targetValue == 0
            && _pendingFeeSnapshots[requestId].feeConfigId == 0 && _requestDisableEpoch[requestId] == 0
            && _openRequestsByFeeConfig[configId] == openBefore - 1
            && (!_specHistoricalAndClosed(configId) || _specRemaindersWaived(configId));
    }

    /// @custom:spec Whether `configId` is a replaced configuration that no open request references.
    function _specHistoricalAndClosed(uint64 configId) internal view returns (bool) {
        return configId != 0 && configId != currentFeeConfigId && _openRequestsByFeeConfig[configId] == 0;
    }

    /// @custom:spec The snapshot's high-water mark per EarnShare, rounded up.
    function _specSnapshotHighWater(PendingFeeSnapshot storage pending) internal view returns (uint256) {
        return EarnFeeMath.ceilDiv(pending.highWaterValue * earnShareScale, pending.burnedEarnShares);
    }

    /// @custom:spec The snapshot's target per EarnShare, grown from the request time to now.
    function _specSnapshotTargetNow(PendingFeeSnapshot storage pending) internal view returns (uint256) {
        return EarnFeeMath.targetFrom(
            EarnFeeMath.ceilDiv(pending.targetValue * earnShareScale, pending.burnedEarnShares),
            _feeConfigs[pending.feeConfigId].excess.annualTargetRateBps,
            pending.requestedAt,
            block.timestamp
        );
    }

    /// @custom:spec Every remainder slot of configuration `configId` is zero.
    function _specRemaindersWaived(uint64 configId) internal view returns (bool) {
        return _feeRemainders[configId][0] == 0 && _feeRemainders[configId][1] == 0 && _feeRemainders[configId][2] == 0
            && _feeRemainders[configId][3] == 0 && _feeRemainders[configId][4] == 0;
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
}
