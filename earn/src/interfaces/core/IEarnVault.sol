// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FeeConfig } from "./EarnFeeTypes.sol";
import { DistributorFeeUpdate, EngineMigrationMode } from "./EarnVaultTypes.sol";

/// @notice Persistent EarnVault surface consumed by scoped routers and supporting contracts.
/// @dev Extends the canonical immediate-execution surface with burn-at-request async claims, permissionless
///      backing contributions, configurable positive-accrual fees, and the operator-controlled engine seam.
interface IEarnVault {
    /// @notice Complete configuration snapshot emitted when an EarnVault proxy is initialized.
    /// @dev This is emitted before the factory completes EarnShare issuer and policy setup; use
    ///      `EarnFactory.EarnStackDeployed` as the final atomic stack-deployment signal.
    event EarnVaultInitialized(
        address indexed engine,
        address indexed earnShare,
        address indexed earnFees,
        address operator,
        address emergencyGuardian,
        address asyncJanitor,
        uint256 maxManagedAssets,
        EngineMigrationMode migrationMode,
        address distributor,
        uint40 distributorUpdateDelay,
        address distributorFeeRecipient,
        uint16 distributorFeeRateBps
    );
    event Deposited(address indexed caller, address indexed receiver, uint256 assets, uint256 earnShares);
    event DepositPauseChanged(address indexed caller, bool paused);
    event EmergencyRolesChanged(address indexed emergencyGuardian, address indexed asyncJanitor);
    event OperatorTransferStarted(address indexed operator, address indexed pendingOperator);
    event OperatorTransferCancelled(address indexed operator, address indexed pendingOperator);
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event DistributorFeeUpdateScheduled(
        address indexed distributor, address indexed recipient, uint16 rateBps, uint40 executableAt
    );
    event DistributorFeeUpdateCancelled(address indexed distributor);
    event DistributorFeeUpdated(address indexed recipient, uint16 rateBps, uint64 indexed feeConfigId);
    event DistributorTransferStarted(address indexed distributor, address indexed pendingDistributor);
    event DistributorTransferCancelled(address indexed distributor, address indexed pendingDistributor);
    event DistributorTransferred(address indexed previousDistributor, address indexed newDistributor);
    event MaxManagedAssetsChanged(uint256 previousMaxManagedAssets, uint256 newMaxManagedAssets);
    event EngineShareSurplusAbsorbed(
        address indexed caller, uint256 engineShares, uint256 anchorEngineShares, uint256 anchorEarnShares
    );
    event EngineShareShortfallReconciled(
        address indexed engine,
        uint256 previousManagedEngineShares,
        uint256 observedRawEngineShares,
        uint256 shortfallEngineShares,
        uint256 totalEarnShares
    );
    event VenueSharesDeposited(
        address indexed caller,
        address indexed receiver,
        uint256 requestedVenueShares,
        uint256 receivedEngineShares,
        uint256 earnShares
    );
    event Redeemed(address indexed caller, address indexed receiver, uint256 earnShares, uint256 assets);
    event WithdrewExact(address indexed caller, address indexed receiver, uint256 assets, uint256 earnSharesBurned);

    function accrueFees() external returns (uint256 feeAssets, uint256 feeEarnShares);
    function MAX_REWARD_RATE_MULTIPLIER() external view returns (uint256);
    function absorbEngineShareSurplus(uint256 engineShares) external;
    function asset() external view returns (address);
    function earnFees() external view returns (address);
    function contribute(uint256 assets) external returns (uint256 engineShares);
    /// @notice Uses the caller as receiver; suitable for self-recipient access-key scopes.
    function deposit(uint256 assets, uint256 minEarnShares) external returns (uint256 earnShares);
    function deposit(uint256 assets, address receiver, uint256 minEarnShares) external returns (uint256 earnShares);
    /// @notice Uses the caller as receiver; suitable for self-recipient access-key scopes.
    function depositVenueShares(uint256 venueShares, uint256 minEarnShares) external returns (uint256 earnShares);
    function depositVenueShares(uint256 venueShares, address receiver, uint256 minEarnShares)
        external
        returns (uint256 earnShares);
    function disableFees() external;
    function distributor() external view returns (address);
    function pendingDistributor() external view returns (address);
    function distributorFee() external view returns (address recipient, uint16 rateBps);
    function distributorUpdateDelay() external view returns (uint40);
    function pendingDistributorFeeUpdate() external view returns (DistributorFeeUpdate memory);
    function scheduleDistributorFeeUpdate(address recipient, uint16 rateBps) external;
    function cancelDistributorFeeUpdate() external;
    function executeDistributorFeeUpdate() external returns (uint64 feeConfigId);
    function transferDistributor(address newDistributor) external;
    function cancelDistributorTransfer() external;
    function acceptDistributor() external;
    function emergencyGuardian() external view returns (address);
    function engine() external view returns (address);
    function engineMigrationMode() external view returns (EngineMigrationMode);
    function engineShares() external view returns (uint256);
    function rawEngineShares() external view returns (uint256);
    function surplusEngineShares() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function isFeeValuationFresh() external view returns (bool);
    function isAccountingAligned() external view returns (bool);
    function operator() external view returns (address);
    function pendingOperator() external view returns (address);
    function transferOperator(address newOperator) external;
    function cancelOperatorTransfer() external;
    function acceptOperator() external;
    function asyncJanitor() external view returns (address);
    function depositsPaused() external view returns (bool);
    function maxManagedAssets() external view returns (uint256);
    function remainingDepositCapacity() external view returns (uint256 assets);
    function openRedeemRequestCount() external view returns (uint256);
    function previewRedeem(uint256 earnShares) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 earnShares);
    function normalizedRewardRate() external view returns (uint256);
    function rewardRateBaseline() external view returns (uint256);
    /// @notice Uses the caller as receiver; suitable for self-recipient access-key scopes.
    function redeem(uint256 earnShares, uint256 minAssets) external returns (uint256 assets);
    function redeem(uint256 earnShares, address receiver, uint256 minAssets) external returns (uint256 assets);
    function convertEngineSharesToEarnShares(uint256 engineShares) external view returns (uint256 earnShares);
    function totalEarnShares() external view returns (uint256);
    function earnShare() external view returns (address);
    function setFeeConfig(FeeConfig calldata config) external returns (uint64 configId);
    function convertToEngineShares(uint256 earnShares) external view returns (uint256 engineShares);
    function setEmergencyRoles(address newGuardian, address newJanitor) external;
    function setDepositsPaused(bool paused) external;
    function setMaxManagedAssets(uint256 newMaxManagedAssets) external;
    /// @notice Uses the caller as receiver; suitable for self-recipient access-key scopes.
    function withdrawExact(uint256 assets, uint256 maxEarnShares) external returns (uint256 earnSharesBurned);
    function withdrawExact(uint256 assets, address receiver, uint256 maxEarnShares)
        external
        returns (uint256 earnSharesBurned);

    // Async extension (burn-at-request pending-claim model).
    /// @notice Uses the caller as receiver; suitable for self-recipient access-key scopes.
    function requestRedeem(uint256 earnShares, bytes calldata engineData) external returns (bytes32 requestId);
    /// @notice Requests redemption to an explicit receiver; preferred parameter order.
    function requestRedeem(uint256 earnShares, address receiver, bytes calldata engineData)
        external
        returns (bytes32 requestId);
    /// @notice Legacy parameter order, equivalent to the receiver-first overload.
    function requestRedeem(uint256 earnShares, bytes calldata engineData, address receiver)
        external
        returns (bytes32 requestId);
    function cancelRedeem(bytes32 requestId, uint256 minReceiverEarnShares) external;

    // Engine seam. Operator-only when the deployment-fixed migration mode enables it. Migration drains
    // all raw old-engine custody while preserving the managed/surplus split in the new denomination
    // within one basis point of value. Any raw-custody migration requires replacement-share and retained-asset
    // floors; when active backing exists, its managed portion must independently meet both floors. An
    // incompatible coarse replacement denomination reverts.
    function migrateEngine(address newEngine, uint256 minNewEngineShares, uint256 minAssetsRetained)
        external
        returns (uint256 newEngineShares);
}
