// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { Conversion } from "../../src/programs/Conversion.sol";
import { IssuerTreasury } from "../../src/programs/IssuerTreasury.sol";
import { FixedPricePool } from "../venues/FixedPricePool.sol";
import { CompEnv } from "./harness/CompStubs.sol";

/// @notice The issuer's treasury: its funds advance payouts the settlement account cannot make and stay behind the
///         program's committed exposure, the settlement token changes only after the settings delay and once nothing
///         is sized in it, carrying issuer debt across, and sponsor collateral is released and seized only within the
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
        conv.setReferenceRate(address(eur), 1.1e18);
        auth.setConversion(address(conv));
        _allowDebt(ITIP20Token(address(usd)), 100e6);
        // The issuer's own funds, which advance what the settlement account lacks.
        usd.mint(address(this), 50e6);
        usd.approve(address(treasury), 50e6);
        treasury.fundIssuerDebt(address(usd), 50e6);
    }

    function test_payOut_advancesWhatTheSettlementAccountLacksAsDebt() public {
        usd.mint(settlement, 5e6);
        vm.prank(settlement);
        assertEq(treasury.payOut(bob, 20e6, bytes32("credit-1")), 15e6);
        assertEq(usd.balanceOf(bob), 20e6);
        assertEq(usd.balanceOf(settlement), 0);
        assertEq(usd.balanceOf(address(treasury)), 35e6);
        assertEq(_owed(settlement, address(usd), address(treasury)), 15e6);
        // What the account receives repays the treasury first.
        usd.mint(settlement, 10e6);
        _repayDebt(settlement, address(usd));
        assertEq(_owed(settlement, address(usd), address(treasury)), 5e6);
        assertEq(usd.balanceOf(address(treasury)), 45e6);
        // A further payout adds to what it owes.
        vm.prank(issuer);
        assertEq(treasury.payOut(bob, 4e6, bytes32("credit-2")), 4e6);
        assertEq(_owed(settlement, address(usd), address(treasury)), 9e6);
        assertEq(usd.balanceOf(address(treasury)), 41e6);
        assertEq(usd.balanceOf(bob), 24e6);
    }

    function test_payOut_refusedPastTheIssuersFunds() public {
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.IssuerFundsShort.selector, 51e6, 50e6));
        treasury.payOut(bob, 51e6, bytes32("credit-1"));
    }

    function test_payOut_refusedPastTheDebtCap() public {
        usd.mint(address(this), 100e6);
        usd.approve(address(treasury), 100e6);
        treasury.fundIssuerDebt(address(usd), 100e6);
        vm.prank(settlement);
        vm.expectRevert();
        treasury.payOut(bob, 100e6 + 1, bytes32("credit-1"));
    }

    function test_payOut_fromWhatTheAccountHoldsNeedsNoAdvance() public {
        usd.mint(settlement, 30e6);
        vm.prank(settlement);
        assertEq(treasury.payOut(bob, 20e6, bytes32("credit-1")), 0);
        assertEq(usd.balanceOf(settlement), 10e6);
        assertEq(_owed(settlement, address(usd), address(treasury)), 0);
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
        // A stand-in approval of 30 the cardholder may not cover: the issuer's funds stand behind it.
        auth.setExposure(30e6, 30e6);
        assertEq(treasury.committedIssuerFunds(address(usd)), 30e6);
        assertEq(treasury.committedIssuerFunds(address(eur)), 0);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.IssuerFundsShort.selector, 20e6 + 1, 20e6));
        treasury.withdrawIssuerFunds(address(usd), 20e6 + 1);
        vm.prank(issuer);
        treasury.withdrawIssuerFunds(address(usd), 20e6);
        // Captured, what remains the cardholder's unsettled debt still holds 20.
        auth.setExposure(30e6, 20e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.IssuerFundsShort.selector, 10e6 + 1, 10e6));
        treasury.withdrawIssuerFunds(address(usd), 10e6 + 1);
        // Settled, the rest is free.
        auth.setExposure(0, 0);
        vm.prank(issuer);
        treasury.withdrawIssuerFunds(address(usd), 30e6);
        assertEq(treasury.issuerFunds(address(usd)), 0);
    }

    function test_setSettlementToken_carriesIssuerDebtAtTheVenuePriceRoundedUp() public {
        vm.prank(settlement);
        treasury.payOut(bob, 20e6, bytes32("credit-1"));
        _allowDebt(eur, type(uint128).max);
        uint256 carried = conv.quoteOut(address(eur), address(usd), 20e6);
        // About 18.24 euros buy back 20 dollars after the venue's cost.
        assertGt(carried, 18.23e6);
        assertLt(carried, 18.25e6);
        _setting(abi.encodeCall(treasury.setSettlementToken, (address(eur))));
        assertEq(auth.settlementToken(), address(eur));
        assertEq(auth.lastStep(), conv.mid(address(eur), address(usd)));
        _repayDebt(settlement, address(usd));
        assertEq(_owed(settlement, address(usd), address(treasury)), 0);
        assertEq(_owed(settlement, address(eur), address(treasury)), carried);
        // Clearing the old debt cost the issuer nothing: what it sent came back as repayment.
        assertEq(usd.balanceOf(address(treasury)), 30e6);
        eur.mint(settlement, carried);
        _repayDebt(settlement, address(eur));
        assertEq(_owed(settlement, address(eur), address(treasury)), 0);
        assertEq(eur.balanceOf(address(treasury)), carried);
    }

    function test_carryIssuerDebt_leavesIssuerFundsAtWhatTheTreasuryHolds() public {
        vm.prank(settlement);
        treasury.payOut(bob, 20e6, bytes32("credit-1"));
        _allowDebt(eur, type(uint128).max);
        _setting(abi.encodeCall(treasury.setSettlementToken, (address(eur))));
        assertEq(usd.balanceOf(address(treasury)), 10e6);
        assertEq(treasury.issuerFunds(address(usd)), 10e6);
        _repayDebt(settlement, address(usd));
        assertEq(usd.balanceOf(address(treasury)), 30e6);
        assertEq(treasury.issuerFunds(address(usd)), 30e6);
    }

    function testFuzz_issuerFunds_neverAboveTheBalanceAfterATokenChange(uint64 paid, uint64 withdrawn) public {
        // Carrying sends the old debt from what the treasury still holds, so it carries at most half its funds.
        paid = uint64(bound(paid, 1, 25e6));
        vm.prank(settlement);
        treasury.payOut(bob, paid, bytes32("credit-1"));
        _allowDebt(eur, type(uint128).max);
        _setting(abi.encodeCall(treasury.setSettlementToken, (address(eur))));
        assertGe(usd.balanceOf(address(treasury)), treasury.issuerFunds(address(usd)));
        assertGe(eur.balanceOf(address(treasury)), treasury.issuerFunds(address(eur)));
        _repayDebt(settlement, address(usd));
        assertGe(usd.balanceOf(address(treasury)), treasury.issuerFunds(address(usd)));
        withdrawn = uint64(bound(withdrawn, 0, treasury.issuerFunds(address(usd))));
        if (withdrawn != 0) {
            vm.prank(issuer);
            treasury.withdrawIssuerFunds(address(usd), withdrawn);
        }
        assertGe(usd.balanceOf(address(treasury)), treasury.issuerFunds(address(usd)));
    }

    function test_setSettlementToken_refusedWhenTheIssuerCannotOweInTheNewToken() public {
        vm.prank(settlement);
        treasury.payOut(bob, 20e6, bytes32("credit-1"));
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.SettlementTokenInUse.selector, uint8(8)));
        treasury.setSettlementToken(address(eur));
        _allowDebt(eur, 18e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.SettlementTokenInUse.selector, uint8(8)));
        treasury.setSettlementToken(address(eur));
    }

    function test_setSettlementToken_withoutIssuerDebtChargesNothing() public {
        _setting(abi.encodeCall(treasury.setSettlementToken, (address(eur))));
        assertEq(_owed(settlement, address(eur), address(treasury)), 0);
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
        assertEq(eta, block.timestamp + treasury.SETTINGS_DELAY());
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.SettingPending.selector, eta));
        treasury.setSettlementToken(address(eur));
        vm.warp(eta);
        vm.prank(issuer);
        treasury.setSettlementToken(address(eur));
        assertEq(auth.settlementToken(), address(eur));
        assertEq(treasury.pendingSetting(id), 0);
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

    function test_seize_coverFollowsTheExposureDown() public {
        _postCash(1000e6);
        auth.setExposure(100e6, 0);
        vm.prank(sponsor);
        treasury.seize(100e6);
        // The exposure the seizure covered closes; once synced, a new exposure can be seized, once.
        auth.setExposure(0, 0);
        treasury.sync();
        assertEq(treasury.seized(), 0);
        auth.setExposure(50e6, 0);
        vm.prank(sponsor);
        treasury.seize(50e6);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.AboveExposure.selector, uint256(1), uint256(0)));
        treasury.seize(1);
        assertEq(usd.balanceOf(sponsor), 150e6);
    }

    function test_seize_withoutASync_aLowerExposureStaysCovered() public {
        _postCash(1000e6);
        auth.setExposure(100e6, 0);
        vm.prank(sponsor);
        treasury.seize(100e6);
        auth.setExposure(50e6, 0);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.AboveExposure.selector, uint256(1), uint256(0)));
        treasury.seize(1);
        treasury.sync();
        assertEq(treasury.seized(), 50e6);
    }

    function test_nothingToSeize_withoutExposure() public {
        _postCash(150e6);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.AboveExposure.selector, uint256(1), uint256(0)));
        treasury.seize(1);
    }

    function test_post_onlySettlementAccount_withAMatchingPledge() public {
        vm.expectRevert(IssuerTreasury.NotSettlementAccount.selector);
        treasury.post(sponsor, IEarnVault(address(0)));
        vm.prank(settlement);
        vm.expectPartialRevert(IssuerTreasury.PledgeMissing.selector);
        treasury.post(sponsor, IEarnVault(address(0)));
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
        treasury.post(sponsor, IEarnVault(address(earnVault)));
        vm.expectRevert(IssuerTreasury.WrongSponsor.selector);
        vm.prank(settlement);
        treasury.post(issuer, IEarnVault(address(0)));
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

    function _postCash(uint128 amount) internal {
        usd.mint(settlement, amount);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(address(treasury), address(usd), id, amount, uint64(block.timestamp + 365 days));
        treasury.post(sponsor, IEarnVault(address(0)));
        vm.stopPrank();
    }

    function _postShares(uint256 assets) internal returns (uint256 shares) {
        usd.mint(settlement, assets);
        shares = _depositEarn(settlement, assets);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        // forge-lint: disable-next-line(unsafe-typecast)
        core.pledge(address(treasury), address(earnShare), id, uint128(shares), uint64(block.timestamp + 365 days));
        treasury.post(sponsor, IEarnVault(address(earnVault)));
        vm.stopPrank();
    }

    function _allowDebt(ITIP20Token token, uint128 cap) internal {
        vm.startPrank(settlement);
        token.approve(address(treasury), type(uint256).max);
        core.approveHolder(address(treasury), address(token), type(uint128).max, 0);
        vm.stopPrank();
        _setDebtCap(settlement, address(treasury), address(token), cap);
    }
}
