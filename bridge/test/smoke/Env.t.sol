// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { TempoEnv } from "../harness/TempoEnv.sol";

contract EnvSmokeTest is TempoEnv {
    function setUp() public {
        _deployTempo();
    }

    function test_worldDeploys() public view {
        assertGt(earnVault.previewRedeem(1e6), 1e6, "share price above par");
        assertEq(bridgeFactory.getSpenderAddress(SPENDER_ID), spender);
        assertTrue(bridgeFactory.isAuthorizedDestination(SPENDER_ID, settlement));
    }
}
