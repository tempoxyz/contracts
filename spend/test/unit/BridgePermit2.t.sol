// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IAllowanceTransfer } from "permit2/interfaces/IAllowanceTransfer.sol";

import { TempoEnv } from "../harness/TempoEnv.sol";

/// @notice Bridge's `SpenderPermit2` ("P2") on Tempo: pulls ride a Permit2 allowance that expires.
contract BridgePermit2Test is TempoEnv {
    address internal alice = makeAddr("alice");

    function setUp() public {
        _deployTempo();
        _mintUsd(alice, 1000e6);
        vm.startPrank(alice);
        usd.approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(address(usd), spender, 100e6, uint48(vm.getBlockTimestamp() + 1 hours));
        vm.stopPrank();
    }

    function test_pullSpendsThePermit2Allowance() public {
        _pull(40e6);
        assertEq(usd.balanceOf(settlement), 40e6);
        (uint160 left,,) = IAllowanceTransfer(permit2).allowance(alice, address(usd), spender);
        assertEq(left, 60e6, "allowance spent down");
    }

    function test_pullBeyondThePermit2AllowanceReverts() public {
        vm.prank(bridgeDebitor);
        vm.expectRevert();
        bridgeFactory.transferToDestination(SPENDER_ID, settlement, _data(101e6));
    }

    function test_expiredPermit2AllowanceReverts() public {
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(bridgeDebitor);
        vm.expectRevert();
        bridgeFactory.transferToDestination(SPENDER_ID, settlement, _data(1e6));
        assertEq(bridgeFactory.availableBalance(SPENDER_ID, _balance()), 0, "nothing available");
    }

    function test_onlyProgramDestinations() public {
        vm.prank(bridgeDebitor);
        vm.expectRevert();
        bridgeFactory.transferToDestination(SPENDER_ID, makeAddr("attacker"), _data(1e6));
    }

    function _pull(uint256 amount) internal {
        vm.prank(bridgeDebitor);
        bridgeFactory.transferToDestination(SPENDER_ID, settlement, _data(amount));
    }

    function _data(uint256 amount) internal view returns (bytes memory) {
        return abi.encodePacked(PREFIX_PERMIT2, alice, address(usd), amount);
    }

    function _balance() internal view returns (bytes memory) {
        return abi.encodePacked(PREFIX_PERMIT2, alice, address(usd));
    }
}
