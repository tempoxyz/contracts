// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ISpenderHandler } from "bridge-spender/src/ISpenderHandler.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";

import { Spend, SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { BridgeSettler } from "../../src/settler/BridgeSettler.sol";
import { AccessKeys } from "../harness/AccessKeys.sol";
import {
    NoopSpendHandler,
    OverReturningSpendHandler,
    ReentrantToken,
    ShortPayingSpendHandler
} from "../harness/Mocks.sol";

/// @notice The settler pays one program's spend from what a Zone router approves it, returns the
///         unused input to the router in the same call, and keeps nothing.
/// @dev No Zone: the settler has no Zone code. `router` plays the Zone router, approving
///      `maxInput` and calling `settle`.
contract BridgeSettlerTest is AccessKeys {
    uint256 internal constant AMOUNT = 40e6;

    BridgeSettler internal settler;
    address internal router = makeAddr("zone.router");

    function setUp() public {
        _deployTempo();
        settler = new BridgeSettler(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID);
    }

    function test_requiresAFactory() public {
        vm.expectRevert(BridgeSettler.ZeroAddress.selector);
        new BridgeSettler(IBridgeSpenderFactory(address(0)), SPENDER_ID);
    }

    /// @notice A stablecoin spend pays the destination and returns exactly the unused input.
    function test_stablecoinSpendPaysAndReturnsUnusedInput() public {
        uint256 maxInput = AMOUNT + 7e6;
        _mintUsd(router, maxInput);
        uint256 before = usd.balanceOf(settlement);
        Spend memory spend = _stableSpend(AMOUNT);
        spend.ref = keccak256("card.auth");
        _approve(address(usd), maxInput);

        vm.expectEmit(true, true, true, true, spender);
        emit SpenderTempoSpend.TempoSpendExecuted(
            spend.ref, address(settler), settlement, address(usd), AMOUNT, AMOUNT, 0, 0
        );
        vm.expectEmit(true, true, true, true, address(settler));
        emit BridgeSettler.SpendSettled(spend.ref, address(usd), AMOUNT, 7e6);
        vm.prank(router);
        settler.settle(address(usd), maxInput, abi.encode(spend));
        _approve(address(usd), 0);

        assertEq(usd.balanceOf(settlement) - before, AMOUNT, "destination paid");
        assertEq(usd.balanceOf(router), 7e6, "unused input returned");
        assertEq(usd.balanceOf(address(settler)), 0, "nothing left in the settler");
        assertEq(usd.balanceOf(spender), 0, "nothing left in the clone");
        _assertNoApprovals(address(usd));
    }

    /// @notice A spend that uses all of `maxInput` returns nothing.
    function test_stablecoinSpendUsingAllInput() public {
        _mintUsd(router, AMOUNT);
        _settle(address(usd), AMOUNT, _stableSpend(AMOUNT));
        assertEq(usd.balanceOf(router), 0);
        assertEq(usd.balanceOf(address(settler)), 0);
        _assertNoApprovals(address(usd));
    }

    /// @notice An Earn spend burns only the shares the withdrawal costs and returns the rest.
    function test_earnSpendReturnsUnusedShares() public {
        _mintUsd(router, 100e6);
        uint256 shares = _depositEarn(router, 100e6);
        uint256 burned = earnVault.previewWithdraw(AMOUNT);
        uint256 maxInput = burned + burned * 50 / 10_000 + 1;
        assertLt(maxInput, shares, "router holds more than it approves");
        uint256 before = usd.balanceOf(settlement);
        Spend memory spend = _stableSpend(AMOUNT);
        spend.vault = address(earnVault);
        spend.fromVault = AMOUNT;
        spend.maxShares = maxInput;
        spend.ref = keccak256("card.auth.earn");
        _approve(address(earnShare), maxInput);

        vm.expectEmit(true, true, true, true, address(settler));
        emit BridgeSettler.SpendSettled(spend.ref, address(earnShare), burned, maxInput - burned);
        vm.prank(router);
        settler.settle(address(earnShare), maxInput, abi.encode(spend));
        _approve(address(earnShare), 0);

        assertEq(usd.balanceOf(settlement) - before, AMOUNT, "destination paid");
        assertEq(shares - earnShare.balanceOf(router), burned, "charged the burned shares only");
        assertEq(earnShare.balanceOf(address(settler)), 0, "nothing left in the settler");
        assertEq(earnShare.balanceOf(spender), 0, "nothing left in the clone");
        assertEq(earnShare.allowance(spender, address(earnVault)), 0, "clone -> vault");
        _assertNoApprovals(address(earnShare));
    }

    /// @notice Whatever the router approves and the spend asks, it loses exactly the spend, never
    ///         more than `maxInput`.
    function testFuzz_callerLosesExactlyTheSpend(uint256 amount, uint256 maxInput, uint256 approved) public {
        amount = bound(amount, 1, 1_000_000e6);
        maxInput = bound(maxInput, amount, 2_000_000e6);
        approved = bound(approved, maxInput, type(uint128).max);
        _mintUsd(router, 2_000_000e6);

        vm.startPrank(router);
        usd.approve(address(settler), approved);
        settler.settle(address(usd), maxInput, abi.encode(_stableSpend(amount)));
        vm.stopPrank();

        assertEq(2_000_000e6 - usd.balanceOf(router), amount, "lost the spend only");
        assertEq(usd.allowance(router, address(settler)), approved - maxInput, "pulled maxInput only");
        assertEq(usd.balanceOf(address(settler)), 0);
    }

    /// @notice A spend above `maxInput` cannot reach the router's other funds, even with a larger
    ///         standing approval.
    function test_spendAboveMaxInputReverts() public {
        _mintUsd(router, 100e6);
        vm.startPrank(router);
        usd.approve(address(settler), 100e6);
        vm.expectRevert();
        settler.settle(address(usd), AMOUNT - 1, abi.encode(_stableSpend(AMOUNT)));
        vm.stopPrank();
        assertEq(usd.balanceOf(router), 100e6, "nothing taken");
    }

    function test_rejectsAnotherProgram() public {
        Spend memory spend = _stableSpend(AMOUNT);
        spend.spenderId = keccak256("another.program");
        _mintUsd(router, AMOUNT);
        vm.startPrank(router);
        usd.approve(address(settler), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(BridgeSettler.WrongProgram.selector, spend.spenderId));
        settler.settle(address(usd), AMOUNT, abi.encode(spend));
        vm.stopPrank();
    }

    function test_rejectsZeroInput() public {
        vm.prank(router);
        vm.expectRevert(BridgeSettler.InvalidAmount.selector);
        settler.settle(address(usd), 0, abi.encode(_stableSpend(AMOUNT)));
    }

    function test_rejectsInputAboveUint128() public {
        bytes memory data = abi.encode(_stableSpend(AMOUNT));
        vm.prank(router);
        vm.expectRevert(BridgeSettler.InvalidAmount.selector);
        settler.settle(address(usd), uint256(type(uint128).max) + 1, data);
    }

    /// @notice A handler under "TS" that moves nothing cannot make a spend look settled.
    function test_rejectsAHandlerThatSettlesNothing() public {
        _replaceHandler(ISpenderHandler(address(new NoopSpendHandler(IFactory(address(bridgeFactory))))));
        _expectSettleRevert(AMOUNT, abi.encodeWithSelector(BridgeSettler.NothingSettled.selector));
    }

    /// @notice A handler that hands back more input than it was given cannot look settled, even
    ///         when it pays the destination.
    function test_rejectsAHandlerThatReturnsMoreThanItWasGiven() public {
        _replaceHandler(ISpenderHandler(address(new OverReturningSpendHandler(IFactory(address(bridgeFactory))))));
        _mintUsd(spender, AMOUNT + 1);
        _expectSettleRevert(AMOUNT, abi.encodeWithSelector(BridgeSettler.NothingSettled.selector));
    }

    /// @notice The input must be the spend's own token: its stablecoin, or the shares of the vault that
    ///         funds all of it. A split spend cannot come from one withdrawal.
    function test_rejectsAnInputThatIsNotTheSpendsToken() public {
        _mintUsd(router, 100e6);
        uint256 shares = _depositEarn(router, 100e6);
        vm.startPrank(router);
        earnShare.approve(address(settler), shares);
        vm.expectRevert(abi.encodeWithSelector(BridgeSettler.WrongInputToken.selector, address(earnShare)));
        settler.settle(address(earnShare), shares, abi.encode(_stableSpend(AMOUNT)));

        Spend memory split = _stableSpend(AMOUNT);
        split.vault = address(earnVault);
        split.fromVault = AMOUNT / 2;
        split.maxShares = shares;
        vm.expectRevert(abi.encodeWithSelector(BridgeSettler.WrongInputToken.selector, address(earnShare)));
        settler.settle(address(earnShare), shares, abi.encode(split));

        Spend memory earn = _stableSpend(AMOUNT);
        earn.vault = address(earnVault);
        earn.fromVault = AMOUNT;
        earn.maxShares = shares;
        usd.approve(address(settler), 50e6);
        vm.expectRevert(abi.encodeWithSelector(BridgeSettler.WrongInputToken.selector, address(usd)));
        settler.settle(address(usd), 50e6, abi.encode(earn));
        vm.stopPrank();
        assertEq(earnShare.balanceOf(router), shares, "nothing taken");
    }

    /// @notice A handler that takes the input but pays the destination short cannot look settled.
    function test_rejectsAHandlerThatPaysShort() public {
        _replaceHandler(ISpenderHandler(address(new ShortPayingSpendHandler(IFactory(address(bridgeFactory))))));
        _expectSettleRevert(AMOUNT, abi.encodeWithSelector(BridgeSettler.DestinationNotPaid.selector));
    }

    /// @notice A token that calls back into the settler during the pull hits the reentrancy lock,
    ///         and the spend still settles.
    function test_rejectsReentrancy() public {
        ReentrantToken token = new ReentrantToken();
        token.mint(router, AMOUNT);
        token.arm(address(settler), abi.encodeCall(BridgeSettler.settle, (address(token), 1, "")));
        Spend memory spend = _stableSpend(AMOUNT);
        spend.token = address(token);

        _settle(address(token), AMOUNT, spend);

        assertTrue(token.reentered(), "token re-entered");
        assertEq(bytes4(token.reentryError()), BridgeSettler.Reentrancy.selector);
        assertEq(token.balanceOf(settlement), AMOUNT, "destination paid");
        assertEq(token.balanceOf(address(settler)), 0);
    }

    function _stableSpend(uint256 amount) internal view returns (Spend memory) {
        return Spend({
            spenderId: SPENDER_ID,
            token: address(usd),
            amount: amount,
            destination: settlement,
            vault: address(0),
            fromVault: 0,
            maxShares: 0,
            ref: bytes32(0)
        });
    }

    /// @dev As the router does: approve `maxInput`, settle, reset the approval.
    function _settle(address token, uint256 maxInput, Spend memory spend) internal {
        _approve(token, maxInput);
        vm.prank(router);
        settler.settle(token, maxInput, abi.encode(spend));
        _approve(token, 0);
    }

    /// @dev The router approves the settler for `amount` of `token`.
    function _approve(address token, uint256 amount) internal {
        vm.prank(router);
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(settler), amount));
        require(ok, "approve");
    }

    function _expectSettleRevert(uint256 maxInput, bytes memory reason) internal {
        _mintUsd(router, maxInput);
        bytes memory data = abi.encode(_stableSpend(AMOUNT));
        vm.startPrank(router);
        usd.approve(address(settler), maxInput);
        vm.expectRevert(reason);
        settler.settle(address(usd), maxInput, data);
        vm.stopPrank();
        assertEq(usd.balanceOf(router), maxInput, "nothing taken");
    }

    function _replaceHandler(ISpenderHandler handler) internal {
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler(PREFIX_TEMPO_SPEND, handler);
    }

    /// @notice The settler's approval to the clone and the router's to the settler are cleared.
    function _assertNoApprovals(address token) internal view {
        (bool ok, bytes memory ret) =
            token.staticcall(abi.encodeWithSignature("allowance(address,address)", address(settler), spender));
        require(ok);
        assertEq(abi.decode(ret, (uint256)), 0, "settler -> clone");
        (ok, ret) = token.staticcall(abi.encodeWithSignature("allowance(address,address)", router, address(settler)));
        require(ok);
        assertEq(abi.decode(ret, (uint256)), 0, "router -> settler");
    }
}
