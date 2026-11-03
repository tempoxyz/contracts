// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Vm } from "forge-std/Vm.sol";

import { CardSettler, ICardSpenderPrivate } from "../../src/core/CardSettler.sol";
import { CardSpend } from "../../src/core/CardSpend.sol";
import { CoreEnv } from "./harness/CoreEnv.sol";

/// @notice `CardSettler` with no provider: the router hands it `maxInput`, it pays through its spender's
///         private entry point and returns the change, keeping nothing.
contract CardSettlerTest is CoreEnv {
    function setUp() public {
        _deployCore();
        _deployMockProgram();
        usd.mint(router, 1000e6);
    }

    function test_settle_paysAndReturnsChange() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 20e6, "private.1");
        vm.recordLogs();
        _routerSettle(address(usd), 20e6 + 7, s);
        assertEq(usd.balanceOf(pooledWallet), 20e6);
        assertEq(usd.balanceOf(router), 1000e6 - 20e6, "change back to the router");
        assertEq(usd.balanceOf(address(settler)), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 settled;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(settler)) continue;
            assertEq(logs[i].topics[0], CardSettler.SpendSettled.selector);
            (, uint256 consumed, uint256 returned) = abi.decode(logs[i].data, (address, uint256, uint256));
            assertEq(consumed, 20e6);
            assertEq(returned, 7);
            ++settled;
        }
        assertEq(settled, 1, "one SpendSettled");
    }

    function test_settle_fromEarnShares() public {
        uint256 shares = _depositEarn(router, 200e6);
        CardSpend memory s = _earnSpend(pooledWallet, 0, 15e6, 15e6, "private.earn");
        uint256 cost = earnVault.previewWithdraw(15e6);
        _routerSettle(address(earnShare), s.maxShares, s);
        assertEq(usd.balanceOf(pooledWallet), 15e6);
        assertEq(earnShare.balanceOf(router), shares - cost, "unused shares back to the router");
        assertEq(earnShare.balanceOf(address(settler)), 0);
        assertEq(earnShare.balanceOf(address(spender)), 0);
    }

    function test_revert_onlyASpenderDeploysItsSettler() public {
        vm.expectRevert(CardSettler.NotSpender.selector);
        new CardSettler(ICardSpenderPrivate(address(spender)), address(mock));
    }

    function test_revert_settle_wrongInputToken() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "input");
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSettler.WrongInputToken.selector, address(earnShare)));
        settler.settle(address(earnShare), 1e6, abi.encode(s));
    }

    function test_revert_settle_wrongProgram() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "program");
        s.program = address(1);
        vm.expectRevert(abi.encodeWithSelector(CardSettler.WrongProgram.selector, address(1)));
        settler.settle(address(usd), 1e6, abi.encode(s));
    }

    function test_revert_settle_insufficientInput() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "short");
        vm.expectRevert(CardSettler.InsufficientInput.selector);
        settler.settle(address(usd), 1e6, abi.encode(s));
    }

    function test_revert_settle_zeroOrHugeMaxInput() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "max");
        vm.expectRevert(CardSettler.InvalidAmount.selector);
        settler.settle(address(usd), 0, abi.encode(s));
        vm.expectRevert(CardSettler.InvalidAmount.selector);
        settler.settle(address(usd), uint256(type(uint128).max) + 1, abi.encode(s));
    }

    function test_revert_settle_maxInputBelowAmount() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 2e6, "below");
        vm.prank(router);
        usd.transfer(address(settler), 1e6);
        vm.expectRevert();
        settler.settle(address(usd), 1e6, abi.encode(s));
    }

    function test_warm_setsStandingApproval() public {
        settler.warm(address(usd));
        assertEq(usd.allowance(address(settler), address(spender)), type(uint256).max);
    }

    function testFuzz_settle_neverKeepsInput(uint256 amount, uint256 change) public {
        amount = bound(amount, 1, 500e6);
        change = bound(change, 0, 100e6);
        CardSpend memory s = _stableSpend(pooledWallet, 0, amount, "fuzz");
        uint256 before = usd.balanceOf(router);
        _routerSettle(address(usd), amount + change, s);
        assertEq(before - usd.balanceOf(router), amount);
        assertEq(usd.balanceOf(address(settler)), 0);
        assertEq(usd.balanceOf(address(spender)), 0);
    }
}
