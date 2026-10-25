// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";

import { IEarnVault } from "../interfaces/core/IEarnVault.sol";
import { EarnContributionController, IContributionTarget } from "./EarnContributionController.sol";
import { EarnMerkleRewardDistributor } from "./EarnMerkleRewardDistributor.sol";

/// @title EarnRewardsFactory
/// @notice Permissionless deterministic installation of reviewed reward periphery on an EarnVault.
/// @dev The caller never gains authority. Every deployed component is immutably bound to the
///      supplied vault and owned by the explicit reward operator. Repeating the same installation
///      is idempotent and returns the already-deployed component addresses.
contract EarnRewardsFactory {
    bytes32 private constant CONTROLLER_DOMAIN = keccak256("TEMPO_EARN_CONTRIBUTION_CONTROLLER_V1");
    bytes32 private constant DISTRIBUTOR_DOMAIN = keccak256("TEMPO_EARN_MERKLE_DISTRIBUTOR_V1");

    struct Installation {
        address contributionController;
        address merkleDistributor;
    }

    event ContributionControllerInstalled(
        address indexed earnVault, address indexed owner, address contributionController
    );
    event MerkleDistributorInstalled(
        address indexed earnVault,
        address indexed owner,
        address indexed treasury,
        address merkleDistributor,
        bytes32 campaignId,
        uint40 claimDeadline
    );

    error EmptyInstallation();
    error InvalidExistingDeployment(address component);
    error InvalidRewardConfiguration();
    error ZeroAddress();

    function install(
        IEarnVault earnVault,
        address owner,
        address treasury,
        uint40 claimDeadline,
        bool targetYield,
        bool boostRewards
    ) external returns (Installation memory result) {
        if (address(earnVault) == address(0) || owner == address(0)) revert ZeroAddress();
        if (!targetYield && !boostRewards) revert EmptyInstallation();
        if (boostRewards && (treasury == address(0) || claimDeadline <= block.timestamp)) {
            revert InvalidRewardConfiguration();
        }
        if (!boostRewards && (treasury != address(0) || claimDeadline != 0)) {
            revert InvalidRewardConfiguration();
        }

        if (targetYield) result.contributionController = _installController(earnVault, owner);
        if (boostRewards) {
            result.merkleDistributor = _installDistributor(earnVault, owner, treasury, claimDeadline);
        }
    }

    function campaignId(IEarnVault earnVault) public pure returns (bytes32) {
        return bytes32(uint256(uint160(address(earnVault))));
    }

    function predictContributionController(IEarnVault earnVault, address owner) public view returns (address) {
        bytes32 salt = _controllerSalt(earnVault, owner);
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(EarnContributionController).creationCode, abi.encode(earnVault, owner)));
        return Create2.computeAddress(salt, initCodeHash, address(this));
    }

    function predictMerkleDistributor(IEarnVault earnVault, address owner, address treasury, uint40 claimDeadline)
        public
        view
        returns (address)
    {
        bytes32 id = campaignId(earnVault);
        bytes32 salt = _distributorSalt(earnVault, owner, treasury, claimDeadline);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(EarnMerkleRewardDistributor).creationCode,
                abi.encode(earnVault, treasury, id, claimDeadline, owner)
            )
        );
        return Create2.computeAddress(salt, initCodeHash, address(this));
    }

    function _installController(IEarnVault earnVault, address owner) private returns (address controllerAddress) {
        controllerAddress = predictContributionController(earnVault, owner);
        if (controllerAddress.code.length == 0) {
            EarnContributionController controller = new EarnContributionController{
                salt: _controllerSalt(earnVault, owner)
            }(
                IContributionTarget(address(earnVault)), owner
            );
            controllerAddress = address(controller);
            emit ContributionControllerInstalled(address(earnVault), owner, controllerAddress);
        }
        EarnContributionController existing = EarnContributionController(controllerAddress);
        if (
            address(existing.earnVault()) != address(earnVault) || existing.owner() != owner
                || existing.asset() != earnVault.asset()
        ) revert InvalidExistingDeployment(controllerAddress);
    }

    function _installDistributor(IEarnVault earnVault, address owner, address treasury, uint40 claimDeadline)
        private
        returns (address distributorAddress)
    {
        bytes32 id = campaignId(earnVault);
        distributorAddress = predictMerkleDistributor(earnVault, owner, treasury, claimDeadline);
        if (distributorAddress.code.length == 0) {
            EarnMerkleRewardDistributor distributor = new EarnMerkleRewardDistributor{
                salt: _distributorSalt(earnVault, owner, treasury, claimDeadline)
            }(
                earnVault, treasury, id, claimDeadline, owner
            );
            distributorAddress = address(distributor);
            emit MerkleDistributorInstalled(address(earnVault), owner, treasury, distributorAddress, id, claimDeadline);
        }
        EarnMerkleRewardDistributor existing = EarnMerkleRewardDistributor(distributorAddress);
        if (
            address(existing.earnVault()) != address(earnVault) || existing.owner() != owner
                || existing.treasury() != treasury || existing.campaignId() != id
                || existing.claimDeadline() != claimDeadline
        ) revert InvalidExistingDeployment(distributorAddress);
    }

    function _controllerSalt(IEarnVault earnVault, address owner) private pure returns (bytes32) {
        return keccak256(abi.encode(CONTROLLER_DOMAIN, earnVault, owner));
    }

    function _distributorSalt(IEarnVault earnVault, address owner, address treasury, uint40 claimDeadline)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(DISTRIBUTOR_DOMAIN, earnVault, owner, treasury, claimDeadline));
    }
}
