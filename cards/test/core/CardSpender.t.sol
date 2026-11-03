// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { CardSpend } from "../../src/core/CardSpend.sol";
import { CardSpender } from "../../src/core/CardSpender.sol";
import { ICardProvider } from "../../src/core/interfaces/ICardProvider.sol";
import { CoreEnv } from "./harness/CoreEnv.sol";
import { MockPayoutTarget, NotAProvider, ReentrantToken } from "./harness/Mocks.sol";

/// @notice `CardSpender` behavior every provider gets, run once with a program that pays directly and once
///         with one that pays through its provider's payout target: public and private spends from stablecoin,
///         Earn or both, every check, the pause, and the program holding nothing afterwards.
abstract contract CardSpenderBehavior is CoreEnv {
    function _payout() internal pure virtual returns (bool);

    function setUp() public {
        _deployCore();
        _deployMockProgram(_payout());
        usd.mint(alice, 1000e6);
        usd.mint(router, 1000e6);
    }

    function _assertEmpty() internal view {
        assertEq(usd.balanceOf(address(program)), 0, "program holds no stablecoin");
        assertEq(earnShare.balanceOf(address(program)), 0, "program holds no shares");
    }

    // Public ------------------------------------------------------------

    function test_publicSpend_fromStable() public {
        CardSpend memory s = _stableSpend(publicWallet, 0, 42e6, "auth.1");
        vm.prank(alice);
        usd.approve(address(program), 42e6);
        vm.expectEmit(address(program));
        emit CardSpender.CardSpent("auth.1", alice, publicWallet, address(usd), 42e6, 0, 0, false);
        vm.prank(alice);
        program.spend(s);
        assertEq(usd.balanceOf(publicWallet), 42e6);
        assertEq(usd.balanceOf(alice), 958e6);
        _assertEmpty();
    }

    function test_publicSpend_fromEarn_redeemsExactlyTheSpend() public {
        uint256 shares = _depositEarn(alice, 500e6);
        uint256 cost = earnVault.previewWithdraw(30e6);
        _publicSpend(alice, _earnSpend(publicWallet, 0, 30e6, 30e6, "auth.earn"));
        assertEq(usd.balanceOf(publicWallet), 30e6, "paid in the vault asset");
        assertEq(earnShare.balanceOf(alice), shares - cost, "burned only what the spend cost");
        _assertEmpty();
    }

    function test_publicSpend_splitAcrossStableAndEarn() public {
        _depositEarn(alice, 500e6);
        uint256 stableBefore = usd.balanceOf(alice);
        _publicSpend(alice, _earnSpend(publicWallet, 0, 50e6, 20e6, "auth.split"));
        assertEq(usd.balanceOf(publicWallet), 50e6);
        assertEq(stableBefore - usd.balanceOf(alice), 30e6);
        _assertEmpty();
    }

    /// @dev A payer spending nearly all their shares, so they hold the live cost but less than the `maxShares`
    ///      cap (live cost plus 0.5%), is still paid: only the live cost moves, whoever pays.
    function test_publicSpend_fromEarn_sharesCoverCostButNotCap() public {
        uint256 shares = _depositEarn(alice, 100e6);
        uint256 amount = earnVault.previewRedeem(shares) - 1;
        CardSpend memory s = _earnSpend(publicWallet, 0, amount, amount, "nearly.all");
        assertGt(s.maxShares, shares, "the cap is above the payer's balance");
        uint256 cost = earnVault.previewWithdraw(amount);
        assertLe(cost, shares, "the live cost is within it");
        _publicSpend(alice, s);
        assertEq(usd.balanceOf(publicWallet), amount);
        assertEq(earnShare.balanceOf(alice), shares - cost);
        _assertEmpty();
    }

    function test_revert_publicSpend_liveCostAboveCap() public {
        _depositEarn(alice, 100e6);
        CardSpend memory s = _earnSpend(publicWallet, 0, 10e6, 10e6, "cap");
        uint256 required = earnVault.previewWithdraw(10e6);
        s.maxShares = required - 1;
        vm.prank(alice);
        earnShare.approve(address(program), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.ShareCostExceeded.selector, required, required - 1));
        program.spend(s);
    }

    function testFuzz_publicSpend_split(uint256 amount, uint256 fromVault) public {
        _depositEarn(alice, 500e6);
        amount = bound(amount, 1, 400e6);
        fromVault = bound(fromVault, 0, amount);
        uint256 total = usd.balanceOf(alice) + earnVault.previewRedeem(earnShare.balanceOf(alice));
        CardSpend memory s = _earnSpend(publicWallet, 0, amount, fromVault, "fuzz");
        if (fromVault == 0) s.vault = address(0);
        _publicSpend(alice, s);
        assertEq(usd.balanceOf(publicWallet), amount, "destination got exactly the spend");
        uint256 left = usd.balanceOf(alice) + earnVault.previewRedeem(earnShare.balanceOf(alice));
        // Rounding in the vault's favor costs at most a unit or two.
        assertApproxEqAbs(total - left, amount, 2);
        assertGe(total - left, amount);
        _assertEmpty();
    }

    // Private ------------------------------------------------------------

    function test_privateSpend_paysAndReturnsChange() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 20e6, "private.1");
        vm.prank(router);
        usd.transfer(address(program), 20e6 + 7);
        vm.expectEmit(address(program));
        emit CardSpender.InputSpent("private.1", address(usd), 20e6, 7);
        vm.prank(router);
        program.spendFrom(address(usd), 20e6 + 7, abi.encode(s));
        assertEq(usd.balanceOf(pooledWallet), 20e6);
        assertEq(usd.balanceOf(router), 1000e6 - 20e6, "change back to the router");
        _assertEmpty();
    }

    function test_privateSpend_fromEarnShares() public {
        uint256 shares = _depositEarn(router, 200e6);
        CardSpend memory s = _earnSpend(pooledWallet, 0, 15e6, 15e6, "private.earn");
        uint256 cost = earnVault.previewWithdraw(15e6);
        _routerSpend(address(earnShare), s.maxShares, s);
        assertEq(usd.balanceOf(pooledWallet), 15e6);
        assertEq(earnShare.balanceOf(router), shares - cost, "unused shares back to the router");
        _assertEmpty();
    }

    function testFuzz_privateSpend_neverKeepsInput(uint256 amount, uint256 change) public {
        amount = bound(amount, 1, 500e6);
        change = bound(change, 0, 100e6);
        uint256 before = usd.balanceOf(router);
        _routerSpend(address(usd), amount + change, _stableSpend(pooledWallet, 0, amount, "fuzz"));
        assertEq(before - usd.balanceOf(router), amount);
        _assertEmpty();
    }

    /// @dev The program tells the provider the path: a destination open only to private spends refuses a
    ///      public one, and the reverse.
    function test_providerSeesWhichPathASpendTakes() public {
        address privateOnly = makeAddr("private-only");
        mock.setDestination(privateOnly, false, true);
        CardSpend memory s = _stableSpend(privateOnly, 0, 1e6, "path");
        vm.prank(alice);
        usd.approve(address(program), 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, privateOnly));
        program.spend(s);
        _routerSpend(address(usd), 1e6, s);
        assertEq(usd.balanceOf(privateOnly), 1e6, "a private spend reaches it");

        CardSpend memory p = _stableSpend(publicWallet, 0, 1e6, "path.2");
        vm.prank(router);
        usd.transfer(address(program), 1e6);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, publicWallet));
        program.spendFrom(address(usd), 1e6, abi.encode(p));
    }

    function test_revert_spendFrom_wrongInputToken() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "input");
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.WrongInputToken.selector, address(earnShare)));
        program.spendFrom(address(earnShare), 1e6, abi.encode(s));
    }

    function test_revert_spendFrom_insufficientInput() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "short");
        vm.expectRevert(CardSpender.InsufficientInput.selector);
        program.spendFrom(address(usd), 1e6, abi.encode(s));
    }

    function test_revert_spendFrom_zeroOrHugeMaxInput() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "max");
        vm.expectRevert(CardSpender.InvalidAmount.selector);
        program.spendFrom(address(usd), 0, abi.encode(s));
        vm.expectRevert(CardSpender.InvalidAmount.selector);
        program.spendFrom(address(usd), uint256(type(uint128).max) + 1, abi.encode(s));
    }

    /// @dev Tokens left in the program outside a spend cannot top up a spend above its `maxInput`.
    function test_revert_spendFrom_amountAboveMaxInput() public {
        vm.prank(router);
        usd.transfer(address(program), 5e6);
        CardSpend memory s = _stableSpend(pooledWallet, 0, 2e6, "above");
        vm.prank(router);
        usd.transfer(address(program), 1e6);
        vm.prank(router);
        vm.expectRevert();
        program.spendFrom(address(usd), 1e6, abi.encode(s));
    }

    // Checks -------------------------------------------------------------

    function test_revert_destinationNotAuthorized() public {
        address stranger = makeAddr("stranger");
        CardSpend memory s = _stableSpend(stranger, 0, 1e6, "stranger");
        vm.prank(alice);
        usd.approve(address(program), 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, stranger));
        program.spend(s);
    }

    function test_revert_tokenNotAccepted() public {
        otherUsd.mint(alice, 10e6);
        CardSpend memory s = _stableSpend(publicWallet, 0, 1e6, "token");
        s.token = address(otherUsd);
        vm.prank(alice);
        otherUsd.approve(address(program), 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, publicWallet));
        program.spend(s);
    }

    function test_revert_wrongProgram() public {
        CardSpend memory s = _stableSpend(publicWallet, 0, 1e6, "program");
        s.program = address(0xBEEF);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.WrongProgram.selector, address(0xBEEF)));
        program.spend(s);
        vm.prank(router);
        usd.transfer(address(program), 1e6);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.WrongProgram.selector, address(0xBEEF)));
        program.spendFrom(address(usd), 1e6, abi.encode(s));
    }

    function test_revert_invalidAmounts() public {
        CardSpend memory s = _stableSpend(publicWallet, 0, 0, "zero");
        vm.prank(alice);
        vm.expectRevert(CardSpender.InvalidAmount.selector);
        program.spend(s);
        s.amount = 1e6;
        s.fromVault = 2e6;
        vm.prank(alice);
        vm.expectRevert(CardSpender.InvalidAmount.selector);
        program.spend(s);
    }

    function test_revert_vaultNotAllowed() public {
        mock.setVault(address(earnVault), false);
        _depositEarn(alice, 100e6);
        CardSpend memory s = _earnSpend(publicWallet, 0, 10e6, 10e6, "vault");
        vm.prank(alice);
        earnShare.approve(address(program), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.VaultNotAllowed.selector, address(earnVault)));
        program.spend(s);
    }

    function test_revert_incorrectAssetForVault() public {
        // The vault holds `usd`; the spend asks it for `otherUsd`, which the provider accepts.
        mock.setToken(address(otherUsd), true);
        _depositEarn(alice, 100e6);
        CardSpend memory s = _earnSpend(publicWallet, 0, 10e6, 10e6, "asset");
        s.token = address(otherUsd);
        vm.prank(alice);
        earnShare.approve(address(program), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(CardSpender.IncorrectAssetForVault.selector);
        program.spend(s);

        uint256 shares = _depositEarn(router, 100e6);
        s.destination = pooledWallet;
        vm.prank(router);
        earnShare.transfer(address(program), shares);
        vm.prank(router);
        vm.expectRevert(CardSpender.IncorrectAssetForVault.selector);
        program.spendFrom(address(earnShare), shares, abi.encode(s));
    }

    /// @dev A withdrawal whose shares fall short of the live cost pays nothing: the direct path refuses it, and
    ///      a payout target cannot pull more shares than the program holds.
    function test_revert_spendFrom_earnInputBelowLiveCost() public {
        _depositEarn(router, 100e6);
        CardSpend memory s = _earnSpend(pooledWallet, 0, 10e6, 10e6, "short.earn");
        uint256 cost = earnVault.previewWithdraw(10e6);
        vm.prank(router);
        earnShare.transfer(address(program), cost - 1);
        vm.prank(router);
        if (_payout()) vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        else vm.expectRevert(CardSpender.InsufficientInput.selector);
        program.spendFrom(address(earnShare), cost - 1, abi.encode(s));
    }

    /// @dev A token that calls back into the program while it moves the spend hits the lock, on either entry
    ///      point, and the spend still pays.
    function test_revert_reentrancy() public {
        ReentrantToken token = new ReentrantToken();
        mock.setToken(address(token), true);
        token.mint(alice, 10e6);
        token.mint(router, 10e6);
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "reenter");
        s.token = address(token);

        token.arm(address(program), abi.encodeCall(CardSpender.spend, (s)));
        vm.prank(alice);
        token.approve(address(program), 1e6);
        vm.prank(alice);
        program.spend(s);
        assertTrue(token.reentered(), "public spend re-entered");
        assertEq(bytes4(token.reentryError()), CardSpender.Reentrancy.selector);

        vm.prank(router);
        token.transfer(address(program), 1e6);
        token.arm(address(program), abi.encodeCall(CardSpender.spendFrom, (address(token), 1, "")));
        vm.prank(router);
        program.spendFrom(address(token), 1e6, abi.encode(s));
        assertTrue(token.reentered(), "private spend re-entered");
        assertEq(bytes4(token.reentryError()), CardSpender.Reentrancy.selector);

        assertEq(token.balanceOf(pooledWallet), 2e6, "both spends paid");
        assertEq(token.balanceOf(address(program)), 0);
    }

    function test_revert_noApproval() public {
        CardSpend memory s = _stableSpend(publicWallet, 0, 1e6, "approval");
        vm.prank(alice);
        vm.expectRevert();
        program.spend(s);
    }

    // Pause -------------------------------------------------------------

    /// @notice The program has no pause of its own: it reads the provider's, live, so the provider's pause
    ///         stops public and private spends and its resume lets them through again.
    function test_providerPause_stopsPublicAndPrivate() public {
        assertFalse(program.paused());
        mock.setPaused(true);
        assertTrue(program.paused());
        _expectPaused();
        mock.setPaused(false);
        assertFalse(program.paused());
        _publicSpend(alice, _stableSpend(pooledWallet, 0, 1e6, "resumed"));
        assertEq(usd.balanceOf(pooledWallet), 1e6);
    }

    function test_availableBalance_countsAllowedVault() public {
        uint256 shares = _depositEarn(alice, 400e6);
        assertEq(program.availableBalance(alice, address(usd), address(0)), 600e6);
        assertEq(
            program.availableBalance(alice, address(usd), address(earnVault)), 600e6 + earnVault.previewRedeem(shares)
        );
        mock.setVault(address(earnVault), false);
        assertEq(program.availableBalance(alice, address(usd), address(earnVault)), 600e6);
    }

    function _expectPaused() internal {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "paused");
        vm.prank(alice);
        usd.approve(address(program), 1e6);
        vm.prank(alice);
        vm.expectRevert(CardSpender.ProgramPaused.selector);
        program.spend(s);
        vm.prank(router);
        usd.transfer(address(program), 1e6);
        vm.prank(router);
        vm.expectRevert(CardSpender.ProgramPaused.selector);
        program.spendFrom(address(usd), 1e6, abi.encode(s));
        vm.prank(address(program));
        usd.transfer(router, 1e6);
    }
}

contract CardSpenderDirectTest is CardSpenderBehavior {
    function _payout() internal pure override returns (bool) {
        return false;
    }

    function test_paysDirectly() public view {
        assertEq(program.PAYOUT_TARGET(), address(0));
    }

    /// @dev The program checks `maxShares` itself only when it pays directly; a payout target enforces it on the
    ///      private path (Bridge's handler does, with its own `ShareCostExceeded`).
    function test_revert_spendFrom_earnShareCostAboveMaxShares() public {
        uint256 shares = _depositEarn(router, 100e6);
        CardSpend memory s = _earnSpend(pooledWallet, 0, 10e6, 10e6, "cap.private");
        uint256 cost = earnVault.previewWithdraw(10e6);
        s.maxShares = cost - 1;
        vm.prank(router);
        earnShare.transfer(address(program), shares);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.ShareCostExceeded.selector, cost, cost - 1));
        program.spendFrom(address(earnShare), shares, abi.encode(s));
    }
}

/// @notice The same behavior through a payout target, plus what a target that misbehaves can and cannot do.
contract CardSpenderPayoutTest is CardSpenderBehavior {
    function _payout() internal pure override returns (bool) {
        return true;
    }

    function test_paysThroughTheTarget() public {
        assertEq(program.PAYOUT_TARGET(), address(target));
        program.warm(address(usd));
        assertEq(usd.allowance(address(program), address(target)), type(uint256).max);
    }

    function test_revert_targetPaysNothing() public {
        target.setMode(MockPayoutTarget.Mode.PayNothing);
        CardSpend memory s = _stableSpend(publicWallet, 0, 1e6, "nothing");
        vm.prank(alice);
        usd.approve(address(program), 1e6);
        vm.prank(alice);
        vm.expectRevert(CardSpender.DestinationNotCredited.selector);
        program.spend(s);
    }

    function test_revert_targetPaysShort() public {
        target.setMode(MockPayoutTarget.Mode.PayShort);
        vm.prank(router);
        usd.transfer(address(program), 2e6);
        vm.prank(router);
        vm.expectRevert(CardSpender.DestinationNotCredited.selector);
        program.spendFrom(address(usd), 2e6, abi.encode(_stableSpend(pooledWallet, 0, 2e6, "short")));
    }

    /// @dev A target that takes more than the spend can take at most the payer's approval (public) or the
    ///      withdrawal's `maxInput` (private); both revert here.
    function test_revert_targetTakesMoreThanTheInput() public {
        target.setMode(MockPayoutTarget.Mode.TakeExtra);
        CardSpend memory s = _stableSpend(publicWallet, 0, 1e6, "extra");
        vm.prank(alice);
        usd.approve(address(program), 1e6);
        vm.prank(alice);
        vm.expectRevert();
        program.spend(s);

        vm.prank(router);
        usd.transfer(address(program), 1e6);
        vm.prank(router);
        vm.expectRevert();
        program.spendFrom(address(usd), 1e6, abi.encode(_stableSpend(pooledWallet, 0, 1e6, "extra.private")));
    }
}

contract CardFactoryTest is CoreEnv {
    function setUp() public {
        _deployCore();
        _deployMockProgram(false);
    }

    function test_deploy_atPredictedAddress_andIdempotent() public {
        address predicted = factory.predict("p", ICardProvider(address(mock)));
        address deployed = factory.deploy("p", ICardProvider(address(mock)));
        assertEq(deployed, predicted);
        assertTrue(factory.isSpender(deployed));
        assertEq(factory.deploy("p", ICardProvider(address(mock))), deployed, "deploying again returns it");
        assertEq(address(CardSpender(deployed).PROVIDER()), address(mock));
    }

    /// @dev The address commits to the program ID and provider, so nobody can take it with another provider.
    function test_addressCommitsToProgramAndProvider() public view {
        address a = factory.predict("p", ICardProvider(address(mock)));
        assertTrue(a != factory.predict("p", ICardProvider(address(0xBEEF))));
        assertTrue(a != factory.predict("q", ICardProvider(address(mock))));
    }

    function test_revert_notAProvider() public {
        NotAProvider bad = new NotAProvider();
        vm.expectRevert();
        factory.deploy("bad", ICardProvider(address(bad)));
    }
}
