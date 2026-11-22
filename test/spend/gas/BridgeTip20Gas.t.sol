// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { CardSpend } from "../../../src/spend/CardSpend.sol";
import { CardSpender } from "../../../src/spend/CardSpender.sol";
import { TempoEnv } from "../bridge/harness/TempoEnv.sol";

/// @notice Plays the Zone router: transfers `maxInput` and calls `spendFrom` in one call.
contract GasSettleCaller {
    function isSpender(address) external pure returns (bool) {
        return true;
    }

    function spendFrom(CardSpender program, address token, uint256 maxInput, bytes calldata data) external {
        SafeTransferLib.safeTransfer(token, address(program), maxInput);
        program.spendFrom(token, maxInput, data);
    }
}

/// @notice Steady-state Bridge card spends (the program pays through its clone's "TS" handler) on real
///         TIP-20: a repeat spend after the first created the destination's, approvals' and seeds' slots,
///         measured with `gasleft` like `RouterTip20Gas`.
contract BridgeTip20GasTest is TempoEnv {
    uint256 internal constant AMOUNT = 40e6;
    GasSettleCaller internal caller;
    address internal alice = makeAddr("alice");

    function setUp() public {
        _deployTempo();
        caller = new GasSettleCaller();
        vm.mockCall(address(routerFactory), abi.encodeCall(routerFactory.isRouter, (address(caller))), abi.encode(true));
        // Seeds and standing approvals, as the deployment runbook leaves them.
        address seeder = makeAddr("seed");
        _mintUsd(address(program), 1);
        _mintUsd(spender, 1);
        _mintUsd(seeder, 10e6);
        _depositEarn(seeder, 10e6);
        vm.startPrank(seeder);
        earnShare.transfer(address(program), 1);
        earnShare.transfer(spender, 1);
        vm.stopPrank();
        program.warm(address(usd));
        program.warm(address(earnShare));
        _mintUsd(address(caller), 1_000_000e6);
        _depositEarn(address(caller), 500_000e6);
        _mintUsd(alice, 1_000_000e6);
        _depositEarn(alice, 500_000e6);
        vm.startPrank(alice);
        usd.approve(address(program), type(uint256).max);
        earnShare.approve(address(program), type(uint256).max);
        vm.stopPrank();
    }

    function _stableSpend(uint256 amount, bytes32 ref) internal view returns (CardSpend memory s) {
        s.program = address(program);
        s.token = address(usd);
        s.amount = amount;
        s.destination = settlement;
        s.ref = ref;
    }

    function _earnSpend(uint256 amount, bytes32 ref) internal view returns (CardSpend memory s) {
        s = _stableSpend(amount, ref);
        s.vault = address(earnVault);
        s.fromVault = amount;
        s.maxShares = earnVault.previewWithdraw(amount) * 1005 / 1000;
    }

    function _private(CardSpend memory s, address token, uint256 maxInput) internal returns (uint256 used) {
        bytes memory data = abi.encode(s);
        uint256 before = gasleft();
        caller.spendFrom(program, token, maxInput, data);
        used = before - gasleft();
    }

    function _public(CardSpend memory s) internal returns (uint256 used) {
        uint256 before = gasleft();
        vm.prank(alice);
        program.spend(s);
        used = before - gasleft();
    }

    function test_gasBridgePublicStableSpend() public {
        _public(_stableSpend(AMOUNT, bytes32(uint256(1))));
        vm.snapshotValue("bridge-tip20", "public.stable.repeat", _public(_stableSpend(AMOUNT, bytes32(uint256(2)))));
    }

    function test_gasBridgePublicEarnSpend() public {
        _public(_earnSpend(AMOUNT, bytes32(uint256(1))));
        vm.snapshotValue("bridge-tip20", "public.earn.repeat", _public(_earnSpend(AMOUNT, bytes32(uint256(2)))));
    }

    function test_gasBridgePrivateStableSpend() public {
        _private(_stableSpend(AMOUNT, bytes32(uint256(1))), address(usd), AMOUNT + 1e6);
        uint256 used = _private(_stableSpend(AMOUNT, bytes32(uint256(2))), address(usd), AMOUNT + 1e6);
        vm.snapshotValue("bridge-tip20", "private.stable.repeat", used);
    }

    function test_gasBridgePrivateEarnSpend() public {
        CardSpend memory s = _earnSpend(AMOUNT, bytes32(uint256(1)));
        _private(s, address(earnShare), s.maxShares);
        s = _earnSpend(AMOUNT, bytes32(uint256(2)));
        uint256 used = _private(s, address(earnShare), s.maxShares);
        vm.snapshotValue("bridge-tip20", "private.earn.repeat", used);
    }
}
