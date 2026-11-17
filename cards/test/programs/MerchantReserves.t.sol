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

    function setUp() public {
        _deployPrograms();
        usd.mint(shop, 100e6);
        usd.mint(settlement, 100e6);
        vm.startPrank(shop);
        core.approveHolder(address(cards), address(usd), 50e6);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
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
        cards.reserve(other, address(usd), R1, 5e6, expiry);

        // The program's own settlement account reserves without a grant, and a reserve outside disputes runs longer.
        vm.prank(issuer);
        cards.reserve(settlement, address(usd), R1, 5e6, expiry);
        vm.prank(issuer);
        cards.reserve(shop, address(usd), R2, 5e6, uint64(vm.getBlockTimestamp() + 200 days));
        assertEq(core.available(settlement, address(usd)), 95e6);
        assertEq(core.available(shop, address(usd)), 95e6);
    }

    function test_collectReserve_paysAndReleasesRest() public {
        vm.prank(issuer);
        cards.reserve(shop, address(usd), R1, 30e6, uint64(vm.getBlockTimestamp() + 30 days));
        vm.prank(issuer);
        cards.collectReserve(R1, 20e6, other);
        assertEq(usd.balanceOf(other), 20e6);
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
        cards.reserve(shop, address(usd), R1, 30e6, uint64(vm.getBlockTimestamp() + 30 days));
        vm.prank(shop);
        cards.revoke();
        vm.prank(issuer);
        vm.expectRevert(CardProgram.NoTerms.selector);
        cards.reserve(shop, address(usd), R2, 1e6, uint64(vm.getBlockTimestamp() + 30 days));
        vm.prank(issuer);
        cards.releaseReserve(R1);
        assertEq(core.available(shop, address(usd)), 100e6);
    }

    function test_reserve_expiresOnlyWhenReleased() public {
        vm.prank(issuer);
        cards.reserve(shop, address(usd), R1, 30e6, uint64(vm.getBlockTimestamp() + 1 days));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(core.available(shop, address(usd)), 70e6);
        vm.prank(other);
        core.releaseExpiredLien(address(cards), R1);
        assertEq(core.available(shop, address(usd)), 100e6);
    }

    function test_setSettlementToken_waitsForReserves() public {
        vm.prank(issuer);
        cards.reserve(settlement, address(usd), R1, 5e6, uint64(vm.getBlockTimestamp() + 1 days));
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SettlementTokenInUse.selector, uint8(1)));
        cards.setSettlementToken(address(otherUsd));
        vm.prank(issuer);
        cards.releaseReserve(R1);
        (,, uint128 amount,,) = core.lienOf(address(cards), R1);
        assertEq(amount, 0);
    }
}
