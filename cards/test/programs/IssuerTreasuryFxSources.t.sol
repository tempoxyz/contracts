// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardLegs } from "../../src/programs/CardLegs.sol";
import { Conversion } from "../../src/programs/Conversion.sol";
import { IssuerTreasury } from "../../src/programs/IssuerTreasury.sol";
import { FixedPricePool } from "../venues/FixedPricePool.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";
import { Rates } from "./harness/Rates.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @dev A funding source whose open converted value a test sets, or that stops answering.
contract SettableSource {
    uint256 public value;
    bool public broken;

    error Broken();

    function set(uint256 value_, bool broken_) external {
        (value, broken) = (value_, broken_);
    }

    function openConverted() external view returns (uint256) {
        if (broken) revert Broken();
        return value;
    }
}

/// @notice Which funding sources the issuer treasury stresses: anyone lists a source the program approves, or is
///         about to, and a listed source leaves only once the program drops it and its converted holds close.
contract IssuerTreasuryFxSourcesTest is AuthEnv {
    using FixedPointMathLib for uint256;

    bytes32 internal constant P1 = bytes32("fx-1");
    bytes32 internal constant P2 = bytes32("fx-2");
    uint256 internal constant BPS = 10_000;

    ITIP20Token internal eur;
    IssuerTreasury internal treasury;
    address internal sponsor = makeAddr("sponsor");
    address internal anyone = makeAddr("anyone");

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

    function test_addFxSource_anyoneListsAnApprovedSourceAndItsConvertedHoldsCount() public {
        assertEq(cards.sourceKind(address(cash)), 1);
        vm.prank(anyone);
        treasury.addFxSource(address(cash));
        assertEq(treasury.fxSources(0), address(cash));
        assertEq(treasury.fxSourcesLength(), 1);
        _authorize(P1, 90e6);
        uint256 open = cash.openConverted();
        assertGt(open, 89e6);
        assertEq(treasury.stressedExposure(), treasury.exposure() + open.mulDivUp(treasury.FX_STRESS_BPS(), BPS));
        // 90 held plus 10% of it leaves less than 10 of the 105 posted.
        vm.prank(issuer);
        vm.expectPartialRevert(IssuerTreasury.ExposureAboveCollateral.selector);
        cards.authorize(CARD, P2, 10e6, merchant, uint64(block.timestamp + 7 days), 0);
        // The issuer cannot take an approved source out.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.FxSourceRefused.selector, address(cash)));
        treasury.removeFxSource(address(cash));
    }

    function test_addFxSource_refusesAnUnapprovedListedOrSilentSource() public {
        address typo = makeAddr("typo");
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.FxSourceRefused.selector, typo));
        treasury.addFxSource(typo);
        treasury.addFxSource(address(cash));
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.FxSourceRefused.selector, address(cash)));
        treasury.addFxSource(address(cash));
        // Once the program proposes approving an address that does not answer openConverted, listing it still fails.
        vm.prank(issuer);
        cards.setSource(typo, true);
        assertGt(cards.pendingSetting(keccak256(abi.encodeCall(cards.setSource, (typo, true)))), 0);
        vm.expectRevert();
        treasury.addFxSource(typo);
        assertEq(treasury.fxSourcesLength(), 1);
    }

    function test_addFxSource_listsASourceWhileItsApprovalWaits() public {
        SettableSource source = new SettableSource();
        vm.prank(issuer);
        cards.setSource(address(source), true);
        vm.prank(sponsor);
        treasury.addFxSource(address(source));
        source.set(50e6, false);
        assertEq(treasury.stressedExposure(), treasury.exposure() + 5e6);
        // Past the program's settings window the proposal lapses, and with it the right to list.
        SettableSource late = new SettableSource();
        vm.prank(issuer);
        cards.setSource(address(late), true);
        vm.warp(block.timestamp + cards.SETTINGS_DELAY() + cards.SETTINGS_WINDOW() + 1);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.FxSourceRefused.selector, address(late)));
        treasury.addFxSource(address(late));
    }

    function test_removeFxSource_waitsUntilTheProgramDropsTheSourceAndItsConvertedHoldsClose() public {
        treasury.addFxSource(address(cash));
        _authorize(P1, 90e6);
        _capture(P1, 90e6, true);
        assertEq(cash.openConverted(), 0);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.FxSourceRefused.selector, address(cash)));
        treasury.removeFxSource(address(cash));
        _setting(abi.encodeCall(cards.setSource, (address(cash), false)));
        vm.prank(anyone);
        treasury.removeFxSource(address(cash));
        assertEq(treasury.fxSourcesLength(), 0);

        // A dropped source that still reports open converted value stays, unless the sponsor takes it out.
        SettableSource source = new SettableSource();
        vm.prank(issuer);
        cards.setSource(address(source), true);
        treasury.addFxSource(address(source));
        source.set(1, false);
        vm.prank(issuer);
        cards.cancelSetting(keccak256(abi.encodeCall(cards.setSource, (address(source), true))));
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.FxSourceRefused.selector, address(source)));
        treasury.removeFxSource(address(source));
        vm.prank(sponsor);
        treasury.removeFxSource(address(source));
        assertEq(treasury.fxSourcesLength(), 0);
    }

    function test_removeFxSource_takesOutASourceThatStopsAnsweringAtOnce() public {
        SettableSource source = new SettableSource();
        vm.prank(issuer);
        cards.setSource(address(source), true);
        treasury.addFxSource(address(source));
        source.set(0, true);
        vm.expectRevert(SettableSource.Broken.selector);
        _authorize(P1, 5e6);
        // The issuer withdraws the proposal; anyone then takes the source out without waiting.
        vm.prank(issuer);
        cards.cancelSetting(keccak256(abi.encodeCall(cards.setSource, (address(source), true))));
        vm.prank(anyone);
        treasury.removeFxSource(address(source));
        _authorize(P1, 5e6);
        assertEq(treasury.exposure(), 5e6);
    }

    function test_stressedExposure_capsAnOversizedAnswerAndRefusesAuthorizations() public {
        SettableSource source = new SettableSource();
        vm.prank(issuer);
        cards.setSource(address(source), true);
        treasury.addFxSource(address(source));
        source.set(type(uint256).max, false);
        assertEq(
            treasury.stressedExposure(),
            treasury.exposure() + uint256(type(uint128).max).mulDivUp(treasury.FX_STRESS_BPS(), BPS)
        );
        vm.prank(issuer);
        vm.expectPartialRevert(IssuerTreasury.ExposureAboveCollateral.selector);
        cards.authorize(CARD, P1, 5e6, merchant, uint64(block.timestamp + 7 days), 0);
    }

    function test_addFxSource_listsAtMostMaxFxSources() public {
        uint256 max = treasury.MAX_FX_SOURCES();
        for (uint256 i; i < max; ++i) {
            SettableSource s = new SettableSource();
            vm.prank(issuer);
            cards.setSource(address(s), true);
            treasury.addFxSource(address(s));
        }
        SettableSource extra = new SettableSource();
        vm.prank(issuer);
        cards.setSource(address(extra), true);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.FxSourceRefused.selector, address(extra)));
        treasury.addFxSource(address(extra));
    }
}
