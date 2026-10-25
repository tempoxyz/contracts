// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IZonePortal, ZONE_MESSENGER_ADDRESS } from "tempo-zones/interfaces/IZone.sol";

import { Spend, SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { ZoneSpendReceiver } from "../../src/ZoneSpendReceiver.sol";
import { ITempoEarnVault } from "../../src/interfaces/ITempoEarnVault.sol";
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

    /// @notice Leftover shares below the portal's fees cannot be deposited back, so the spend
    ///         bounces, nothing is paid and the input returns to the Zone.
    function test_earnLeftoverBelowFeesBounces() public {
        uint256 maxShares = _quote(AMOUNT);
        assertLt(
            maxShares - earnVault.previewWithdraw(AMOUNT), _change() - 1, "leftover below fees"
        );
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
            zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS),
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
            burned + zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS) + portal.calculateDepositFee(),
            "charged the burned shares and fees only"
        );
        assertEq(earnShare.balanceOf(address(receiver)), 0, "nothing left in the receiver");
        assertEq(earnShare.balanceOf(spender), 0, "nothing left in the clone");
        _assertNoApprovals(address(earnShare));
    }

    /// @notice A vault that burns fewer shares than it quoted leaves the rest with the receiver,
    ///         which returns them to the cardholder in the Zone with the change.
    function test_earnSharesTheVaultDidNotBurnReturnToTheZone() public {
        OverQuotingEarnVault vault = new OverQuotingEarnVault(ITempoEarnVault(address(earnVault)));
        _bridgeGovernorCall(
            abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(1), address(vault))
        );
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
            burned + zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS) + portal.calculateDepositFee(),
            "charged the burned shares and fees only"
        );
        assertEq(earnShare.balanceOf(address(receiver)), 0, "nothing left in the receiver");
        assertEq(earnShare.balanceOf(spender), 0, "nothing left in the clone");
        assertEq(earnShare.balanceOf(address(vault)), 0, "nothing left in the vault");
        _assertNoApprovals(address(earnShare));
    }

    /// @notice The clone reports the receiver as the payer and the shares it burned, and the
    ///         receiver reports the shares consumed and returned.
    function test_earnSpendEmitsEvents() public {
        bytes32 senderTag = keccak256("zone.sender-tag");
        uint256 burned = earnVault.previewWithdraw(AMOUNT);
        uint256 input = _quote(AMOUNT) + _change();
        Spend memory spend = _earnSpend(AMOUNT, settlement, _quote(AMOUNT));
        spend.ref = keccak256("card.auth");
        _fundReceiver(address(earnShare), input);

        bytes memory data = _callback(spend);
        vm.expectEmit(true, true, true, true, spender);
        emit SpenderTempoSpend.TempoSpendExecuted(
            spend.ref, address(receiver), settlement, address(usd), AMOUNT, 0, AMOUNT, burned
        );
        vm.expectEmit(true, true, true, true, address(receiver));
        emit ZoneSpendReceiver.PrivateSpendSettled(
            senderTag, spend.ref, address(earnShare), burned, input - burned
        );
        vm.prank(ZONE_MESSENGER_ADDRESS);
        receiver.onWithdrawalReceived(
            ZONE_ID, address(portal), senderTag, address(earnShare), uint128(input), data
        );
        _assertNoApprovals(address(earnShare));
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
