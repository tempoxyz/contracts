// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SpenderBase } from "bridge-spender/src/spenders/SpenderBase.sol";
import { IAccessControl } from "openzeppelin-contracts/access/IAccessControl.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { FeeConfig } from "tempo-earn/interfaces/core/EarnFeeTypes.sol";

import { Spend, SpenderTempoSpend, SpenderTempoSpendStorageLib } from "../../src/SpenderTempoSpend.sol";
import { ITempoEarnVault } from "../../src/interfaces/ITempoEarnVault.sol";
import { FeeOnTransferToken, MockToken, PartialBurnEarnVault } from "../harness/Mocks.sol";
import { TempoEnv } from "../harness/TempoEnv.sol";

/// @notice The "TS" handler: `publicCall "PS"` through the program's Bridge clone.
contract SpenderTempoSpendTest is TempoEnv {
    address internal alice = makeAddr("alice");

    function setUp() public {
        _deployTempo();
        _mintUsd(alice, 1000e6);
        _depositEarn(alice, 500e6);
        vm.startPrank(alice);
        usd.approve(spender, type(uint256).max);
        earnShare.approve(spender, type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Spend
    // ------------------------------------------------------------------

    function test_spendStablecoin() public {
        uint256 before = usd.balanceOf(settlement);
        _spendAs(alice, _stable(40e6));
        assertEq(usd.balanceOf(settlement) - before, 40e6);
        assertEq(usd.balanceOf(alice), 460e6);
    }

    function test_spendFromEarnBurnsOnlyWhatIsNeeded() public {
        uint256 required = earnVault.previewWithdraw(100e6);
        uint256 sharesBefore = earnShare.balanceOf(alice);
        _spendAs(alice, _earn(100e6, 100e6, required * 2));
        assertEq(sharesBefore - earnShare.balanceOf(alice), required);
        assertEq(earnShare.balanceOf(spender), 0, "no residue in the clone");
    }

    function test_spendSplitsStablecoinAndEarn() public {
        uint256 stableBefore = usd.balanceOf(alice);
        _spendAs(alice, _earn(100e6, 60e6, earnVault.previewWithdraw(60e6)));
        assertEq(stableBefore - usd.balanceOf(alice), 40e6);
    }

    function test_spendOnlyToProgramDestinations() public {
        Spend memory s = _stable(1e6);
        s.destination = makeAddr("attacker");
        _expectRevert(
            alice, s, abi.encodeWithSelector(SpenderTempoSpend.DestinationNotAuthorized.selector, s.destination)
        );
    }

    function test_spendBlockedWhenProgramPaused() public {
        vm.prank(bridgePauser);
        bridgeFactory.pause();
        _expectRevert(alice, _stable(1e6), abi.encodeWithSelector(SpenderBase.FactoryPaused.selector));
    }

    function test_spendRequiresAllowlistedVault() public {
        _bridgeGovernorCall(abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(0), address(earnVault)));
        _expectRevert(alice, _earn(10e6, 10e6, 0), abi.encodeWithSelector(SpenderTempoSpend.VaultNotAllowed.selector));
    }

    function test_spendCapsShareCost() public {
        uint256 required = earnVault.previewWithdraw(10e6);
        _expectRevert(
            alice,
            _earn(10e6, 10e6, required - 1),
            abi.encodeWithSelector(SpenderTempoSpend.ShareCostExceeded.selector, required, required - 1)
        );
    }

    /// @notice Earn shares redeem into the vault's own asset, so the spend must settle in it.
    function test_spendFromEarnSettlesInTheVaultAsset() public {
        Spend memory s = _earn(10e6, 10e6, 0);
        s.token = address(_createToken("Deel USD", "DLUSD"));
        _expectRevert(alice, s, abi.encodeWithSelector(SpenderTempoSpend.IncorrectAssetForVault.selector));
    }

    function test_spendRejectsVaultPortionAboveAmount() public {
        _expectRevert(alice, _earn(10e6, 11e6, 0), abi.encodeWithSelector(SpenderBase.InvalidAmount.selector));
    }

    function test_spendRejectsZeroAmount() public {
        _expectRevert(alice, _stable(0), abi.encodeWithSelector(SpenderBase.InvalidAmount.selector));
    }

    /// @notice A token that delivers less than it was asked to cannot settle a spend.
    function test_spendRejectsFeeOnTransferToken() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        token.mint(alice, 100e6);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        Spend memory s = _stable(10e6);
        s.token = address(token);
        _expectRevert(alice, s, abi.encodeWithSelector(SpenderBase.DestinationNotCredited.selector));
        assertEq(token.balanceOf(settlement), 0);
    }

    function test_spendEmitsTempoSpendExecuted() public {
        Spend memory s = _stable(40e6);
        vm.expectEmit(true, true, true, true, spender);
        emit SpenderTempoSpend.TempoSpendExecuted(s.ref, alice, settlement, address(usd), 40e6, 40e6, 0, 0);
        _spendAs(alice, s);
    }

    function test_splitSpendEmitsTempoSpendExecuted() public {
        uint256 shares = earnVault.previewWithdraw(60e6);
        Spend memory s = _earn(100e6, 60e6, shares);
        vm.expectEmit(true, true, true, true, spender);
        emit SpenderTempoSpend.TempoSpendExecuted(s.ref, alice, settlement, address(usd), 100e6, 40e6, 60e6, shares);
        _spendAs(alice, s);
    }

    /// @notice The clone approves the vault for one spend's shares and clears it after.
    function test_spendFromEarnLeavesNoApproval() public {
        _spendAs(alice, _earn(100e6, 100e6, earnVault.previewWithdraw(100e6) * 2));
        assertEq(earnShare.allowance(spender, address(earnVault)), 0, "clone -> vault");
        assertEq(earnShare.balanceOf(spender), 0, "clone holds no shares");
        assertEq(usd.balanceOf(spender), 0, "clone holds no stablecoin");
    }

    /// @notice A vault that burns fewer shares than it quoted leaves the difference with the payer,
    ///         not the clone.
    function test_spendReturnsSharesTheVaultDidNotBurn() public {
        PartialBurnEarnVault vault = new PartialBurnEarnVault(address(usd), 9000);
        _mintUsd(address(vault), 100e6);
        _setVault(address(vault), true);
        MockToken share = vault.SHARE();
        share.mint(alice, 500e6);
        vm.prank(alice);
        share.approve(spender, type(uint256).max);

        uint256 quoted = vault.previewWithdraw(50e6);
        uint256 burned = quoted * 9000 / 10_000;
        uint256 before = usd.balanceOf(settlement);
        Spend memory s = _earn(50e6, 50e6, quoted);
        s.vault = address(vault);
        vm.expectEmit(true, true, true, true, spender);
        emit SpenderTempoSpend.TempoSpendExecuted(s.ref, alice, settlement, address(usd), 50e6, 0, 50e6, burned);
        _spendAs(alice, s);

        assertEq(usd.balanceOf(settlement) - before, 50e6, "destination paid");
        assertEq(500e6 - share.balanceOf(alice), burned, "payer charged only the burn");
        assertEq(share.balanceOf(spender), 0, "clone holds no shares");
        assertEq(share.allowance(spender, address(vault)), 0, "clone -> vault");
    }

    /// @notice With Tempo Earn's fees accruing over time, a spend still pays exactly the amount
    ///         and burns the shares previewed at execution, within `maxShares`.
    function test_spendFromEarnWithFeesAccrued() public {
        address feeRecipient = makeAddr("earn.fee-recipient");
        FeeConfig memory fees;
        fees.fixedFeeCount = 1;
        fees.fixedFees[0].account = feeRecipient;
        fees.fixedFees[0].rateBps = 1000;
        earnVault.setFeeConfig(fees);
        uint256 supplyBefore = earnShare.totalSupply();
        vm.warp(block.timestamp + 90 days);
        _accrueYield(200);

        uint256 required = earnVault.previewWithdraw(100e6);
        uint256 sharesBefore = earnShare.balanceOf(alice);
        uint256 before = usd.balanceOf(settlement);
        _spendAs(alice, _earn(100e6, 100e6, required));

        assertEq(usd.balanceOf(settlement) - before, 100e6, "destination paid");
        assertEq(sharesBefore - earnShare.balanceOf(alice), required, "burned the preview");
        assertGt(earnShare.totalSupply() + required, supplyBefore, "fee shares minted");
        assertEq(earnShare.balanceOf(spender), 0, "clone holds no shares");
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// @notice Any amount, split any way between stablecoin and Earn, pays the destination exactly
    ///         and leaves nothing in the clone.
    function testFuzz_spendSplit(uint256 amount, uint256 fromVault) public {
        amount = bound(amount, 1, 400e6);
        fromVault = bound(fromVault, 0, amount);
        uint256 maxShares = fromVault == 0 ? 0 : earnVault.previewWithdraw(fromVault);
        uint256 stableBefore = usd.balanceOf(alice);
        uint256 sharesBefore = earnShare.balanceOf(alice);
        uint256 before = usd.balanceOf(settlement);

        _spendAs(alice, _earn(amount, fromVault, maxShares));

        assertEq(usd.balanceOf(settlement) - before, amount, "destination paid");
        assertEq(stableBefore - usd.balanceOf(alice), amount - fromVault, "stablecoin part");
        assertLe(sharesBefore - earnShare.balanceOf(alice), maxShares, "share cost");
        _assertCloneEmpty();
    }

    /// @notice After any yield and time, an Earn spend pays exactly the amount and burns no more
    ///         than the shares quoted for it.
    function testFuzz_spendFromEarnAfterYield(uint256 amount, uint256 yieldBps, uint256 elapsed) public {
        yieldBps = bound(yieldBps, 0, 5000);
        elapsed = bound(elapsed, 0, 730 days);
        vm.warp(block.timestamp + elapsed);
        _accrueYield(yieldBps);
        amount = bound(amount, 1, _shareValue(earnShare.balanceOf(alice)));
        uint256 maxShares = earnVault.previewWithdraw(amount);
        uint256 sharesBefore = earnShare.balanceOf(alice);
        uint256 before = usd.balanceOf(settlement);

        _spendAs(alice, _earn(amount, amount, maxShares));

        assertEq(usd.balanceOf(settlement) - before, amount, "destination paid");
        assertLe(sharesBefore - earnShare.balanceOf(alice), maxShares, "share cost");
        _assertCloneEmpty();
    }

    /// @notice With Tempo Earn's fees at any rate, after any yield and time, an Earn spend pays
    ///         exactly the amount and burns exactly the shares quoted for it in the same block.
    function testFuzz_spendFromEarnWithFees(uint256 amount, uint256 feeBps, uint256 yieldBps, uint256 elapsed) public {
        FeeConfig memory fees;
        fees.fixedFeeCount = 1;
        fees.fixedFees[0].account = makeAddr("earn.fee-recipient");
        fees.fixedFees[0].rateBps = uint16(bound(feeBps, 1, 3000));
        earnVault.setFeeConfig(fees);
        vm.warp(block.timestamp + bound(elapsed, 0, 730 days));
        _accrueYield(bound(yieldBps, 0, 5000));
        amount = bound(amount, 1, _shareValue(earnShare.balanceOf(alice)));
        uint256 required = earnVault.previewWithdraw(amount);
        uint256 sharesBefore = earnShare.balanceOf(alice);
        uint256 before = usd.balanceOf(settlement);

        _spendAs(alice, _earn(amount, amount, required));

        assertEq(usd.balanceOf(settlement) - before, amount, "destination paid");
        assertEq(sharesBefore - earnShare.balanceOf(alice), required, "burned the quote");
        _assertCloneEmpty();
    }

    function test_spendBoundToItsProgram() public {
        Spend memory s = _stable(1e6);
        s.spenderId = keccak256("another.program");
        _expectRevert(alice, s, abi.encodeWithSelector(SpenderTempoSpend.WrongProgram.selector, s.spenderId));
    }

    /// @notice A manager can register another ID on the clone, with its own destinations. Only the
    ///         ID the clone was created for can spend.
    function test_spendRejectsAnotherIdOnTheSameClone() public {
        bytes32 aliasId = keccak256("alias");
        address attacker = makeAddr("attacker");
        address[] memory destinations = new address[](1);
        destinations[0] = attacker;
        vm.prank(bridgeManager);
        bridgeFactory.createSpenderWithExistingContract(aliasId, destinations, spender);

        Spend memory s = _stable(1e6);
        s.spenderId = aliasId;
        s.destination = attacker;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SpenderTempoSpend.WrongProgram.selector, aliasId));
        _cloneCall(_psCall(s));
        assertEq(usd.balanceOf(attacker), 0);
    }

    /// @notice The clone pays only from the caller. Nobody can spend another account's approval.
    function test_spendPaidByCallerOnly() public {
        address bob = makeAddr("bob");
        uint256 aliceBefore = usd.balanceOf(alice);
        _expectRevert(bob, _stable(1e6), abi.encodeWithSelector(SafeTransferLib.TransferFromFailed.selector));
        assertEq(usd.balanceOf(alice), aliceBefore);
    }

    // ------------------------------------------------------------------
    // Other entrypoints
    // ------------------------------------------------------------------

    function test_pullPipelineIsDisabled() public {
        bytes memory data = abi.encodePacked(PREFIX_TEMPO_SPEND, alice, address(usd), uint256(1e6));
        vm.prank(bridgeDebitor);
        vm.expectRevert(SpenderTempoSpend.PipelineDisabled.selector);
        bridgeFactory.transferToDestination(SPENDER_ID, settlement, data);
    }

    function test_onlySpendIsPublic() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SpenderBase.PrefixUnknown.selector, bytes2("RF")));
        _cloneCall(abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("RF"), alice));
    }

    function test_availableBalance() public {
        uint256 stable = usd.balanceOf(alice);
        assertEq(
            bridgeFactory.availableBalance(SPENDER_ID, abi.encodePacked(PREFIX_TEMPO_SPEND, alice, address(usd))),
            stable
        );
    }

    function test_availableBalanceIncludesAllowedVault() public {
        uint256 total = bridgeFactory.availableBalance(
            SPENDER_ID, abi.encodePacked(PREFIX_TEMPO_SPEND, alice, address(usd), address(earnVault))
        );
        assertEq(total, usd.balanceOf(alice) + _shareValue(earnShare.balanceOf(alice)));
    }

    /// @notice A vault whose asset is not `token` adds nothing to the stablecoin balance.
    function test_availableBalanceSkipsVaultInAnotherToken() public {
        MockToken other = new MockToken("Deel USD", "DLUSD");
        other.mint(alice, 7e6);
        assertEq(_available(address(other), address(earnVault)), 7e6);
    }

    /// @notice A vault the program has not allowed adds nothing to the stablecoin balance.
    function test_availableBalanceSkipsDisallowedVault() public {
        _setVault(address(earnVault), false);
        assertEq(_available(address(usd), address(earnVault)), usd.balanceOf(alice));
    }

    /// @notice A vault whose engine cannot preview a redemption adds nothing.
    function test_availableBalanceSkipsVaultWhosePreviewReverts() public {
        vm.mockCallRevert(
            address(earnVault), abi.encodeWithSelector(ITempoEarnVault.previewRedeem.selector), "engine paused"
        );
        assertEq(_available(address(usd), address(earnVault)), usd.balanceOf(alice));
    }

    /// @notice A vault that cannot report its asset or share adds nothing instead of reverting.
    function test_availableBalanceSkipsVaultWhoseGettersRevert() public {
        uint256 stable = usd.balanceOf(alice);
        vm.mockCallRevert(address(earnShare), abi.encodeWithSelector(earnShare.balanceOf.selector), "broken");
        assertEq(_available(address(usd), address(earnVault)), stable, "share balance reverts");
        vm.mockCallRevert(address(earnVault), abi.encodeCall(ITempoEarnVault.earnShare, ()), "migrating");
        assertEq(_available(address(usd), address(earnVault)), stable, "share reverts");
        vm.mockCallRevert(address(earnVault), abi.encodeCall(ITempoEarnVault.asset, ()), "paused");
        assertEq(_available(address(usd), address(earnVault)), stable, "asset reverts");
    }

    /// @notice An allowed vault address without code adds nothing instead of reverting.
    function test_availableBalanceSkipsVaultWithoutCode() public {
        address empty = makeAddr("no-code-vault");
        _setVault(empty, true);
        assertEq(_available(address(usd), empty), usd.balanceOf(alice));
    }

    /// @notice A vault that returns nothing, a short reply, or a non-address word adds nothing.
    function test_availableBalanceSkipsVaultWithMalformedReplies() public {
        uint256 stable = usd.balanceOf(alice);
        vm.mockCall(address(earnVault), abi.encodeCall(ITempoEarnVault.asset, ()), "");
        assertEq(_available(address(usd), address(earnVault)), stable, "empty asset reply");
        vm.mockCall(address(earnVault), abi.encodeCall(ITempoEarnVault.asset, ()), hex"0102");
        assertEq(_available(address(usd), address(earnVault)), stable, "short asset reply");
        vm.clearMockedCalls();
        vm.mockCall(address(earnVault), abi.encodeCall(ITempoEarnVault.earnShare, ()), abi.encode(type(uint256).max));
        assertEq(_available(address(usd), address(earnVault)), stable, "share is not an address");
        vm.clearMockedCalls();
        vm.mockCall(address(earnVault), abi.encodeWithSelector(ITempoEarnVault.previewRedeem.selector), "");
        assertEq(_available(address(usd), address(earnVault)), stable, "empty preview reply");
    }

    function test_strictPullPipelineIsDisabled() public {
        bytes memory data = abi.encodePacked(PREFIX_TEMPO_SPEND, alice, address(usd), uint256(1e6));
        vm.prank(bridgeDebitor);
        vm.expectRevert(SpenderTempoSpend.PipelineDisabled.selector);
        bridgeFactory.transferToDestinationStrict(SPENDER_ID, settlement, data);
    }

    function test_availableBalanceRejectsBadLength() public {
        vm.expectRevert(SpenderBase.DataIncorrectLength.selector);
        bridgeFactory.availableBalance(SPENDER_ID, abi.encodePacked(PREFIX_TEMPO_SPEND, alice, bytes19(0)));
    }

    function test_governorCallRequiresGovernance() public {
        bytes memory data = abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(1), alice);
        bytes32 role = bridgeFactory.GOVERNANCE_ROLE();
        address[2] memory callers = [alice, bridgeManager];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], role)
            );
            bridgeFactory.governorCall(SPENDER_ID, data);
        }
        assertFalse(_vaultAllowed(alice));
    }

    /// @notice The manager cannot allow a vault: a vault decides where redeemed value goes, so it
    ///         is as strong as a destination, which only governance adds.
    function test_managerCannotAllowAVault() public {
        vm.prank(bridgeManager);
        vm.expectRevert(bytes("This contract does not support manager calls"));
        bridgeFactory.managerCall(SPENDER_ID, abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(1), alice));
        assertFalse(_vaultAllowed(alice));
    }

    function test_governorCallRejectsUnknownAction() public {
        vm.prank(bridgeGovernor);
        vm.expectRevert(abi.encodeWithSelector(SpenderBase.PrefixUnknown.selector, bytes2("XV")));
        bridgeFactory.governorCall(
            SPENDER_ID, abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("XV"), uint8(1), address(earnVault))
        );
    }

    function test_governorCallRejectsBadLength() public {
        vm.prank(bridgeGovernor);
        vm.expectRevert(SpenderBase.DataIncorrectLength.selector);
        bridgeFactory.governorCall(SPENDER_ID, abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(1)));
    }

    function test_governorCallRejectsNonBooleanFlag() public {
        vm.prank(bridgeGovernor);
        vm.expectRevert(SpenderTempoSpend.ExpectedBooleanByte.selector);
        bridgeFactory.governorCall(
            SPENDER_ID, abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(2), address(earnVault))
        );
        assertTrue(_vaultAllowed(address(earnVault)), "allowlist unchanged");
    }

    /// @notice "UV" emits the vault and its new status from the clone, both ways.
    function test_governorCallEmitsSpendVaultUpdated() public {
        address vault = makeAddr("vault");
        vm.expectEmit(true, true, true, true, spender);
        emit SpenderTempoSpend.SpendVaultUpdated(vault, true);
        _setVault(vault, true);
        assertTrue(_vaultAllowed(vault));

        vm.expectEmit(true, true, true, true, spender);
        emit SpenderTempoSpend.SpendVaultUpdated(vault, false);
        _setVault(vault, false);
        assertFalse(_vaultAllowed(vault));
    }

    function test_publicGetCallRejectsUnknownQuery() public {
        vm.expectRevert(abi.encodeWithSelector(SpenderBase.PrefixUnknown.selector, bytes2("GX")));
        _cloneGet(abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("GX"), address(earnVault)));
    }

    function test_publicGetCallRejectsBadLength() public {
        vm.expectRevert(SpenderBase.DataIncorrectLength.selector);
        _cloneGet(abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("GV"), bytes19(0)));
    }

    function test_storageSlotIsErc7201() public pure {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("tempo.spend.SpenderTempoSpend")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(SpenderTempoSpendStorageLib.SLOT, expected);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _stable(uint256 amount) internal view returns (Spend memory) {
        return Spend({
            spenderId: SPENDER_ID,
            token: address(usd),
            amount: amount,
            destination: settlement,
            vault: address(0),
            fromVault: 0,
            maxShares: 0,
            ref: keccak256(abi.encode("card.auth", amount))
        });
    }

    function _earn(uint256 amount, uint256 fromVault, uint256 maxShares) internal view returns (Spend memory s) {
        s = _stable(amount);
        s.vault = address(earnVault);
        s.fromVault = fromVault;
        s.maxShares = maxShares;
    }

    function _setVault(address vault, bool allowed) internal {
        _bridgeGovernorCall(abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), allowed ? uint8(1) : uint8(0), vault));
    }

    function _vaultAllowed(address vault) internal returns (bool) {
        return abi.decode(_cloneGet(abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("GV"), vault)), (bool));
    }

    function _available(address token, address vault) internal returns (uint256) {
        return bridgeFactory.availableBalance(SPENDER_ID, abi.encodePacked(PREFIX_TEMPO_SPEND, alice, token, vault));
    }

    function _assertCloneEmpty() internal view {
        assertEq(usd.balanceOf(spender), 0, "clone holds no stablecoin");
        assertEq(earnShare.balanceOf(spender), 0, "clone holds no shares");
        assertEq(earnShare.allowance(spender, address(earnVault)), 0, "clone -> vault");
    }

    function _spendAs(address payer, Spend memory s) internal {
        vm.prank(payer);
        _cloneCall(_psCall(s));
    }

    function _expectRevert(address payer, Spend memory s, bytes memory err) internal {
        vm.prank(payer);
        vm.expectRevert(err);
        _cloneCall(_psCall(s));
    }
}
