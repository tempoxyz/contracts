// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { EarnMerkleRewardDistributor } from "../../src/rewards/EarnMerkleRewardDistributor.sol";
import { IEarnVault } from "../../src/interfaces/core/IEarnVault.sol";
import { Script, console2 } from "forge-std/Script.sol";

/// @notice Deploys one EarnShare-only cumulative Merkle reward campaign.
contract DeployEarnMerkleRewardDistributorScript is Script {
    /// @notice The deployment step's typed input.
    struct Input {
        uint256 expectedChainId;
        IEarnVault earnVault;
        address treasury;
        bytes32 campaignId;
        uint40 claimDeadline;
        address owner;
        string outputPath;
    }

    error BindingFailed();
    error UnexpectedChain(uint256 actual, uint256 expected);

    function run(Input calldata input) external returns (EarnMerkleRewardDistributor distributor) {
        if (block.chainid != input.expectedChainId) revert UnexpectedChain(block.chainid, input.expectedChainId);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        distributor =
            _deployDistributor(input.earnVault, input.treasury, input.campaignId, input.claimDeadline, input.owner);
        vm.stopBroadcast();
        _verifyDistributor(
            distributor, input.earnVault, input.treasury, input.campaignId, input.claimDeadline, input.owner
        );
        vm.writeJson(
            vm.serializeAddress("deployment", "earnMerkleRewardDistributor", address(distributor)),
            input.outputPath,
            ".latestOutputs"
        );

        console2.log("EARN_REWARD_DISTRIBUTOR_ADDRESS", address(distributor));
        console2.log("EARN_VAULT_ADDRESS", address(input.earnVault));
        console2.log("EARN_SHARE_ADDRESS", input.earnVault.earnShare());
        console2.log("EARN_REWARD_TREASURY_ADDRESS", input.treasury);
        console2.logBytes32(input.campaignId);
        console2.log("EARN_REWARD_CLAIM_DEADLINE", input.claimDeadline);
        console2.log("EARN_REWARD_DISTRIBUTOR_OWNER_ADDRESS", input.owner);
    }

    function _deployDistributor(
        IEarnVault earnVault,
        address treasury,
        bytes32 campaignId,
        uint40 claimDeadline,
        address owner
    ) internal returns (EarnMerkleRewardDistributor distributor) {
        distributor = new EarnMerkleRewardDistributor(earnVault, treasury, campaignId, claimDeadline, owner);
    }

    function _verifyDistributor(
        EarnMerkleRewardDistributor distributor,
        IEarnVault earnVault,
        address treasury,
        bytes32 campaignId,
        uint40 claimDeadline,
        address owner
    ) internal view {
        if (
            address(distributor.earnVault()) != address(earnVault) || distributor.asset() != earnVault.asset()
                || distributor.earnShare() != earnVault.earnShare() || distributor.treasury() != treasury
                || distributor.campaignId() != campaignId || distributor.claimDeadline() != claimDeadline
                || distributor.owner() != owner
        ) {
            revert BindingFailed();
        }
    }
}
