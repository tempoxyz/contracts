// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../../src/interfaces/earn/IEarnVault.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { Conversion } from "../../../src/spend/programs/Conversion.sol";
import { IssuerTreasury } from "../../../src/spend/programs/IssuerTreasury.sol";
import { IReservationCore } from "../../../src/interfaces/spend/programs/IReservationCore.sol";
import { FixedPricePool } from "./venues/FixedPricePool.sol";
import { CompEnv } from "./harness/CompStubs.sol";
import { Rates } from "./harness/Rates.sol";

/// @notice The issuer's treasury: its funds advance payouts the settlement account cannot make and stay behind the
///         program's committed exposure, the settlement token changes only after the settings delay and once nothing
///         is sized in it, carrying what the account owes the issuer across, and sponsor collateral is released and seized only within the
///         program's exposure.
contract IssuerTreasuryTest is CompEnv {
    uint256 internal constant BID = 1.0967e18;
    uint256 internal constant ASK = 1_103_310_000_000_000_000;

    ITIP20Token internal eur;
    Conversion internal conv;
    FixedPricePool internal ask;
    address internal sponsor = makeAddr("sponsor");

    function setUp() public {
        _deployComp();
        eur = _createToken("Euro", "EURX");
        conv = new Conversion(address(usd), address(this));
        FixedPricePool bid = new FixedPricePool(address(eur), address(usd), BID);
        ask = new FixedPricePool(address(eur), address(usd), ASK);
        usd.mint(address(bid), 1_000_000e6);
        eur.mint(address(ask), 1_000_000e6);
        conv.setVenue(address(eur), address(usd), address(bid), true);
        conv.setVenue(address(usd), address(eur), address(ask), false);
        Rates.set(conv, address(eur), 1.1e18);
        auth.setConversion(address(conv));
        _approveTreasury(ITIP20Token(address(usd)));
        // The issuer's own funds, which advance what the settlement account lacks.
        usd.mint(address(this), 50e6);
        usd.approve(address(treasury), 50e6);
        treasury.fundIssuerDebt(address(usd), 50e6);
    }

    function test_payOut_advancesWhatTheSettlementAccountLacksAsAReceivable() public {
        usd.mint(settlement, 5e6);
        vm.prank(settlement);
        assertEq(treasury.payOut(bob, 20e6, bytes32("credit-1")), 15e6);
        assertEq(usd.balanceOf(bob), 20e6);
        assertEq(usd.balanceOf(settlement), 0);
        assertEq(usd.balanceOf(address(treasury)), 35e6);
        assertEq(treasury.advanceOf(address(usd)), 15e6);
        assertEq(treasury.issuerFunds(address(usd)), 35e6);
        // What the account receives stays with it until it repays the treasury.
        usd.mint(settlement, 10e6);
        assertEq(treasury.advanceOf(address(usd)), 15e6);
        vm.prank(settlement);
        assertEq(treasury.repayAdvance(address(usd), 100e6), 10e6);
        assertEq(treasury.advanceOf(address(usd)), 5e6);
        assertEq(usd.balanceOf(address(treasury)), 45e6);
        assertEq(treasury.issuerFunds(address(usd)), 45e6);
        // A further payout adds to what it owes.
        vm.prank(issuer);
        assertEq(treasury.payOut(bob, 4e6, bytes32("credit-2")), 4e6);
        assertEq(treasury.advanceOf(address(usd)), 9e6);
        assertEq(usd.balanceOf(address(treasury)), 41e6);
        assertEq(usd.balanceOf(bob), 24e6);
        _assertCoreBalanced();
    }

    function test_payOut_refusedPastTheIssuersFunds() public {
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.IssuerFundsShort.selector, 51e6, 50e6));
        treasury.payOut(bob, 51e6, bytes32("credit-1"));
    }

    function test_payOut_advanceNeedsNoHolderApprovalOfTheTreasury() public {
        // The advance is the treasury's own receivable: the account never approved the treasury as a core holder.
        assertEq(core.budget(settlement, address(treasury), address(usd)).limit, 0);
        vm.prank(settlement);
        assertEq(treasury.payOut(bob, 50e6, bytes32("credit-1")), 50e6);
        assertEq(treasury.advanceOf(address(usd)), 50e6);
        assertEq(core.reserved(settlement, address(usd)), 0);
    }

    function test_repayAdvance_onlyTheAccountIssuerOrATreasuryOperator_atMostWhatIsOwedAndFree() public {
        vm.prank(settlement);
        treasury.payOut(bob, 20e6, bytes32("credit-1"));
        usd.mint(settlement, 30e6);
        vm.prank(bob);
        vm.expectRevert(IssuerTreasury.NotIssuer.selector);
        treasury.repayAdvance(address(usd), 1e6);
        auth.setRoles(operator, SETTLE, 100e6);
        vm.prank(operator);
        vm.expectRevert(IssuerTreasury.NotIssuer.selector);
        treasury.repayAdvance(address(usd), 1e6);
        // A treasury key repays without using its cap: the money stays with the program.
        auth.setRoles(operator, TREASURY, 1);
        vm.prank(operator);
        assertEq(treasury.repayAdvance(address(usd), 5e6), 5e6);
        assertEq(auth.usedOf(operator), 0);
        // Never past what is owed, nor what the account holds free.
        vm.prank(issuer);
        assertEq(treasury.repayAdvance(address(usd), 100e6), 15e6);
        assertEq(usd.balanceOf(settlement), 10e6);
        assertEq(treasury.advanceOf(address(usd)), 0);
        vm.prank(issuer);
        assertEq(treasury.repayAdvance(address(usd), 1e6), 0);
        // A held balance is not free.
        vm.prank(settlement);
        treasury.payOut(bob, 20e6, bytes32("credit-2"));
        usd.mint(settlement, 10e6);
        bytes32 id = treasury.pledgeId(1);
        vm.prank(settlement);
        core.pledge(address(treasury), address(usd), id, 6e6, uint64(block.timestamp + 365 days));
        vm.prank(settlement);
        assertEq(treasury.repayAdvance(address(usd), 100e6), 4e6);
    }

    function test_payOut_fromWhatTheAccountHoldsNeedsNoAdvance() public {
        usd.mint(settlement, 30e6);
        vm.prank(settlement);
        assertEq(treasury.payOut(bob, 20e6, bytes32("credit-1")), 0);
        assertEq(usd.balanceOf(settlement), 10e6);
        assertEq(treasury.advanceOf(address(usd)), 0);
        assertEq(usd.balanceOf(address(treasury)), 50e6);
    }

    function test_payOut_onlyTheSettlementAccountIssuerOrATreasuryOperatorWithinItsCap() public {
        vm.prank(bob);
        vm.expectRevert(IssuerTreasury.NotIssuer.selector);
        treasury.payOut(bob, 1e6, bytes32("credit-1"));
        // An authorizing key is not a treasury key.
        auth.setRoles(operator, SETTLE, 100e6);
        vm.prank(operator);
        vm.expectRevert(IssuerTreasury.NotIssuer.selector);
        treasury.payOut(bob, 1e6, bytes32("credit-1"));
        auth.setRoles(operator, TREASURY, 30e6);
        assertEq(auth.ROLE_TREASURY(), TREASURY);
        usd.mint(settlement, 100e6);
        vm.prank(operator);
        treasury.payOut(bob, 20e6, bytes32("credit-1"));
        assertEq(auth.usedOf(operator), 20e6);
        vm.prank(operator);
        vm.expectRevert();
        treasury.payOut(bob, 10e6 + 1, bytes32("credit-2"));
        // The issuer itself has no cap.
        vm.prank(issuer);
        treasury.payOut(bob, 50e6, bytes32("credit-3"));
    }

    function test_withdrawIssuerFunds_paysTheSettlementAccountWithinWhatIsHeld() public {
        vm.prank(settlement);
        treasury.payOut(bob, 20e6, bytes32("credit-1"));
        vm.prank(bob);
        vm.expectRevert(IssuerTreasury.NotIssuer.selector);
        treasury.withdrawIssuerFunds(address(usd), 1e6);
        // 30 dollars stay the issuer's while the account owes 20.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.IssuerFundsShort.selector, 30e6 + 1, 30e6));
        treasury.withdrawIssuerFunds(address(usd), 30e6 + 1);
        vm.prank(issuer);
        treasury.withdrawIssuerFunds(address(usd), 10e6);
        assertEq(usd.balanceOf(settlement), 10e6);
        assertEq(usd.balanceOf(address(treasury)), 20e6);
        assertEq(treasury.issuerFunds(address(usd)), 20e6);
    }

    function test_withdrawIssuerFunds_keepsWhatTheProgramsCommittedExposureNeeds() public {
        // The settlement account owes the network 30 for captures and holds nothing: the issuer's funds stand behind it.
        auth.setExposure(0, 30e6);
        assertEq(treasury.committedIssuerFunds(address(usd)), 30e6);
        assertEq(treasury.committedIssuerFunds(address(eur)), 0);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.IssuerFundsShort.selector, 20e6 + 1, 20e6));
        treasury.withdrawIssuerFunds(address(usd), 20e6 + 1);
        vm.prank(issuer);
        treasury.withdrawIssuerFunds(address(usd), 20e6);
        // The account now holds the 20 withdrawn, so the issuer's funds keep the other 10.
        assertEq(treasury.committedIssuerFunds(address(usd)), 10e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.IssuerFundsShort.selector, 20e6 + 1, 20e6));
        treasury.withdrawIssuerFunds(address(usd), 20e6 + 1);
        // Open holds alone commit nothing: they settle from the cardholders' reserved funds.
        auth.setExposure(30e6, 0);
        assertEq(treasury.committedIssuerFunds(address(usd)), 0);
        // Settled, the rest is free.
        auth.setExposure(0, 0);
        vm.prank(issuer);
        treasury.withdrawIssuerFunds(address(usd), 30e6);
        assertEq(treasury.issuerFunds(address(usd)), 0);
    }

    function test_setSettlementToken_carriesTheAdvanceAtTheVenuePriceRoundedUp() public {
        vm.prank(settlement);
        treasury.payOut(bob, 20e6, bytes32("credit-1"));
        _approveTreasury(eur);
        uint256 carried = conv.quoteOut(address(eur), address(usd), 20e6);
        // About 18.24 euros buy back 20 dollars after the venue's cost.
        assertGt(carried, 18.23e6);
        assertLt(carried, 18.25e6);
        vm.expectEmit(address(treasury));
        emit IssuerTreasury.IssuerDebtCarried(address(usd), 20e6, address(eur), carried);
        _setting(abi.encodeCall(treasury.setSettlementToken, (address(eur))));
        assertEq(auth.settlementToken(), address(eur));
        assertEq(auth.lastScale(), conv.mid(address(usd), address(eur)));
        assertEq(treasury.advanceOf(address(usd)), 0);
        assertEq(treasury.advanceOf(address(eur)), carried);
        // Carrying moved no money.
        assertEq(usd.balanceOf(address(treasury)), 30e6);
        eur.mint(settlement, carried);
        vm.prank(settlement);
        assertEq(treasury.repayAdvance(address(eur), carried), carried);
        assertEq(treasury.advanceOf(address(eur)), 0);
        assertEq(eur.balanceOf(address(treasury)), carried);
    }

    function test_carryIssuerDebt_leavesIssuerFundsAtWhatTheTreasuryHolds() public {
        vm.prank(settlement);
        treasury.payOut(bob, 20e6, bytes32("credit-1"));
        _approveTreasury(eur);
        _setting(abi.encodeCall(treasury.setSettlementToken, (address(eur))));
        // The dollar claim is dropped with the funds it stood for and owed again in euros: nothing leaves the treasury.
        uint256 carried = conv.quoteOut(address(eur), address(usd), 20e6);
        assertEq(usd.balanceOf(address(treasury)), 30e6);
        assertEq(treasury.issuerFunds(address(usd)), 30e6);
        assertEq(treasury.issuerFunds(address(eur)), 0);
        eur.mint(settlement, carried);
        vm.prank(settlement);
        treasury.repayAdvance(address(eur), carried);
        assertEq(eur.balanceOf(address(treasury)), carried);
        assertEq(treasury.issuerFunds(address(eur)), carried);
    }

    function testFuzz_issuerFunds_neverAboveTheBalanceAfterATokenChange(uint64 paid, uint64 withdrawn) public {
        // Carrying sends nothing, so it carries a claim up to all the funds.
        paid = uint64(bound(paid, 1, 50e6));
        vm.prank(settlement);
        treasury.payOut(bob, paid, bytes32("credit-1"));
        _approveTreasury(eur);
        _setting(abi.encodeCall(treasury.setSettlementToken, (address(eur))));
        assertGe(usd.balanceOf(address(treasury)), treasury.issuerFunds(address(usd)));
        assertGe(eur.balanceOf(address(treasury)), treasury.issuerFunds(address(eur)));
        withdrawn = uint64(bound(withdrawn, 0, treasury.issuerFunds(address(usd))));
        if (withdrawn != 0) {
            vm.prank(issuer);
            treasury.withdrawIssuerFunds(address(usd), withdrawn);
        }
        assertGe(usd.balanceOf(address(treasury)), treasury.issuerFunds(address(usd)));
    }

    /// @dev Open holds and unsettled steps refuse the change when proposed, not only when it applies.
    function test_setSettlementToken_proposalRefusedWhileTheProgramHoldsOrIsUnsettled() public {
        auth.setGranted(1);
        auth.setExposure(10e6, 0);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.SettlementTokenInUse.selector, uint8(1)));
        treasury.setSettlementToken(address(eur));
        auth.setExposure(0, 10e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.SettlementTokenInUse.selector, uint8(2)));
        treasury.setSettlementToken(address(eur));
        auth.setExposure(0, 0);
        vm.prank(issuer);
        treasury.setSettlementToken(address(eur));
        assertNotEq(treasury.pendingSetting(keccak256(abi.encodeCall(treasury.setSettlementToken, (address(eur))))), 0);
    }

    function test_setSettlementToken_withoutIssuerDebtChargesNothing() public {
        _setting(abi.encodeCall(treasury.setSettlementToken, (address(eur))));
        assertEq(treasury.advanceOf(address(eur)), 0);
        assertEq(usd.balanceOf(address(treasury)), 50e6);
    }

    function test_setSettlementToken_waitsTheSettingsDelayOnceAnyoneWasGranted() public {
        auth.setGranted(1);
        vm.prank(issuer);
        treasury.setSettlementToken(address(eur));
        // Proposed, not applied: cardholders get the delay to leave before the token changes under them.
        assertEq(auth.settlementToken(), address(usd));
        bytes32 id = keccak256(abi.encodeCall(treasury.setSettlementToken, (address(eur))));
        uint64 eta = treasury.pendingSetting(id);
        assertEq(eta, block.timestamp + auth.SETTINGS_DELAY());
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.SettingPending.selector, eta));
        treasury.setSettlementToken(address(eur));
        vm.warp(eta);
        vm.prank(issuer);
        treasury.setSettlementToken(address(eur));
        assertEq(auth.settlementToken(), address(eur));
        assertEq(treasury.pendingSetting(id), 0);
    }

    function test_setSettlementToken_proposalLapsesAfterTheSettingsWindow() public {
        auth.setGranted(1);
        vm.prank(issuer);
        treasury.setSettlementToken(address(eur));
        bytes32 id = keccak256(abi.encodeCall(treasury.setSettlementToken, (address(eur))));
        uint64 eta = treasury.pendingSetting(id);
        vm.warp(eta + auth.SETTINGS_WINDOW() + 1);
        Rates.set(conv, address(eur), 1.1e18);
        vm.prank(issuer);
        treasury.setSettlementToken(address(eur));
        // Recorded afresh, not applied.
        assertEq(auth.settlementToken(), address(usd));
        assertEq(treasury.pendingSetting(id), vm.getBlockTimestamp() + auth.SETTINGS_DELAY());
    }

    function test_setSettlementToken_cancelledProposalNeverApplies() public {
        auth.setGranted(1);
        vm.prank(issuer);
        treasury.setSettlementToken(address(eur));
        bytes32 id = keccak256(abi.encodeCall(treasury.setSettlementToken, (address(eur))));
        vm.prank(bob);
        vm.expectRevert(IssuerTreasury.NotIssuer.selector);
        treasury.cancelSetting(id);
        vm.prank(issuer);
        treasury.cancelSetting(id);
        vm.warp(block.timestamp + 3 days);
        vm.prank(issuer);
        treasury.setSettlementToken(address(eur));
        assertEq(auth.settlementToken(), address(usd));
    }

    function test_setSettlementToken_refusedWhileAGuardReportsUse_andOnApplyToo() public {
        auth.setGranted(1);
        address[] memory guards = new address[](3);
        (guards[0], guards[1], guards[2]) = (address(credit), address(desk), address(reserves));
        // Appending guards applies at once.
        vm.prank(issuer);
        treasury.setTokenGuards(guards);
        assertEq(treasury.tokenGuardsLength(), 3);
        vm.prank(issuer);
        treasury.setSettlementToken(address(eur));
        // A line accepted during the delay holds the change back when it applies.
        _openLine(alice, 100e6, IEarnVault(address(0)), 0, 0);
        vm.warp(block.timestamp + 2 days);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.SettlementTokenInUse.selector, uint8(7)));
        treasury.setSettlementToken(address(eur));
        // Dropping a guard waits the delay.
        address[] memory fewer = new address[](1);
        fewer[0] = address(desk);
        vm.prank(issuer);
        treasury.setTokenGuards(fewer);
        assertEq(treasury.tokenGuardsLength(), 3);
    }

    function test_setSettlementToken_refusedWhileTheSettlementBalanceIsHeld() public {
        // A hold on the settlement account's balance that no guard explains still keeps the token.
        usd.mint(settlement, 10e6);
        vm.startPrank(settlement);
        core.approveHolder(bob, address(usd), 10e6, 0);
        vm.stopPrank();
        vm.prank(bob);
        core.holdFrom(
            settlement,
            IReservationCore.HoldRequest({
                token: address(usd),
                id: bytes32("hold"),
                amount: 10e6,
                expiresAt: uint64(vm.getBlockTimestamp() + 1 days),
                payee: bob
            })
        );
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.SettlementTokenInUse.selector, uint8(6)));
        treasury.setSettlementToken(address(eur));
        vm.prank(bob);
        core.release(settlement, bob, bytes32("hold"));
        _setting(abi.encodeCall(treasury.setSettlementToken, (address(eur))));
        assertEq(auth.settlementToken(), address(eur));
    }

    function test_setSettlementToken_needsAVenueAndANewToken() public {
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.TokenNotAccepted.selector, address(usd)));
        treasury.setSettlementToken(address(usd));
        auth.setConversion(address(0));
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.NoConversion.selector);
        treasury.setSettlementToken(address(eur));
        vm.prank(bob);
        vm.expectRevert(IssuerTreasury.NotIssuer.selector);
        treasury.setSettlementToken(address(eur));
    }

    // Sponsor collateral.

    function test_collateral_cashValueAndPostedCollateralHoldsTheToken() public {
        _postCash(150e6);
        assertEq(treasury.valueOf(), 150e6);
        assertEq(core.reserved(settlement, address(usd)), 150e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.SettlementTokenInUse.selector, uint8(5)));
        treasury.setSettlementToken(address(eur));
    }

    function test_collateral_sharesEarnAndValueFollowsThePrice() public {
        uint256 shares = _postShares(500e6);
        assertEq(core.reserved(settlement, address(earnShare)), shares);
        assertApproxEqAbs(treasury.valueOf(), 500e6, 1);
        usd.mint(address(venue), usd.balanceOf(address(venue)) / 4);
        assertGt(treasury.valueOf(), 600e6);
    }

    function test_release_onlySponsor_andNeverBelowExposure() public {
        _postCash(150e6);
        auth.setExposure(100e6, 0);
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.NotSponsor.selector);
        treasury.release(10e6);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.BelowExposure.selector, uint256(90e6), uint256(100e6)));
        treasury.release(60e6);
        vm.prank(sponsor);
        treasury.release(50e6);
        assertEq(treasury.valueOf(), 100e6);
        assertEq(core.reserved(settlement, address(usd)), 100e6);
    }

    function test_seize_cappedAtExposure_andPaysTheSponsor() public {
        _postCash(150e6);
        auth.setExposure(100e6, 0);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.AboveExposure.selector, uint256(101e6), uint256(100e6)));
        treasury.seize(101e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.NotSponsor.selector);
        treasury.seize(10e6);
        vm.prank(sponsor);
        treasury.seize(100e6);
        assertEq(usd.balanceOf(sponsor), 100e6);
        assertEq(treasury.valueOf(), 50e6);
        _assertCoreBalanced();
    }

    function test_seize_repeatedCallsTakeNoMoreThanTheExposure() public {
        _postCash(1000e6);
        auth.setExposure(100e6, 0);
        vm.startPrank(sponsor);
        treasury.seize(60e6);
        treasury.seize(40e6);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.AboveExposure.selector, uint256(1), uint256(0)));
        treasury.seize(1);
        vm.stopPrank();
        assertEq(usd.balanceOf(sponsor), 100e6);
        assertEq(treasury.seized(), 100e6);
        assertEq(treasury.valueOf(), 900e6);
    }

    function test_seize_appliedToAnAcknowledgedSettlement_letsANewExposureBeSeizedOnce() public {
        _postCash(1000e6);
        auth.setExposure(0, 100e6);
        vm.prank(sponsor);
        treasury.seize(100e6);
        // The sponsor acknowledges the 100 as settled and applies what it seized to it.
        vm.prank(sponsor);
        treasury.acknowledgeSettlement(1, 100e6);
        assertEq(treasury.seized(), 0);
        auth.setExposure(0, 50e6);
        vm.prank(sponsor);
        treasury.seize(50e6);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.AboveExposure.selector, uint256(1), uint256(0)));
        treasury.seize(1);
        // Never more in all than the program came to owe.
        assertEq(usd.balanceOf(sponsor), 150e6);
    }

    function test_seize_lowerExposureNeverReopensRoom() public {
        _postCash(1000e6);
        auth.setExposure(100e6, 0);
        vm.prank(sponsor);
        treasury.seize(100e6);
        auth.setExposure(50e6, 0);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.AboveExposure.selector, uint256(1), uint256(0)));
        treasury.seize(1);
        // The exposure coming back is the one already seized.
        auth.setExposure(100e6, 0);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.AboveExposure.selector, uint256(1), uint256(0)));
        treasury.seize(1);
        assertEq(treasury.seized(), 100e6);
    }

    function test_acknowledgeSettlement_appliesAtMostWhatItClearsAndWasSeized() public {
        _postCash(1000e6);
        auth.setExposure(0, 100e6);
        vm.prank(sponsor);
        treasury.seize(40e6);
        // More than was seized.
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.AboveExposure.selector, uint256(41e6), uint256(40e6)));
        treasury.acknowledgeSettlement(1, 41e6);
        // Nothing cleared, nothing applies.
        auth.setExposure(0, 0);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.AboveExposure.selector, uint256(1), uint256(0)));
        treasury.acknowledgeSettlement(1, 1);
    }

    function test_acknowledgeSettlement_sponsorOnceCollateralIsPosted() public {
        auth.setExposure(0, 10e6);
        // Before any collateral the issuer acknowledges.
        vm.prank(sponsor);
        vm.expectRevert(IssuerTreasury.NotSponsor.selector);
        treasury.acknowledgeSettlement(1, 0);
        vm.prank(issuer);
        treasury.acknowledgeSettlement(1, 0);
        _postCash(100e6);
        auth.setExposure(0, 10e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.NotSponsor.selector);
        treasury.acknowledgeSettlement(1, 0);
        vm.prank(sponsor);
        treasury.acknowledgeSettlement(1, 0);
        assertEq(treasury.exposure(), 0);
    }

    function test_nothingToSeize_withoutExposure() public {
        _postCash(150e6);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.AboveExposure.selector, uint256(1), uint256(0)));
        treasury.seize(1);
    }

    function test_payOut_advancesAllTheIssuersFundsOnTopOfExistingDebt() public {
        vm.prank(settlement);
        treasury.payOut(bob, 30e6, bytes32("credit-1"));
        assertEq(treasury.issuerFunds(address(usd)), 20e6);
        // The last 20 of the issuer's funds advance in full, though the account already owes 30.
        vm.prank(settlement);
        assertEq(treasury.payOut(bob, 20e6, bytes32("credit-2")), 20e6);
        assertEq(usd.balanceOf(bob), 50e6);
        assertEq(usd.balanceOf(address(treasury)), 0);
        assertEq(treasury.advanceOf(address(usd)), 50e6);
        assertEq(treasury.issuerFunds(address(usd)), 0);
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.IssuerFundsShort.selector, 1, 0));
        treasury.payOut(bob, 1, bytes32("credit-3"));
        _assertCoreBalanced();
    }

    function test_carryIssuerDebt_carriesDebtWorthAllTheIssuersFunds() public {
        vm.prank(settlement);
        treasury.payOut(bob, 50e6, bytes32("credit-1"));
        assertEq(usd.balanceOf(address(treasury)), 0);
        _setting(abi.encodeCall(treasury.setSettlementToken, (address(eur))));
        assertEq(auth.settlementToken(), address(eur));
        assertEq(treasury.advanceOf(address(usd)), 0);
        assertEq(treasury.advanceOf(address(eur)), conv.quoteOut(address(eur), address(usd), 50e6));
        assertEq(treasury.issuerFunds(address(usd)), 0);
        assertEq(treasury.issuerFunds(address(eur)), 0);
    }

    function test_post_refusesAPledgeExpiringBeforeTheCoverTerm() public {
        usd.mint(settlement, 100e6);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(address(treasury), address(usd), id, 100e6, uint64(block.timestamp + treasury.COVER_TERM()));
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.PledgeMissing.selector, id));
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
    }

    function test_collateral_stopsCoveringACoverTermBeforeItExpiresYetStaysSeizable() public {
        usd.mint(settlement, 100e6);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(
            address(treasury), address(usd), id, 100e6, uint64(block.timestamp + treasury.COVER_TERM() + 1 days)
        );
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
        auth.setExposure(60e6, 0);
        treasury.checkExposure();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        // It no longer covers new exposure, but what it already covers can still be seized.
        assertEq(treasury.valueOf(), 0);
        assertEq(treasury.unitsOf(), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 60e6, 0));
        treasury.checkExposure();
        vm.warp(vm.getBlockTimestamp() + treasury.COVER_TERM() - 1);
        vm.prank(sponsor);
        treasury.seize(60e6);
        assertEq(usd.balanceOf(sponsor), 60e6);
    }

    function test_post_endedPledgesFreeTheirSlots() public {
        uint256 max = treasury.MAX_PLEDGES();
        usd.mint(settlement, 1000e6);
        vm.startPrank(settlement);
        for (uint256 n = 1; n <= max; ++n) {
            core.pledge(address(treasury), address(usd), treasury.pledgeId(n), 10e6, uint64(block.timestamp + 365 days));
            treasury.post(sponsor, IEarnVault(address(0)), n);
        }
        vm.expectRevert(IssuerTreasury.TooManyPledges.selector);
        treasury.post(sponsor, IEarnVault(address(0)), max + 1);
        vm.stopPrank();
        assertEq(treasury.valueOf(), max * 10e6);
        // Releasing whole pledges ends them and frees their slots.
        vm.prank(sponsor);
        treasury.release(25e6);
        assertEq(treasury.valueOf(), max * 10e6 - 25e6);
        (,,, uint16 slots,) = treasury.collateral();
        assertEq(slots, type(uint16).max >> 2);
        vm.startPrank(settlement);
        core.pledge(address(treasury), address(usd), treasury.pledgeId(max), 30e6, uint64(block.timestamp + 365 days));
        treasury.post(sponsor, IEarnVault(address(0)), max);
        vm.stopPrank();
        assertEq(treasury.valueOf(), max * 10e6 + 5e6);
    }

    function test_post_slotOfAnExpiredPledgeTakesANewOne() public {
        usd.mint(settlement, 100e6);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(address(treasury), address(usd), id, 50e6, uint64(block.timestamp + 60 days));
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.warp(vm.getBlockTimestamp() + 60 days);
        assertEq(treasury.unitsOf(), 0);
        core.releaseExpired(settlement, settlement, id);
        core.pledge(address(treasury), address(usd), id, 80e6, uint64(vm.getBlockTimestamp() + 60 days));
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
        assertEq(treasury.valueOf(), 80e6);
    }

    function test_post_aSlotReusedForAnotherHoldCountsNothing() public {
        usd.mint(settlement, 100e6);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(address(treasury), address(usd), id, 50e6, uint64(block.timestamp + 60 days));
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
        vm.prank(sponsor);
        treasury.release(50e6);
        // The settlement account pledges the freed id to someone else: the treasury counts none of it.
        vm.prank(settlement);
        core.pledge(bob, address(usd), id, 50e6, uint64(block.timestamp + 60 days));
        assertEq(treasury.unitsOf(), 0);
        assertEq(treasury.valueOf(), 0);
    }

    function test_post_sponsorChangesOnlyOnceNothingIsLiveSeizedOrExposed() public {
        _postCash(100e6);
        auth.setExposure(10e6, 0);
        vm.prank(sponsor);
        treasury.release(90e6);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.BelowExposure.selector, uint256(0), uint256(10e6)));
        treasury.release(10e6);
        auth.setExposure(0, 0);
        vm.prank(sponsor);
        treasury.release(10e6);
        assertEq(treasury.unitsOf(), 0);
        usd.mint(settlement, 100e6);
        vm.startPrank(settlement);
        core.pledge(address(treasury), address(usd), treasury.pledgeId(2), 100e6, uint64(block.timestamp + 365 days));
        treasury.post(bob, IEarnVault(address(0)), 2);
        vm.stopPrank();
        (address now_,,,,) = treasury.collateral();
        assertEq(now_, bob);
    }

    function test_post_sponsorStaysWhileExposed() public {
        _postCash(100e6);
        auth.setExposure(0, 50e6);
        vm.prank(sponsor);
        treasury.seize(50e6);
        assertEq(treasury.unitsOf(), 50e6);
        // The rest expires: the seizure and the exposure still keep the sponsor.
        vm.warp(vm.getBlockTimestamp() + 365 days);
        usd.mint(settlement, 100e6);
        vm.startPrank(settlement);
        core.pledge(
            address(treasury), address(usd), treasury.pledgeId(2), 100e6, uint64(vm.getBlockTimestamp() + 365 days)
        );
        vm.expectRevert(IssuerTreasury.WrongSponsor.selector);
        treasury.post(bob, IEarnVault(address(0)), 2);
        vm.stopPrank();
    }

    function test_post_onlySettlementAccount_withAMatchingPledge() public {
        vm.expectRevert(IssuerTreasury.NotSettlementAccount.selector);
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.prank(settlement);
        vm.expectPartialRevert(IssuerTreasury.PledgeMissing.selector);
        treasury.post(sponsor, IEarnVault(address(0)), 1);
    }

    function test_post_keepsOneAssetAndSponsor() public {
        _postCash(10e6);
        usd.mint(settlement, 100e6);
        uint256 shares = _depositEarn(settlement, 100e6);
        bytes32 id = treasury.pledgeId(2);
        vm.prank(settlement);
        // forge-lint: disable-next-line(unsafe-typecast)
        core.pledge(address(treasury), address(earnShare), id, uint128(shares), uint64(block.timestamp + 365 days));
        vm.expectRevert(IssuerTreasury.WrongAsset.selector);
        vm.prank(settlement);
        treasury.post(sponsor, IEarnVault(address(earnVault)), 2);
        vm.expectRevert(IssuerTreasury.WrongSponsor.selector);
        vm.prank(settlement);
        treasury.post(issuer, IEarnVault(address(0)), 1);
    }

    function test_seize_dollarSharesSoldForEurosWhenTheProgramSettlesInEuros() public {
        uint256 shares = _postShares(330e6);
        auth.setToken(address(eur));
        uint256 value = treasury.valueOf();
        assertEq(value, conv.quoteIn(address(usd), address(eur), earnVault.previewRedeem(shares)));
        auth.setExposure(100e6, 0);
        vm.prank(sponsor);
        treasury.seize(100e6);
        assertApproxEqAbs(eur.balanceOf(sponsor), 100e6, 2);
        assertLe(eur.balanceOf(sponsor), 100e6);
        assertEq(usd.balanceOf(address(treasury)), 50e6);
        assertEq(earnShare.balanceOf(address(treasury)), 0);
        assertApproxEqAbs(treasury.valueOf(), value - 100e6, 2);
    }

    function test_checkExposure_refusesPastTheCollateral() public {
        // Nothing owed passes without collateral.
        treasury.checkExposure();
        auth.setExposure(10e6, 0);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 10e6, 0));
        treasury.checkExposure();
        _postCash(10e6);
        treasury.checkExposure();
        auth.setExposure(8e6, 3e6);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 11e6, 10e6));
        treasury.checkExposure();
    }

    function _postCash(uint128 amount) internal {
        usd.mint(settlement, amount);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(address(treasury), address(usd), id, amount, uint64(block.timestamp + 365 days));
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
    }

    function _postShares(uint256 assets) internal returns (uint256 shares) {
        usd.mint(settlement, assets);
        shares = _depositEarn(settlement, assets);
        bytes32 id = treasury.pledgeId(1);
        // The sponsor accepts the vault's shares before the settlement account posts them.
        vm.prank(sponsor);
        treasury.acceptCollateral(IEarnVault(address(earnVault)));
        vm.startPrank(settlement);
        // forge-lint: disable-next-line(unsafe-typecast)
        core.pledge(address(treasury), address(earnShare), id, uint128(shares), uint64(block.timestamp + 365 days));
        treasury.post(sponsor, IEarnVault(address(earnVault)), 1);
        vm.stopPrank();
    }

    /// @dev The settlement account lets the treasury move its free `token` for payouts and repayments.
    function _approveTreasury(ITIP20Token token) internal {
        vm.prank(settlement);
        token.approve(address(treasury), type(uint256).max);
    }
}
