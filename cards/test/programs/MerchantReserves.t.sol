// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardLimits } from "../../src/programs/CardLimits.sol";
import { CardProgram } from "../../src/programs/CardProgram.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice Merchant reserves: an acquirer's program holds back part of a merchant's balance with holder pledges
///         inside the mandate the merchant granted, and collects or releases them.
contract MerchantReservesTest is ProgramsEnv {
    address internal shop = makeAddr("shop");
    address internal other = makeAddr("other");
    bytes32 internal constant R1 = bytes32("reserve-1");
    bytes32 internal constant R2 = bytes32("reserve-2");
    bytes32 internal constant REF = bytes32("purchase");
    bytes32 internal constant FEES = bytes32("fees");

    function setUp() public {
        _deployPrograms();
        usd.mint(shop, 100e6);
        usd.mint(settlement, 100e6);
        vm.startPrank(shop);
        core.approveHolder(address(cards), address(usd), 50e6);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
        cards.allowReserves(address(usd), 40e6, FEES);
        vm.stopPrank();
        vm.prank(settlement);
        core.approveHolder(address(cards), address(usd), type(uint128).max);
    }

    function test_reserveDispute_needsConsentAndWindow() public {
        uint64 expiry = uint64(vm.getBlockTimestamp() + 120 days);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.ReserveNotAllowed.selector);
        cards.reserveDispute(
            shop, address(usd), REF, [uint128(30e6), uint128(50e6)], [uint128(30e6), uint128(50e6)], expiry
        );
        vm.prank(issuer);
        vm.expectRevert(CardProgram.NoTerms.selector);
        cards.reserveDispute(other, address(usd), REF, [uint128(0), uint128(50e6)], [uint128(0), uint128(50e6)], expiry);

        vm.prank(shop);
        cards.setDisputeReserves(true);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.ReserveTooLong.selector);
        cards.reserveDispute(
            shop, address(usd), REF, [uint128(30e6), uint128(50e6)], [uint128(30e6), uint128(50e6)], expiry + 1 days
        );
        vm.prank(issuer);
        cards.reserveDispute(
            shop, address(usd), REF, [uint128(30e6), uint128(50e6)], [uint128(30e6), uint128(50e6)], expiry
        );

        (address owner,, uint128 amount, uint64 expiresAt, bool pledged) =
            core.lienOf(address(cards), cards.reserveId(REF, shop));
        assertEq(owner, shop);
        assertEq(amount, 30e6);
        assertEq(expiresAt, expiry);
        assertTrue(pledged);
        (owner,, amount,,) = core.lienOf(address(cards), cards.reserveId(REF, settlement));
        assertEq(owner, settlement);
        assertEq(amount, 50e6);
        assertEq(core.available(shop, address(usd)), 70e6);
        assertEq(core.available(settlement, address(usd)), 50e6);

        // The mandate's limit bounds what the program reserves on the merchant.
        vm.prank(issuer);
        vm.expectRevert(IReservationCore.AllowanceExceeded.selector);
        cards.reserveDispute(
            shop, address(usd), bytes32("purchase-2"), [uint128(21e6), uint128(0)], [uint128(21e6), uint128(0)], expiry
        );
        _assertCoreBalanced();
    }

    function test_reserve_needsGrantExceptSettlement() public {
        uint64 expiry = uint64(vm.getBlockTimestamp() + 90 days);
        usd.mint(other, 10e6);
        vm.prank(other);
        core.approveHolder(address(cards), address(usd), 10e6);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.NoTerms.selector);
        cards.reserve(other, address(usd), R1, 5e6, expiry, FEES);

        // The program's own settlement account reserves without a grant, and a reserve outside disputes runs longer.
        vm.prank(issuer);
        cards.reserve(settlement, address(usd), R1, 5e6, expiry, FEES);
        vm.prank(issuer);
        cards.reserve(shop, address(usd), R2, 5e6, uint64(vm.getBlockTimestamp() + 200 days), FEES);
        assertEq(core.available(settlement, address(usd)), 95e6);
        assertEq(core.available(shop, address(usd)), 95e6);
    }

    function test_reserve_needsTheOwnersConsentForItsPurpose() public {
        uint64 expiry = uint64(vm.getBlockTimestamp() + 30 days);
        usd.mint(other, 100e6);
        vm.startPrank(other);
        core.approveHolder(address(cards), address(usd), 100e6);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
        vm.stopPrank();
        // A grant and a holder allowance alone let no one lien the balance.
        vm.prank(issuer);
        vm.expectRevert(CardProgram.ReserveNotAllowed.selector);
        cards.reserve(other, address(usd), R1, 5e6, expiry, FEES);
        // The shop allows reserves for fees only, up to 40 dollars.
        vm.prank(issuer);
        vm.expectRevert(CardProgram.ReserveNotAllowed.selector);
        cards.reserve(shop, address(usd), R1, 5e6, expiry, bytes32("chargebacks"));
        vm.prank(issuer);
        vm.expectRevert(CardProgram.ReserveNotAllowed.selector);
        cards.reserve(shop, address(usd), R1, 40e6 + 1, expiry, FEES);
        vm.prank(issuer);
        cards.reserve(shop, address(usd), R1, 40e6, expiry, FEES);
        (uint128 cap, uint128 collected, bytes32 purpose) = cards.reserveConsent(shop, address(usd));
        assertEq(cap, 40e6);
        assertEq(collected, 0);
        assertEq(purpose, FEES);
    }

    function test_collectReserve_neverPastTheCapAndOnlyToTheSettlementAccount() public {
        uint64 expiry = uint64(vm.getBlockTimestamp() + 30 days);
        vm.prank(issuer);
        cards.reserve(shop, address(usd), R1, 25e6, expiry, FEES);
        vm.prank(issuer);
        cards.reserve(shop, address(usd), R2, 25e6, expiry, FEES);
        vm.prank(issuer);
        cards.collectReserve(R1, 25e6);
        // 15 dollars of the cap are left: the second reserve cannot be collected in full.
        vm.prank(issuer);
        vm.expectRevert(CardProgram.ReserveNotAllowed.selector);
        cards.collectReserve(R2, 15e6 + 1);
        vm.prank(issuer);
        cards.collectReserve(R2, 15e6);
        (, uint128 collected,) = cards.reserveConsent(shop, address(usd));
        assertEq(collected, 40e6);
        assertEq(usd.balanceOf(settlement), 140e6);
        assertEq(usd.balanceOf(shop), 60e6);
        assertEq(usd.balanceOf(issuer), 0);
        // With the cap spent, nothing more can be reserved.
        vm.prank(issuer);
        vm.expectRevert(CardProgram.ReserveNotAllowed.selector);
        cards.reserve(shop, address(usd), bytes32("reserve-3"), 1, expiry, FEES);
        _assertCoreBalanced();
    }

    function test_collectReserve_refusedOnceTheOwnerWithdrawsConsent() public {
        vm.prank(issuer);
        cards.reserve(shop, address(usd), R1, 30e6, uint64(vm.getBlockTimestamp() + 30 days), FEES);
        vm.prank(shop);
        cards.allowReserves(address(usd), 0, FEES);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.ReserveNotAllowed.selector);
        cards.collectReserve(R1, 1e6);
        vm.prank(issuer);
        cards.collectReserve(R1, 0);
        assertEq(core.available(shop, address(usd)), 100e6);
    }

    function test_collectReserve_disputeReservePaysTheSettlementAccount() public {
        vm.prank(shop);
        cards.setDisputeReserves(true);
        vm.prank(issuer);
        cards.reserveDispute(
            shop,
            address(usd),
            REF,
            [uint128(30e6), uint128(0)],
            [uint128(30e6), uint128(0)],
            uint64(vm.getBlockTimestamp() + 30 days)
        );
        bytes32 id = cards.reserveId(REF, shop);
        vm.prank(issuer);
        cards.collectReserve(id, 30e6);
        assertEq(usd.balanceOf(settlement), 130e6);
        // A dispute reserve does not use the shop's reserve consent.
        (, uint128 collected,) = cards.reserveConsent(shop, address(usd));
        assertEq(collected, 0);
    }

    function test_collectReserve_paysAndReleasesRest() public {
        vm.prank(issuer);
        cards.reserve(shop, address(usd), R1, 30e6, uint64(vm.getBlockTimestamp() + 30 days), FEES);
        vm.prank(issuer);
        cards.collectReserve(R1, 20e6);
        assertEq(usd.balanceOf(settlement), 120e6);
        assertEq(usd.balanceOf(shop), 80e6);
        assertEq(core.available(shop, address(usd)), 80e6);
        (,, uint128 amount,,) = core.lienOf(address(cards), R1);
        assertEq(amount, 0);
        (, uint128 outstanding) = core.allowance(shop, address(cards), address(usd));
        assertEq(outstanding, 0);
        _assertCoreBalanced();
    }

    function test_reserve_revokedMandateStillReleases() public {
        vm.prank(issuer);
        cards.reserve(shop, address(usd), R1, 30e6, uint64(vm.getBlockTimestamp() + 30 days), FEES);
        vm.prank(shop);
        cards.revoke();
        vm.prank(issuer);
        vm.expectRevert(CardProgram.NoTerms.selector);
        cards.reserve(shop, address(usd), R2, 1e6, uint64(vm.getBlockTimestamp() + 30 days), FEES);
        vm.prank(issuer);
        cards.releaseReserve(R1);
        assertEq(core.available(shop, address(usd)), 100e6);
    }

    function test_reserve_expiresOnlyWhenReleased() public {
        vm.prank(issuer);
        cards.reserve(shop, address(usd), R1, 30e6, uint64(vm.getBlockTimestamp() + 1 days), FEES);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(core.available(shop, address(usd)), 70e6);
        vm.prank(other);
        core.releaseExpiredLien(address(cards), R1);
        assertEq(core.available(shop, address(usd)), 100e6);
    }

    function test_setSettlementToken_waitsForReserves() public {
        vm.prank(issuer);
        cards.reserve(settlement, address(usd), R1, 5e6, uint64(vm.getBlockTimestamp() + 1 days), FEES);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SettlementTokenInUse.selector, uint8(1)));
        cards.setSettlementToken(address(otherUsd));
        vm.prank(issuer);
        cards.releaseReserve(R1);
        (,, uint128 amount,,) = core.lienOf(address(cards), R1);
        assertEq(amount, 0);
    }
}
