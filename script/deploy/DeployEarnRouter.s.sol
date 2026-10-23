// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script, console2 } from "forge-std/Script.sol";
import { IEarnVault } from "../../src/interfaces/core/IEarnVault.sol";
import { IManagedPropAMMVenue } from "../../src/interfaces/external/propamm/IManagedPropAMMVenue.sol";
import { IPropAMMVenue } from "../../src/interfaces/external/propamm/IPropAMMVenue.sol";
import { SingleZoneEarnRouter } from "../../src/router/SingleZoneEarnRouter.sol";

contract DeployEarnRouterScript is Script {
    /// @notice The deployment step's typed input; a zero pool and customer ID bind the vault asset itself.
    /// @dev `poolKind` is the router's `PoolKind`; `pairIndex` and `sponsorId` are zero unless it is `Managed`.
    struct Input {
        uint256 expectedChainId;
        uint32 zoneId;
        address earnVault;
        address privateAsset;
        address pool;
        bytes32 customerId;
        uint8 poolKind;
        uint16 pairIndex;
        uint64 sponsorId;
        string outputPath;
    }

    error BindingFailed();
    error InvalidZone(uint256 zoneId);
    error UnexpectedChain(uint256 actual, uint256 expected);

    function run(Input calldata input) external returns (SingleZoneEarnRouter router) {
        if (block.chainid != input.expectedChainId) revert UnexpectedChain(block.chainid, input.expectedChainId);
        if (input.zoneId == 0) revert InvalidZone(input.zoneId);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        router = new SingleZoneEarnRouter(
            input.zoneId,
            input.earnVault,
            input.privateAsset,
            input.pool,
            input.customerId,
            SingleZoneEarnRouter.PoolKind(input.poolKind),
            input.pairIndex,
            input.sponsorId
        );
        vm.stopBroadcast();
        _verifyRouter(router, input);
        vm.writeJson(
            vm.serializeAddress("deployment", "earnRouter", address(router)), input.outputPath, ".latestOutputs"
        );
        console2.log("EARN_ROUTER_ADDRESS", address(router));
    }

    function _verifyRouter(SingleZoneEarnRouter router, Input calldata input) internal view {
        uint32 scopedZoneId = input.zoneId;
        address earnVault = input.earnVault;
        address privateAsset = input.privateAsset;
        address pool = input.pool;
        bytes32 customerId = input.customerId;
        IEarnVault expectedEarnVault = IEarnVault(earnVault);
        if (
            uint8(router.poolKind()) != input.poolKind || router.pairIndex() != input.pairIndex
                || router.sponsorId() != input.sponsorId
        ) revert BindingFailed();
        if (
            router.allowedZoneId() != scopedZoneId || router.earnVault() != earnVault
                || router.privateAsset() != privateAsset || router.vaultAsset() != expectedEarnVault.asset()
                || router.earnShare() != expectedEarnVault.earnShare()
        ) revert BindingFailed();
        if (pool == address(0)) {
            // A router without conversion binds the vault asset itself and no pool route.
            if (
                address(router.pool()) != address(0) || router.customerId() != customerId
                    || privateAsset != router.vaultAsset()
            ) {
                revert BindingFailed();
            }
            return;
        }
        address base;
        address quote;
        if (router.poolKind() == SingleZoneEarnRouter.PoolKind.Direct) {
            base = IPropAMMVenue(pool).baseToken();
            quote = IPropAMMVenue(pool).quoteToken();
        } else {
            IManagedPropAMMVenue.Pair memory managed = IManagedPropAMMVenue(pool).pair(input.pairIndex);
            base = managed.base;
            quote = managed.quote;
        }
        address privateSide = router.privateAssetIsBase() ? base : quote;
        address vaultSide = router.privateAssetIsBase() ? quote : base;
        if (
            address(router.pool()) != pool || router.customerId() != customerId || privateSide != privateAsset
                || vaultSide != router.vaultAsset()
        ) revert BindingFailed();
    }
}
