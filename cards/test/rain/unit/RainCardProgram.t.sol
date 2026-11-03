// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import { CardSettler } from "../../../src/core/CardSettler.sol";
import { CardSpend } from "../../../src/core/CardSpend.sol";
import { CardSpender } from "../../../src/core/CardSpender.sol";
import { RainCardProgram } from "../../../src/providers/rain/RainCardProgram.sol";
import { RainEnv } from "../harness/RainEnv.sol";

/// @notice `RainCardProgram` on the core contracts: which Rain collateral a public and a private spend may
///         fund, from stablecoin or Earn, and Rain's pause key.
contract RainCardProgramTest is RainEnv {
    function setUp() public {
        _deployWorld();
        usd.mint(alice, 1000e6);
        usd.mint(bob, 1000e6);
        usd.mint(router, 1000e6);
    }

    // ------------------------------------------------------------------
    // Public spend: the cardholder's own collateral
    // ------------------------------------------------------------------

    function test_publicSpend_fundsOwnCollateral() public {
        _publicSpend(alice, _stableSpend(aliceCollateral, aliceIndex, 42e6, "auth.1"));
        assertEq(usd.balanceOf(aliceCollateral), 42e6);
        assertEq(usd.allowance(alice, address(spender)), 0, "no standing allowance");
    }

    function test_publicSpend_fromEarn_fundsOwnCollateral() public {
        _depositEarn(alice, 500e6);
        _publicSpend(alice, _earnSpend(aliceCollateral, aliceIndex, 30e6, 30e6, "auth.earn"));
        assertEq(usd.balanceOf(aliceCollateral), 30e6, "collateral funded in the vault asset");
    }

    function test_publicSpend_pooledCollateral_anyPayer() public {
        _publicSpend(alice, _stableSpend(programCollateral, programCollateralIndex, 5e6, "pooled"));
        assertEq(usd.balanceOf(programCollateral), 5e6);
    }

    function test_revert_anotherCardholdersCollateral() public {
        _expectRefused(alice, bobCollateral, bobIndex);
    }

    /// @dev Alice hands Bob ownership of her collateral, which keeps her as its only admin: Bob's spends
    ///      cannot fund it until he also administers it, at which point Rain lets him withdraw it.
    function test_revert_transferredCollateralWithoutAdminRights() public {
        vm.prank(alice);
        (bool ok,) = aliceCollateral.call(abi.encodeWithSignature("transferOwnership(address)", bob));
        assertTrue(ok);
        _expectRefused(bob, aliceCollateral, aliceIndex);
        vm.prank(bob);
        (ok,) = aliceCollateral.call(abi.encodeWithSignature("addAdmin(address)", bob));
        assertTrue(ok);
        assertTrue(program.isAuthorizedDestination(bob, aliceCollateral, address(usd), aliceIndex, false));
        assertFalse(program.isAuthorizedDestination(alice, aliceCollateral, address(usd), aliceIndex, false));
    }

    function test_revert_wrongIndex() public {
        _expectRefused(alice, aliceCollateral, bobIndex);
    }

    function test_revert_indexPastTheEnd() public view {
        assertFalse(program.isAuthorizedDestination(alice, aliceCollateral, address(usd), 3, false));
        assertFalse(program.isAuthorizedDestination(alice, aliceCollateral, address(usd), type(uint256).max, false));
    }

    /// @dev A proxy on Rain's own beacon, owned by Alice, that Rain's factory did not create.
    function test_revert_collateralNotFromRainsFactory() public {
        vm.prank(alice);
        address fake = address(
            new BeaconProxy(rain.factory.getBeacon(), abi.encodeWithSignature("initialize(string,address)", "x", alice))
        );
        for (uint256 i; i < 6; ++i) {
            assertFalse(program.isAuthorizedDestination(alice, fake, address(usd), i, false));
        }
    }

    function test_revert_beaconIsNotADestination() public view {
        for (uint256 i; i < 4; ++i) {
            assertFalse(program.isAuthorizedDestination(alice, rain.factory.getBeacon(), address(usd), i, false));
        }
    }

    function test_revert_tokenNotAccepted() public view {
        assertFalse(program.isAuthorizedDestination(alice, aliceCollateral, address(otherUsd), aliceIndex, false));
    }

    // ------------------------------------------------------------------
    // Private spend: pooled collateral only
    // ------------------------------------------------------------------

    function test_privateSpend_fundsPooledCollateral() public {
        _routerSettle(address(usd), 20e6 + 7, _stableSpend(programCollateral, programCollateralIndex, 20e6, "p.1"));
        assertEq(usd.balanceOf(programCollateral), 20e6);
        assertEq(usd.balanceOf(router), 1000e6 - 20e6);
    }

    function test_privateSpend_fromEarn_fundsPooledCollateral() public {
        _depositEarn(router, 200e6);
        CardSpend memory s = _earnSpend(programCollateral, programCollateralIndex, 15e6, 15e6, "p.earn");
        _routerSettle(address(earnShare), s.maxShares, s);
        assertEq(usd.balanceOf(programCollateral), 15e6);
    }

    /// @dev A private spend never names the cardholder, so it cannot fund their own collateral, even one they
    ///      made the settler own and administer.
    function test_revert_privateSpend_toCardholderCollateral() public {
        _expectPrivateRefused(aliceCollateral, aliceIndex);
        vm.startPrank(alice);
        (bool ok,) = aliceCollateral.call(abi.encodeWithSignature("addAdmin(address)", address(settler)));
        assertTrue(ok);
        (ok,) = aliceCollateral.call(abi.encodeWithSignature("transferOwnership(address)", address(settler)));
        assertTrue(ok);
        vm.stopPrank();
        _expectPrivateRefused(aliceCollateral, aliceIndex);
    }

    // ------------------------------------------------------------------
    // Rain's pause key
    // ------------------------------------------------------------------

    function test_pause_stopsEverySpendUntilResumed() public {
        vm.prank(rainPauser);
        vm.expectEmit(address(program));
        emit RainCardProgram.PausedSet(true);
        program.setPaused(true);

        CardSpend memory s = _stableSpend(aliceCollateral, aliceIndex, 1e6, "paused");
        vm.prank(alice);
        usd.approve(address(spender), 1e6);
        vm.prank(alice);
        vm.expectRevert(CardSpender.ProgramPaused.selector);
        spender.spend(s);

        CardSpend memory p = _stableSpend(programCollateral, programCollateralIndex, 1e6, "paused.private");
        vm.prank(router);
        usd.transfer(address(settler), 1e6);
        vm.prank(router);
        vm.expectRevert(CardSpender.ProgramPaused.selector);
        settler.settle(address(usd), 1e6, abi.encode(p));

        vm.prank(rainPauser);
        program.setPaused(false);
        vm.prank(alice);
        spender.spend(s);
        assertEq(usd.balanceOf(aliceCollateral), 1e6);
    }

    function test_revert_onlyThePauserPauses() public {
        vm.prank(alice);
        vm.expectRevert(RainCardProgram.NotPauser.selector);
        program.setPaused(true);
    }

    function test_revert_noPauserMeansNoPause() public {
        RainCardProgram unpausable = _deployProgram(address(earnVault), address(0));
        vm.prank(address(0));
        vm.expectRevert(RainCardProgram.NotPauser.selector);
        unpausable.setPaused(true);
        assertFalse(unpausable.paused());
    }

    // ------------------------------------------------------------------

    function _expectRefused(address payer, address destination, uint256 hint) private {
        CardSpend memory s = _stableSpend(destination, hint, 1e6, "refused");
        vm.prank(payer);
        usd.approve(address(spender), 1e6);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, destination));
        spender.spend(s);
    }

    function _expectPrivateRefused(address destination, uint256 hint) private {
        CardSpend memory s = _stableSpend(destination, hint, 1e6, "private.refused");
        vm.prank(router);
        usd.transfer(address(settler), 1e6);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, destination));
        settler.settle(address(usd), 1e6, abi.encode(s));
        // Not settled: take the input back for the next attempt.
        vm.prank(address(settler));
        usd.transfer(router, 1e6);
    }
}
