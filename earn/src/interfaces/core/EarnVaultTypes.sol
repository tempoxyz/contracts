// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Deployment-fixed policy for the EarnVault's whole-pool engine migration seam.
enum EngineMigrationMode {
    UserOnly,
    OperatorEnabled
}

/// @notice Initial emergency roles and controls for one Earn deployment.
struct EarnVaultControls {
    /// @dev Optional fast risk-reducing seat. May pause new exposure, but never unpause or move backing.
    ///      Set to zero for operator-only pause authority.
    address emergencyGuardian;
    /// @dev Optional narrow liveness seat. May cancel open async requests only to their stored receivers.
    ///      Set to zero for requester-only cancellation.
    address asyncJanitor;
    /// @dev Initial maximum active assets after a voluntary inflow. The operator may update it later.
    ///      Zero disables the limit.
    ///      Passive yield may move managed assets above the limit; exits remain available and reopen capacity.
    uint256 maxManagedAssets;
    /// @dev Fixed forever at EarnVault initialization; there is intentionally no setter.
    EngineMigrationMode migrationMode;
}

/// @notice Initialization-time configuration for the protected distributor fee authority.
/// @dev A zero distributor disables the role and requires a zero update delay.
struct DistributorConfig {
    /// @dev Initial distributor authority. The role may later transfer itself through a two-step handoff.
    address distributor;
    /// @dev Nonzero delay between scheduling and executing a distributor fee update.
    uint40 updateDelay;
}

/// @notice Timelocked prospective update to the distributor's reserved fixed-fee item.
struct DistributorFeeUpdate {
    address recipient;
    uint16 rateBps;
    uint40 executableAt;
    bool pending;
}
