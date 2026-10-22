// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Factory, ITIP20IssuerAccess } from "../interfaces/external/tempo/ITIP20Factory.sol";
import {
    ALWAYS_ALLOW_POLICY_ID,
    ITIP20PolicyAccess,
    ITIP403Registry,
    TIP403_REGISTRY_ADDRESS,
    WHITELIST_POLICY_TYPE
} from "../interfaces/external/tempo/ITIP403Registry.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IEarnEngine } from "../interfaces/engines/IEarnEngine.sol";
import { DistributorConfig, EarnVaultControls, EngineMigrationMode } from "../interfaces/core/EarnVaultTypes.sol";
import { FeeConfig } from "../interfaces/core/EarnFeeTypes.sol";
import { IEarnFees } from "../interfaces/core/IEarnFees.sol";
import { EarnFees } from "./EarnFees.sol";
import { EarnVault } from "./EarnVault.sol";

/// @notice Atomic deployer for canonical Earn v1 stacks.
/// @dev One call deploys the vault-backed TIP20 EarnShare and its `EarnVault`, then wires roles so
///      the supply invariant cannot be misconfigured: `EarnVault` receives the EXCLUSIVE TIP20
///      issuer (mint/burn) role, fixes the initial transfer policy, and relinquishes all EarnShare
///      administration. The EarnVault is wired to `params.engine` as its INITIAL engine. The
///      deployment-fixed migration mode determines whether the operator may later swap that engine
///      or users must opt into a replacement Earn stack individually.
///
///      ROUTERS ARE DEPLOYED SEPARATELY (DELIBERATE). The canonical `SingleZoneEarnRouter` binds one
///      Zone and the resulting EarnVault immutably, and enforces same-source-Zone callback delivery
///      without token roles, mutable configuration, or factory involvement.
///      The atomic guarantee the factory exists to protect is the ISSUER wiring (the EarnVault is the
///      sole minter/burner; deployer admin revoked; no replacement admin installed).
///
///      WHY THE SPLIT: embedding the EarnVault implementation in this factory pushes deployment gas beyond
///      Tempo's per-transaction limit. The deployer supplies one separately deployed, locked implementation;
///      the factory fixes that address immutably and creates non-upgradeable ERC-1967 proxies for each stack,
///      preserving the atomic token+EarnVault+issuer story. A caller-chosen `deploymentId` gives each
///      logical stack a stable deterministic namespace. The initial engine, owner, and fees also bind
///      the salt so an unrelated configuration cannot squat that namespace, while separately
///      deployed, replaceable periphery does not affect the EarnShare address.
contract EarnFactory {
    struct DeployParams {
        bytes32 deploymentId;
        address engine;
        address owner;
        EarnVaultControls controls;
        DistributorConfig distributorConfig;
        FeeConfig fees;
        /// @notice Optional protected simple-whitelist policy. Zero retains the default always-allow policy.
        uint64 transferPolicyId;
    }

    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 public constant EARN_SHARE_SALT_DOMAIN = keccak256("EarnFactory.earnShare.v1");
    bytes32 public constant FEES_SALT_DOMAIN = keccak256("EarnFactory.fees.v1");
    /// @notice TIP-20 currency for every EarnShare. Deliberately empty rather than the underlying
    ///         asset's currency: EarnShares are not 1:1 convertible with each other or the asset, and a
    ///         `USD` EarnShare would become eligible for fee payment and the stablecoin DEX.
    string public constant EARN_SHARE_CURRENCY = "";

    address public immutable tip20Factory;
    address public immutable earnVaultImplementation;
    address public immutable earnFeesImplementation;

    event EarnStackDeployed(
        address indexed earnVault,
        address indexed earnShare,
        address indexed earnFees,
        address engine,
        address asset,
        address owner,
        bytes32 deploymentId,
        address emergencyGuardian,
        address asyncJanitor,
        uint256 maxManagedAssets,
        EngineMigrationMode migrationMode,
        uint64 transferPolicyId,
        bytes32 earnShareSalt,
        bytes32 controlConfigHash,
        bytes32 feeConfigHash,
        bytes32 earnFeesSalt
    );

    error AdminRelinquishmentFailed();
    error EmptyDeploymentId();
    error EmptyEarnShareMetadata();
    error EngineAlreadyBound(address earnVault);
    error FactoryCannotBeFinalOwner();
    error InvalidEngine();
    error InvalidDistributorConfig();
    error InvalidEarnVaultImplementation();
    error InvalidEarnFeesImplementation();
    error InvalidTransferPolicy(uint64 policyId);
    error IssuerGrantFailed();
    error TransferPolicyMismatch(uint64 expected, uint64 actual);
    error UnsupportedTransferPolicy(uint64 policyId, uint8 policyType);
    error EarnShareAlreadyExists(address earnShare);
    error EarnShareSupplyNotZero();
    error ZeroAddress();

    constructor(address tip20Factory_, address earnVaultImplementation_, address earnFeesImplementation_) {
        if (
            tip20Factory_ == address(0) || earnVaultImplementation_ == address(0)
                || earnFeesImplementation_ == address(0)
        ) revert ZeroAddress();
        if (earnVaultImplementation_.code.length == 0) revert InvalidEarnVaultImplementation();
        if (earnFeesImplementation_.code.length == 0) revert InvalidEarnFeesImplementation();
        tip20Factory = tip20Factory_;
        earnVaultImplementation = earnVaultImplementation_;
        earnFeesImplementation = earnFeesImplementation_;
    }

    /// @notice Atomically create the EarnShare and its `EarnVault`, grant the EarnVault the sole
    ///         issuer role, fix the transfer policy, and relinquish EarnShare administration. Earn
    ///         routers are deployed separately (see contract NatSpec) and consume the factory-produced
    ///         EarnVault.
    /// @dev The EarnShare salt is derived from `deploymentId` and the immutable stack configuration,
    ///      so only an exact copy can preempt the predicted token address. `params.owner` is also the
    ///      EarnVault's operator seat. Emergency pause and async-cancellation authority are
    ///      separately bounded by `params.controls`. A nonzero transfer policy must be an existing
    ///      simple whitelist. Its external administrator remains responsible for authorizing the
    ///      generated core, later router, and eligible holders before activation.
    function deploy(DeployParams calldata params)
        external
        returns (address earnShare, EarnVault earnVault, EarnFees earnFees)
    {
        _validateParams(params);

        address asset = IEarnEngine(params.engine).asset();
        if (asset == address(0)) revert ZeroAddress();
        string memory engineName = IEarnEngine(params.engine).name();
        string memory engineSymbol = IEarnEngine(params.engine).symbol();
        if (bytes(engineName).length == 0 || bytes(engineSymbol).length == 0) {
            revert EmptyEarnShareMetadata();
        }

        bytes32 controlConfigHash = keccak256(abi.encode(params.controls));
        bytes32 feeConfigHash = keccak256(abi.encode(params.distributorConfig, params.fees));
        uint64 transferPolicyId = _effectiveTransferPolicyId(params.transferPolicyId);
        _validateTransferPolicy(transferPolicyId);
        bytes32 earnShareSalt = _earnShareSalt(
            params.deploymentId, params.engine, params.owner, controlConfigHash, feeConfigHash, transferPolicyId
        );
        address predictedEarnShare = ITIP20Factory(tip20Factory).getTokenAddress(address(this), earnShareSalt);
        if (predictedEarnShare.code.length != 0) revert EarnShareAlreadyExists(predictedEarnShare);

        earnShare = ITIP20Factory(tip20Factory)
            .createToken(
                string.concat(engineName, " (Earn)"),
                string.concat(engineSymbol, "E"),
                EARN_SHARE_CURRENCY,
                asset,
                address(this),
                earnShareSalt
            );
        if (earnShare == address(0)) revert ZeroAddress();
        if (ITIP20IssuerAccess(earnShare).totalSupply() != 0) revert EarnShareSupplyNotZero();

        earnVault = EarnVault(address(new ERC1967Proxy(earnVaultImplementation, bytes(""))));
        bytes32 earnFeesSalt = _earnFeesSalt(earnShareSalt);
        earnFees = EarnFees(Clones.cloneDeterministic(earnFeesImplementation, earnFeesSalt));
        IEarnFees(address(earnFees)).initialize(address(earnVault), earnShare, params.fees);
        earnVault.initialize(
            params.engine, earnShare, address(earnFees), params.owner, params.controls, params.distributorConfig
        );

        _grantEarnVaultIssuerRole(earnShare, address(earnVault));
        _setTransferPolicy(earnShare, transferPolicyId);
        _relinquishShareAdmin(earnShare);

        emit EarnStackDeployed(
            address(earnVault),
            earnShare,
            address(earnFees),
            params.engine,
            asset,
            params.owner,
            params.deploymentId,
            params.controls.emergencyGuardian,
            params.controls.asyncJanitor,
            params.controls.maxManagedAssets,
            params.controls.migrationMode,
            transferPolicyId,
            earnShareSalt,
            controlConfigHash,
            feeConfigHash,
            earnFeesSalt
        );
    }

    /// @notice Computes the EarnShare salt for `params`.
    function computeEarnShareSalt(DeployParams calldata params) external pure returns (bytes32) {
        return _earnShareSalt(
            params.deploymentId,
            params.engine,
            params.owner,
            keccak256(abi.encode(params.controls)),
            keccak256(abi.encode(params.distributorConfig, params.fees)),
            _effectiveTransferPolicyId(params.transferPolicyId)
        );
    }

    /// @notice Predicts the EarnShare address that `deploy` would create for `params`.
    function predictEarnShare(DeployParams calldata params) external view returns (address) {
        return ITIP20Factory(tip20Factory)
            .getTokenAddress(
                address(this),
                _earnShareSalt(
                    params.deploymentId,
                    params.engine,
                    params.owner,
                    keccak256(abi.encode(params.controls)),
                    keccak256(abi.encode(params.distributorConfig, params.fees)),
                    _effectiveTransferPolicyId(params.transferPolicyId)
                )
            );
    }

    function predictEarnFees(DeployParams calldata params) external view returns (address) {
        bytes32 earnShareSalt = _earnShareSalt(
            params.deploymentId,
            params.engine,
            params.owner,
            keccak256(abi.encode(params.controls)),
            keccak256(abi.encode(params.distributorConfig, params.fees)),
            _effectiveTransferPolicyId(params.transferPolicyId)
        );
        return Clones.predictDeterministicAddress(earnFeesImplementation, _earnFeesSalt(earnShareSalt), address(this));
    }

    function _validateParams(DeployParams calldata params) internal view {
        if (params.deploymentId == bytes32(0)) revert EmptyDeploymentId();
        if (params.engine == address(0) || params.owner == address(0)) revert ZeroAddress();
        if (params.owner == address(this)) revert FactoryCannotBeFinalOwner();
        if (params.distributorConfig.distributor == address(0)) {
            if (params.distributorConfig.updateDelay != 0) revert InvalidDistributorConfig();
        } else {
            if (params.distributorConfig.updateDelay == 0) {
                revert InvalidDistributorConfig();
            }
        }
        if (params.engine.code.length == 0) revert InvalidEngine();
        address boundEarnVault = IEarnEngine(params.engine).earnVault();
        if (boundEarnVault != address(0)) revert EngineAlreadyBound(boundEarnVault);
    }

    function _grantEarnVaultIssuerRole(address earnShare, address earnVault) internal {
        bytes32 issuerRole = ITIP20IssuerAccess(earnShare).ISSUER_ROLE();
        ITIP20IssuerAccess(earnShare).grantRole(issuerRole, earnVault);
        if (!ITIP20IssuerAccess(earnShare).hasRole(earnVault, issuerRole)) revert IssuerGrantFailed();
    }

    function _setTransferPolicy(address earnShare, uint64 transferPolicyId) internal {
        ITIP20PolicyAccess policyAccess = ITIP20PolicyAccess(earnShare);
        if (policyAccess.transferPolicyId() != transferPolicyId) {
            policyAccess.changeTransferPolicyId(transferPolicyId);
        }
        uint64 actualPolicyId = policyAccess.transferPolicyId();
        if (actualPolicyId != transferPolicyId) {
            revert TransferPolicyMismatch(transferPolicyId, actualPolicyId);
        }
    }

    function _relinquishShareAdmin(address earnShare) internal {
        ITIP20IssuerAccess(earnShare).revokeRole(DEFAULT_ADMIN_ROLE, address(this));
        if (ITIP20IssuerAccess(earnShare).hasRole(address(this), DEFAULT_ADMIN_ROLE)) {
            revert AdminRelinquishmentFailed();
        }
    }

    function _earnShareSalt(
        bytes32 deploymentId,
        address engine,
        address owner,
        bytes32 controlConfigHash,
        bytes32 feeConfigHash,
        uint64 transferPolicyId
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EARN_SHARE_SALT_DOMAIN, deploymentId, engine, owner, controlConfigHash, feeConfigHash, transferPolicyId
            )
        );
    }

    function _effectiveTransferPolicyId(uint64 requestedPolicyId) internal pure returns (uint64) {
        return requestedPolicyId == 0 ? ALWAYS_ALLOW_POLICY_ID : requestedPolicyId;
    }

    function _validateTransferPolicy(uint64 transferPolicyId) internal view {
        if (transferPolicyId == ALWAYS_ALLOW_POLICY_ID) return;
        if (TIP403_REGISTRY_ADDRESS.code.length == 0) revert InvalidTransferPolicy(transferPolicyId);
        ITIP403Registry registry = ITIP403Registry(TIP403_REGISTRY_ADDRESS);
        if (!registry.policyExists(transferPolicyId)) revert InvalidTransferPolicy(transferPolicyId);
        (uint8 policyType,) = registry.policyData(transferPolicyId);
        if (policyType != WHITELIST_POLICY_TYPE) {
            revert UnsupportedTransferPolicy(transferPolicyId, policyType);
        }
    }

    function _earnFeesSalt(bytes32 earnShareSalt) internal pure returns (bytes32) {
        return keccak256(abi.encode(FEES_SALT_DOMAIN, earnShareSalt));
    }
}
