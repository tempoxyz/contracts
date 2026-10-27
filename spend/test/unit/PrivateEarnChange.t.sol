// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IZonePortal, ZONE_MESSENGER_ADDRESS } from "tempo-zones/interfaces/IZone.sol";
import { ZoneRouter } from "zone-router/ZoneRouter.sol";

import { Spend, SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { ITempoEarnVault } from "../../src/interfaces/ITempoEarnVault.sol";
import { BridgeSettler } from "../../src/settler/BridgeSettler.sol";
import { OverQuotingEarnVault } from "../harness/Mocks.sol";
import { PrivateSpendFixture } from "../harness/PrivateSpendFixture.sol";

/// @notice A private spend from Earn always returns its unused shares to the Zone, so with the
///         portal's deposit and bounce-back fees on it must carry change that covers them, on an
///         open Zone as on a closed-loop one.
abstract contract PrivateEarnChangeTest is PrivateSpendFixture {
    uint256 internal constant AMOUNT = 40e6;

    function _closedLoop() internal pure virtual returns (bool);

    function setUp() public {
        _setUpPrivateSpend(_closedLoop());
        _enrollEarnInZone(alice, 500e6);
        assertGt(portal.calculateBouncebackFee(), 0, "bounce-back fee on");
        assertGt(portal.calculateDepositFee(), 0, "deposit fee on");
    }

    /// @notice A withdrawal of exactly `maxShares` leaves only the quote's margin as change, below
    ///         the portal's fees, so it cannot be deposited back: the spend bounces, nothing is paid
    ///         and the input returns to the Zone.
    function test_earnLeftoverBelowFeesBounces() public {
        uint256 maxShares = _quote(AMOUNT);
        assertLt(maxShares - earnVault.previewWithdraw(AMOUNT), _change() - 1, "leftover below fees");
        uint256 before = usd.balanceOf(settlement);
        uint256 zoneBefore = _zoneBalance(address(earnShare), alice);

        bytes memory callbackData = _callback(_earnSpend(AMOUNT, settlement, maxShares));
        assertTrue(_request(alice, address(earnShare), maxShares, callbackData), "accepted");
        _zoneSettle();

        assertFalse(lastCallbackResults[0], "callback rejected");
        assertEq(bytes4(lastCallbackErrors[0]), IZonePortal.DepositTooSmall.selector);
        assertEq(usd.balanceOf(settlement), before, "nothing paid");
        assertEq(
            zoneBefore - _zoneBalance(address(earnShare), alice),
            zoneOutbox.calculateWithdrawalFee(callbackGas),
            "input returned to the Zone"
        );
    }

    /// @notice With change of the deposit fee, the bounce-back fee and one unit, the spend settles
    ///         and the shares it did not burn come back to the cardholder in the Zone.
    function test_earnWithChangeSettlesAndReturnsUnusedShares() public {
        uint256 burned = earnVault.previewWithdraw(AMOUNT);
        uint256 maxShares = _quote(AMOUNT);
        uint256 before = usd.balanceOf(settlement);
        uint256 zoneBefore = _zoneBalance(address(earnShare), alice);

        bytes memory callbackData = _callback(_earnSpend(AMOUNT, settlement, maxShares));
        assertTrue(_request(alice, address(earnShare), maxShares + _change(), callbackData));
        _zoneSettle();

        assertTrue(lastCallbackResults[0], "callback settled");
        assertEq(usd.balanceOf(settlement) - before, AMOUNT, "destination paid");
        assertEq(
            zoneBefore - _zoneBalance(address(earnShare), alice),
            burned + zoneOutbox.calculateWithdrawalFee(callbackGas) + portal.calculateDepositFee(),
            "charged the burned shares and fees only"
        );
        _assertNothingHeld(address(earnShare));
    }

    /// @notice A vault that burns fewer shares than it quoted leaves the rest with the settler,
    ///         which hands them back to the router to return to the cardholder with the change.
    function test_earnSharesTheVaultDidNotBurnReturnToTheZone() public {
        OverQuotingEarnVault vault = new OverQuotingEarnVault(ITempoEarnVault(address(earnVault)));
        // The mock vault's extra share hops cost about 0.8M gas on top of a spend's 2.4M.
        callbackGas = 4_000_000;
        _bridgeGovernorCall(abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(1), address(vault)));
        uint256 quoted = vault.previewWithdraw(AMOUNT);
        uint256 burned = earnVault.previewWithdraw(AMOUNT);
        assertGt(quoted, burned, "quote above the burn");
        Spend memory spend = _earnSpend(AMOUNT, settlement, quoted);
        spend.vault = address(vault);
        uint256 before = usd.balanceOf(settlement);
        uint256 zoneBefore = _zoneBalance(address(earnShare), alice);

        bytes memory callbackData = _callback(spend);
        assertTrue(_request(alice, address(earnShare), quoted + _change(), callbackData));
        _zoneSettle();

        assertTrue(lastCallbackResults[0], "callback settled");
        assertEq(usd.balanceOf(settlement) - before, AMOUNT, "destination paid");
        assertEq(
            zoneBefore - _zoneBalance(address(earnShare), alice),
            burned + zoneOutbox.calculateWithdrawalFee(callbackGas) + portal.calculateDepositFee(),
            "charged the burned shares and fees only"
        );
        assertEq(earnShare.balanceOf(address(vault)), 0, "nothing left in the vault");
        _assertNothingHeld(address(earnShare));
    }

    /// @notice The clone reports the settler as the payer and the shares it burned, the settler the
    ///         shares consumed and handed back, and the router the shares returned to the Zone.
    function test_earnSpendEmitsEvents() public {
        uint256 burned = earnVault.previewWithdraw(AMOUNT);
        uint256 maxShares = _quote(AMOUNT);
        uint256 input = maxShares + _change();
        Spend memory spend = _earnSpend(AMOUNT, settlement, maxShares);
        spend.ref = keccak256("card.auth");
        _fundRouter(address(earnShare), input);

        bytes memory data = _callback(spend);
        vm.expectEmit(true, true, true, true, spender);
        emit SpenderTempoSpend.TempoSpendExecuted(
            spend.ref, address(settler), settlement, address(usd), AMOUNT, 0, AMOUNT, burned
        );
        vm.expectEmit(true, true, true, true, address(settler));
        emit BridgeSettler.SpendSettled(spend.ref, address(earnShare), burned, maxShares - burned);
        // The Zone deposit hash is the portal's; the rest is checked.
        vm.expectEmit(true, true, false, false, address(zoneRouter));
        emit ZoneRouter.Spent(address(settler), address(earnShare), burned, input - burned, bytes32(0));
        vm.prank(ZONE_MESSENGER_ADDRESS);
        zoneRouter.onWithdrawalReceived(
            ZONE_ID, address(portal), keccak256("zone.sender-tag"), address(earnShare), uint128(input), data
        );
        _assertNothingHeld(address(earnShare));
    }

    /// @dev Bridge's Earn quote: the live share cost plus 0.5% and one unit.
    function _quote(uint256 assets) internal view returns (uint256) {
        uint256 live = earnVault.previewWithdraw(assets);
        return live + live * 50 / 10_000 + 1;
    }
}

contract PrivateEarnChangeOpenZoneTest is PrivateEarnChangeTest {
    function _closedLoop() internal pure override returns (bool) {
        return false;
    }
}

contract PrivateEarnChangeClosedLoopTest is PrivateEarnChangeTest {
    function _closedLoop() internal pure override returns (bool) {
        return true;
    }
}
