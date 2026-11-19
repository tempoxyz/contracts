// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { EarnVault } from "../../../src/earn/core/EarnVault.sol";
import { ERC4626Engine, IERC4626Vault } from "../../../src/earn/engines/erc4626/ERC4626Engine.sol";
import { Simple4626Vault } from "../../../src/demo/Simple4626Vault.sol";
import { IEarnEngineHeldDeposit } from "../../../src/interfaces/earn/engines/IEarnEngineHeldDeposit.sol";
import {
    IEarnVaultWithdrawCallback,
    IEarnWithdrawCallback
} from "../../../src/interfaces/earn/IEarnWithdrawCallback.sol";
import { CoreMockEngine, CoreMockToken, earnVaultTestNoFees } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";

contract EarnVaultWithdrawCallbackTest is Test {
    CoreMockToken asset;
    CoreMockToken share;
    CoreMockEngine engine;
    EarnVault core;
    CallbackPayer payer;
    address receiver = address(0xB0B);
    address operator = address(0x0FF1CE);

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 18);
        share = new CoreMockToken("Share", "SH", 18);
        engine = new CoreMockEngine(asset, 18);
        core = EarnVaultTestDeployer.deploy(address(engine), address(share), operator, earnVaultTestNoFees());
        payer = new CallbackPayer(core, share);
        asset.mint(address(payer), 10 ether);
        payer.deposit(10 ether);
    }

    function testReportsCallbackInterface() public view {
        assertTrue(core.supportsInterface(type(IEarnVaultWithdrawCallback).interfaceId));
        assertTrue(core.supportsInterface(type(IERC165).interfaceId));
        assertFalse(core.supportsInterface(0xffffffff));
    }

    function testRevertsWhenTheReturnIsNotCredited() public {
        RedirectingShare redirecting = new RedirectingShare(address(0xBEEF));
        EarnVault redirectCore =
            EarnVaultTestDeployer.deploy(address(engine), address(redirecting), operator, earnVaultTestNoFees());
        CallbackPayer redirectPayer = new CallbackPayer(redirectCore, redirecting);
        asset.mint(address(redirectPayer), 10 ether);
        redirectPayer.deposit(10 ether);

        // Transfers from the vault land with another holder, as a redirecting receive policy would send them.
        redirecting.setRedirectFrom(address(redirectCore));
        engine.setWithdrawBurnOverride(2 ether);
        vm.expectRevert(EarnVault.EarnSharesNotReturned.selector);
        redirectPayer.withdraw(5 ether, receiver, 5 ether);
    }

    function testReturnsQuotedSharesTheBurnLeaves() public {
        engine.setWithdrawBurnOverride(2 ether);
        uint256 burned = payer.withdraw(5 ether, receiver, 5 ether);

        assertEq(burned, 2 ether);
        assertEq(payer.requested(), 5 ether);
        assertEq(asset.balanceOf(receiver), 5 ether);
        assertEq(share.balanceOf(address(payer)), 8 ether);
        assertEq(share.balanceOf(address(core)), 0);
        assertEq(core.totalEarnShares(), core.engineShares());
    }

    function testBurnAboveTheQuoteReverts() public {
        engine.setWithdrawBurnOverride(6 ether);
        vm.expectRevert(EarnVault.ExceedsMaxEarnShares.selector);
        payer.withdraw(5 ether, receiver, 10 ether);
    }

    /// @dev The callback runs before the payout, so the views it can read show the settled price.
    function testCallbackSeesTheSettledPrice() public {
        uint256 assetsPerShare = core.previewRedeem(1 ether);
        uint256 assetsBefore = core.totalAssets();
        payer.withdraw(5 ether, receiver, 5 ether);
        assertEq(payer.priceDuring(), assetsPerShare);
        assertEq(payer.assetsDuring(), assetsBefore);
    }

    /// @dev The quoted shares paid in by the callback must not count against the residual-backing guard: leaving
    ///      one backed share on a vault with no residue still succeeds.
    function testCallbackCanLeaveTheLastBackedShare() public {
        assertEq(share.balanceOf(address(core)), 0);
        uint256 burned = payer.withdraw(10 ether - 1, receiver, 10 ether);
        assertEq(burned, 10 ether - 1);
        assertEq(share.totalSupply(), 1);
        assertEq(core.engineShares(), 1);
    }

    /// @dev A burn of the whole supply that would strand backing still reverts on the callback path.
    function testCallbackFullSupplyBurnWithBackingLeftReverts() public {
        asset.mint(address(this), 10 ether);
        asset.approve(address(core), type(uint256).max);
        core.contribute(10 ether);
        vm.expectRevert(EarnVault.ResidualBacking.selector);
        payer.withdraw(20 ether - 1, receiver, 10 ether);
    }

    /// @dev A callback that raises the venue's NAV cannot let a full burn pay out less than current backing.
    function testCallbackNavRiseBeforeFullBurnReverts() public {
        engine.setWithdrawBurnOverride(10 ether);
        payer.setNavBump(engine, 1 ether);
        vm.expectRevert(EarnVault.ResidualBacking.selector);
        payer.withdraw(10 ether, receiver, 10 ether);
    }

    function testRevertsWhenTheCallbackUnderpays() public {
        payer.setShortfall(1);
        vm.expectRevert(EarnVault.EarnSharesNotReceived.selector);
        payer.withdraw(5 ether, receiver, 5 ether);
        assertEq(share.balanceOf(address(payer)), 10 ether);
        assertEq(asset.balanceOf(receiver), 0);
    }

    function testRevertsWhenTheCallbackOverpays() public {
        payer.setShortfall(type(uint256).max);
        vm.expectRevert(EarnVault.EarnSharesNotReceived.selector);
        payer.withdraw(5 ether, receiver, 5 ether);
    }

    function testCostAboveTheCapRevertsBeforeTheCallback() public {
        // A reverted call rolls back state, so count calls instead of reading what the callback wrote.
        vm.expectCall(address(payer), abi.encodeWithSelector(IEarnWithdrawCallback.earnWithdrawCallback.selector), 0);
        vm.expectRevert(EarnVault.ExceedsMaxEarnShares.selector);
        payer.withdraw(5 ether, receiver, 4 ether);
    }

    function testCallbackCannotReenterTheVault() public {
        payer.setReenter(true);
        vm.expectRevert(EarnVault.ReentrantCall.selector);
        payer.withdraw(5 ether, receiver, 5 ether);
    }

    function testHeldDepositRefusesAShortCredit() public {
        ShortCreditToken heldAsset = new ShortCreditToken();
        CoreMockToken heldShare = new CoreMockToken("Held Share", "HSH", 18);
        Simple4626Vault venue = new Simple4626Vault(address(heldAsset), "Venue", "VEN", 18);
        ERC4626Engine heldEngine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        EarnVault heldCore =
            EarnVaultTestDeployer.deploy(address(heldEngine), address(heldShare), operator, earnVaultTestNoFees());
        heldEngine.initializeEarnVault(address(heldCore));

        // Stray assets on the engine would otherwise cover the shortfall.
        heldAsset.mint(address(heldEngine), 1 ether);
        heldAsset.mint(address(this), 3 ether);
        heldAsset.approve(address(heldCore), type(uint256).max);
        vm.expectRevert(EarnVault.InsufficientOutput.selector);
        heldCore.deposit(3 ether, receiver, 1);
    }

    function testHeldDepositSkipsTheVaultAllowance() public {
        CoreMockToken heldAsset = new CoreMockToken("Held", "HLD", 18);
        CoreMockToken heldShare = new CoreMockToken("Held Share", "HSH", 18);
        Simple4626Vault venue = new Simple4626Vault(address(heldAsset), "Venue", "VEN", 18);
        ERC4626Engine heldEngine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        EarnVault heldCore =
            EarnVaultTestDeployer.deploy(address(heldEngine), address(heldShare), operator, earnVaultTestNoFees());
        heldEngine.initializeEarnVault(address(heldCore));

        heldAsset.mint(address(this), 3 ether);
        heldAsset.approve(address(heldCore), type(uint256).max);
        heldCore.deposit(3 ether, receiver, 3 ether);

        assertEq(heldShare.balanceOf(receiver), 3 ether);
        assertEq(heldAsset.balanceOf(address(venue)), 3 ether);
        assertEq(heldAsset.allowance(address(heldCore), address(heldEngine)), 0);
        assertEq(heldAsset.balanceOf(address(heldCore)), 0);
        assertEq(heldAsset.balanceOf(address(heldEngine)), 0);
        assertEq(heldCore.engineShares(), venue.balanceOf(address(heldEngine)));

        vm.expectRevert(abi.encodeWithSelector(ERC4626Engine.NotEarnVault.selector, address(this)));
        IEarnEngineHeldDeposit(address(heldEngine)).depositHeld(1);
    }
}

contract CallbackPayer is IEarnWithdrawCallback {
    EarnVault immutable vault;
    CoreMockToken immutable share;
    uint256 public requested;
    uint256 public priceDuring;
    uint256 public assetsDuring;
    uint256 shortfall;
    bool reenter;

    constructor(EarnVault vault_, CoreMockToken share_) {
        vault = vault_;
        share = share_;
    }

    function setShortfall(uint256 value) external {
        shortfall = value;
    }

    function setReenter(bool value) external {
        reenter = value;
    }

    function deposit(uint256 assets) external {
        CoreMockToken(vault.asset()).approve(address(vault), type(uint256).max);
        vault.deposit(assets, address(this), assets);
    }

    function withdraw(uint256 assets, address to, uint256 maxEarnShares) external returns (uint256) {
        return vault.withdrawExactWithCallback(assets, to, maxEarnShares);
    }

    CoreMockEngine internal navEngine;
    uint256 internal navBump;

    function setNavBump(CoreMockEngine engine_, uint256 bump) external {
        navEngine = engine_;
        navBump = bump;
    }

    function earnWithdrawCallback(uint256 earnShares) external override {
        require(msg.sender == address(vault), "not vault");
        requested = earnShares;
        priceDuring = vault.previewRedeem(1 ether);
        assetsDuring = vault.totalAssets();
        if (reenter) {
            // Re-enter once, so a missing lock shows up as a different result rather than running out of gas.
            reenter = false;
            vault.withdrawExactWithCallback(1, address(this), type(uint256).max);
        }
        if (address(navEngine) != address(0)) navEngine.setNavGain(navBump);
        uint256 amount = shortfall == type(uint256).max ? earnShares + 1 : earnShares - shortfall;
        share.transfer(address(vault), amount);
    }
}

/// @notice Credits the recipient one unit less than a {transferFrom} moves.
contract ShortCreditToken is CoreMockToken {
    constructor() CoreMockToken("Short", "SHT", 18) { }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        super.transferFrom(from, to, value);
        balanceOf[to] -= 1;
        return true;
    }
}

/// @notice Sends {transfer}s from one sender to a fixed holder instead of the named recipient.
contract RedirectingShare is CoreMockToken {
    address internal immutable divertTo;
    address internal redirectFrom;

    constructor(address divertTo_) CoreMockToken("Redirecting", "RDR", 18) {
        divertTo = divertTo_;
    }

    function setRedirectFrom(address from) external {
        redirectFrom = from;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        address credited = msg.sender == redirectFrom ? divertTo : to;
        balanceOf[msg.sender] -= value;
        balanceOf[credited] += value;
        return true;
    }
}
