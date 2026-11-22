// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { ManagedPropAMMEngine } from "../../../../src/earn/engines/propamm/ManagedPropAMMEngine.sol";
import {
    IManagedPropAMMVenue,
    IManagedPropAMMSettler
} from "../../../../src/interfaces/external/propamm/IManagedPropAMMVenue.sol";
import { EarnVault } from "../../../../src/earn/core/EarnVault.sol";
import { FeeConfig, ExcessReturnFee } from "../../../../src/interfaces/earn/EarnFeeTypes.sol";
import { EarnVaultTestDeployer } from "../../helpers/EarnVaultTestDeployer.sol";
import { CoreMockToken } from "../../helpers/EarnVaultMocks.sol";
import { MemoMockToken, PropAMMTestOracle } from "../../helpers/PropAMMEngineMocks.sol";
import { IManagedPropAMMTestFactory, IManagedPropAMMTestSettler } from "../../helpers/ManagedPropAMMEngineMocks.sol";

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
    function setSettler(address settler) external;
    /// @dev The pool's direct swap, which pulls from its caller. The engine never sends it.
    function swapExactInput(
        uint16 pairIndex,
        bool baseToQuote,
        uint256 amountIn,
        uint256 minAmountOut,
        uint64 sponsorId,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external returns (uint256 amountOut);
    function swapExactOutput(
        uint16 pairIndex,
        bool baseToQuote,
        uint256 amountOut,
        uint256 maxAmountIn,
        uint64 sponsorId,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external returns (uint256 amountIn);
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

/// @dev Exercises the engine against the unmodified pinned artifacts: a ManagedDirectPropAMM pool the pinned
/// PoolFactory creates, and the Settler that factory deploys.
contract ManagedPropAMMIntegrationTest is Test {
    uint64 constant SPONSOR = 7;
    bytes32 constant ROUTE = bytes32(uint256(1));

    /// @dev The pool's trade event.
    event TradeExecuted(
        uint16 indexed pairIndex,
        address indexed taker,
        bytes32 indexed customerId,
        uint64 sponsorId,
        bytes32 tradeId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 oraclePrice,
        uint256 oracleUpdatedAt
    );

    MemoMockToken asset;
    MemoMockToken baseToken;
    MemoMockToken otherBase;
    CoreMockToken share;
    PropAMMTestOracle oracle;
    IManagedPropAMMTestFactory factory;
    address settler;
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
        // PropAMM pins solc 0.8.30; deploy its unmodified artifacts alongside Earn's 0.8.36 code. The factory
        // deploys the pool implementation and the Settler, and creates the pool on that Settler, owned by
        // this test and paused.
        factory = IManagedPropAMMTestFactory(deployCode("test/earn/fixtures/propamm/PoolFactory.json"));
        settler = factory.defaultSettler();
        pool = IManagedPropAMMPoolAdmin(factory.createPool(address(this), bytes32(0)));
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

    /// @dev The engine's standing allowances are the Settler's: one unit of each token, none on the pool, and
    /// the Settler holds nothing.
    function _assertSettlerApprovals() internal view {
        assertEq(asset.allowance(address(engine), settler), 1);
        assertEq(baseToken.allowance(address(engine), settler), 1);
        assertEq(asset.allowance(address(engine), address(pool)), 0);
        assertEq(baseToken.allowance(address(engine), address(pool)), 0);
        assertEq(asset.balanceOf(settler), 0);
        assertEq(baseToken.balanceOf(settler), 0);
    }

    /// @dev One swap of the engine's at the oracle's current observation, as its `trade`-th of the transaction:
    /// the trade ID is the block number above the transaction's trade count.
    function _params(bool baseToQuote, bool exactInput, uint256 amount, uint256 limit, uint64 sponsorId, uint256 trade)
        internal
        view
        returns (IManagedPropAMMVenue.SwapParams memory)
    {
        return IManagedPropAMMVenue.SwapParams({
            pairIndex: pairIndex,
            baseToQuote: baseToQuote,
            exactInput: exactInput,
            amount: amount,
            limit: limit,
            sponsorId: sponsorId,
            customerId: ROUTE,
            tradeId: bytes32((vm.getBlockNumber() << 128) | trade),
            deadline: vm.getBlockTimestamp(),
            expectedOraclePrice: oracle.price(),
            oraclePriceToleranceBps: 0,
            minimumOracleUpdatedAt: oracle.updatedAt()
        });
    }

    /// @dev Expects the engine to send the Settler exactly this swap, and the pool to record it for the engine.
    function _expectSettlement(
        bool baseToQuote,
        bool exactInput,
        uint256 amount,
        uint256 limit,
        uint256 trade,
        uint256 amountIn,
        uint256 amountOut
    ) internal {
        IManagedPropAMMVenue.SwapParams memory params = _params(baseToQuote, exactInput, amount, limit, 0, trade);
        vm.expectCall(settler, abi.encodeCall(IManagedPropAMMSettler.swap, (address(pool), params)));
        vm.expectEmit(address(pool));
        emit TradeExecuted(
            pairIndex,
            address(engine),
            ROUTE,
            0,
            params.tradeId,
            address(baseToQuote ? baseToken : asset),
            address(baseToQuote ? asset : baseToken),
            amountIn,
            amountOut,
            params.expectedOraclePrice,
            params.minimumOracleUpdatedAt
        );
    }

    /// @dev Every balance the settlement touches; the engine keeps no cash and the Settler nothing.
    function _assertBalances(uint256 aliceCash, uint256 poolCash, uint256 poolBase, uint256 engineBase) internal view {
        assertEq(asset.balanceOf(alice), aliceCash);
        assertEq(asset.balanceOf(address(pool)), poolCash);
        assertEq(baseToken.balanceOf(address(pool)), poolBase);
        assertEq(baseToken.balanceOf(address(engine)), engineBase);
        assertEq(engine.totalShares(), engineBase);
        assertEq(asset.balanceOf(address(engine)), 0);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(baseToken.balanceOf(alice), 0);
        _assertSettlerApprovals();
    }

    function _credit(address taker) internal view returns (uint256) {
        return pool.roundingCredit(pool.roundingRouteKey(pairIndex, taker, ROUTE));
    }

    function _assertEveryFlowReverts(bytes4 reason) internal {
        _assertEveryFlowReverts(abi.encodeWithSelector(reason));
    }

    /// @dev With alice holding 100e6 shares: a deposit, a redemption and an exact withdrawal each revert with
    /// `reason` and leave every balance, share and allowance as it was.
    function _assertEveryFlowReverts(bytes memory reason) internal {
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
        _assertSettlerApprovals();
    }

    function testConstructorBindsTheFactorysSettler() public view {
        assertTrue(factory.isPool(address(pool)));
        assertEq(pool.factory(), address(factory));
        assertEq(engine.settler(), factory.defaultSettler());
        assertEq(engine.settler(), pool.settler());
        assertEq(IManagedPropAMMTestSettler(settler).factory(), address(factory));
        assertEq(IManagedPropAMMTestSettler(settler).implementation(), factory.implementation());
        _assertSettlerApprovals();
    }

    function testConstructorRejectsAStandalonePool() public {
        // The pinned pool deployed on its own names no factory and no settler: only its direct swaps work,
        // and the engine sends none.
        IManagedPropAMMPoolAdmin standalone = IManagedPropAMMPoolAdmin(
            deployCode("test/earn/fixtures/propamm/ManagedDirectPropAMM.json", abi.encode(address(this), address(0)))
        );
        uint16 index = standalone.addPair(address(baseToken), address(asset), address(oracle), 1 days, 50);
        assertEq(standalone.factory(), address(0));
        assertEq(standalone.settler(), address(0));
        assertFalse(factory.isPool(address(standalone)));
        vm.expectRevert(ManagedPropAMMEngine.StandalonePool.selector);
        new ManagedPropAMMEngine(
            address(standalone), index, 0, address(asset), address(baseToken), address(this), 1 days, ROUTE
        );
    }

    function testDepositAndExitsSettleThroughTheSettlerWithExactBalances() public {
        // The engine never calls the pool's direct swaps.
        vm.expectCall(address(pool), abi.encodeWithSelector(IManagedPropAMMPoolAdmin.swapExactInput.selector), 0);
        vm.expectCall(address(pool), abi.encodeWithSelector(IManagedPropAMMPoolAdmin.swapExactOutput.selector), 0);

        // The vault sends a deposit straight to the engine, which buys with what it holds.
        vm.expectCall(address(engine), abi.encodeCall(engine.depositHeld, (105e6)));
        _expectSettlement(false, true, 105e6, 100e6, 1, 105e6, 100e6);
        assertEq(_deposit(alice, 105e6), 100e6);
        _assertBalances(895e6, 10_105e6, 9_900e6, 100e6);

        _expectSettlement(true, false, 21e6, 20e6, 1, 20e6, 21e6);
        vm.prank(alice);
        assertEq(vault.withdrawExact(21e6, alice, 20e6), 20e6);
        _assertBalances(916e6, 10_084e6, 9_920e6, 80e6);

        _expectSettlement(true, true, 80e6, 84e6, 1, 80e6, 84e6);
        assertEq(_redeem(alice, 80e6, 84e6), 84e6);
        _assertBalances(1_000e6, 10_000e6, 10_000e6, 0);
        assertEq(share.balanceOf(alice), 0);
    }

    function testRoundingCreditAccruesOnTheEnginesRoute() public {
        _deposit(alice, 1e6 + 1);
        // The Settler's caller is the taker, so the route is the engine's: (pairIndex, engine, customerId).
        assertEq(
            pool.roundingRouteKey(pairIndex, address(engine), ROUTE), keccak256(abi.encode(pairIndex, engine, ROUTE))
        );
        uint256 credit = _credit(address(engine));
        assertGt(credit, 0);
        assertEq(_credit(settler), 0);
        assertEq(_credit(address(vault)), 0);
        assertEq(_credit(alice), 0);
        assertTrue(pool.takerAllowed(pairIndex, address(engine), 0));
        assertFalse(pool.takerAllowed(pairIndex, settler, 0));

        // The next trade spends and leaves credit on that same route alone.
        (,,, uint256 creditAfter) = pool.quoteExactInputFor(pairIndex, address(engine), ROUTE, true, 400_000);
        _redeem(alice, 400_000, 1);
        assertEq(_credit(address(engine)), creditAfter);
        assertEq(_credit(settler), 0);
        assertEq(_credit(address(vault)), 0);
        _assertSettlerApprovals();
    }

    function testExactWithdrawalBurnsTheSettlersQuote() public {
        _deposit(alice, 100e6 + 1);
        uint256 held = engine.totalShares();
        assertGt(_credit(address(engine)), 0);
        // The Settler quotes an exact output for its caller's route, credit included, and the fill must take
        // exactly that: the engine names the same quote as its limit and burns it.
        (uint256 quoted,,, uint256 creditAfter) =
            pool.quoteExactOutputFor(pairIndex, address(engine), ROUTE, true, 33_333_333);
        assertEq(engine.previewWithdraw(33_333_333), quoted);
        uint256 maximumShares = share.balanceOf(alice);
        _expectSettlement(true, false, 33_333_333, quoted, 1, quoted, 33_333_333);
        vm.prank(alice);
        uint256 burned = vault.withdrawExact(33_333_333, alice, maximumShares);
        assertEq(held - engine.totalShares(), quoted);
        assertEq(burned, maximumShares - share.balanceOf(alice));
        assertEq(_credit(address(engine)), creditAfter);
        assertEq(asset.balanceOf(alice), 1_000e6 - (100e6 + 1) + 33_333_333);
        assertEq(baseToken.balanceOf(address(pool)), 10_000e6 - held + quoted);
        _assertSettlerApprovals();
    }

    function testReplacedSettlerRevertsEveryFlow() public {
        _deposit(alice, 105e6);
        // The pool's owner moves it to another Settler of the same factory, from the same pinned build.
        address replacement =
            deployCode("test/earn/fixtures/propamm/Settler.json", abi.encode(factory.implementation()));
        assertEq(IManagedPropAMMTestSettler(replacement).factory(), address(factory));
        pool.setSettler(replacement);
        bytes memory mismatch =
            abi.encodeWithSelector(ManagedPropAMMEngine.SettlerMismatch.selector, settler, replacement);

        // The engine approves and swaps through its own settler alone: it stops rather than follow the pool.
        _assertEveryFlowReverts(mismatch);
        assertEq(asset.allowance(address(engine), replacement), 0);
        assertEq(baseToken.allowance(address(engine), replacement), 0);
        (bool paused, bool admitted,,,) = engine.liquidityStatus();
        assertFalse(paused);
        assertFalse(admitted);
        assertTrue(pool.takerAllowed(pairIndex, address(engine), 0));
        // Valuation does not depend on the settler.
        assertEq(vault.totalAssets(), 105e6);

        // The pool refuses the engine's settler now, so the engine's refusal costs no trade that would settle.
        _expectSettlerRefusal(0, abi.encodeWithSignature("NotSettler()"));
        // No new engine binds while the pool is on another settler.
        vm.expectRevert(mismatch);
        new ManagedPropAMMEngine(
            address(pool), pairIndex, 0, address(asset), address(baseToken), address(this), 1 days, ROUTE
        );

        pool.setSettler(settler);
        (, admitted,,,) = engine.liquidityStatus();
        assertTrue(admitted);
        vm.prank(alice);
        assertEq(vault.withdrawExact(21e6, alice, 20e6), 20e6);
        assertEq(_redeem(alice, 80e6, 84e6), 84e6);
        assertEq(asset.balanceOf(alice), 1_000e6);
        _assertSettlerApprovals();
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
        _assertSettlerApprovals();
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
        // The engine's checks mirror the pool's own refusals: its swap sent straight to the Settler reverts too.
        _deposit(alice, 105e6);
        pool.closePair(pairIndex);
        _expectSettlerRefusal(0, abi.encodeWithSignature("TakerNotAllowed(address)", address(engine)));
        pool.setPairAccess(pairIndex, IManagedPropAMMVenue.AccessMode.Listed);

        _list(0, address(engine), false);
        _expectSettlerRefusal(0, abi.encodeWithSignature("TakerNotAllowed(address)", address(engine)));
        _list(0, address(engine), true);

        _deny(address(engine), true);
        _expectSettlerRefusal(0, abi.encodeWithSignature("TakerDenied(address)", address(engine)));
        _deny(address(engine), false);

        pool.pause();
        _expectSettlerRefusal(0, abi.encodeWithSignature("Paused()"));
        pool.unpause();

        _expectSettlerRefusal(SPONSOR, abi.encodeWithSignature("UnknownSponsor(uint64)", SPONSOR));
        _assertSettlerApprovals();
    }

    /// @dev The engine's sale of its 100e6 base tokens, sent to the Settler as the engine. The Settler moves the
    /// input before the pool checks anything, so the engine approves it first, as it does in a trade.
    function _expectSettlerRefusal(uint64 sponsorId, bytes memory reason) internal {
        IManagedPropAMMVenue.SwapParams memory params = _params(true, true, 100e6, 1, sponsorId, 99);
        vm.prank(address(engine));
        baseToken.approve(settler, 100e6 + 1);
        vm.prank(address(engine));
        vm.expectRevert(reason);
        IManagedPropAMMSettler(settler).swap(address(pool), params);
        vm.prank(address(engine));
        baseToken.approve(settler, 1);
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
        _assertSettlerApprovals();
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
        _assertSettlerApprovals();
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
        _assertSettlerApprovals();
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
