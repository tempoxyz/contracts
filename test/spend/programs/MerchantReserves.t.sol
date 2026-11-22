// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { MerchantReserves } from "../../../src/spend/programs/MerchantReserves.sol";
import { IReservationCore } from "../../../src/interfaces/spend/programs/IReservationCore.sol";
import { CompCardAuth, CompEnv } from "./harness/CompStubs.sol";

/// @notice Merchant reserves: pledges on balances that approved the reserves contract, for purposes the owner
///         consented to and never collected past its cap; dispute reserves once the merchant allowed them, within the
///         dispute window; every collection pays the program's settlement account.
contract MerchantReservesTest is CompEnv {
    uint8 internal constant PLEDGE_KIND = 2;
    bytes32 internal constant FEES = bytes32("fees");
    bytes32 internal constant REF = bytes32("purchase-1");
    bytes32 internal constant R1 = bytes32("reserve-1");
    bytes32 internal constant R2 = bytes32("reserve-2");
    address internal shop = makeAddr("shop");
    address internal other = makeAddr("other");
    bytes32 internal shopR1;
    bytes32 internal shopR2;
    bytes32 internal settlementR1;
    bytes32 internal settlementR2;

    function setUp() public {
        _deployComp();
        (shopR1, shopR2) = (reserves.reserveRefId(shop, R1), reserves.reserveRefId(shop, R2));
        (settlementR1, settlementR2) = (reserves.reserveRefId(settlement, R1), reserves.reserveRefId(settlement, R2));
        usd.mint(shop, 100e6);
        usd.mint(settlement, 100e6);
        vm.startPrank(shop);
        core.approveHolder(address(reserves), address(usd), 50e6, 0);
        reserves.allowReserves(address(usd), 40e6, FEES);
        vm.stopPrank();
        vm.prank(settlement);
        core.approveHolder(address(reserves), address(usd), type(uint128).max, 0);
    }

    function test_reserveDispute_needsConsentAndWindow() public {
        uint64 expiry = uint64(vm.getBlockTimestamp() + 120 days);
        vm.prank(issuer);
        vm.expectRevert(MerchantReserves.ReserveNotAllowed.selector);
        reserves.reserveDispute(
            shop, address(usd), REF, [uint128(30e6), uint128(50e6)], [uint128(30e6), uint128(50e6)], expiry
        );
        vm.prank(shop);
        reserves.setDisputeReserves(true);
        vm.prank(issuer);
        vm.expectRevert(MerchantReserves.ReserveTooLong.selector);
        reserves.reserveDispute(
            shop, address(usd), REF, [uint128(30e6), uint128(50e6)], [uint128(30e6), uint128(50e6)], expiry + 1 days
        );
        vm.prank(issuer);
        reserves.reserveDispute(
            shop, address(usd), REF, [uint128(30e6), uint128(50e6)], [uint128(30e6), uint128(50e6)], expiry
        );
        // Each reserve is a pledge to the reserves contract, keyed by the owner.
        IReservationCore.HoldRecord memory h = core.getHold(shop, address(reserves), reserves.reserveId(REF, shop));
        assertEq(h.held, 30e6);
        assertEq(h.expiresAt, expiry);
        assertEq(h.payee, address(reserves));
        assertEq(h.kind, PLEDGE_KIND);
        h = core.getHold(settlement, address(reserves), reserves.reserveId(REF, settlement));
        assertEq(h.held, 50e6);
        assertEq(core.available(shop, address(usd)), 70e6);
        assertEq(core.available(settlement, address(usd)), 50e6);
        // The merchant's holder allowance bounds what is reserved on it.
        vm.prank(issuer);
        vm.expectRevert(IReservationCore.BudgetExceeded.selector);
        reserves.reserveDispute(
            shop, address(usd), bytes32("purchase-2"), [uint128(21e6), uint128(0)], [uint128(21e6), uint128(0)], expiry
        );
        _assertCoreBalanced();
    }

    function test_reserve_settlementAccountNeedsNoConsent_othersDo() public {
        uint64 expiry = uint64(vm.getBlockTimestamp() + 90 days);
        usd.mint(other, 10e6);
        vm.prank(other);
        core.approveHolder(address(reserves), address(usd), 10e6, 0);
        // A holder allowance alone lets no one lien the balance.
        vm.prank(issuer);
        vm.expectRevert(MerchantReserves.ReserveNotAllowed.selector);
        reserves.reserve(other, address(usd), R1, 5e6, expiry, FEES);
        vm.prank(issuer);
        reserves.reserve(settlement, address(usd), R1, 5e6, expiry, FEES);
        // A reserve outside disputes may run longer than the dispute window.
        vm.prank(issuer);
        reserves.reserve(shop, address(usd), R2, 5e6, uint64(vm.getBlockTimestamp() + 200 days), FEES);
        assertEq(core.available(settlement, address(usd)), 95e6);
        assertEq(core.available(shop, address(usd)), 95e6);
    }

    function test_reserve_needsTheOwnersConsentForItsPurpose() public {
        uint64 expiry = uint64(vm.getBlockTimestamp() + 30 days);
        vm.prank(issuer);
        vm.expectRevert(MerchantReserves.ReserveNotAllowed.selector);
        reserves.reserve(shop, address(usd), R1, 5e6, expiry, bytes32("chargebacks"));
        vm.prank(issuer);
        vm.expectRevert(MerchantReserves.ReserveNotAllowed.selector);
        reserves.reserve(shop, address(usd), R1, 40e6 + 1, expiry, FEES);
        vm.prank(issuer);
        reserves.reserve(shop, address(usd), R1, 40e6, expiry, FEES);
        (uint128 cap, uint128 collected, bytes32 purpose) = reserves.consentOf(shop, address(usd));
        assertEq(cap, 40e6);
        assertEq(collected, 0);
        assertEq(purpose, FEES);
        // The same reference cannot name a second live reserve on the same owner.
        vm.prank(issuer);
        vm.expectRevert(MerchantReserves.ReserveExists.selector);
        reserves.reserve(shop, address(usd), R1, 0, expiry, FEES);
    }

    function test_reserve_onlyTheIssuerOrATreasuryOperatorWithinItsCap() public {
        uint64 expiry = uint64(vm.getBlockTimestamp() + 30 days);
        vm.prank(bob);
        vm.expectRevert(MerchantReserves.NotOperator.selector);
        reserves.reserve(shop, address(usd), R1, 5e6, expiry, FEES);
        auth.setRoles(operator, SETTLE, 100e6);
        vm.prank(operator);
        vm.expectRevert(MerchantReserves.NotOperator.selector);
        reserves.reserve(shop, address(usd), R1, 5e6, expiry, FEES);
        auth.setRoles(operator, TREASURY, 10e6);
        vm.prank(operator);
        vm.expectRevert();
        reserves.reserve(shop, address(usd), R1, 10e6 + 1, expiry, FEES);
        vm.prank(operator);
        reserves.reserve(shop, address(usd), R1, 10e6, expiry, FEES);
        // Collecting the merchant's reserve counts against the cap too.
        vm.prank(operator);
        vm.expectRevert();
        reserves.collectReserve(shopR1, 1);
    }

    function test_reserve_operatorCapCountsReservesOnTheSettlementAccount() public {
        uint64 expiry = uint64(vm.getBlockTimestamp() + 30 days);
        auth.setRoles(operator, TREASURY, 10e6);
        vm.prank(operator);
        vm.expectRevert(CompCardAuth.CapExceeded.selector);
        reserves.reserve(settlement, address(usd), R1, 10e6 + 1, expiry, FEES);
        vm.prank(operator);
        reserves.reserve(settlement, address(usd), R1, 10e6, expiry, FEES);
        vm.prank(operator);
        vm.expectRevert(CompCardAuth.CapExceeded.selector);
        reserves.reserve(settlement, address(usd), R2, 1, expiry, FEES);
        assertEq(core.available(settlement, address(usd)), 90e6);
    }

    function test_reserve_operatorCapCountsBothSidesOfADisputeReserve() public {
        vm.prank(shop);
        reserves.setDisputeReserves(true);
        auth.setRoles(operator, TREASURY, 30e6);
        uint64 expiry = uint64(vm.getBlockTimestamp() + 30 days);
        vm.prank(operator);
        vm.expectRevert(CompCardAuth.CapExceeded.selector);
        reserves.reserveDispute(
            shop, address(usd), REF, [uint128(10e6), uint128(20e6 + 1)], [uint128(10e6), uint128(20e6 + 1)], expiry
        );
        vm.prank(operator);
        reserves.reserveDispute(
            shop, address(usd), REF, [uint128(10e6), uint128(20e6)], [uint128(10e6), uint128(20e6)], expiry
        );
    }

    function test_reserve_cannotTakeTheIdOfADisputeReserve() public {
        vm.prank(shop);
        reserves.setDisputeReserves(true);
        uint64 expiry = uint64(vm.getBlockTimestamp() + 30 days);
        // A reserve named after the purchase, on either side, lands under a different id from the dispute's.
        vm.startPrank(issuer);
        reserves.reserve(settlement, address(usd), REF, 1, expiry, FEES);
        reserves.reserve(shop, address(usd), REF, 1, expiry, FEES);
        reserves.reserveDispute(
            shop, address(usd), REF, [uint128(10e6), uint128(5e6)], [uint128(10e6), uint128(5e6)], expiry
        );
        vm.stopPrank();
        assertEq(core.getHold(shop, address(reserves), reserves.reserveId(REF, shop)).held, 10e6);
        assertEq(core.getHold(settlement, address(reserves), reserves.reserveId(REF, settlement)).held, 5e6);
    }

    function test_reserve_sameReferenceOnTwoOwnersNamesTwoReserves() public {
        uint64 expiry = uint64(vm.getBlockTimestamp() + 30 days);
        vm.startPrank(issuer);
        reserves.reserve(settlement, address(usd), R1, 5e6, expiry, FEES);
        reserves.reserve(shop, address(usd), R1, 7e6, expiry, FEES);
        vm.stopPrank();
        assertEq(core.getHold(settlement, address(reserves), settlementR1).held, 5e6);
        assertEq(core.getHold(shop, address(reserves), shopR1).held, 7e6);
    }

    function test_collectReserve_neverPastTheCapAndOnlyToTheSettlementAccount() public {
        uint64 expiry = uint64(vm.getBlockTimestamp() + 30 days);
        vm.startPrank(issuer);
        reserves.reserve(shop, address(usd), R1, 25e6, expiry, FEES);
        reserves.reserve(shop, address(usd), R2, 25e6, expiry, FEES);
        reserves.collectReserve(shopR1, 25e6);
        // 15 dollars of the cap are left: the second reserve cannot be collected in full.
        vm.expectRevert(MerchantReserves.ReserveNotAllowed.selector);
        reserves.collectReserve(shopR2, 15e6 + 1);
        reserves.collectReserve(shopR2, 15e6);
        vm.stopPrank();
        (, uint128 collected,) = reserves.consentOf(shop, address(usd));
        assertEq(collected, 40e6);
        assertEq(usd.balanceOf(settlement), 140e6);
        assertEq(usd.balanceOf(shop), 60e6);
        assertEq(usd.balanceOf(issuer), 0);
        assertEq(usd.balanceOf(address(reserves)), 0);
        vm.prank(issuer);
        vm.expectRevert(MerchantReserves.ReserveNotAllowed.selector);
        reserves.reserve(shop, address(usd), bytes32("reserve-3"), 1, expiry, FEES);
        _assertCoreBalanced();
    }

    function test_collectReserve_refusedOnceTheOwnerWithdrawsConsent() public {
        vm.prank(issuer);
        reserves.reserve(shop, address(usd), R1, 30e6, uint64(vm.getBlockTimestamp() + 30 days), FEES);
        vm.prank(shop);
        reserves.allowReserves(address(usd), 0, FEES);
        vm.prank(issuer);
        vm.expectRevert(MerchantReserves.ReserveNotAllowed.selector);
        reserves.collectReserve(shopR1, 1e6);
        vm.prank(issuer);
        reserves.collectReserve(shopR1, 0);
        assertEq(core.available(shop, address(usd)), 100e6);
    }

    function test_collectReserve_disputeReservePaysTheSettlementAccount() public {
        vm.prank(shop);
        reserves.setDisputeReserves(true);
        vm.prank(issuer);
        reserves.reserveDispute(
            shop,
            address(usd),
            REF,
            [uint128(30e6), uint128(0)],
            [uint128(30e6), uint128(0)],
            uint64(vm.getBlockTimestamp() + 30 days)
        );
        bytes32 id = reserves.reserveId(REF, shop);
        vm.prank(issuer);
        reserves.collectReserve(id, 30e6);
        assertEq(usd.balanceOf(settlement), 130e6);
        // A dispute reserve does not use the shop's reserve consent.
        (, uint128 collected,) = reserves.consentOf(shop, address(usd));
        assertEq(collected, 0);
    }

    function test_collectReserve_paysAndReleasesRest() public {
        vm.prank(issuer);
        reserves.reserve(shop, address(usd), R1, 30e6, uint64(vm.getBlockTimestamp() + 30 days), FEES);
        vm.prank(issuer);
        reserves.collectReserve(shopR1, 20e6);
        assertEq(usd.balanceOf(settlement), 120e6);
        assertEq(usd.balanceOf(shop), 80e6);
        assertEq(core.available(shop, address(usd)), 80e6);
        assertEq(core.getHold(shop, address(reserves), shopR1).held, 0);
        assertEq(core.budget(shop, address(reserves), address(usd)).outstanding, 0);
        _assertCoreBalanced();
    }

    function test_reserve_revokedAllowanceStillReleases() public {
        vm.prank(issuer);
        reserves.reserve(shop, address(usd), R1, 30e6, uint64(vm.getBlockTimestamp() + 30 days), FEES);
        vm.prank(shop);
        core.approveHolder(address(reserves), address(usd), 0, 0);
        vm.prank(issuer);
        vm.expectRevert();
        reserves.reserve(shop, address(usd), R2, 1e6, uint64(vm.getBlockTimestamp() + 30 days), FEES);
        vm.prank(issuer);
        reserves.releaseReserve(shopR1);
        assertEq(core.available(shop, address(usd)), 100e6);
    }

    function test_reserve_expiresOnlyWhenReleased() public {
        vm.prank(issuer);
        reserves.reserve(shop, address(usd), R1, 30e6, uint64(vm.getBlockTimestamp() + 1 days), FEES);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(core.available(shop, address(usd)), 70e6);
        vm.prank(other);
        core.releaseExpired(shop, address(reserves), shopR1);
        assertEq(core.available(shop, address(usd)), 100e6);
    }

    function test_settlementTokenInUse_whileAReserveIsHeld() public {
        assertEq(reserves.settlementTokenInUse(address(auth)), 0);
        vm.prank(issuer);
        reserves.reserve(settlement, address(usd), R1, 5e6, uint64(vm.getBlockTimestamp() + 1 days), FEES);
        assertEq(reserves.settlementTokenInUse(address(auth)), 9);
        vm.prank(issuer);
        reserves.releaseReserve(settlementR1);
        assertEq(reserves.settlementTokenInUse(address(auth)), 0);
        // Ended reserves are pruned as new ones are placed.
        vm.prank(issuer);
        reserves.reserve(settlement, address(usd), R2, 5e6, uint64(vm.getBlockTimestamp() + 1 days), FEES);
        vm.prank(issuer);
        reserves.collectReserve(settlementR2, 0);
        assertEq(reserves.settlementTokenInUse(address(auth)), 0);
    }
}
