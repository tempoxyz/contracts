// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IAccessControl } from "openzeppelin-contracts/access/IAccessControl.sol";

import { ISpenderHandler, SpenderStatus } from "bridge-spender/src/ISpenderHandler.sol";
import { SpenderFactoryErrorsAndEvents } from "bridge-spender/src/SpenderFactoryErrorsAndEvents.sol";
import { SpenderBase } from "bridge-spender/src/spenders/SpenderBase.sol";

import { Spend } from "../../src/SpenderTempoSpend.sol";
import { PrivateSpendFixture } from "../harness/PrivateSpendFixture.sol";

/// @notice Bridge's factory roles as the "TS" handler relies on them: each role's calls refuse every
///         other role holder and an outsider, a pause stops spend until governance unpauses, and a `Disabled` handler
///         stops spend until governance enables it again, on both the public and the private path.
contract RolesTest is PrivateSpendFixture {
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        _setUpPrivateSpend();
        _mintUsd(alice, 100e6);
        vm.prank(alice);
        usd.approve(spender, type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Wrong callers
    // ------------------------------------------------------------------

    function test_onlyAdminSetsHandlers() public {
        bytes32 role = bridgeFactory.DEFAULT_ADMIN_ROLE();
        address[] memory callers = _everyoneBut(bridgeAdmin);
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(_unauthorized(callers[i], role));
            bridgeFactory.setSpenderHandler(PREFIX_TEMPO_SPEND, ISpenderHandler(outsider));
        }
    }

    function test_onlyGovernanceGovernsTheHandlerAndDestinations() public {
        bytes32 role = bridgeFactory.GOVERNANCE_ROLE();
        address[] memory callers = _everyoneBut(bridgeGovernor);
        for (uint256 i; i < callers.length; ++i) {
            address caller = callers[i];
            vm.prank(caller);
            vm.expectRevert(_unauthorized(caller, role));
            bridgeFactory.updateSpenderHandlerStatus(PREFIX_TEMPO_SPEND, SpenderStatus.Disabled);

            vm.prank(caller);
            vm.expectRevert(_unauthorized(caller, role));
            bridgeFactory.updateSpenderHandlerAllowlist(PREFIX_TEMPO_SPEND, SPENDER_ID, true);

            vm.prank(caller);
            vm.expectRevert(_unauthorized(caller, role));
            bridgeFactory.updateSpenderDestination(SPENDER_ID, outsider, true);
        }
        assertFalse(bridgeFactory.isAuthorizedDestination(SPENDER_ID, outsider));
    }

    function test_onlyGovernanceConfiguresTheHandler() public {
        bytes32 role = bridgeFactory.GOVERNANCE_ROLE();
        bytes memory allowVault = abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(1), outsider);
        address[] memory callers = _everyoneBut(bridgeGovernor);
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(_unauthorized(callers[i], role));
            bridgeFactory.governorCall(SPENDER_ID, allowVault);
        }

        // Past the factory, the clone and the handler only take governor calls from the factory.
        vm.prank(outsider);
        vm.expectRevert(SpenderBase.NotFactory.selector);
        ISpenderHandler(spender).governorCall(allowVault);
        address handler = address(bridgeFactory.getSpenderHandler(PREFIX_TEMPO_SPEND));
        vm.prank(outsider);
        vm.expectRevert(SpenderBase.NotFactory.selector);
        ISpenderHandler(handler).governorCall(abi.encodePacked(bytes2("UV"), uint8(1), outsider));
    }

    function test_onlyPauserPausesAndOnlyGovernanceUnpauses() public {
        bytes32 pauserRole = bridgeFactory.PAUSER_ROLE();
        address[] memory callers = _everyoneBut(bridgePauser);
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(_unauthorized(callers[i], pauserRole));
            bridgeFactory.pause();
        }

        vm.prank(bridgePauser);
        bridgeFactory.pause();
        bytes32 governanceRole = bridgeFactory.GOVERNANCE_ROLE();
        address[] memory unpausers = _everyoneBut(bridgeGovernor);
        for (uint256 i; i < unpausers.length; ++i) {
            vm.prank(unpausers[i]);
            vm.expectRevert(_unauthorized(unpausers[i], governanceRole));
            bridgeFactory.unpause();
        }
        assertTrue(bridgeFactory.paused());
    }

    function test_onlyDebitorReachesThePullPipeline() public {
        bytes32 role = bridgeFactory.DEBITOR_ROLE();
        bytes memory data = abi.encodePacked(PREFIX_TEMPO_SPEND, alice, address(usd), uint256(1e6));
        address[] memory callers = _everyoneBut(bridgeDebitor);
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(_unauthorized(callers[i], role));
            bridgeFactory.transferToDestination(SPENDER_ID, settlement, data);
        }
    }

    function test_rolesAreGrantedOnlyByTheirAdminRole() public {
        bytes32 managerRole = bridgeFactory.MANAGER_ROLE();
        bytes32 debitorRole = bridgeFactory.DEBITOR_ROLE();
        bytes32 governanceRole = bridgeFactory.GOVERNANCE_ROLE();
        vm.prank(outsider);
        vm.expectRevert(_unauthorized(outsider, governanceRole));
        bridgeFactory.grantRole(managerRole, outsider);
        vm.prank(outsider);
        vm.expectRevert(_unauthorized(outsider, managerRole));
        bridgeFactory.grantRole(debitorRole, outsider);
        assertFalse(bridgeFactory.hasRole(managerRole, outsider));
        assertFalse(bridgeFactory.hasRole(debitorRole, outsider));
    }

    // ------------------------------------------------------------------
    // Pause and unpause
    // ------------------------------------------------------------------

    function test_pauseStopsPublicSpendUntilGovernanceUnpauses() public {
        vm.prank(bridgePauser);
        bridgeFactory.pause();
        vm.prank(alice);
        vm.expectRevert(SpenderBase.FactoryPaused.selector);
        _cloneCall(_psCall(_publicSpend(10e6)));

        vm.prank(bridgeGovernor);
        bridgeFactory.unpause();
        uint256 before = usd.balanceOf(settlement);
        vm.prank(alice);
        _cloneCall(_psCall(_publicSpend(10e6)));
        assertEq(usd.balanceOf(settlement) - before, 10e6, "spend after unpause");
    }

    function test_pauseBouncesPrivateSpendUntilGovernanceUnpauses() public {
        vm.prank(bridgePauser);
        bridgeFactory.pause();
        _assertPrivateSpendBounces();

        vm.prank(bridgeGovernor);
        bridgeFactory.unpause();
        _assertPrivateSpendSettles();
    }

    // ------------------------------------------------------------------
    // Disabled handler
    // ------------------------------------------------------------------

    function test_disabledHandlerStopsPublicSpendAndManagerCallsUntilEnabled() public {
        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderHandlerStatus(PREFIX_TEMPO_SPEND, SpenderStatus.Disabled);

        vm.prank(alice);
        vm.expectRevert(SpenderFactoryErrorsAndEvents.SpenderHandlerDisabled.selector);
        _cloneCall(_psCall(_publicSpend(10e6)));
        vm.prank(bridgeGovernor);
        vm.expectRevert(SpenderFactoryErrorsAndEvents.SpenderHandlerDisabled.selector);
        bridgeFactory.governorCall(
            SPENDER_ID, abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(1), address(earnVault))
        );

        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderHandlerStatus(PREFIX_TEMPO_SPEND, SpenderStatus.Enabled);
        uint256 before = usd.balanceOf(settlement);
        vm.prank(alice);
        _cloneCall(_psCall(_publicSpend(10e6)));
        assertEq(usd.balanceOf(settlement) - before, 10e6, "spend after enabling");
    }

    function test_disabledHandlerBouncesPrivateSpendUntilEnabled() public {
        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderHandlerStatus(PREFIX_TEMPO_SPEND, SpenderStatus.Disabled);
        _assertPrivateSpendBounces();

        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderHandlerStatus(PREFIX_TEMPO_SPEND, SpenderStatus.Enabled);
        _assertPrivateSpendSettles();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Every factory role holder and an outsider, except `authorized`.
    function _everyoneBut(address authorized) internal view returns (address[] memory callers) {
        address[6] memory all = [bridgeAdmin, bridgeGovernor, bridgeManager, bridgePauser, bridgeDebitor, outsider];
        callers = new address[](all.length - 1);
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            if (all[i] != authorized) callers[n++] = all[i];
        }
        require(n == callers.length, "authorized is not a role holder");
    }

    function _unauthorized(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role);
    }

    function _publicSpend(uint256 amount) internal view returns (Spend memory s) {
        s = _spend(amount, settlement);
        s.token = address(usd);
    }

    /// @dev A Zone withdrawal to the receiver whose callback reverts: nothing is paid and the input,
    ///      less the withdrawal and bounce-back fees, returns to the Zone.
    function _assertPrivateSpendBounces() internal {
        uint256 before = usd.balanceOf(settlement);
        uint256 zoneBefore = _zoneBalance(address(usd), alice);
        assertTrue(_request(alice, 10e6 + _change(), _callback(_spend(10e6, settlement))));
        _zoneSettle();
        assertFalse(lastCallbackResults[0], "callback rejected");
        assertEq(usd.balanceOf(settlement), before, "nothing paid");
        uint256 fees = zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS) + portal.calculateBouncebackFee();
        assertLe(zoneBefore - _zoneBalance(address(usd), alice), fees, "input bounced back");
    }

    function _assertPrivateSpendSettles() internal {
        uint256 before = usd.balanceOf(settlement);
        assertTrue(_request(alice, 10e6 + _change(), _callback(_spend(10e6, settlement))));
        _zoneSettle();
        assertTrue(lastCallbackResults[0], "callback settled");
        assertEq(usd.balanceOf(settlement) - before, 10e6, "destination paid");
    }
}
