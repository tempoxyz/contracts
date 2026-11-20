// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { ManagedPropAMMEngine } from "../../../../src/earn/engines/propamm/ManagedPropAMMEngine.sol";
import { IManagedPropAMMVenue } from "../../../../src/interfaces/external/propamm/IManagedPropAMMVenue.sol";
import { EarnVault } from "../../../../src/earn/core/EarnVault.sol";
import { FeeConfig, ExcessReturnFee } from "../../../../src/interfaces/earn/EarnFeeTypes.sol";
import { EarnVaultTestDeployer } from "../../helpers/EarnVaultTestDeployer.sol";
import { CoreMockToken } from "../../helpers/EarnVaultMocks.sol";
import { MemoMockToken, PropAMMTestOracle } from "../../helpers/PropAMMEngineMocks.sol";

interface IManagedPropAMMPoolAdmin is IManagedPropAMMVenue {
    function addPair(address base, address quote, address oracle, uint256 maxOracleAge, uint256 maxPriceDeviationBps)
        external
        returns (uint16 pairIndex);
    function removePair(uint16 pairIndex) external;
    function setPairAccess(uint16 pairIndex, AccessMode mode) external;
    function closePair(uint16 pairIndex) external;
    function setPairHook(uint16 pairIndex, address hook, uint8 flags) external;
    function setMaxOracleAge(uint16 pairIndex, uint256 age) external;
    function addSponsor(uint64 sponsorId, address admin) external;
    function setSponsorEnabled(uint64 sponsorId, bool enabled) external;
    function setPairSponsor(uint16 pairIndex, uint64 sponsorId, bool admitted) external;
    function setMembers(uint16 pairIndex, uint64 sponsorId, address[] calldata accounts, bool allowed) external;
    function setDenied(address[] calldata accounts, bool deny) external;
    function roundingCredit(bytes32 routeKey) external view returns (uint256);
    function roundingRouteKey(uint16 pairIndex, address taker, bytes32 customerId) external pure returns (bytes32);
    function pause() external;
    function unpause() external;
    function withdraw(address token, address recipient, uint256 amount, bytes32 memo) external;
}

/// @dev A pair hook that charges a fixed input-token fee on every quote and swap.
contract ManagedPropAMMTestFeeHook {
    struct QuoteContext {
        uint16 pairIndex;
        address taker;
        bool baseToQuote;
        bool exactInput;
        uint256 amount;
    }

    function supportedFlags() external pure returns (uint8) {
        return 1;
    }

    function quote(QuoteContext calldata) external pure returns (uint16 feeBps) {
        return 100;
    }
}

/// @dev Exercises the engine against the unmodified pinned ManagedDirectPropAMM artifact.
contract ManagedPropAMMIntegrationTest is Test {
    uint64 constant SPONSOR = 7;
    bytes32 constant ROUTE = bytes32(uint256(1));

    MemoMockToken asset;
    MemoMockToken baseToken;
    MemoMockToken otherBase;
    CoreMockToken share;
    PropAMMTestOracle oracle;
    IManagedPropAMMPoolAdmin pool;
    ManagedPropAMMEngine engine;
    EarnVault vault;
    uint16 decoyPair;
    uint16 pairIndex;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address customer = makeAddr("customer");

    function setUp() public {
        _setUp(6, 6, 8);
    }

    function _setUp(uint8 baseDecimals, uint8 quoteDecimals, uint8 oracleDecimals) internal {
        vm.warp(1_800_000_000);
        asset = new MemoMockToken("Quote", "Quote", quoteDecimals);
        baseToken = new MemoMockToken("Base", "Base", baseDecimals);
        otherBase = new MemoMockToken("Other", "Other", baseDecimals);
        share = new CoreMockToken("Earn Base", "eBASE", 6);
        oracle = new PropAMMTestOracle();
        vm.mockCall(address(oracle), abi.encodeWithSignature("decimals()"), abi.encode(oracleDecimals));
        oracle.set(105 * 10 ** uint256(oracleDecimals) / 100, vm.getBlockTimestamp());
        // PropAMM pins solc 0.8.30; deploy its unmodified artifact alongside Earn's 0.8.36 code. With no
        // factory the pool is its own owner-initialized instance, and it starts paused.
        pool = IManagedPropAMMPoolAdmin(
            deployCode("test/earn/fixtures/propamm/ManagedDirectPropAMM.json", abi.encode(address(this), address(0)))
        );
        // The engine's pair is not the pool's first, and the pool's other pair shares its quote inventory.
        PropAMMTestOracle decoyOracle = new PropAMMTestOracle();
        vm.mockCall(address(decoyOracle), abi.encodeWithSignature("decimals()"), abi.encode(oracleDecimals));
        decoyPair = pool.addPair(address(otherBase), address(asset), address(decoyOracle), 1 days, 50);
        pairIndex = pool.addPair(address(baseToken), address(asset), address(oracle), 1 days, 50);
        engine = _newEngine(0);
        FeeConfig memory noFees;
        vault = EarnVaultTestDeployer.deploy(address(engine), address(share), address(this), noFees);
        engine.initializeEarnVault(address(vault));
        baseToken.mint(address(pool), 10_000 * 10 ** uint256(baseDecimals));
        asset.mint(address(pool), 10_000 * 10 ** uint256(quoteDecimals));
        pool.setPairAccess(pairIndex, IManagedPropAMMVenue.AccessMode.Listed);
        pool.unpause();
        _fund(alice);
        _fund(bob);
    }

    function testDecimalConfigurations() public {
        uint8[3] memory baseDecimals = [18, 6, 6];
        uint8[3] memory quoteDecimals = [6, 18, 6];
        uint8[3] memory oracleDecimals = [8, 18, 12];
        for (uint256 i; i < baseDecimals.length; ++i) {
            _setUp(baseDecimals[i], quoteDecimals[i], oracleDecimals[i]);
            uint256 baseUnit = 10 ** uint256(baseDecimals[i]);
            uint256 quoteUnit = 10 ** uint256(quoteDecimals[i]);
            uint256 principal = 100 * quoteUnit + 1;
            uint256 startingCash = asset.balanceOf(alice);
            _deposit(alice, principal);
            uint256 backing = baseToken.balanceOf(address(engine));
            assertEq(engine.shareScale(), baseUnit);
            assertEq(engine.priceScale(), pool.pair(pairIndex).priceScale);
            assertEq(backing, principal * baseUnit * 20 / (21 * quoteUnit));
            assertEq(engine.totalShares(), backing);
            assertEq(engine.totalAssets(), backing * 21 * quoteUnit / (20 * baseUnit));
            assertEq(engine.valueOf(baseUnit), 21 * quoteUnit / 20);

            uint256 withdrawal = 7 * quoteUnit + 1;
            uint256 maximumShares = share.balanceOf(alice);
            vm.prank(alice);
            vault.withdrawExact(withdrawal, alice, maximumShares);
            assertEq(asset.balanceOf(alice), startingCash - principal + withdrawal);
            assertLt(baseToken.balanceOf(address(engine)), backing);
            _redeem(alice, share.balanceOf(alice), 1);
            assertEq(engine.totalShares(), vault.surplusEngineShares());
            // EarnShare has six decimals; finer venue units can remain as quarantined rounding surplus.
            assertLt(engine.totalShares(), 2 * baseUnit / 1e6);
            assertEq(share.balanceOf(alice), 0);
            uint256 endingCash = asset.balanceOf(alice);
            assertLe(endingCash, startingCash);
            assertLe(startingCash - endingCash, 3 * quoteUnit / 1e6);
        }
    }

    function _newEngine(uint64 sponsorId) internal returns (ManagedPropAMMEngine result) {
        result = new ManagedPropAMMEngine(
            address(pool), pairIndex, sponsorId, address(asset), address(baseToken), address(this), 1 days, ROUTE
        );
        if (sponsorId == 0) _list(0, address(result), true);
    }

    function _list(uint64 sponsorId, address account, bool allowed) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        pool.setMembers(pairIndex, sponsorId, accounts, allowed);
    }

    function _deny(address account, bool deny) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        pool.setDenied(accounts, deny);
    }

    /// @dev A pair's oracle window changes only while the pair is Closed.
    function _setPoolOracleAge(uint256 age) internal {
        pool.closePair(pairIndex);
        pool.setMaxOracleAge(pairIndex, age);
        pool.setPairAccess(pairIndex, IManagedPropAMMVenue.AccessMode.Listed);
    }

    function _fund(address account) internal {
        asset.mint(account, 1_000 * 10 ** uint256(asset.decimals()));
        vm.startPrank(account);
        asset.approve(address(vault), type(uint256).max);
        share.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(address account, uint256 assets) internal returns (uint256) {
        vm.prank(account);
        return vault.deposit(assets, account, 1);
    }

    function _redeem(address account, uint256 shares, uint256 minAssets) internal returns (uint256) {
        vm.prank(account);
        return vault.redeem(shares, account, minAssets);
    }

    /// @dev With alice holding 100e6 shares: a deposit, a redemption and an exact withdrawal each revert with
    /// `reason` and leave every balance, share and allowance as it was.
    function _assertEveryFlowReverts(bytes4 reason) internal {
        uint256 bobCash = asset.balanceOf(bob);
        uint256 aliceCash = asset.balanceOf(alice);
        vm.expectRevert(reason);
        _deposit(bob, 105e6);
        vm.expectRevert(reason);
        _redeem(alice, 100e6, 1);
        vm.prank(alice);
        vm.expectRevert(reason);
        vault.withdrawExact(21e6, alice, 100e6);
        assertEq(asset.balanceOf(bob), bobCash);
        assertEq(asset.balanceOf(alice), aliceCash);
        assertEq(share.balanceOf(bob), 0);
        assertEq(share.balanceOf(alice), 100e6);
        assertEq(engine.totalShares(), 100e6);
        assertEq(baseToken.balanceOf(address(engine)), 100e6);
        assertEq(asset.allowance(address(engine), address(pool)), 1);
        assertEq(baseToken.allowance(address(engine), address(pool)), 1);
    }

    function testConstructorReadsTheLivePair() public view {
        IManagedPropAMMVenue.Pair memory traded = pool.pair(pairIndex);
        assertEq(traded.base, address(baseToken));
        assertEq(traded.quote, address(asset));
        assertEq(address(engine.priceOracle()), traded.oracle);
        assertEq(engine.oracleDecimals(), traded.oracleDecimals);
        assertEq(engine.priceScale(), traded.priceScale);
        assertEq(engine.pairIndex(), 1);
        assertEq(engine.sponsorId(), 0);
        assertTrue(pool.takerAllowed(pairIndex, address(engine), 0));
    }

    function testConstructorRejectsUnknownRemovedAndMismatchedPairs() public {
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        new ManagedPropAMMEngine(address(pool), 2, 0, address(asset), address(baseToken), address(this), 1 days, ROUTE);
        // Another live pair of the pool: same quote, another base.
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        new ManagedPropAMMEngine(
            address(pool), decoyPair, 0, address(asset), address(baseToken), address(this), 1 days, ROUTE
        );
        // The pair's tokens the wrong way round.
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        new ManagedPropAMMEngine(
            address(pool), pairIndex, 0, address(baseToken), address(asset), address(this), 1 days, ROUTE
        );
        pool.removePair(pairIndex);
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        new ManagedPropAMMEngine(
            address(pool), pairIndex, 0, address(asset), address(baseToken), address(this), 1 days, ROUTE
        );
    }

    function testConstructorRejectsAPairWithAHook() public {
        pool.closePair(pairIndex);
        pool.setPairHook(pairIndex, address(new ManagedPropAMMTestFeeHook()), 1);
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        new ManagedPropAMMEngine(
            address(pool), pairIndex, 0, address(asset), address(baseToken), address(this), 1 days, ROUTE
        );
    }

    function testLongerPoolFreshnessWindowCannotChargeNewPrincipalForOldYield() public {
        FeeConfig memory config;
        config.excess = ExcessReturnFee(true, customer, 0, 2_000);
        vault.setFeeConfig(config);
        _deposit(alice, 105e6);
        oracle.set(105_100_000, vm.getBlockTimestamp());
        _setPoolOracleAge(2 days);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        assertFalse(vault.isFeeValuationFresh());
        vm.expectRevert(ManagedPropAMMEngine.InvalidOracle.selector);
        _deposit(bob, 105_100_000);
        vm.prank(bob);
        vm.expectRevert(ManagedPropAMMEngine.InvalidOracle.selector);
        vault.contribute(105_100_000);
        assertEq(asset.balanceOf(bob), 1_000e6);
        assertEq(share.balanceOf(bob), 0);
        assertEq(engine.totalShares(), 100e6);
        assertEq(asset.allowance(address(engine), address(pool)), 1);
        oracle.set(105_100_000, vm.getBlockTimestamp());
        (uint256 feeAssets,) = vault.accrueFees();
        assertEq(feeAssets, 20_000);
        _deposit(bob, 105_100_000);
        (feeAssets,) = vault.accrueFees();
        assertEq(feeAssets, 0);
        assertApproxEqAbs(vault.previewRedeem(share.balanceOf(bob)), 105_100_000, 2);
    }

    function testFreshnessBoundaryAndStaleExitsWithLongerPoolWindow() public {
        _setPoolOracleAge(2 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertTrue(vault.isFeeValuationFresh());
        assertEq(_deposit(alice, 105e6), 100e6);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertFalse(vault.isFeeValuationFresh());
        vm.expectRevert(ManagedPropAMMEngine.InvalidOracle.selector);
        _deposit(bob, 105e6);
        vm.prank(alice);
        assertEq(vault.withdrawExact(52_500_000, alice, 50e6), 50e6);
        assertEq(_redeem(alice, 50e6, 52_500_000), 52_500_000);
    }

    function testCreditCannotFundAWithdrawalWithoutBurningBase() public {
        _deposit(alice, 1e6);
        uint256 shares = share.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(ManagedPropAMMEngine.InvalidAmount.selector);
        vault.withdrawExact(1, alice, shares);
        assertEq(share.balanceOf(alice), shares);
        assertEq(engine.totalShares(), 952380);
    }

    function testStalePriceIsDiscoveredByEarnVault() public {
        _deposit(alice, 105e6);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        assertFalse(vault.isFeeValuationFresh());
        FeeConfig memory config;
        vm.expectRevert(EarnVault.FeeValuationStale.selector);
        vault.setFeeConfig(config);
        uint256 aliceShares = share.balanceOf(alice);
        vm.expectRevert();
        _redeem(alice, aliceShares, 1);
        assertEq(share.balanceOf(alice), 100e6);
        oracle.set(105_000_000, vm.getBlockTimestamp());
        assertTrue(vault.isFeeValuationFresh());
        assertEq(_redeem(alice, share.balanceOf(alice), 105e6), 105e6);
    }

    function testBaseDonationIsQuarantinedAndCashIsExcluded() public {
        _deposit(alice, 105e6);
        baseToken.mint(address(engine), 1e6);
        asset.mint(address(engine), 1e6);
        assertEq(vault.surplusEngineShares(), 1e6);
        assertEq(vault.totalAssets(), 105e6);
        vault.absorbEngineShareSurplus(1e6);
        assertEq(vault.totalAssets(), 106_050_000);
        assertEq(_redeem(alice, share.balanceOf(alice), 106_050_000), 106_050_000);
        assertEq(asset.balanceOf(address(engine)), 1e6);
    }

    function testMigrationPreservesSharesAndDrainsOldEngine() public {
        _deposit(alice, 105e6);
        ManagedPropAMMEngine replacement = _newEngine(0);
        replacement.initializeEarnVault(address(vault));
        assertEq(vault.migrateEngine(address(replacement), 100e6, 105e6), 100e6);
        assertEq(vault.engine(), address(replacement));
        assertEq(share.balanceOf(alice), 100e6);
        assertEq(engine.totalShares(), 0);
        assertEq(baseToken.balanceOf(address(engine)), 0);
        assertEq(asset.balanceOf(address(engine)), 0);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(pairIndex, address(engine), ROUTE)), 0);
        assertEq(
            pool.roundingRouteKey(pairIndex, address(engine), ROUTE), keccak256(abi.encode(pairIndex, engine, ROUTE))
        );
        assertEq(_redeem(alice, share.balanceOf(alice), 105e6), 105e6);
    }

    function testIlliquidPoolRollsBackBurnAndMigration() public {
        _deposit(alice, 105e6);
        pool.pause();
        pool.withdraw(address(asset), address(this), asset.balanceOf(address(pool)), bytes32(0));
        pool.unpause();
        vm.expectRevert();
        _redeem(alice, 100e6, 105e6);
        ManagedPropAMMEngine replacement = _newEngine(0);
        replacement.initializeEarnVault(address(vault));
        vm.expectRevert();
        vault.migrateEngine(address(replacement), 100e6, 105e6);
        assertEq(vault.engine(), address(engine));
        assertEq(share.balanceOf(alice), 100e6);
        assertEq(engine.totalShares(), 100e6);
        assertEq(baseToken.balanceOf(address(engine)), 100e6);
    }

    function testRevokedPermissionRollsBackDeposit() public {
        _list(0, address(engine), false);
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        _deposit(alice, 105e6);
        assertEq(asset.balanceOf(alice), 1_000e6);
        assertEq(share.balanceOf(alice), 0);
    }

    function testPoolPauseRollsBackRedemption() public {
        _deposit(alice, 105e6);
        pool.pause();
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        _redeem(alice, 100e6, 105e6);
        assertEq(share.balanceOf(alice), 100e6);
        assertEq(engine.totalShares(), 100e6);
    }

    function testClosedPairRevertsEveryFlow() public {
        _deposit(alice, 105e6);
        pool.closePair(pairIndex);
        _assertEveryFlowReverts(ManagedPropAMMEngine.InvalidConfiguration.selector);
        (bool paused, bool admitted,,,) = engine.liquidityStatus();
        assertFalse(paused);
        assertFalse(admitted);
        assertEq(vault.totalAssets(), 105e6);

        pool.setPairAccess(pairIndex, IManagedPropAMMVenue.AccessMode.Listed);
        assertEq(_redeem(alice, 100e6, 105e6), 105e6);
    }

    function testUnlistedTakerRevertsEveryFlow() public {
        _deposit(alice, 105e6);
        _list(0, address(engine), false);
        _assertEveryFlowReverts(ManagedPropAMMEngine.InvalidConfiguration.selector);
        (, bool admitted,,,) = engine.liquidityStatus();
        assertFalse(admitted);

        // A listing under a sponsor the engine does not name does not admit it.
        pool.addSponsor(SPONSOR, address(this));
        pool.setPairSponsor(pairIndex, SPONSOR, true);
        _list(SPONSOR, address(engine), true);
        _assertEveryFlowReverts(ManagedPropAMMEngine.InvalidConfiguration.selector);

        _list(0, address(engine), true);
        assertEq(_redeem(alice, 100e6, 105e6), 105e6);
    }

    function testPausedPoolRevertsEveryFlow() public {
        _deposit(alice, 105e6);
        pool.pause();
        _assertEveryFlowReverts(ManagedPropAMMEngine.InvalidConfiguration.selector);
        (bool paused, bool admitted,,,) = engine.liquidityStatus();
        assertTrue(paused);
        assertTrue(admitted);

        pool.unpause();
        assertEq(_redeem(alice, 100e6, 105e6), 105e6);
    }

    function testDeniedTakerRevertsEveryFlow() public {
        _deposit(alice, 105e6);
        _deny(address(engine), true);
        _assertEveryFlowReverts(ManagedPropAMMEngine.InvalidConfiguration.selector);

        _deny(address(engine), false);
        assertEq(_redeem(alice, 100e6, 105e6), 105e6);
    }

    function testThePoolRefusesWhatTheEngineChecksFirst() public {
        // The engine's checks mirror the pool's own refusals: its swap sent straight to the pool reverts too.
        _deposit(alice, 105e6);
        pool.closePair(pairIndex);
        _expectPoolRefusal(abi.encodeWithSignature("TakerNotAllowed(address)", address(engine)));
        pool.setPairAccess(pairIndex, IManagedPropAMMVenue.AccessMode.Listed);

        _list(0, address(engine), false);
        _expectPoolRefusal(abi.encodeWithSignature("TakerNotAllowed(address)", address(engine)));
        _list(0, address(engine), true);

        _deny(address(engine), true);
        _expectPoolRefusal(abi.encodeWithSignature("TakerDenied(address)", address(engine)));
        _deny(address(engine), false);

        pool.pause();
        _expectPoolRefusal(abi.encodeWithSignature("Paused()"));
        pool.unpause();

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSignature("UnknownSponsor(uint64)", SPONSOR));
        pool.swapExactInput(
            pairIndex, true, 100e6, 1, SPONSOR, ROUTE, bytes32(uint256(99)), block.timestamp, 105_000_000, 0, 0
        );
    }

    function _expectPoolRefusal(bytes memory reason) internal {
        vm.prank(address(engine));
        vm.expectRevert(reason);
        pool.swapExactInput(
            pairIndex, true, 100e6, 1, 0, ROUTE, bytes32(uint256(99)), block.timestamp, 105_000_000, 0, 0
        );
    }

    function testTradesUnderASponsorList() public {
        pool.addSponsor(SPONSOR, address(this));
        pool.setPairSponsor(pairIndex, SPONSOR, true);
        ManagedPropAMMEngine sponsored = _newEngine(SPONSOR);
        assertFalse(pool.takerAllowed(pairIndex, address(sponsored), SPONSOR));
        _list(SPONSOR, address(sponsored), true);
        // The home list does not hold the sponsored engine: only its sponsor's list admits it.
        assertFalse(pool.takerAllowed(pairIndex, address(sponsored), 0));
        sponsored.initializeEarnVault(address(vault));
        assertEq(vault.migrateEngine(address(sponsored), 0, 0), 0);
        engine = sponsored;

        assertEq(_deposit(alice, 105e6), 100e6);
        assertEq(baseToken.balanceOf(address(sponsored)), 100e6);

        pool.setSponsorEnabled(SPONSOR, false);
        _assertEveryFlowReverts(ManagedPropAMMEngine.InvalidConfiguration.selector);
        pool.setSponsorEnabled(SPONSOR, true);

        pool.setPairSponsor(pairIndex, SPONSOR, false);
        _assertEveryFlowReverts(ManagedPropAMMEngine.InvalidConfiguration.selector);
        pool.setPairSponsor(pairIndex, SPONSOR, true);

        vm.prank(alice);
        assertEq(vault.withdrawExact(21e6, alice, 20e6), 20e6);
        assertEq(_redeem(alice, 80e6, 84e6), 84e6);
        assertEq(asset.balanceOf(alice), 1_000e6);
    }

    function testHookInstalledAfterDeploymentBlocksDepositsNotExits() public {
        _deposit(alice, 105e6);
        pool.closePair(pairIndex);
        pool.setPairHook(pairIndex, address(new ManagedPropAMMTestFeeHook()), 1);
        pool.setPairAccess(pairIndex, IManagedPropAMMVenue.AccessMode.Listed);
        // The pool fills at a fee the oracle valuation does not reflect, so the engine takes no new deposit.
        assertTrue(pool.takerAllowed(pairIndex, address(engine), 0));
        (uint256 feeInclusive,,,) = pool.quoteExactInputFor(pairIndex, address(engine), ROUTE, true, 100e6);
        assertLt(feeInclusive, engine.valueOf(100e6));
        uint256 bobCash = asset.balanceOf(bob);
        vm.expectRevert(ManagedPropAMMEngine.InvalidConfiguration.selector);
        _deposit(bob, 105e6);
        assertEq(asset.balanceOf(bob), bobCash);
        assertEq(share.balanceOf(bob), 0);
        (, bool admitted,,,) = engine.liquidityStatus();
        assertFalse(admitted);
        // The oracle valuation leaves the hook's fee out, so no fee accrues on it while the hook stays.
        assertFalse(vault.isFeeValuationFresh());

        // Holders are not trapped. A redemption that demands the oracle value still reverts: the caller's
        // minimum bounds the fee, and nothing moves.
        uint256 aliceCash = asset.balanceOf(alice);
        vm.expectRevert();
        _redeem(alice, 100e6, 105e6);
        assertEq(engine.totalShares(), 100e6);
        assertEq(share.balanceOf(alice), 100e6);

        // An exact withdrawal burns the pool's fee-inclusive quote, more than the 20e6 a pair without a hook
        // takes for the same assets.
        (uint256 quotedShares,,,) = pool.quoteExactOutputFor(pairIndex, address(engine), ROUTE, true, 21e6);
        assertGt(quotedShares, 20e6);
        vm.prank(alice);
        assertEq(vault.withdrawExact(21e6, alice, 21e6), quotedShares);
        assertEq(asset.balanceOf(alice), aliceCash + 21e6);
        assertEq(engine.totalShares(), 100e6 - quotedShares);

        // A redemption pays the pool's fee-inclusive quote, below the oracle valuation.
        uint256 remaining = 100e6 - quotedShares;
        (uint256 quotedAssets,,,) = pool.quoteExactInputFor(pairIndex, address(engine), ROUTE, true, remaining);
        assertLt(quotedAssets, engine.valueOf(remaining));
        assertEq(_redeem(alice, remaining, quotedAssets), quotedAssets);
        assertEq(asset.balanceOf(alice), aliceCash + 21e6 + quotedAssets);
        assertEq(engine.totalShares(), 0);
        assertEq(share.balanceOf(alice), 0);
        assertEq(asset.balanceOf(address(engine)), 0);
        assertEq(asset.allowance(address(engine), address(pool)), 1);
        assertEq(baseToken.allowance(address(engine), address(pool)), 1);
    }

    /// @dev The vault refuses an exact withdrawal that burns all backing for less than its valuation, and a
    /// hook's fee makes the last one do that. The last holder leaves by redemption instead.
    function testLastExactWithdrawalThroughAHookedPairRevertsAndRedemptionExits() public {
        _deposit(alice, 105e6);
        pool.closePair(pairIndex);
        pool.setPairHook(pairIndex, address(new ManagedPropAMMTestFeeHook()), 1);
        pool.setPairAccess(pairIndex, IManagedPropAMMVenue.AccessMode.Listed);
        (uint256 proceeds,,,) = pool.quoteExactInputFor(pairIndex, address(engine), ROUTE, true, 100e6);
        assertLt(proceeds, engine.totalAssets());
        (uint256 sold,,,) = pool.quoteExactOutputFor(pairIndex, address(engine), ROUTE, true, proceeds);
        assertEq(sold, 100e6);

        uint256 aliceCash = asset.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(EarnVault.ResidualBacking.selector);
        vault.withdrawExact(proceeds, alice, 100e6);
        assertEq(engine.totalShares(), 100e6);
        assertEq(share.balanceOf(alice), 100e6);
        assertEq(asset.balanceOf(alice), aliceCash);

        assertEq(_redeem(alice, 100e6, proceeds), proceeds);
        assertEq(asset.balanceOf(alice), aliceCash + proceeds);
        assertEq(engine.totalShares(), 0);
        assertEq(share.balanceOf(alice), 0);
    }

    function testRemovedPairFailsClosed() public {
        _deposit(alice, 105e6);
        pool.removePair(pairIndex);
        vm.expectRevert(ManagedPropAMMEngine.InvalidOracle.selector);
        engine.totalAssets();
        assertFalse(vault.isFeeValuationFresh());
        vm.expectRevert(ManagedPropAMMEngine.InvalidOracle.selector);
        _deposit(bob, 105e6);
        vm.expectRevert();
        _redeem(alice, 100e6, 1);
        assertEq(share.balanceOf(alice), 100e6);
        assertEq(engine.totalShares(), 100e6);
        assertEq(asset.balanceOf(bob), 1_000e6);
        // The pool never reuses an index, so a later pair cannot take the engine's place.
        uint16 next = pool.addPair(address(baseToken), address(asset), address(oracle), 1 days, 50);
        assertEq(next, 2);
        vm.expectRevert(ManagedPropAMMEngine.InvalidOracle.selector);
        engine.totalAssets();
    }

    function testAnotherPairsTradesDoNotMoveTheEnginesRoute() public {
        _deposit(alice, 1e6 + 1);
        uint256 credit = pool.roundingCredit(pool.roundingRouteKey(pairIndex, address(engine), ROUTE));
        uint256 held = engine.totalShares();
        // A taker on the pool's other pair spends the quote inventory both pairs share.
        otherBase.mint(address(pool), 1_000e6);
        pool.pause();
        pool.setPairAccess(decoyPair, IManagedPropAMMVenue.AccessMode.Open);
        pool.unpause();
        vm.startPrank(bob);
        asset.approve(address(pool), 105e6);
        pool.swapExactInput(
            decoyPair, false, 105e6, 1, 0, ROUTE, bytes32(uint256(1)), block.timestamp, 105_000_000, 0, 0
        );
        vm.stopPrank();
        assertEq(otherBase.balanceOf(bob), 100e6);
        assertEq(pool.roundingCredit(pool.roundingRouteKey(pairIndex, address(engine), ROUTE)), credit);
        assertEq(engine.totalShares(), held);
        (,,, uint256 venueCash,) = engine.liquidityStatus();
        assertEq(venueCash, asset.balanceOf(address(pool)));
        assertEq(_redeem(alice, share.balanceOf(alice), 1), 1e6 + 1);
    }

    function testBlockedPoolRecipientRollsBackDeposit() public {
        baseToken.blockReceiver(address(engine));
        vm.expectRevert(bytes("BLOCKED"));
        _deposit(alice, 105e6);
        assertEq(asset.balanceOf(alice), 1_000e6);
        assertEq(vault.totalEarnShares(), 0);
        assertEq(engine.totalShares(), 0);
    }

    function testPriceAnchorRejectsDiscontinuousExecution() public {
        _deposit(alice, 105e6);
        oracle.set(110_000_000, vm.getBlockTimestamp());
        assertEq(vault.totalAssets(), 110e6);
        vm.expectRevert();
        _redeem(alice, 100e6, 110e6);
        assertEq(share.balanceOf(alice), 100e6);
        assertEq(baseToken.balanceOf(address(engine)), 100e6);
    }

    function testFuzzUnchangedPriceConservesCash(uint64 first, uint64 second, uint32 fraction) public {
        uint256 aliceAssets = bound(first, 100, 500e6);
        uint256 bobAssets = bound(second, 100, 500e6);
        uint256 aliceShares = _deposit(alice, aliceAssets);
        uint256 partialShares = bound(fraction, 1, aliceShares - 1);
        uint256 alicePayout = _redeem(alice, partialShares, 1);
        uint256 bobShares = _deposit(bob, bobAssets);
        uint256 bobPayout = _redeem(bob, bobShares, 1);
        alicePayout += _redeem(alice, share.balanceOf(alice), 1);
        assertEq(alicePayout + bobPayout, aliceAssets + bobAssets);
        assertEq(vault.totalEarnShares(), 0);
        assertEq(engine.totalShares(), 0);
        assertEq(engine.totalAssets(), 0);
        assertEq(asset.allowance(address(engine), address(pool)), 1);
        assertEq(baseToken.allowance(address(engine), address(pool)), 1);
    }

    function testNewDepositAfterLossTracksBaseWithoutDilution() public {
        uint256 first = _deposit(alice, 105e6);
        oracle.set(104_900_000, vm.getBlockTimestamp());
        uint256 second = _deposit(bob, 104_900_000);
        assertEq(first, second);
        assertEq(_redeem(alice, first, 104_900_000), 104_900_000);
        assertEq(_redeem(bob, second, 104_900_000), 104_900_000);
    }

    function testExactWithdrawalChargesConsumedBase() public {
        _deposit(alice, 105e6);
        uint256 beforeShares = engine.totalShares();
        uint256 expected = engine.previewWithdraw(21e6);
        vm.prank(alice);
        uint256 burned = vault.withdrawExact(21e6, alice, expected);
        assertEq(burned, 20e6);
        assertEq(beforeShares - engine.totalShares(), burned);
        assertEq(baseToken.allowance(address(engine), address(pool)), 1);
        assertEq(_redeem(alice, share.balanceOf(alice), 84e6), 84e6);
    }

    function testRepeatedTinyRoundTripsCannotDrainPool() public {
        uint256 cashBefore = asset.balanceOf(address(pool));
        for (uint256 i; i < 20; ++i) {
            uint256 amount = i + 2;
            uint256 minted = _deposit(alice, amount);
            assertEq(_redeem(alice, minted, 1), amount);
            assertEq(engine.totalShares(), 0);
        }
        assertEq(asset.balanceOf(address(pool)), cashBefore);
        assertEq(asset.balanceOf(alice), 1_000e6);
    }
}
