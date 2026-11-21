// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardAuth } from "../../src/programs/CardAuth.sol";
import { CardAuthBase } from "../../src/programs/CardAuthBase.sol";
import { CardLegs } from "../../src/programs/CardLegs.sol";
import { Conversion } from "../../src/programs/Conversion.sol";
import { IssuerTreasury } from "../../src/programs/IssuerTreasury.sol";
import { ICardAuth } from "../../src/programs/interfaces/ICardAuth.sol";
import { FixedPricePool } from "../venues/FixedPricePool.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";
import { Rates } from "./harness/Rates.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @dev A cash source whose open converted value per token a test sets, or that stops answering.
contract SettableCashSource {
    uint8 public constant KIND = 1;
    address[] internal _tokens;
    uint256[] internal _open;
    bool public broken;

    error Broken();

    function set(address token, uint256 open) external {
        for (uint256 i; i < _tokens.length; ++i) {
            if (_tokens[i] == token) {
                _open[i] = open;
                return;
            }
        }
        _tokens.push(token);
        _open.push(open);
    }

    function setBroken(bool broken_) external {
        broken = broken_;
    }

    function convertedTokens() external view returns (address[] memory, uint256[] memory) {
        if (broken) revert Broken();
        return (_tokens, _open);
    }

    function openConverted() external view returns (uint256 sum) {
        if (broken) revert Broken();
        for (uint256 i; i < _open.length; ++i) {
            sum += _open[i];
        }
    }
}

/// @notice The issuer treasury's stress share: every cash source the program approves counts from its approval,
///         without listing, each converted token at the figure the issuer set for it (raised at once, lowered after the
///         settings delay) or DEFAULT_FX_STRESS_BPS.
contract IssuerTreasuryFxStressTest is AuthEnv {
    using FixedPointMathLib for uint256;

    bytes32 internal constant P1 = bytes32("fx-1");
    bytes32 internal constant P2 = bytes32("fx-2");
    uint256 internal constant BPS = 10_000;

    ITIP20Token internal eur;
    address internal ars = makeAddr("ars");
    IssuerTreasury internal treasury;
    address internal sponsor = makeAddr("sponsor");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(5000e6, 10_000e6, 50_000e6));
        // EUR at $1.10, as the FX band tests price it.
        eur = _createToken("Euro", "EURX");
        Conversion conv = new Conversion(address(usd), address(this));
        FixedPricePool bid = new FixedPricePool(address(eur), address(usd), 1.0967e18);
        FixedPricePool ask = new FixedPricePool(address(eur), address(usd), 1_103_310_000_000_000_000);
        usd.mint(address(bid), 1_000_000e6);
        eur.mint(address(ask), 1_000_000e6);
        conv.setVenue(address(eur), address(usd), address(bid), true);
        conv.setVenue(address(usd), address(eur), address(ask), false);
        Rates.set(conv, address(eur), 1.1e18);
        conv.setTrusted(address(cash), true);
        usd.mint(address(conv), 100_000e6);
        eur.mint(address(conv), 100_000e6);
        _setting(abi.encodeCall(cards.setCompanions, (address(0), address(0), address(0), address(conv))));
        vm.startPrank(alice);
        core.approveHolder(address(cash), address(eur), type(uint128).max, 0);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](2);
        order[0] = _cashEntry(address(eur), 100);
        order[1] = _cashEntry(address(usd), 100);
        cards.setFunding(order);
        vm.stopPrank();
        _setTolerance(alice, address(cash), address(eur), 1000);
        eur.mint(alice, 1000e6);

        treasury = new IssuerTreasury(cards);
        usd.mint(settlement, 105e6);
        vm.startPrank(settlement);
        core.pledge(address(treasury), address(usd), treasury.pledgeId(1), 105e6, uint64(block.timestamp + 365 days));
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
        _setting(abi.encodeCall(cards.setExposureGuard, (address(treasury))));
    }

    // Automatic inclusion.

    function test_stressedExposure_countsAnApprovedCashSourceWithoutListing() public {
        address[] memory sources = cards.cashSources();
        assertEq(sources.length, 1);
        assertEq(sources[0], address(cash));
        _authorize(P1, 90e6);
        uint256 open = cash.openConvertedOf(address(eur));
        assertGt(open, 89e6);
        assertEq(treasury.stressedExposure(), treasury.exposure() + open.mulDivUp(1000, BPS));
        // 90 held plus 10% of it leaves less than 10 of the 105 posted.
        vm.prank(issuer);
        vm.expectPartialRevert(IssuerTreasury.ExposureAboveCollateral.selector);
        cards.authorize(CARD, P2, 10e6, merchant, uint64(block.timestamp + 7 days), 0);
    }

    function test_setSource_aNewCashSourceCountsFromItsApproval() public {
        SettableCashSource source = new SettableCashSource();
        source.set(address(eur), 50e6);
        vm.prank(issuer);
        cards.setSource(address(source), true);
        // Proposed, not yet approved: it cannot hold, and does not count.
        assertEq(cards.cashSources().length, 1);
        assertEq(treasury.stressedExposure(), 0);
        vm.warp(cards.pendingSetting(keccak256(abi.encodeCall(cards.setSource, (address(source), true)))));
        vm.prank(issuer);
        cards.setSource(address(source), true);
        assertEq(cards.cashSources()[1], address(source));
        assertEq(treasury.stressedExposure(), 5e6);
        // Approving it again lists it once.
        _setting(abi.encodeCall(cards.setSource, (address(source), true)));
        assertEq(cards.cashSources().length, 2);
        // Other kinds never list.
        assertEq(cards.sourceKind(address(savings)), 2);
    }

    function test_setSource_aStoppedSourceCountsUntilItsConvertedHoldsClose() public {
        _authorize(P1, 90e6);
        uint256 open = cash.openConverted();
        _setting(abi.encodeCall(cards.setSource, (address(cash), false)));
        assertEq(cards.sourceKind(address(cash)), 0);
        assertEq(cards.cashSources()[0], address(cash));
        assertEq(treasury.stressedExposure(), treasury.exposure() + open.mulDivUp(1000, BPS));
        // A stopped source still settles what it holds; once that closes it counts nothing.
        _capture(P1, 90e6, true);
        assertEq(cash.openConverted(), 0);
        assertEq(treasury.stressedExposure(), treasury.exposure());
    }

    function test_setSource_keepsAtMostEightCashSourcesAndReusesADrainedStoppedPlace() public {
        SettableCashSource[] memory more = new SettableCashSource[](7);
        for (uint256 i; i < 7; ++i) {
            more[i] = new SettableCashSource();
            _setting(abi.encodeCall(cards.setSource, (address(more[i]), true)));
        }
        assertEq(cards.cashSources().length, 8);
        SettableCashSource extra = new SettableCashSource();
        vm.expectRevert(CardAuthBase.InvalidOrder.selector);
        this.approve(address(extra));
        // A stopped source with open converted value keeps its place.
        more[3].set(address(eur), 1e6);
        _setting(abi.encodeCall(cards.setSource, (address(more[3]), false)));
        vm.expectRevert(CardAuthBase.InvalidOrder.selector);
        this.approve(address(extra));
        assertEq(treasury.stressedExposure(), 1e5);
        // Once it drains, the next approval takes its place.
        more[3].set(address(eur), 0);
        _setting(abi.encodeCall(cards.setSource, (address(extra), true)));
        address[] memory sources = cards.cashSources();
        assertEq(sources.length, 8);
        assertEq(sources[4], address(extra));
    }

    /// @dev Approves `source` through the settings delay, as an external call so a revert can be expected.
    function approve(address source) external {
        _setting(abi.encodeCall(cards.setSource, (source, true)));
    }

    function test_stressedExposure_refusesWhileAnApprovedSourceStopsAnswering() public {
        SettableCashSource source = new SettableCashSource();
        _setting(abi.encodeCall(cards.setSource, (address(source), true)));
        source.setBroken(true);
        vm.expectRevert(SettableCashSource.Broken.selector);
        treasury.stressedExposure();
        vm.prank(issuer);
        vm.expectRevert(SettableCashSource.Broken.selector);
        cards.authorize(CARD, P1, 5e6, merchant, uint64(block.timestamp + 7 days), 0);
        // Stopped, it no longer counts, and its place is free for the next approval.
        _setting(abi.encodeCall(cards.setSource, (address(source), false)));
        _authorize(P1, 5e6);
        assertEq(treasury.stressedExposure(), treasury.exposure() + cash.openConverted().mulDivUp(1000, BPS));
    }

    function test_stressedExposure_capsAnOversizedAnswerAndRefusesAuthorizations() public {
        SettableCashSource source = new SettableCashSource();
        _setting(abi.encodeCall(cards.setSource, (address(source), true)));
        source.set(address(eur), type(uint256).max);
        assertEq(treasury.stressedExposure(), treasury.exposure() + uint256(type(uint128).max).mulDivUp(1000, BPS));
        vm.prank(issuer);
        vm.expectPartialRevert(IssuerTreasury.ExposureAboveCollateral.selector);
        cards.authorize(CARD, P1, 5e6, merchant, uint64(block.timestamp + 7 days), 0);
    }

    // Per-token figures.

    function test_stressedExposure_weighsEachTokenByItsFigure() public {
        SettableCashSource source = new SettableCashSource();
        _setting(abi.encodeCall(cards.setSource, (address(source), true)));
        source.set(address(eur), 30e6);
        source.set(ars, 20e6);
        _setFxStress(ars, 4000);
        // 10% of 30 plus 40% of 20.
        assertEq(treasury.stressedExposure(), 3e6 + 8e6);
        _authorize(P1, 50e6);
        uint256 open = cash.openConvertedOf(address(eur));
        // The same token in two sources adds up before the figure applies (rounded up once).
        assertEq(
            treasury.stressedExposure(), treasury.exposure() + (open * 1000 + 30e6 * 1000 + 20e6 * 4000).divUp(BPS)
        );
    }

    function test_fxStressOf_defaultsUntilSet() public {
        assertEq(treasury.DEFAULT_FX_STRESS_BPS(), 1000);
        assertEq(treasury.fxStressOf(address(eur)), 1000);
        assertEq(treasury.fxStressOf(ars), 1000);
        _setFxStress(ars, 4000);
        assertEq(treasury.fxStressOf(ars), 4000);
        assertEq(treasury.fxStressOf(address(eur)), 1000);
    }

    function test_setFxStress_refusesZeroAndMoreThanTheWhole() public {
        vm.startPrank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.InvalidFxStress.selector, 0));
        treasury.setFxStress(ars, 0);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.InvalidFxStress.selector, BPS + 1));
        treasury.setFxStress(ars, BPS + 1);
        treasury.setFxStress(ars, BPS);
        vm.stopPrank();
        assertEq(treasury.fxStressOf(ars), BPS);
    }

    function test_setFxStress_onlyTheIssuer() public {
        vm.prank(sponsor);
        vm.expectRevert(IssuerTreasury.NotIssuer.selector);
        treasury.setFxStress(ars, 4000);
    }

    function test_setFxStress_raisingAppliesAtOnceAndLoweringWaitsTheDelay() public {
        assertGt(cards.grantedOwners(), 0);
        vm.startPrank(issuer);
        // Raising, and setting the same figure, apply at once.
        treasury.setFxStress(ars, 4000);
        assertEq(treasury.fxStressOf(ars), 4000);
        treasury.setFxStress(ars, 4000);
        // Lowering waits.
        bytes memory data = abi.encodeCall(treasury.setFxStress, (ars, 2000));
        treasury.setFxStress(ars, 2000);
        uint64 eta = treasury.pendingSetting(keccak256(data));
        assertEq(eta, block.timestamp + cards.SETTINGS_DELAY());
        assertEq(treasury.fxStressOf(ars), 4000);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.SettingPending.selector, eta));
        treasury.setFxStress(ars, 2000);
        vm.warp(eta);
        treasury.setFxStress(ars, 2000);
        assertEq(treasury.fxStressOf(ars), 2000);
        assertEq(treasury.pendingSetting(keccak256(data)), 0);
        // Lowering the default for a token waits too; the issuer may drop the proposal.
        treasury.setFxStress(address(eur), 500);
        assertEq(treasury.fxStressOf(address(eur)), 1000);
        treasury.cancelSetting(keccak256(abi.encodeCall(treasury.setFxStress, (address(eur), 500))));
        vm.warp(block.timestamp + cards.SETTINGS_DELAY());
        treasury.setFxStress(address(eur), 500);
        assertEq(treasury.fxStressOf(address(eur)), 1000, "a dropped proposal starts again");
        vm.stopPrank();
    }

    function test_setFxStress_loweringAppliesAtOnceBeforeAnyGrant() public {
        CardAuth program = new CardAuth(issuer, settlement, address(usd), address(admin));
        IssuerTreasury fresh = new IssuerTreasury(ICardAuth(address(program)));
        assertEq(program.grantedOwners(), 0);
        vm.startPrank(issuer);
        fresh.setFxStress(ars, 4000);
        fresh.setFxStress(ars, 500);
        vm.stopPrank();
        assertEq(fresh.fxStressOf(ars), 500);
    }

    function test_setFxStress_aRaiseAppliesWhileALoweringWaits() public {
        vm.startPrank(issuer);
        treasury.setFxStress(ars, 500);
        assertEq(treasury.fxStressOf(ars), 1000);
        treasury.setFxStress(ars, 3000);
        assertEq(treasury.fxStressOf(ars), 3000);
        // The waiting lowering still applies after its delay, from wherever the figure stands then.
        vm.warp(block.timestamp + cards.SETTINGS_DELAY());
        treasury.setFxStress(ars, 500);
        vm.stopPrank();
        assertEq(treasury.fxStressOf(ars), 500);
    }

    function _setFxStress(address token, uint256 bps) internal {
        vm.prank(issuer);
        treasury.setFxStress(token, bps);
    }
}
