// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Vm } from "forge-std/Vm.sol";

import { CardSettler } from "../../src/CardSettler.sol";
import { CardSpend } from "../../src/CardSpend.sol";
import { CardSpender } from "../../src/CardSpender.sol";
import { CardsEnv } from "../harness/CardsEnv.sol";

/// @notice Private spend with Rain as the provider: the Zone router hands `maxInput` to the program's
///         `CardSettler`, which pays the program's pooled Rain collateral and returns the change. The
///         settlement names no cardholder.
contract CardSettlerTest is CardsEnv {
    address internal router = makeAddr("zone-router");

    function setUp() public {
        _deployWorld();
        usd.mint(router, 1000e6);
    }

    function test_settle_paysPooledCollateral_returnsChange() public {
        CardSpend memory s = _stableSpend(programCollateral, programCollateralNonce, 20e6, "private.1");
        vm.recordLogs();
        _routerSettle(router, address(usd), 20e6 + 7, s);
        assertEq(usd.balanceOf(programCollateral), 20e6);
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
        CardSpend memory s = _earnSpend(programCollateral, programCollateralNonce, 15e6, 15e6, "private.earn");
        uint256 cost = earnVault.previewWithdraw(15e6);
        _routerSettle(router, address(earnShare), s.maxShares, s);
        assertEq(usd.balanceOf(programCollateral), 15e6);
        assertEq(earnShare.balanceOf(router), shares - cost, "unused shares back to the router");
        assertEq(earnShare.balanceOf(address(settler)), 0);
        assertEq(earnShare.balanceOf(address(spender)), 0);
    }

    /// @dev The settler is the payer of a private spend and owns no collateral, so a private spend can only
    ///      fund the program's pooled collateral, never name a cardholder's own.
    function test_revert_settle_toCardholderCollateral() public {
        CardSpend memory s = _stableSpend(aliceCollateral, aliceNonce, 1e6, "private.named");
        vm.prank(router);
        usd.transfer(address(settler), 1e6);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, aliceCollateral));
        settler.settle(address(usd), 1e6, abi.encode(s));
    }

    /// @dev A cardholder who hands their own collateral to the settler still cannot receive a private spend.
    function test_revert_settle_toCollateralOwnedBySettler() public {
        vm.prank(alice);
        (bool ok,) = aliceCollateral.call(abi.encodeWithSignature("transferOwnership(address)", address(settler)));
        assertTrue(ok, "ownership moved to the settler");
        CardSpend memory s = _stableSpend(aliceCollateral, aliceNonce, 1e6, "private.owned");
        vm.prank(router);
        usd.transfer(address(settler), 1e6);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, aliceCollateral));
        settler.settle(address(usd), 1e6, abi.encode(s));
    }

    function test_revert_settle_wrongInputToken() public {
        CardSpend memory s = _stableSpend(programCollateral, programCollateralNonce, 1e6, "input");
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSettler.WrongInputToken.selector, address(earnShare)));
        settler.settle(address(earnShare), 1e6, abi.encode(s));
    }

    function test_revert_settle_wrongProgram() public {
        CardSpend memory s = _stableSpend(programCollateral, programCollateralNonce, 1e6, "program");
        s.program = address(1);
        vm.expectRevert(abi.encodeWithSelector(CardSettler.WrongProgram.selector, address(1)));
        settler.settle(address(usd), 1e6, abi.encode(s));
    }

    function test_revert_settle_insufficientInput() public {
        CardSpend memory s = _stableSpend(programCollateral, programCollateralNonce, 1e6, "short");
        vm.expectRevert(CardSettler.InsufficientInput.selector);
        settler.settle(address(usd), 1e6, abi.encode(s));
    }

    function test_revert_settle_zeroOrHugeMaxInput() public {
        CardSpend memory s = _stableSpend(programCollateral, programCollateralNonce, 1e6, "max");
        vm.expectRevert(CardSettler.InvalidAmount.selector);
        settler.settle(address(usd), 0, abi.encode(s));
        vm.expectRevert(CardSettler.InvalidAmount.selector);
        settler.settle(address(usd), uint256(type(uint128).max) + 1, abi.encode(s));
    }

    function test_revert_settle_maxInputBelowAmount() public {
        CardSpend memory s = _stableSpend(programCollateral, programCollateralNonce, 2e6, "below");
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
        CardSpend memory s = _stableSpend(programCollateral, programCollateralNonce, amount, "fuzz");
        uint256 before = usd.balanceOf(router);
        _routerSettle(router, address(usd), amount + change, s);
        assertEq(before - usd.balanceOf(router), amount);
        assertEq(usd.balanceOf(address(settler)), 0);
        assertEq(usd.balanceOf(address(spender)), 0);
    }
}
