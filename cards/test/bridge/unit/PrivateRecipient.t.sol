// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { IAddressRegistry } from "tempo-std/interfaces/IAddressRegistry.sol";

import { CardSpender } from "../../../src/core/CardSpender.sol";
import { PrivateSpendFixture } from "../harness/PrivateSpendFixture.sol";

/// @notice Private card settlement cannot pay the calling router, including through a virtual alias.
contract PrivateRecipientTest is PrivateSpendFixture {
    uint256 internal constant AMOUNT = 40e6;

    function setUp() public {
        _setUpPrivateSpend(true);
        _enrollEarnInZone(alice, 500e6);
        assertTrue(portal.isAccessEnforced(), "closed Zone");
        assertTrue(address(earnShare) != address(usd), "input differs from settlement token");
    }

    function test_earnToCallingRouterBouncesAtomically() public {
        _assertEarnBounces(address(zoneRouter));
    }

    function test_earnToVirtualCallingRouterBouncesAtomically() public {
        _assertEarnBounces(_virtualRecipient(address(zoneRouter)));
    }

    function test_earnToSettlementPaysAndReturnsChange() public {
        _assertEarnSettles(settlement, settlement);
    }

    function test_earnToVirtualSettlementPaysAndReturnsChange() public {
        _assertEarnSettles(_virtualRecipient(settlement), settlement);
    }

    function test_stableToSettlementStillPaysAndReturnsChange() public {
        uint256 zoneBefore = _zoneBalance(address(usd), alice);
        uint256 paidBefore = usd.balanceOf(settlement);
        assertTrue(_request(alice, AMOUNT + _change(), _callback(_spend(AMOUNT, settlement))));
        _zoneSettle();

        assertTrue(lastCallbackResults[0], "callback settled");
        assertEq(usd.balanceOf(settlement) - paidBefore, AMOUNT, "destination paid");
        assertEq(
            zoneBefore - _zoneBalance(address(usd), alice),
            AMOUNT + zoneOutbox.calculateWithdrawalFee(callbackGas) + portal.calculateDepositFee(),
            "amount plus fees"
        );
        _assertNothingHeld(address(usd));
        _assertNothingHeld(address(earnShare));
    }

    function _assertEarnBounces(address destination) internal {
        _authorizeDestination(destination);
        uint256 maxShares = earnVault.previewWithdraw(AMOUNT);
        uint256 zoneBefore = _zoneBalance(address(earnShare), alice);
        uint256 supplyBefore = earnShare.totalSupply();
        uint256 paidBefore = usd.balanceOf(settlement);
        // Cover both Portal fees so a change-return failure cannot mask recipient validation.
        assertTrue(
            _request(
                alice, address(earnShare), maxShares + _change(), _callback(_earnSpend(AMOUNT, destination, maxShares))
            ),
            "Zone accepted the request"
        );
        _zoneSettle();

        assertFalse(lastCallbackResults[0], "router cannot be the settlement recipient");
        assertEq(
            lastCallbackErrors[0], abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, destination)
        );
        assertEq(earnShare.totalSupply(), supplyBefore, "no shares burned");
        assertEq(usd.balanceOf(settlement), paidBefore, "nothing paid");
        assertEq(
            zoneBefore - _zoneBalance(address(earnShare), alice),
            zoneOutbox.calculateWithdrawalFee(callbackGas),
            "full principal returned, only withdrawal fee charged"
        );
        _assertNothingHeld(address(usd));
        _assertNothingHeld(address(earnShare));
    }

    function _assertEarnSettles(address destination, address payee) internal {
        _authorizeDestination(destination);
        uint256 maxShares = earnVault.previewWithdraw(AMOUNT);
        uint256 zoneBefore = _zoneBalance(address(earnShare), alice);
        uint256 paidBefore = usd.balanceOf(payee);
        assertTrue(
            _request(
                alice, address(earnShare), maxShares + _change(), _callback(_earnSpend(AMOUNT, destination, maxShares))
            )
        );
        _zoneSettle();

        assertTrue(lastCallbackResults[0], "callback settled");
        assertEq(usd.balanceOf(payee) - paidBefore, AMOUNT, "destination paid");
        assertEq(
            zoneBefore - _zoneBalance(address(earnShare), alice),
            maxShares + zoneOutbox.calculateWithdrawalFee(callbackGas) + portal.calculateDepositFee(),
            "burned shares plus fees"
        );
        _assertNothingHeld(address(usd));
        _assertNothingHeld(address(earnShare));
    }

    function _authorizeDestination(address destination) internal {
        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderDestination(SPENDER_ID, destination, true);
    }

    function _virtualRecipient(address master) internal returns (address destination) {
        IAddressRegistry registry = IAddressRegistry(StdPrecompiles.ADDRESS_REGISTRY_ADDRESS);
        bytes4 masterId = 0x12345678;
        // Seed the native registry's registered-master state without mining registration proof of work.
        assertEq(registry.getMaster(masterId), address(0));
        // Native mapping keys right-align the master ID; RegistryData stores its address in the low 20 bytes.
        bytes32 slot = keccak256(abi.encode(uint32(masterId), uint256(0)));
        vm.store(address(registry), slot, bytes32(uint256(uint160(master))));
        destination = address(uint160(0x12345678fDFDfDFdFDfdFdfdFDFd000000000001));
        assertEq(registry.getMaster(masterId), master, "registered master");
        assertEq(registry.resolveRecipient(destination), master, "native virtual resolution");
    }
}
