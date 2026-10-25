// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ISpenderHandler } from "bridge-spender/src/ISpenderHandler.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import {
    IZoneFactory,
    IZonePortal,
    ZONE_FACTORY_ADDRESS,
    ZONE_MESSENGER_ADDRESS,
    ZoneInfo
} from "tempo-zones/interfaces/IZone.sol";

import { Spend } from "../../src/SpenderTempoSpend.sol";
import { ZoneSpendReceiver } from "../../src/ZoneSpendReceiver.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { AccessKeys } from "../harness/AccessKeys.sol";
import { NoopSpendHandler, OverReturningSpendHandler, ReentrantToken } from "../harness/Mocks.sol";

/// @notice The receiver only settles callbacks from the canonical messenger, portal and Zone.
contract ZoneSpendReceiverTest is AccessKeys {
    ZoneSpendReceiver internal receiver;

    function setUp() public {
        _deployTempo();
        _deployZone(false);
        receiver = new ZoneSpendReceiver(
            IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, ZONE_ID
        );
    }

    function test_callbackOnlyFromMessenger() public {
        vm.expectRevert(ZoneSpendReceiver.NotZoneMessenger.selector);
        receiver.onWithdrawalReceived(ZONE_ID, address(portal), bytes32(0), address(usd), 1, "");
    }

    function test_callbackOnlyFromConfiguredZone() public {
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(
            abi.encodeWithSelector(ZoneSpendReceiver.WrongSourceZone.selector, uint32(8))
        );
        receiver.onWithdrawalReceived(8, address(portal), bytes32(0), address(usd), 1, "");
    }

    function test_callbackOnlyFromCanonicalPortal() public {
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneSpendReceiver.InvalidSourcePortal.selector);
        receiver.onWithdrawalReceived(
            ZONE_ID, makeAddr("fake.portal"), bytes32(0), address(usd), 1, ""
        );
    }

    function test_requiresAZone() public {
        vm.expectRevert(ZoneSpendReceiver.InvalidZone.selector);
        new ZoneSpendReceiver(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, 0);
    }

    function test_requiresAFactory() public {
        vm.expectRevert(ZoneSpendReceiver.ZeroAddress.selector);
        new ZoneSpendReceiver(IBridgeSpenderFactory(address(0)), SPENDER_ID, ZONE_ID);
    }

    /// @notice A handler under "TS" that moves nothing cannot make a callback look settled.
    function test_callbackRejectsAHandlerThatSettlesNothing() public {
        NoopSpendHandler noop = new NoopSpendHandler(IFactory(address(bridgeFactory)));
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler(PREFIX_TEMPO_SPEND, ISpenderHandler(address(noop)));
        _mintUsd(address(receiver), 10e6);

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneSpendReceiver.NothingSettled.selector);
        receiver.onWithdrawalReceived(
            ZONE_ID, address(portal), bytes32(0), address(usd), 10e6, _spendCallback(10e6)
        );
    }

    /// @notice A handler that hands back more input than it was given cannot look settled, even
    ///         when it pays the destination.
    function test_callbackRejectsAHandlerThatReturnsMoreThanItWasGiven() public {
        OverReturningSpendHandler generous =
            new OverReturningSpendHandler(IFactory(address(bridgeFactory)));
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler(PREFIX_TEMPO_SPEND, ISpenderHandler(address(generous)));
        _mintUsd(spender, 11e6);
        _mintUsd(address(receiver), 10e6);
        bytes memory callbackData = _spendCallback(10e6);

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneSpendReceiver.NothingSettled.selector);
        receiver.onWithdrawalReceived(
            ZONE_ID, address(portal), bytes32(0), address(usd), 10e6, callbackData
        );
    }

    /// @notice A portal the factory does not register as one cannot settle or take a refund.
    function test_callbackAndRefundRejectAnUnregisteredPortal() public {
        vm.mockCall(
            ZONE_FACTORY_ADDRESS,
            abi.encodeCall(IZoneFactory.isZonePortal, (address(portal))),
            abi.encode(false)
        );
        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(ZoneSpendReceiver.InvalidSourcePortal.selector);
        receiver.onWithdrawalReceived(ZONE_ID, address(portal), bytes32(0), address(usd), 1, "");

        ZoneSpendReceiver.ZoneReturn memory ret = _return();
        vm.startPrank(programWallet);
        usd.approve(address(receiver), 5e6);
        vm.expectRevert(ZoneSpendReceiver.InvalidSourcePortal.selector);
        receiver.refundPrivate(address(usd), 5e6, ret);
        vm.stopPrank();
    }

    /// @notice Unused input the portal did not take back makes the callback revert.
    function test_callbackRejectsAResidualBalance() public {
        vm.mockCall(
            address(portal),
            abi.encodeWithSelector(IZonePortal.depositEncrypted.selector),
            abi.encode(bytes32(0))
        );
        _mintUsd(address(receiver), 15e6);

        vm.prank(ZONE_MESSENGER_ADDRESS);
        vm.expectRevert(
            abi.encodeWithSelector(ZoneSpendReceiver.ResidualBalance.selector, address(usd))
        );
        receiver.onWithdrawalReceived(
            ZONE_ID, address(portal), bytes32(0), address(usd), 15e6, _spendCallback(10e6)
        );
    }

    function test_privateRefundEmitsPrivateRefundCredited() public {
        vm.startPrank(programWallet);
        usd.approve(address(receiver), 5e6);
        vm.expectEmit(true, true, true, true, address(receiver));
        emit ZoneSpendReceiver.PrivateRefundCredited(address(usd), 5e6);
        receiver.refundPrivate(address(usd), 5e6, _return());
        vm.stopPrank();
    }

    function test_privateRefundRejectsZeroAmount() public {
        vm.prank(programWallet);
        vm.expectRevert(ZoneSpendReceiver.InvalidAmount.selector);
        receiver.refundPrivate(address(usd), 0, _return());
    }

    /// @notice A refund above what the portal's `uint128` deposit can carry reverts instead of
    ///         stranding the rest in the receiver.
    function test_privateRefundRejectsAnAmountAboveUint128() public {
        ZoneSpendReceiver.ZoneReturn memory ret = _return();
        vm.prank(programWallet);
        vm.expectRevert(ZoneSpendReceiver.InvalidAmount.selector);
        receiver.refundPrivate(address(usd), uint256(type(uint128).max) + 1, ret);
    }

    function test_privateRefundStopsWhenProgramPaused() public {
        vm.prank(bridgePauser);
        bridgeFactory.pause();
        vm.startPrank(programWallet);
        usd.approve(address(receiver), 5e6);
        vm.expectRevert(ZoneSpendReceiver.ProgramPaused.selector);
        receiver.refundPrivate(address(usd), 5e6, _return());
        vm.stopPrank();
    }

    /// @notice A refund whose deposit fee is above its cap reverts, so the Zone admin cannot keep
    ///         most of it by raising the fee.
    function test_privateRefundRejectsADepositFeeAboveItsCap() public {
        ZoneSpendReceiver.ZoneReturn memory ret = _return();
        ret.maxDepositFee = portal.calculateDepositFee();
        vm.prank(zoneAdmin);
        portal.setZoneGasRate(1000);
        uint128 fee = portal.calculateDepositFee();
        assertGt(fee, ret.maxDepositFee, "fee raised");
        vm.startPrank(programWallet);
        usd.approve(address(receiver), 5e6);
        vm.expectRevert(abi.encodeWithSelector(ZoneSpendReceiver.DepositFeeTooHigh.selector, fee));
        receiver.refundPrivate(address(usd), 5e6, ret);
        vm.stopPrank();
    }

    /// @notice A Zone the factory reports without a portal cannot be paid into.
    function test_privateRefundNeedsTheZonesPortal() public {
        ZoneInfo memory zone = IZoneFactory(ZONE_FACTORY_ADDRESS).zones(ZONE_ID);
        zone.portal = address(0);
        vm.mockCall(
            ZONE_FACTORY_ADDRESS, abi.encodeCall(IZoneFactory.zones, (ZONE_ID)), abi.encode(zone)
        );
        vm.startPrank(programWallet);
        usd.approve(address(receiver), 5e6);
        vm.expectRevert(ZoneSpendReceiver.InvalidSourcePortal.selector);
        receiver.refundPrivate(address(usd), 5e6, _return());
        vm.stopPrank();
    }

    /// @notice A token that calls back into the receiver during a refund hits the reentrancy lock.
    function test_privateRefundRejectsReentrancy() public {
        ReentrantToken token = new ReentrantToken();
        token.mint(programWallet, 5e6);
        token.arm(
            address(receiver),
            abi.encodeCall(ZoneSpendReceiver.refundPrivate, (address(token), 1, _return()))
        );
        vm.mockCall(
            address(portal),
            abi.encodeWithSelector(IZonePortal.depositEncrypted.selector),
            abi.encode(bytes32(0))
        );
        vm.startPrank(programWallet);
        token.approve(address(receiver), 5e6);
        receiver.refundPrivate(address(token), 5e6, _return());
        vm.stopPrank();

        assertTrue(token.reentered(), "token re-entered");
        assertEq(bytes4(token.reentryError()), ZoneSpendReceiver.Reentrancy.selector);
    }

    function test_privateRefundIsStablecoinIntoTheZone() public {
        uint256 portalBefore = usd.balanceOf(address(portal));
        vm.startPrank(programWallet);
        usd.approve(address(receiver), 5e6);
        receiver.refundPrivate(address(usd), 5e6, _return());
        vm.stopPrank();
        assertEq(usd.balanceOf(address(portal)) - portalBefore, 5e6, "deposited into the Zone");
        assertEq(usd.balanceOf(address(receiver)), 0);
    }

    /// @notice The receiver can be a Zone's callback gateway, so only a program destination may
    ///         deposit through it.
    function test_privateRefundOnlyFromAProgramDestination() public {
        address outsider = makeAddr("outsider");
        _mintUsd(outsider, 5e6);
        vm.startPrank(outsider);
        usd.approve(address(receiver), 5e6);
        vm.expectRevert(
            abi.encodeWithSelector(ZoneSpendReceiver.NotProgramDestination.selector, outsider)
        );
        receiver.refundPrivate(address(usd), 5e6, _return());
        vm.stopPrank();
    }

    /// @notice Removing the destination stops its refunds.
    function test_privateRefundStopsWhenDestinationRemoved() public {
        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderDestination(SPENDER_ID, programWallet, false);
        vm.startPrank(programWallet);
        usd.approve(address(receiver), 5e6);
        vm.expectRevert(
            abi.encodeWithSelector(ZoneSpendReceiver.NotProgramDestination.selector, programWallet)
        );
        receiver.refundPrivate(address(usd), 5e6, _return());
        vm.stopPrank();
    }

    function _spendCallback(uint256 amount) internal returns (bytes memory) {
        Spend memory spend = Spend({
            spenderId: SPENDER_ID,
            token: address(usd),
            amount: amount,
            destination: settlement,
            vault: address(0),
            fromVault: 0,
            maxShares: 0,
            ref: bytes32(0)
        });
        return abi.encode(spend, _return());
    }

    function _return() internal returns (ZoneSpendReceiver.ZoneReturn memory) {
        return ZoneSpendReceiver.ZoneReturn({
            keyIndex: 0,
            encrypted: _encryptedTo(makeAddr("alice")),
            refundRecipient: programWallet,
            maxDepositFee: type(uint128).max
        });
    }
}
