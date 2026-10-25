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

    function shouldChargeRedeem(bytes32 requestId) external view returns (bool) {
        PendingFeeSnapshot storage pending = _pendingFeeSnapshots[requestId];
        return pending.open && _requestDisableEpoch[requestId] == _disableEpoch && !feesDisabled
            && _configHasFees(_feeConfigs[pending.feeConfigId]) && _feeValuationFresh();
    }

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

    function accrueFees() external onlyEarnVault returns (FeePreview memory result) {
        result = _accrueFees();
    }

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
    function validateFeeConfig(FeeConfig calldata config) external view {
        _validateFeeConfig(config);
    }

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
    function initializeBaselines() external onlyEarnVault {
        if (_feesActive()) _updateBaselinesAfterPrincipalEntry();
    }

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

    function closeRedeemRequest(bytes32 requestId) external onlyEarnVault {
        PendingFeeSnapshot storage pending = _pendingFeeSnapshots[requestId];
        if (!pending.open) return;
        uint64 configId = pending.feeConfigId;
        delete _pendingFeeSnapshots[requestId];
        delete _requestDisableEpoch[requestId];
        _openRequestsByFeeConfig[configId] -= 1;
        _waiveClosedHistoricalRemainders(configId);
    }

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

    function claim(address to, uint256 earnShares) external nonReentrant {
        if (to == address(0) || to == address(this) || to == earnVault) revert InvalidFeeClaimReceiver();
        if (earnShares == 0) revert ZeroAmount();
        uint256 claimable = claimableEarnShares[msg.sender];
        if (earnShares > claimable) revert InsufficientClaimableEarnShares();

        claimableEarnShares[msg.sender] = claimable - earnShares;
        totalClaimableEarnShares -= earnShares;
        _safeTransfer(earnShare, to, earnShares);
        emit FeeEarnSharesClaimed(msg.sender, to, earnShares);
    }

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

    function _creditCalculatedAllocations(uint64 configId, FeePreview memory fees) internal {
        for (uint256 i = 0; i < fees.allocationCount; i++) {
            uint256 earnShares = fees.allocations[i].feeEarnShares;
            if (earnShares != 0) {
                _creditFeeEarnShares(configId, fees.allocations[i].account, fees.allocations[i].feeAssets, earnShares);
            }
        }
    }

    function _creditAllocatedFeeEarnShares(uint64 configId, FeePreview memory fees, uint256 feeEarnShares) internal {
        if (feeEarnShares == 0 || fees.totalFeeAssets == 0) return;
        uint256 assigned;
        uint256 last = type(uint256).max;
        for (uint256 i = 0; i < fees.allocationCount; i++) {
            if (fees.allocations[i].feeAssets != 0) last = i;
        }
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

    function _creditFeeEarnShares(uint64 configId, address account, uint256 feeAssets, uint256 earnShares) internal {
        claimableEarnShares[account] += earnShares;
        totalClaimableEarnShares += earnShares;
        emit FeeEarnSharesAllocated(configId, account, feeAssets, earnShares);
    }

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

    function _feesActive() internal view returns (bool) {
        if (feesDisabled) return false;
        FeeConfig storage config = _feeConfigs[currentFeeConfigId];
        return config.fixedFeeCount != 0 || config.excess.enabled;
    }

    function _configHasFees(FeeConfig memory config) internal pure returns (bool) {
        return config.fixedFeeCount != 0 || config.excess.enabled;
    }

    function _validateFeeConfig(FeeConfig memory config) internal view {
        if (config.fixedFeeCount > MAX_FIXED_FEE_RECIPIENTS) revert InvalidFeeConfiguration();
        uint256 totalFixed;
        for (uint256 i = 0; i < config.fixedFeeCount; i++) {
            address account = config.fixedFees[i].account;
            uint256 rateBps = config.fixedFees[i].rateBps;
            if (_invalidRecipient(account) || rateBps == 0) revert InvalidFeeConfiguration();
            for (uint256 j = 0; j < i; j++) {
                if (config.fixedFees[j].account == account) revert InvalidFeeConfiguration();
            }
            totalFixed += rateBps;
        }
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

    function _invalidRecipient(address account) internal view returns (bool) {
        return account == address(0) || account == address(this) || account == earnVault;
    }

    function _storeFeeConfig(uint64 configId, FeeConfig memory config) internal {
        FeeConfig storage stored = _feeConfigs[configId];
        stored.fixedFeeCount = config.fixedFeeCount;
        for (uint256 i = 0; i < MAX_FIXED_FEE_RECIPIENTS; i++) {
            stored.fixedFees[i] = config.fixedFees[i];
        }
        stored.excess = config.excess;
    }

    function _remainders(uint64 configId, FeeConfig storage config)
        internal
        view
        returns (uint256[5] memory remainders)
    {
        for (uint8 i = 0; i < config.fixedFeeCount; i++) {
            remainders[i] = _feeRemainders[configId][i];
        }
        if (config.excess.enabled) remainders[4] = _feeRemainders[configId][4];
    }

    function _storeRemainders(uint64 configId, FeeConfig storage config, uint256[5] memory remainders) internal {
        for (uint8 i = 0; i < config.fixedFeeCount; i++) {
            _feeRemainders[configId][i] = remainders[i];
        }
        if (config.excess.enabled) _feeRemainders[configId][4] = remainders[4];
    }

    function _waiveCurrentRemainders() internal {
        if (!feesDisabled && _openRequestsByFeeConfig[currentFeeConfigId] != 0) return;
        _waiveRemainders(currentFeeConfigId);
    }

    function _waiveClosedHistoricalRemainders(uint64 configId) internal {
        if (configId == 0 || configId == currentFeeConfigId || _openRequestsByFeeConfig[configId] != 0) return;
        _waiveRemainders(configId);
    }

    function _waiveRemainders(uint64 configId) internal {
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
}
