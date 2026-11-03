// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { CardSpend } from "../../src/core/CardSpend.sol";
import { CardSpender } from "../../src/core/CardSpender.sol";
import { ICardProvider } from "../../src/core/interfaces/ICardProvider.sol";
import { ITempoEarnVault } from "../../src/core/interfaces/ITempoEarnVault.sol";
import { CoreEnv } from "./harness/CoreEnv.sol";
import { ADDRESS_REGISTRY_ADDRESS, IAddressRegistry } from "zone-router/interfaces/IAddressRegistry.sol";

import {
    LiteralReceiverVault,
    MockPayoutProvider,
    MockPayoutTarget,
    MockProvider,
    MockRouter,
    NotAProvider,
    ReentrantToken,
    VirtualAwareToken
} from "./harness/Mocks.sol";

/// @notice `CardSpender` behavior every provider gets, run once with a program that pays directly and once
///         with one that pays through its provider's payout target: public and private spends from stablecoin,
///         Earn or both, every check, the pause, and the program holding nothing afterwards.
abstract contract CardSpenderBehavior is CoreEnv {
    /// @dev Tempo Earn's `EarnVault.ExceedsMaxEarnShares()`.
    bytes4 internal constant EXCEEDS_MAX_EARN_SHARES = bytes4(keccak256("ExceedsMaxEarnShares()"));

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
        vm.prank(router);
        vm.expectRevert(CardSpender.InsufficientInput.selector);
        program.spendFrom(address(usd), 1e6, abi.encode(s));
    }

    function test_revert_spendFrom_zeroOrHugeMaxInput() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "max");
        vm.prank(router);
        vm.expectRevert(CardSpender.InvalidAmount.selector);
        program.spendFrom(address(usd), 0, abi.encode(s));
        vm.prank(router);
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

    // Router authentication and the seed --------------------------------

    /// @dev Only a router the program's router factory deployed, whose mode lists the program, may call
    ///      `spendFrom`: nobody else can spend what the program holds.
    function test_revert_spendFrom_notRouter() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "not.router");
        usd.mint(address(program), 1e6);
        vm.prank(alice);
        vm.expectRevert(CardSpender.NotRouter.selector);
        program.spendFrom(address(usd), 1e6, abi.encode(s));

        MockRouter unlisted = new MockRouter();
        routerFactory.register(address(unlisted), true);
        vm.prank(address(unlisted));
        vm.expectRevert(CardSpender.NotRouter.selector);
        program.spendFrom(address(usd), 1e6, abi.encode(s));

        MockRouter rogue = new MockRouter();
        rogue.list(address(program), true);
        vm.prank(address(rogue));
        vm.expectRevert(CardSpender.NotRouter.selector);
        program.spendFrom(address(usd), 1e6, abi.encode(s));
        assertEq(usd.balanceOf(address(program)), 1e6, "the stray balance stays");
    }

    /// @dev A private spend names no cardholder, so the provider is asked with no payer.
    function test_privateSpend_asksTheProviderWithNoPayer() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "zero.payer");
        vm.expectCall(
            address(mock),
            abi.encodeCall(ICardProvider.isAuthorizedDestination, (address(0), pooledWallet, address(usd), 0, true))
        );
        _routerSpend(address(usd), 1e6, s);
    }

    /// @dev A one-unit seed of each token is the baseline every spend leaves untouched, public or private,
    ///      from stablecoin or Earn.
    function test_seedIsTheBaseline() public {
        _depositEarn(router, 200e6);
        _depositEarn(alice, 100e6);
        usd.mint(address(program), 1);
        vm.prank(router);
        earnShare.transfer(address(program), 1);

        _routerSpend(address(usd), 5e6 + 3, _stableSpend(pooledWallet, 0, 5e6, "seed.1"));
        CardSpend memory e = _earnSpend(pooledWallet, 0, 4e6, 4e6, "seed.2");
        _routerSpend(address(earnShare), e.maxShares, e);
        _publicSpend(alice, _earnSpend(publicWallet, 0, 6e6, 3e6, "seed.3"));

        assertEq(usd.balanceOf(pooledWallet), 9e6);
        assertEq(usd.balanceOf(publicWallet), 6e6);
        assertEq(usd.balanceOf(address(program)), 1, "stablecoin seed kept");
        assertEq(earnShare.balanceOf(address(program)), 1, "share seed kept");
    }

    /// @dev A hand-back that reports success without moving the change leaves it behind, which is refused.
    function test_revert_residualBalance() public {
        StuckToken token = new StuckToken();
        mock.setToken(address(token), true);
        token.mint(router, 10e6);
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "residual");
        s.token = address(token);
        vm.prank(router);
        token.transfer(address(program), 2e6);
        token.setStuck(address(program), router);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.ResidualBalance.selector, address(token)));
        program.spendFrom(address(token), 2e6, abi.encode(s));
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
        // The vault refuses the cap on the direct path; a payout target cannot pull more than the program holds.
        if (_payout()) vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        else vm.expectRevert(EXCEEDS_MAX_EARN_SHARES);
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

    /// @dev Anyone may set the program's standing EarnShare approval to an allowed vault before its first
    ///      spend from it, after which a spend approves nothing; a vault the provider does not allow is refused.
    function test_warmVault() public {
        vm.prank(makeAddr("anyone"));
        program.warmVault(address(earnVault));
        assertEq(earnShare.allowance(address(program), address(earnVault)), type(uint256).max);

        _depositEarn(router, 100e6);
        CardSpend memory s = _earnSpend(pooledWallet, 0, 5e6, 5e6, "warm");
        _routerSpend(address(earnShare), s.maxShares, s);
        assertEq(usd.balanceOf(pooledWallet), 5e6);

        address other = makeAddr("other.vault");
        vm.expectRevert(abi.encodeWithSelector(CardSpender.VaultNotAllowed.selector, other));
        program.warmVault(other);
    }

    /// @dev The private Earn path lets the vault price the shares, capped by the lower of `maxInput` and
    ///      `maxShares`: a withdrawal whose shares fall short of the live cost reverts in the vault.
    function test_privateEarn_capIsTheLowerOfMaxInputAndMaxShares() public {
        uint256 shares = _depositEarn(router, 100e6);
        CardSpend memory s = _earnSpend(pooledWallet, 0, 10e6, 10e6, "cap.min");
        uint256 cost = earnVault.previewWithdraw(10e6);
        s.maxShares = cost;
        vm.prank(router);
        earnShare.transfer(address(program), shares);
        vm.expectCall(
            address(earnVault), abi.encodeCall(ITempoEarnVault.withdrawExact, (uint256(10e6), pooledWallet, cost))
        );
        vm.prank(router);
        program.spendFrom(address(earnShare), shares, abi.encode(s));
        assertEq(usd.balanceOf(pooledWallet), 10e6);
    }

    /// @dev On the private direct path the vault enforces `maxShares` as its cap; a payout target enforces it
    ///      itself (Bridge's handler does, with its own `ShareCostExceeded`).
    function test_revert_spendFrom_earnShareCostAboveMaxShares() public {
        uint256 shares = _depositEarn(router, 100e6);
        CardSpend memory s = _earnSpend(pooledWallet, 0, 10e6, 10e6, "cap.private");
        uint256 cost = earnVault.previewWithdraw(10e6);
        s.maxShares = cost - 1;
        vm.prank(router);
        earnShare.transfer(address(program), shares);
        vm.prank(router);
        vm.expectRevert(EXCEEDS_MAX_EARN_SHARES);
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
        // The stablecoin it pulled is left unused, which the program checks first.
        vm.expectRevert(abi.encodeWithSelector(CardSpender.InputNotConsumed.selector, 0, 1e6));
        program.spend(s);
    }

    /// @dev A payout target cannot keep the rest of a withdrawal: a private stablecoin spend uses exactly its
    ///      amount and a private Earn spend at most the share cost quoted before the payout.
    function test_revert_targetKeepsSurplus() public {
        target.setMode(MockPayoutTarget.Mode.KeepSurplus);
        vm.prank(router);
        usd.transfer(address(program), 5e6 + 7);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.InputNotConsumed.selector, 5e6 + 7, 5e6));
        program.spendFrom(address(usd), 5e6 + 7, abi.encode(_stableSpend(pooledWallet, 0, 5e6, "surplus")));

        _depositEarn(router, 100e6);
        CardSpend memory e = _earnSpend(pooledWallet, 0, 5e6, 5e6, "surplus.earn");
        uint256 cost = earnVault.previewWithdraw(5e6);
        vm.prank(router);
        earnShare.transfer(address(program), e.maxShares);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.InputNotConsumed.selector, e.maxShares, cost));
        program.spendFrom(address(earnShare), e.maxShares, abi.encode(e));
    }

    /// @dev A target that pays the destination from its own funds consumes nothing: a private Earn spend is
    ///      refused as spending nothing, and a public spend for leaving the payer's stablecoin unused.
    function test_revert_targetPaysFromItsOwnFunds() public {
        target.setMode(MockPayoutTarget.Mode.PayFromOwn);
        usd.mint(address(target), 100e6);
        _depositEarn(router, 100e6);
        CardSpend memory e = _earnSpend(pooledWallet, 0, 5e6, 5e6, "own.earn");
        vm.prank(router);
        earnShare.transfer(address(program), e.maxShares);
        vm.prank(router);
        vm.expectRevert(CardSpender.NothingSpent.selector);
        program.spendFrom(address(earnShare), e.maxShares, abi.encode(e));

        CardSpend memory s = _stableSpend(publicWallet, 0, 3e6, "own.public");
        vm.prank(alice);
        usd.approve(address(program), 3e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.InputNotConsumed.selector, 0, 3e6));
        program.spend(s);
    }

    function test_warmVault_doesNothingThroughATarget() public {
        program.warmVault(address(earnVault));
        assertEq(earnShare.allowance(address(program), address(earnVault)), 0);
    }

    function test_revert_targetPaysShort() public {
        target.setMode(MockPayoutTarget.Mode.PayShort);
        vm.prank(router);
        usd.transfer(address(program), 2e6);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.InputNotConsumed.selector, 2e6 - 1, 2e6));
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
        assertTrue(factory.isDeployed(deployed));
        assertEq(CardSpender(deployed).ROUTER_FACTORY(), address(routerFactory));
        assertEq(factory.ROUTER_FACTORY(), address(routerFactory));
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

/// @notice TIP-1022 virtual destinations: a transfer to one credits its master, so the program checks the
///         master's balance, and redeems Earn shares to itself first, since Earn's engines check the literal
///         receiver. Paying directly and through a payout target.
contract CardSpenderVirtualDestinationTest is CoreEnv {
    address internal constant VIRTUAL = address(uint160(0x12345678fDFDfDFdFDfdFdfdFDFd000000000001));
    address internal constant UNREGISTERED = address(uint160(0x87654321fDfdFdFDfdFDfDfDfdfD000000000001));

    address internal master = makeAddr("virtual.master");
    VirtualAwareToken internal vusd;
    LiteralReceiverVault internal vault;

    function setUp() public {
        _deployCore();
        // The registry precompile resolves VIRTUAL to its master, as it would once the master registered.
        vm.mockCall(
            ADDRESS_REGISTRY_ADDRESS, abi.encodeCall(IAddressRegistry.resolveRecipient, (VIRTUAL)), abi.encode(master)
        );
        vusd = new VirtualAwareToken("VUSD");
        vault = new LiteralReceiverVault(address(vusd));
        vusd.mint(address(vault), 1000e6);
        vusd.mint(alice, 1000e6);
        vusd.mint(router, 1000e6);
        VirtualAwareToken(vault.earnShare()).mint(alice, 1000e6);
        VirtualAwareToken(vault.earnShare()).mint(router, 1000e6);
    }

    function test_direct_paysVirtualDestinations() public {
        _program(false);
        _publicSplit();
        _privateStable();
        _privateEarn();
        assertEq(vusd.balanceOf(master), 6e6 + 2e6 + 3e6);
        assertEq(vusd.balanceOf(address(program)), 0);
        assertEq(VirtualAwareToken(vault.earnShare()).balanceOf(address(program)), 0);
    }

    function test_payout_paysVirtualDestinations() public {
        _program(true);
        CardSpend memory s = _spend(VIRTUAL, 6e6, 0);
        vm.prank(alice);
        vusd.approve(address(program), 6e6);
        vm.prank(alice);
        program.spend(s);
        _privateStable();
        assertEq(vusd.balanceOf(master), 8e6);
    }

    function test_revert_unregisteredVirtualDestination() public {
        _program(false);
        MockProvider(address(mock)).setDestination(UNREGISTERED, true, true);
        CardSpend memory s = _spend(UNREGISTERED, 1e6, 0);
        vm.prank(alice);
        vusd.approve(address(program), 1e6);
        vm.prank(alice);
        // The registry precompile refuses a virtual address without a registered master.
        vm.expectRevert(bytes4(keccak256("VirtualAddressUnregistered()")));
        program.spend(s);
    }

    function _program(bool payout) internal {
        if (payout) {
            target = new MockPayoutTarget();
            mock = new MockPayoutProvider(address(target));
        } else {
            mock = new MockProvider();
        }
        mock.setToken(address(vusd), true);
        mock.setVault(address(vault), true);
        mock.setDestination(VIRTUAL, true, true);
        program = CardSpender(factory.deploy(payout ? bytes32("virtual.payout") : bytes32("virtual"), mock));
        _listInRouter(address(program));
    }

    function _spend(address destination, uint256 amount, uint256 fromVault) internal view returns (CardSpend memory s) {
        s.program = address(program);
        s.token = address(vusd);
        s.amount = amount;
        s.destination = destination;
        s.fromVault = fromVault;
        if (fromVault != 0) s.vault = address(vault);
        s.ref = "virtual";
    }

    function _publicSplit() internal {
        CardSpend memory s = _spend(VIRTUAL, 6e6, 4e6);
        vm.startPrank(alice);
        vusd.approve(address(program), 2e6);
        VirtualAwareToken(vault.earnShare()).approve(address(program), 8e6);
        program.spend(s);
        vm.stopPrank();
    }

    function _privateStable() internal {
        vm.prank(router);
        vusd.transfer(address(program), 2e6 + 5);
        vm.prank(router);
        program.spendFrom(address(vusd), 2e6 + 5, abi.encode(_spend(VIRTUAL, 2e6, 0)));
    }

    function _privateEarn() internal {
        address share = vault.earnShare();
        vm.prank(router);
        VirtualAwareToken(share).transfer(address(program), 7e6);
        vm.prank(router);
        program.spendFrom(share, 7e6, abi.encode(_spend(VIRTUAL, 3e6, 3e6)));
        assertEq(VirtualAwareToken(share).balanceOf(router), 1000e6 - 6e6, "only the cost was burned");
    }
}

/// @dev An ERC-20 whose transfers from one account to another report success without moving anything.
contract StuckToken is ERC20 {
    address public stuckFrom;
    address public stuckTo;

    constructor() ERC20("Stuck USD", "SUSD") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setStuck(address from, address to) external {
        stuckFrom = from;
        stuckTo = to;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == stuckFrom && to == stuckTo) return;
        super._update(from, to, value);
    }
}
