// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CompEnv } from "./harness/CompStubs.sol";

/// @notice Gas of the companions' main paths over the core model, snapshotted to snapshots/CompanionGas.json.
contract CompanionGasTest is CompEnv {
    bytes32 internal constant REF = bytes32("purchase-1");
    bytes32 internal constant LEG = bytes32("leg-1");
    uint64 internal lineId;

    function setUp() public {
        _deployComp();
        lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 1500);
        auth.setRoles(operator, TREASURY | SETTLE, type(uint256).max);
        // repayFor and redraw are for the program's companions, such as its issuer desk.
        auth.setCompanion(operator, true);
    }

    function test_gas_credit() public {
        auth.hold(credit, alice, _pos(lineId), LEG, 100e6);
        vm.snapshotGasLastCall("CompanionGas", "credit_hold");
        auth.capture(credit, alice, LEG, 100e6, true, REF);
        vm.snapshotGasLastCall("CompanionGas", "credit_captureFinal");
        auth.refundLeg(credit, alice, LEG, 20e6);
        vm.snapshotGasLastCall("CompanionGas", "credit_refund");
        vm.warp(vm.getBlockTimestamp() + 30 days);
        credit.accrue(lineId);
        vm.snapshotGasLastCall("CompanionGas", "credit_accrue");
        usd.mint(operator, 100e6);
        vm.startPrank(operator);
        usd.approve(address(credit), 100e6);
        credit.repayFor(lineId, 50e6, REF);
        vm.snapshotGasLastCall("CompanionGas", "credit_repayFor");
        credit.redraw(lineId, 50e6, REF);
        vm.snapshotGasLastCall("CompanionGas", "credit_redraw");
        credit.repay(lineId, 30e6);
        vm.snapshotGasLastCall("CompanionGas", "credit_repay");
        vm.stopPrank();
        vm.prank(lender);
        credit.closeStatement(lineId, uint64(vm.getBlockTimestamp() + 1 days));
        vm.snapshotGasLastCall("CompanionGas", "credit_closeStatement");
        usd.mint(alice, 100e6);
        vm.prank(alice);
        usd.approve(address(credit), type(uint256).max);
        address[] memory sources = new address[](1);
        sources[0] = address(usd);
        vm.prank(alice);
        credit.setAutopay(lineId, sources);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        credit.collect(lineId);
        vm.snapshotGasLastCall("CompanionGas", "credit_collect");
    }

    function test_gas_treasury() public {
        vm.startPrank(settlement);
        usd.approve(address(treasury), type(uint256).max);
        core.approveHolder(address(treasury), address(usd), type(uint128).max, 0);
        vm.stopPrank();
        usd.mint(address(this), 50e6);
        usd.approve(address(treasury), 50e6);
        treasury.fundIssuerDebt(address(usd), 50e6);
        vm.snapshotGasLastCall("CompanionGas", "treasury_fundIssuerDebt");
        usd.mint(settlement, 30e6);
        vm.prank(operator);
        treasury.payOut(bob, 20e6, bytes32("memo"));
        vm.snapshotGasLastCall("CompanionGas", "treasury_payOut");
        vm.prank(operator);
        treasury.payOut(bob, 30e6, bytes32("memo"));
        vm.snapshotGasLastCall("CompanionGas", "treasury_payOutAdvanced");
        usd.mint(settlement, 20e6);
        vm.prank(operator);
        treasury.repayAdvance(address(usd), 20e6);
        vm.snapshotGasLastCall("CompanionGas", "treasury_repayAdvance");
        usd.mint(settlement, 100e6);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(address(treasury), address(usd), id, 100e6, uint64(vm.getBlockTimestamp() + 365 days));
        treasury.post(bob, IEarnVault(address(0)), 1);
        vm.snapshotGasLastCall("CompanionGas", "treasury_postCollateral");
        vm.stopPrank();
        auth.setExposure(40e6, 0);
        vm.prank(bob);
        treasury.seize(40e6);
        vm.snapshotGasLastCall("CompanionGas", "treasury_seize");
    }

    function test_gas_reserves() public {
        address shop = makeAddr("shop");
        usd.mint(shop, 100e6);
        vm.startPrank(shop);
        core.approveHolder(address(reserves), address(usd), 100e6, 0);
        reserves.allowReserves(address(usd), 100e6, bytes32("fees"));
        reserves.setDisputeReserves(true);
        vm.stopPrank();
        vm.prank(operator);
        reserves.reserve(shop, address(usd), bytes32("r1"), 30e6, uint64(vm.getBlockTimestamp() + 30 days), "fees");
        vm.snapshotGasLastCall("CompanionGas", "reserves_reserve");
        vm.prank(operator);
        reserves.reserveDispute(
            shop,
            address(usd),
            REF,
            [uint128(20e6), uint128(0)],
            [uint128(20e6), uint128(0)],
            uint64(vm.getBlockTimestamp() + 30 days)
        );
        vm.snapshotGasLastCall("CompanionGas", "reserves_reserveDispute");
        bytes32 id = reserves.reserveRefId(shop, bytes32("r1"));
        vm.prank(operator);
        reserves.collectReserve(id, 10e6);
        vm.snapshotGasLastCall("CompanionGas", "reserves_collectReserve");
    }

    function test_gas_desk() public {
        // A purchase of 100: 60 on the line, 40 in cash, disputed in full.
        _draw(alice, lineId, LEG, 60e6, REF);
        auth.setPurchase(REF, alice, 100e6, 0);
        vm.prank(alice);
        core.approveHolder(address(desk), address(usd), type(uint128).max, 0);
        usd.mint(settlement, 200e6);
        vm.prank(operator);
        desk.openDispute(REF, 100e6, hex"c1a1");
        vm.snapshotGasLastCall("CompanionGas", "desk_openDispute");
        vm.prank(operator);
        desk.disputeStep(REF, 2, 100e6, "", false);
        vm.snapshotGasLastCall("CompanionGas", "desk_disputeStepOnCredit");
        vm.prank(operator);
        desk.resolveDispute(REF, false);
        vm.snapshotGasLastCall("CompanionGas", "desk_resolveMerchantWins");
        bytes32 p2 = bytes32("purchase-2");
        auth.setPurchase(p2, alice, 50e6, 0);
        vm.prank(operator);
        desk.openDispute(p2, 50e6, "");
        vm.prank(operator);
        desk.disputeStep(p2, 2, 20e6, "", false);
        vm.snapshotGasLastCall("CompanionGas", "desk_disputeStepCash");
        vm.prank(operator);
        desk.resolveDispute(p2, true);
        vm.snapshotGasLastCall("CompanionGas", "desk_resolveCardholderWins");
        bytes32 p3 = bytes32("purchase-3");
        auth.setPurchase(p3, alice, 50e6, 0);
        vm.prank(operator);
        desk.refund(p3, 10e6);
        vm.snapshotGasLastCall("CompanionGas", "desk_refund");
    }
}
