// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// Stateful Veda claim-ledger invariants.
// The handler intentionally co-locates contracts, calls tracked ledgers in loops, and uses bounded test fixtures.
// forge-lint: disable-start(calls-loop,missing-zero-check,multi-contract-file,screaming-snake-case-immutable)
// forge-lint: disable-start(uninitialized-local,unsafe-typecast,unused-return)
import { Test } from "forge-std/Test.sol";

import { VedaEngine } from "../../../src/engines/veda/VedaEngine.sol";
import { OnChainWithdraw } from "../../../src/interfaces/external/veda/VedaTypes.sol";
import { VedaEngineTestBase } from "../../helpers/VedaEngineTestBase.sol";
import { MockAsset, MockBoringVault, MockCore, MockQueue } from "../../helpers/VedaEngineMocks.sol";

contract VedaClaimLedgerHandler is Test {
    uint256 private constant MAX_REQUESTS = 32;

    MockAsset public immutable asset;
    MockBoringVault public immutable vault;
    MockQueue public immutable queue;
    VedaEngine public immutable engine;
    MockCore public immutable core;
    address public immutable engineOwner;

    bytes32[] private requestIds;

    constructor(
        MockAsset asset_,
        MockBoringVault vault_,
        MockQueue queue_,
        VedaEngine engine_,
        MockCore core_,
        address engineOwner_
    ) {
        asset = asset_;
        vault = vault_;
        queue = queue_;
        engine = engine_;
        core = core_;
        engineOwner = engineOwner_;
    }

    function request(uint128 rawShares) external {
        if (requestIds.length >= MAX_REQUESTS) return;
        uint128 shares = uint128(bound(rawShares, 1, 1e18));
        vault.mint(address(engine), shares);
        requestIds.push(core.requestRedeem(shares, address(asset), 0, 3600));
    }

    function cancel(uint256 seed) external {
        bytes32 id = _find(seed, VedaEngine.ClaimStatus.Open, VedaEngine.ClaimStatus.None);
        if (id == bytes32(0)) return;
        core.cancelRedeem(id);
    }

    function solve(uint256 seed, bool failFinalize, uint128 rawSurplus) external {
        bytes32 id = _find(seed, VedaEngine.ClaimStatus.Open, VedaEngine.ClaimStatus.None);
        if (id == bytes32(0)) return;
        (, OnChainWithdraw memory request_) = engine.getClaim(id);
        uint256 surplus = bound(rawSurplus, 0, request_.amountOfAssets);
        uint256 delivered = uint256(request_.amountOfAssets) + surplus;
        asset.mint(address(engine), delivered);
        core.setRevertFinalize(failFinalize);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        engine.forwardSolved(ids, address(asset), delivered);
        core.setRevertFinalize(false);
    }

    function claim(uint256 seed) external {
        bytes32 id = _find(seed, VedaEngine.ClaimStatus.Claimable, VedaEngine.ClaimStatus.None);
        if (id == bytes32(0)) return;
        engine.claimRedeem(id);
    }

    function sweepSurplus(uint256 rawAmount) external {
        if (engine.unresolvedClaimCount() != 0) return;
        uint256 balance = asset.balanceOf(address(engine));
        uint256 reserved = engine.settled(address(asset));
        if (balance <= reserved) return;
        uint256 amount = bound(rawAmount, 1, balance - reserved);
        vm.prank(engineOwner);
        engine.sweepDust(address(asset), address(this), amount);
    }

    function requestCount() external view returns (uint256) {
        return requestIds.length;
    }

    function requestIdAt(uint256 index) external view returns (bytes32) {
        return requestIds[index];
    }

    function _find(uint256 seed, VedaEngine.ClaimStatus first, VedaEngine.ClaimStatus second)
        private
        view
        returns (bytes32 id)
    {
        uint256 count = requestIds.length;
        if (count == 0) return bytes32(0);
        uint256 start = seed % count;
        for (uint256 i = 0; i < count; i++) {
            id = requestIds[(start + i) % count];
            (VedaEngine.ClaimStatus status,) = engine.getClaim(id);
            if (status == first || status == second) return id;
        }
        return bytes32(0);
    }
}

contract VedaClaimLedgerInvariantTest is VedaEngineTestBase {
    VedaClaimLedgerHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new VedaClaimLedgerHandler(asset, vault, queue, engine, core, address(this));
        engine.setAuthorizedForwarder(address(handler), true);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = VedaClaimLedgerHandler.request.selector;
        selectors[1] = VedaClaimLedgerHandler.cancel.selector;
        selectors[2] = VedaClaimLedgerHandler.solve.selector;
        selectors[3] = VedaClaimLedgerHandler.claim.selector;
        selectors[4] = VedaClaimLedgerHandler.sweepSurplus.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_settledEqualsClaimableLedger() public view {
        uint256 claimableAssets;
        uint256 unresolvedClaims;
        uint256 count = handler.requestCount();

        for (uint256 i = 0; i < count; i++) {
            bytes32 id = handler.requestIdAt(i);
            (VedaEngine.ClaimStatus status, OnChainWithdraw memory request_) = engine.getClaim(id);
            if (status == VedaEngine.ClaimStatus.Claimable) claimableAssets += request_.amountOfAssets;
            if (status == VedaEngine.ClaimStatus.Open || status == VedaEngine.ClaimStatus.Claimable) {
                unresolvedClaims += 1;
            }

            if (status == VedaEngine.ClaimStatus.Paid) {
                assertEq(core.finalizedAmount(id), request_.amountOfAssets);
            } else {
                assertEq(core.finalizedAmount(id), 0);
            }
        }

        uint256 settled = engine.settled(address(asset));
        assertEq(settled, claimableAssets);
        assertLe(settled, asset.balanceOf(address(engine)));
        assertEq(engine.openClaimsByQueue(address(queue)), unresolvedClaims);
        assertEq(engine.unresolvedClaimCount(), unresolvedClaims);
    }
}
