// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { ReceiveSweep } from "../../src/programs/ReceiveSweep.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice A token whose credits repay a fixed debt to a creditor first, as the core does on Tempo.
contract RepayingToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public immutable CREDITOR;
    uint256 public debt;

    constructor(address creditor, uint256 debt_) {
        CREDITOR = creditor;
        debt = debt_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFromWithMemo(address from, address to, uint256 amount, bytes32) external returns (bool) {
        return transferFrom(from, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        uint256 repaid = amount < debt ? amount : debt;
        debt -= repaid;
        balanceOf[CREDITOR] += repaid;
        balanceOf[to] += amount - repaid;
        return true;
    }
}

/// @notice A vault of one asset that refuses every deposit, as a paused or full vault does.
contract RefusingVault {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }

    function deposit(uint256, address, uint256) external pure returns (uint256) {
        revert("paused");
    }
}

contract ReceiveSweepTest is AuthEnv {
    ReceiveSweep internal sweep;
    address internal payer = makeAddr("payer");

    function setUp() public {
        _deployPrograms();
        sweep = new ReceiveSweep();
        usd.mint(payer, 1000e6);
        vm.prank(payer);
        usd.approve(address(sweep), type(uint256).max);
    }

    function _optIn(address token, IEarnVault vault) internal {
        vm.startPrank(alice);
        sweep.setSweep(token, vault);
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(sweep), type(uint256).max));
        assertTrue(ok);
        vm.stopPrank();
    }

    function test_pay_withoutSweep_isAPlainCredit() public {
        vm.prank(payer);
        uint256 swept = sweep.pay(alice, address(usd), 100e6, bytes32("memo"));
        assertEq(swept, 0);
        assertEq(usd.balanceOf(alice), 100e6);
        assertEq(earnShare.balanceOf(alice), 0);
    }

    function test_pay_sweepsIntoTheOwnersVault() public {
        _optIn(address(usd), IEarnVault(address(earnVault)));
        vm.prank(payer);
        uint256 swept = sweep.pay(alice, address(usd), 100e6, bytes32("memo"));
        assertEq(swept, 100e6);
        assertEq(usd.balanceOf(alice), 0);
        assertGt(earnShare.balanceOf(alice), 0);
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice)), 100e6, 1);
        assertEq(usd.balanceOf(address(sweep)), 0);
    }

    function test_pay_leavesWhatTheOwnerAlreadyHad() public {
        usd.mint(alice, 40e6);
        _optIn(address(usd), IEarnVault(address(earnVault)));
        vm.prank(payer);
        sweep.pay(alice, address(usd), 60e6, bytes32("memo"));
        // Only the new credit is swept; cash the owner already held stays cash.
        assertEq(usd.balanceOf(alice), 40e6);
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice)), 60e6, 1);
    }

    function test_pay_debtIsRepaidFirst() public {
        address creditor = makeAddr("creditor");
        RepayingToken token = new RepayingToken(creditor, 20e6);
        token.mint(payer, 100e6);
        vm.prank(payer);
        token.approve(address(sweep), type(uint256).max);
        // A vault of this token is out of reach here, so the test checks what would be swept with no vault: the rise.
        vm.prank(alice);
        token.approve(address(sweep), type(uint256).max);
        vm.prank(payer);
        sweep.pay(alice, address(token), 100e6, bytes32("memo"));
        assertEq(token.balanceOf(creditor), 20e6);
        assertEq(token.balanceOf(alice), 80e6);
    }

    function test_setSweep_rejectsAVaultOfAnotherAsset() public {
        vm.prank(alice);
        vm.expectRevert(ReceiveSweep.InvalidVault.selector);
        sweep.setSweep(address(earnShare), IEarnVault(address(earnVault)));
    }

    function test_setSweep_offStopsSweeping() public {
        _optIn(address(usd), IEarnVault(address(earnVault)));
        vm.prank(alice);
        sweep.setSweep(address(usd), IEarnVault(address(0)));
        vm.prank(payer);
        assertEq(sweep.pay(alice, address(usd), 10e6, bytes32("memo")), 0);
        assertEq(usd.balanceOf(alice), 10e6);
    }

    function test_pay_cannotSweepSomeoneWhoDidNotApprove() public {
        vm.prank(alice);
        sweep.setSweep(address(usd), IEarnVault(address(earnVault)));
        vm.prank(payer);
        vm.expectRevert();
        sweep.pay(alice, address(usd), 10e6, bytes32("memo"));
    }

    function test_pay_vaultRefusingDeposits_leavesThePaymentWithTheOwner() public {
        RefusingVault vault = new RefusingVault(address(usd));
        _optIn(address(usd), IEarnVault(address(vault)));
        vm.prank(payer);
        vm.expectEmit(address(sweep));
        emit ReceiveSweep.SweepRefused(alice, address(usd), address(vault), 100e6);
        uint256 swept = sweep.pay(alice, address(usd), 100e6, bytes32("memo"));
        assertEq(swept, 0);
        assertEq(usd.balanceOf(alice), 100e6);
        assertEq(usd.balanceOf(payer), 900e6);
        assertEq(usd.balanceOf(address(sweep)), 0);
        assertEq(usd.allowance(address(sweep), address(vault)), 0);
    }

    function test_policy_isPerOwner() public {
        _optIn(address(usd), IEarnVault(address(earnVault)));
        vm.prank(payer);
        sweep.pay(bob, address(usd), 10e6, bytes32("memo"));
        assertEq(usd.balanceOf(bob), 10e6);
    }
}
