// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ISpenderHandler } from "bridge-spender/src/ISpenderHandler.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { CardSpend } from "../../../src/core/CardSpend.sol";
import { CardSpender } from "../../../src/core/CardSpender.sol";
import { BridgeProvider } from "../../../src/providers/bridge/BridgeProvider.sol";
import { SpenderTempoSpend } from "../../../src/providers/bridge/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../../src/providers/bridge/interfaces/IBridgeSpenderFactory.sol";
import { AccessKeys } from "../harness/AccessKeys.sol";
import {
    ChangeKeepingSpendHandler,
    DivertingSpendHandler,
    NoopSpendHandler,
    OverReturningSpendHandler,
    ReentrantToken,
    ShortPayingSpendHandler
} from "../harness/Mocks.sol";
import { isStandingOrNone } from "../harness/StandingApproval.sol";

/// @notice Hands input to a program as the Zone router does: transfers exactly `maxInput` and calls
///         `settle` in one call, so a revert returns the input.
contract SettleCaller {
    function settle(CardSpender program, address token, uint256 maxInput, bytes calldata data) external {
        SafeTransferLib.safeTransfer(token, address(program), maxInput);
        program.settle(token, maxInput, data);
    }
}

/// @notice A Bridge program's `CardSpender` on Bridge's real factory and the "TS" handler. As the Zone
///         router's settler it pays a spend from the input the router transfers it, returns the unused
///         input in the same call and keeps nothing; as the public entry point it pays from the
///         cardholder's approval to it and returns what the clone did not use. Either way the clone sees
///         the program as the payer, and a replaced handler can take at most the spend.
/// @dev No Zone: the program has no Zone code. `router` plays the Zone router, transferring `maxInput`
///      and calling `settle` in one call.
contract BridgeProgramTest is AccessKeys {
    uint256 internal constant AMOUNT = 40e6;

    SettleCaller internal caller;
    address internal router;
    address internal alice = makeAddr("alice");

    function setUp() public {
        _deployTempo();
        caller = new SettleCaller();
        router = address(caller);
        vm.label(router, "zone.router");
    }

    // ------------------------------------------------------------------
    // The provider on Bridge's factory
    // ------------------------------------------------------------------

    function test_requiresAFactoryAndAClone() public {
        vm.expectRevert(BridgeProvider.ZeroAddress.selector);
        new BridgeProvider(IBridgeSpenderFactory(address(0)), SPENDER_ID);
        // Bridge's factory predicts a clone for every ID; one it never created has no code.
        vm.expectRevert(BridgeProvider.NoClone.selector);
        new BridgeProvider(IBridgeSpenderFactory(address(bridgeFactory)), keccak256("no such program"));
    }

    /// @notice The program is bound to its clone, and its provider contract reads Bridge's own state as it
    ///         changes.
    function test_providerFollowsBridgesGovernance() public {
        assertEq(provider.CLONE(), spender);
        assertEq(program.PAYOUT_TARGET(), spender);
        assertEq(address(program.PROVIDER()), address(provider));
        assertTrue(cardFactory.isSpender(address(program)));

        address next = makeAddr("bridge.settlement.next");
        assertFalse(provider.isAuthorizedDestination(alice, next, address(usd), 0, false));
        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderDestination(SPENDER_ID, next, true);
        assertTrue(provider.isAuthorizedDestination(alice, next, address(usd), 0, false));
        assertTrue(provider.isAuthorizedDestination(router, next, address(usd), 0, true));

        assertTrue(provider.isAllowedVault(address(earnVault)));
        _bridgeGovernorCall(abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(0), address(earnVault)));
        assertFalse(provider.isAllowedVault(address(earnVault)));

        vm.prank(bridgePauser);
        bridgeFactory.pause();
        assertTrue(provider.paused());
        assertTrue(program.paused());
    }

    /// @notice The program has no pause of its own: Bridge's factory pause stops a private settle before any
    ///         funds move, and governance's unpause resumes it.
    function test_factoryPauseStopsThePrivateSettle() public {
        vm.prank(bridgePauser);
        bridgeFactory.pause();
        _mintUsd(router, AMOUNT);
        bytes memory data = abi.encode(_stableSpend(AMOUNT));
        vm.expectRevert(CardSpender.ProgramPaused.selector);
        caller.settle(program, address(usd), AMOUNT, data);

        vm.prank(bridgeGovernor);
        bridgeFactory.unpause();
        assertFalse(program.paused());
        _settle(address(usd), AMOUNT, _stableSpend(AMOUNT));
    }

    // ------------------------------------------------------------------
    // Private spend: the router's settler
    // ------------------------------------------------------------------

    /// @notice A stablecoin spend pays the destination and returns exactly the unused input.
    function test_stablecoinSpendPaysAndReturnsUnusedInput() public {
        uint256 maxInput = AMOUNT + 7e6;
        _mintUsd(router, maxInput);
        uint256 before = usd.balanceOf(settlement);
        CardSpend memory spend = _stableSpend(AMOUNT);
        spend.ref = keccak256("card.auth");

        vm.expectEmit(true, true, true, true, spender);
        emit SpenderTempoSpend.TempoSpendExecuted(
            spend.ref, address(program), settlement, address(usd), AMOUNT, AMOUNT, 0, 0
        );
        vm.expectEmit(true, true, true, true, address(program));
        emit CardSpender.CardSpent(spend.ref, router, settlement, address(usd), AMOUNT, 0, 0, true);
        vm.expectEmit(true, true, true, true, address(program));
        emit CardSpender.SpendSettled(spend.ref, address(usd), AMOUNT, 7e6);
        _settle(address(usd), maxInput, spend);

        assertEq(usd.balanceOf(settlement) - before, AMOUNT, "destination paid");
        assertEq(usd.balanceOf(router), 7e6, "unused input returned");
        assertEq(usd.balanceOf(address(program)), 0, "nothing left in the program");
        assertEq(usd.balanceOf(spender), 0, "nothing left in the clone");
        _assertNoApprovals(address(usd));
    }

    /// @notice A spend that uses all of `maxInput` returns nothing.
    function test_stablecoinSpendUsingAllInput() public {
        _mintUsd(router, AMOUNT);
        _settle(address(usd), AMOUNT, _stableSpend(AMOUNT));
        assertEq(usd.balanceOf(router), 0);
        assertEq(usd.balanceOf(address(program)), 0);
        _assertNoApprovals(address(usd));
    }

    /// @notice An Earn spend burns only the shares the withdrawal costs and returns the rest.
    function test_earnSpendReturnsUnusedShares() public {
        _mintUsd(router, 100e6);
        uint256 shares = _depositEarn(router, 100e6);
        uint256 burned = earnVault.previewWithdraw(AMOUNT);
        uint256 maxInput = burned + burned * 50 / 10_000 + 1;
        assertLt(maxInput, shares, "router holds more than it sends");
        uint256 before = usd.balanceOf(settlement);
        CardSpend memory spend = _earnSpend(AMOUNT, maxInput);
        spend.ref = keccak256("card.auth.earn");

        vm.expectEmit(true, true, true, true, address(program));
        emit CardSpender.CardSpent(spend.ref, router, settlement, address(usd), AMOUNT, AMOUNT, burned, true);
        vm.expectEmit(true, true, true, true, address(program));
        emit CardSpender.SpendSettled(spend.ref, address(earnShare), burned, maxInput - burned);
        _settle(address(earnShare), maxInput, spend);

        assertEq(usd.balanceOf(settlement) - before, AMOUNT, "destination paid");
        assertEq(shares - earnShare.balanceOf(router), burned, "charged the burned shares only");
        assertEq(earnShare.balanceOf(address(program)), 0, "nothing left in the program");
        assertEq(earnShare.balanceOf(spender), 0, "nothing left in the clone");
        assertTrue(isStandingOrNone(earnShare.allowance(spender, address(earnVault))), "clone -> vault");
        _assertNoApprovals(address(earnShare));
    }

    /// @notice Whatever `maxInput` the router sends and the spend asks, it loses exactly the
    ///         spend, never more than `maxInput`, and the program keeps nothing.
    function testFuzz_callerLosesExactlyTheSpend(uint256 amount, uint256 maxInput) public {
        amount = bound(amount, 1, 1_000_000e6);
        maxInput = bound(maxInput, amount, 2_000_000e6);
        _mintUsd(router, 2_000_000e6);

        _settle(address(usd), maxInput, _stableSpend(amount));

        assertEq(2_000_000e6 - usd.balanceOf(router), amount, "lost the spend only");
        assertEq(usd.balanceOf(address(program)), 0, "nothing left in the program");
        _assertNoApprovals(address(usd));
    }

    /// @notice A spend above `maxInput` cannot reach the router's other funds: the program holds
    ///         only what it was sent and no allowance from the router.
    function test_spendAboveMaxInputReverts() public {
        _mintUsd(router, 100e6);
        bytes memory data = abi.encode(_stableSpend(AMOUNT));
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        caller.settle(program, address(usd), AMOUNT - 1, data);
        assertEq(usd.balanceOf(router), 100e6, "nothing taken");
    }

    /// @notice A call that did not send `maxInput` first cannot settle.
    function test_rejectsSettleWithoutInput() public {
        _mintUsd(router, 100e6);
        _mintUsd(address(program), AMOUNT - 1);
        bytes memory data = abi.encode(_stableSpend(AMOUNT));
        vm.prank(router);
        vm.expectRevert(CardSpender.InsufficientInput.selector);
        program.settle(address(usd), AMOUNT, data);
        assertEq(usd.balanceOf(router), 100e6, "nothing taken");
    }

    /// @notice Tokens sent to the program outside a settle call are not accounted for: a later caller
    ///         can spend them, but only through this program to a destination Bridge authorizes, and
    ///         gets back only what that spend did not use.
    function test_strayTokensOnlyPayTheProgramsDestination() public {
        address stranger = makeAddr("stranger");
        _mintUsd(address(program), AMOUNT + 5e6);

        CardSpend memory elsewhere = _stableSpend(AMOUNT);
        elsewhere.destination = stranger;
        bytes memory data = abi.encode(elsewhere);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, stranger));
        program.settle(address(usd), AMOUNT + 5e6, data);

        uint256 before = usd.balanceOf(settlement);
        vm.prank(stranger);
        program.settle(address(usd), AMOUNT + 5e6, abi.encode(_stableSpend(AMOUNT)));
        assertEq(usd.balanceOf(settlement) - before, AMOUNT, "program destination paid");
        assertEq(usd.balanceOf(stranger), 5e6, "only the unused part returns");
        assertEq(usd.balanceOf(address(program)), 0);
    }

    /// @notice A spend for another program cannot use this one, even with this program's clone.
    function test_rejectsAnotherProgram() public {
        CardSpend memory spend = _stableSpend(AMOUNT);
        spend.program = makeAddr("another.program");
        _mintUsd(router, AMOUNT);
        bytes memory data = abi.encode(spend);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.WrongProgram.selector, spend.program));
        caller.settle(program, address(usd), AMOUNT, data);
    }

    /// @notice A program over a spender ID a manager added to this program's clone pays through the same
    ///         clone, but "TS" accepts only the ID the clone was created for, so it cannot pay with this
    ///         program's clone and the alias's destinations.
    function test_aProgramForAnIdAddedToTheCloneCannotPay() public {
        bytes32 aliasId = keccak256("bridge.card-program.alias");
        address[] memory destinations = new address[](1);
        destinations[0] = makeAddr("alias.destination");
        vm.prank(bridgeManager);
        bridgeFactory.createSpenderWithExistingContract(aliasId, destinations, spender);
        BridgeProvider aliasProvider = new BridgeProvider(IBridgeSpenderFactory(address(bridgeFactory)), aliasId);
        assertEq(aliasProvider.CLONE(), spender, "the same clone");
        CardSpender aliasProgram = CardSpender(cardFactory.deploy(aliasId, aliasProvider));

        CardSpend memory spend = _stableSpend(AMOUNT);
        spend.program = address(aliasProgram);
        spend.destination = destinations[0];
        _mintUsd(router, AMOUNT);
        bytes memory data = abi.encode(spend);
        vm.expectRevert(abi.encodeWithSelector(SpenderTempoSpend.WrongProgram.selector, aliasId));
        caller.settle(aliasProgram, address(usd), AMOUNT, data);
        assertEq(usd.balanceOf(destinations[0]), 0, "nothing paid");
    }

    function test_rejectsZeroInput() public {
        vm.prank(router);
        vm.expectRevert(CardSpender.InvalidAmount.selector);
        program.settle(address(usd), 0, abi.encode(_stableSpend(AMOUNT)));
    }

    function test_rejectsInputAboveUint128() public {
        bytes memory data = abi.encode(_stableSpend(AMOUNT));
        vm.prank(router);
        vm.expectRevert(CardSpender.InvalidAmount.selector);
        program.settle(address(usd), uint256(type(uint128).max) + 1, data);
    }

    /// @notice A handler under "TS" that moves nothing cannot make a spend look settled.
    function test_rejectsAHandlerThatSettlesNothing() public {
        _replaceHandler(ISpenderHandler(address(new NoopSpendHandler(IFactory(address(bridgeFactory))))));
        _expectSettleRevert(AMOUNT, abi.encodeWithSelector(CardSpender.NothingSettled.selector));
    }

    /// @notice A handler that hands back more input than it was given cannot look settled, even
    ///         when it pays the destination.
    function test_rejectsAHandlerThatReturnsMoreThanItWasGiven() public {
        _replaceHandler(ISpenderHandler(address(new OverReturningSpendHandler(IFactory(address(bridgeFactory))))));
        _mintUsd(spender, AMOUNT + 1);
        _expectSettleRevert(AMOUNT, abi.encodeWithSelector(CardSpender.NothingSettled.selector));
    }

    /// @notice The input must be the spend's own token: its stablecoin, or the shares of the vault that
    ///         funds all of it. A split spend cannot come from one withdrawal.
    function test_rejectsAnInputThatIsNotTheSpendsToken() public {
        _mintUsd(router, 100e6);
        uint256 shares = _depositEarn(router, 100e6);
        bytes memory data = abi.encode(_stableSpend(AMOUNT));
        vm.expectRevert(abi.encodeWithSelector(CardSpender.WrongInputToken.selector, address(earnShare)));
        caller.settle(program, address(earnShare), shares, data);

        CardSpend memory split = _earnSpend(AMOUNT, shares);
        split.fromVault = AMOUNT / 2;
        data = abi.encode(split);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.WrongInputToken.selector, address(earnShare)));
        caller.settle(program, address(earnShare), shares, data);

        _mintUsd(router, 50e6);
        data = abi.encode(_earnSpend(AMOUNT, shares));
        vm.expectRevert(abi.encodeWithSelector(CardSpender.WrongInputToken.selector, address(usd)));
        caller.settle(program, address(usd), 50e6, data);
        assertEq(earnShare.balanceOf(router), shares, "nothing taken");
    }

    /// @notice A handler that takes the input but pays the destination short cannot look settled.
    function test_rejectsAHandlerThatPaysShort() public {
        _replaceHandler(ISpenderHandler(address(new ShortPayingSpendHandler(IFactory(address(bridgeFactory))))));
        _expectSettleRevert(AMOUNT, abi.encodeWithSelector(CardSpender.DestinationNotCredited.selector));
    }

    /// @notice A token that calls back into the program while the clone pulls the input hits the
    ///         reentrancy lock, and the spend still settles.
    function test_rejectsReentrancy() public {
        ReentrantToken token = new ReentrantToken();
        token.mint(router, AMOUNT);
        token.arm(address(program), abi.encodeCall(CardSpender.settle, (address(token), 1, "")));
        CardSpend memory spend = _stableSpend(AMOUNT);
        spend.token = address(token);

        _settle(address(token), AMOUNT, spend);

        assertTrue(token.reentered(), "token re-entered");
        assertEq(bytes4(token.reentryError()), CardSpender.Reentrancy.selector);
        assertEq(token.balanceOf(settlement), AMOUNT, "destination paid");
        assertEq(token.balanceOf(address(program)), 0);
    }

    /// @notice Warming the program's approval to the clone ahead of the first spend makes that spend
    ///         approve nothing, and needs no role.
    function test_warmSetsTheStandingApprovalToTheClone() public {
        assertEq(usd.allowance(address(program), spender), 0);
        vm.prank(makeAddr("anyone"));
        program.warm(address(usd));
        assertEq(usd.allowance(address(program), spender), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Public spend: the cardholder's entry point
    // ------------------------------------------------------------------

    /// @notice A public spend takes exactly the amount from the cardholder's approval to the program, and
    ///         the clone sees the program, not the cardholder, as its payer.
    function test_publicSpendPaysFromTheCardholdersApproval() public {
        _mintUsd(alice, 100e6);
        vm.prank(alice);
        usd.approve(address(program), AMOUNT);
        CardSpend memory spend = _stableSpend(AMOUNT);
        spend.ref = keccak256("card.auth.public");
        uint256 before = usd.balanceOf(settlement);

        vm.expectEmit(true, true, true, true, spender);
        emit SpenderTempoSpend.TempoSpendExecuted(
            spend.ref, address(program), settlement, address(usd), AMOUNT, AMOUNT, 0, 0
        );
        vm.expectEmit(true, true, true, true, address(program));
        emit CardSpender.CardSpent(spend.ref, alice, settlement, address(usd), AMOUNT, 0, 0, false);
        vm.prank(alice);
        program.spend(spend);

        assertEq(usd.balanceOf(settlement) - before, AMOUNT, "destination paid");
        assertEq(usd.balanceOf(alice), 100e6 - AMOUNT, "charged the spend only");
        assertEq(usd.allowance(alice, address(program)), 0, "the exact approval is used up");
        assertEq(usd.balanceOf(address(program)), 0, "nothing left in the program");
        assertEq(usd.balanceOf(spender), 0, "nothing left in the clone");
    }

    /// @notice A public spend from Earn pulls the share quote and returns the shares the vault did not burn.
    function test_publicEarnSpendReturnsUnusedShares() public {
        _mintUsd(alice, 100e6);
        uint256 shares = _depositEarn(alice, 100e6);
        uint256 burned = earnVault.previewWithdraw(AMOUNT);
        uint256 quote = burned + burned * 50 / 10_000 + 1;
        vm.prank(alice);
        earnShare.approve(address(program), quote);
        CardSpend memory spend = _earnSpend(AMOUNT, quote);
        uint256 before = usd.balanceOf(settlement);

        vm.expectEmit(true, true, true, true, address(program));
        emit CardSpender.CardSpent(spend.ref, alice, settlement, address(usd), AMOUNT, AMOUNT, burned, false);
        vm.prank(alice);
        program.spend(spend);

        assertEq(usd.balanceOf(settlement) - before, AMOUNT, "destination paid");
        assertEq(shares - earnShare.balanceOf(alice), burned, "charged the burned shares only");
        assertEq(earnShare.balanceOf(address(program)), 0, "nothing left in the program");
        assertEq(earnShare.balanceOf(spender), 0, "nothing left in the clone");
    }

    /// @notice A replaced handler that diverts the spend cannot look paid, and the cardholder keeps
    ///         everything: the spend reverts.
    function test_publicSpendThroughADivertingHandlerReverts() public {
        address thief = makeAddr("thief");
        _replaceHandler(ISpenderHandler(address(new DivertingSpendHandler(IFactory(address(bridgeFactory)), thief))));
        _mintUsd(alice, 100e6);
        vm.prank(alice);
        usd.approve(address(program), AMOUNT);
        vm.prank(alice);
        vm.expectRevert(CardSpender.DestinationNotCredited.selector);
        program.spend(_stableSpend(AMOUNT));
        assertEq(usd.balanceOf(thief), 0, "nothing diverted");
        assertEq(usd.balanceOf(alice), 100e6, "nothing taken");
    }

    /// @notice The Cyclops finding, on the public path: a replaced handler that pays exactly and takes
    ///         whatever else its payer approved gets nothing more, even from a cardholder who left a large
    ///         approval standing to the program, since the program approves the clone only from what it
    ///         pulled for this spend.
    function test_publicSpendThroughAChangeKeepingHandlerTakesOnlyTheSpend() public {
        address thief = makeAddr("thief");
        _replaceHandler(
            ISpenderHandler(address(new ChangeKeepingSpendHandler(IFactory(address(bridgeFactory)), thief)))
        );
        _mintUsd(alice, 100e6);
        vm.prank(alice);
        usd.approve(address(program), type(uint256).max);
        uint256 before = usd.balanceOf(settlement);
        vm.prank(alice);
        program.spend(_stableSpend(AMOUNT));
        assertEq(usd.balanceOf(settlement) - before, AMOUNT, "destination paid");
        assertEq(usd.balanceOf(thief), 0, "handler kept nothing");
        assertEq(usd.balanceOf(alice), 100e6 - AMOUNT, "charged the spend only");
    }

    /// @notice The program pays only what its payer gives it: a spend with nothing approved fails before
    ///         the clone is reached.
    function test_publicSpendNeedsTheCardholdersApproval() public {
        _mintUsd(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        program.spend(_stableSpend(AMOUNT));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _stableSpend(uint256 amount) internal view returns (CardSpend memory) {
        return CardSpend({
            program: address(program),
            token: address(usd),
            amount: amount,
            destination: settlement,
            destinationHint: 0,
            vault: address(0),
            fromVault: 0,
            maxShares: 0,
            ref: bytes32(0)
        });
    }

    function _earnSpend(uint256 amount, uint256 maxShares) internal view returns (CardSpend memory s) {
        s = _stableSpend(amount);
        s.vault = address(earnVault);
        s.fromVault = amount;
        s.maxShares = maxShares;
    }

    /// @dev As the router does: transfer `maxInput`, then settle, in one call.
    function _settle(address token, uint256 maxInput, CardSpend memory spend) internal {
        caller.settle(program, token, maxInput, abi.encode(spend));
    }

    function _expectSettleRevert(uint256 maxInput, bytes memory reason) internal {
        _mintUsd(router, maxInput);
        bytes memory data = abi.encode(_stableSpend(AMOUNT));
        vm.expectRevert(reason);
        caller.settle(program, address(usd), maxInput, data);
        assertEq(usd.balanceOf(router), maxInput, "nothing taken");
    }

    function _replaceHandler(ISpenderHandler handler) internal {
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler(PREFIX_TEMPO_SPEND, handler);
    }

    /// @notice The program's approval to the clone is none or standing, and the router never approves
    ///         the program.
    function _assertNoApprovals(address token) internal view {
        (bool ok, bytes memory ret) =
            token.staticcall(abi.encodeWithSignature("allowance(address,address)", address(program), spender));
        require(ok);
        assertTrue(isStandingOrNone(abi.decode(ret, (uint256))), "program -> clone");
        (ok, ret) = token.staticcall(abi.encodeWithSignature("allowance(address,address)", router, address(program)));
        require(ok);
        assertEq(abi.decode(ret, (uint256)), 0, "router -> program");
    }
}
