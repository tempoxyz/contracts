// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script, console2 } from "forge-std/Script.sol";

import {
    ALWAYS_ALLOW_POLICY_ID,
    ITIP20PolicyAccess,
    ITIP403Registry,
    TIP403_REGISTRY_ADDRESS,
    WHITELIST_POLICY_TYPE
} from "../../src/interfaces/external/tempo/ITIP403Registry.sol";

/// @notice Validates and attaches an existing simple TIP-403 whitelist to one EarnShare.
/// @dev Policy membership is operational readiness managed separately by the existing policy administrator.
///      This script never creates a policy, reads membership, or edits membership.
contract AttachEarnSharePolicyScript is Script {
    /// @notice The deployment step's typed input.
    struct Input {
        uint256 expectedChainId;
        uint64 policyId;
        address earnShare;
    }

    error InvalidPolicyId(uint256 policyId);
    error PolicyHasNoAdministrator(uint64 policyId);
    error PolicyDoesNotExist(uint64 policyId);
    error TransferPolicyMismatch(uint64 actual, uint64 expected);
    error UnexpectedChain(uint256 actual, uint256 expected);
    error UnsupportedPolicyType(uint8 policyType);

    function run(Input calldata input) external {
        if (block.chainid != input.expectedChainId) revert UnexpectedChain(block.chainid, input.expectedChainId);
        if (input.policyId == 0 || input.policyId == ALWAYS_ALLOW_POLICY_ID) revert InvalidPolicyId(input.policyId);
        address administrator = _attachPolicy(vm.envUint("DEPLOYER_PRIVATE_KEY"), input.policyId, input.earnShare);

        console2.log("EARN_SHARE_ADDRESS", input.earnShare);
        console2.log("EARN_SHARE_POLICY_ID", uint256(input.policyId));
        console2.log("EARN_ACCESS_ADMIN_ADDRESS", administrator);
    }

    function _attachPolicy(uint256 deployerPrivateKey, uint64 policyId, address earnShareAddress)
        internal
        returns (address administrator)
    {
        ITIP403Registry registry = ITIP403Registry(TIP403_REGISTRY_ADDRESS);
        if (!registry.policyExists(policyId)) revert PolicyDoesNotExist(policyId);
        (uint8 policyType, address discoveredAdministrator) = registry.policyData(policyId);
        if (policyType != WHITELIST_POLICY_TYPE) revert UnsupportedPolicyType(policyType);
        if (discoveredAdministrator == address(0)) revert PolicyHasNoAdministrator(policyId);
        administrator = discoveredAdministrator;
        ITIP20PolicyAccess earnShare = ITIP20PolicyAccess(earnShareAddress);
        uint64 currentPolicyId = earnShare.transferPolicyId();
        if (currentPolicyId == ALWAYS_ALLOW_POLICY_ID) {
            vm.startBroadcast(deployerPrivateKey);
            earnShare.changeTransferPolicyId(policyId);
            vm.stopBroadcast();
        } else if (currentPolicyId != policyId) {
            revert TransferPolicyMismatch(currentPolicyId, policyId);
        }
        if (earnShare.transferPolicyId() != policyId) {
            revert TransferPolicyMismatch(earnShare.transferPolicyId(), policyId);
        }
    }
}
