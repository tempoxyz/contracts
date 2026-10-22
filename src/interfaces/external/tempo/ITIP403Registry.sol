// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

address constant TIP403_REGISTRY_ADDRESS = 0x403c000000000000000000000000000000000000;
uint64 constant ALWAYS_ALLOW_POLICY_ID = 1;
uint8 constant WHITELIST_POLICY_TYPE = 0;

interface ITIP403Registry {
    function policyExists(uint64 policyId) external view returns (bool);
    function policyData(uint64 policyId) external view returns (uint8 policyType, address administrator);
    function isAuthorized(uint64 policyId, address account) external view returns (bool);
    function modifyPolicyWhitelist(uint64 policyId, address account, bool allowed) external;
}

interface ITIP20PolicyAccess {
    function changeTransferPolicyId(uint64 policyId) external;
    function transferPolicyId() external view returns (uint64);
}
