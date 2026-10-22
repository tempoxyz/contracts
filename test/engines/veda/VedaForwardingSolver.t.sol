// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { VedaForwardingSolver, IForwardingEngine } from "../../../src/engines/veda/VedaForwardingSolver.sol";
import { IBoringQueue } from "../../../src/interfaces/external/veda/IBoringQueue.sol";
import { IBoringSolver } from "../../../src/interfaces/external/veda/IBoringSolver.sol";
import { OnChainWithdraw } from "../../../src/interfaces/external/veda/VedaTypes.sol";
import { CoreMockToken } from "../../helpers/EarnVaultMocks.sol";

/// @dev Reproduces the stock BoringSolver's exact deficit behavior: the Teller output is compared
///      against the Queue liability and any permitted shortfall is pulled from `solverOrigin`, which
///      is the immediate caller (the VedaForwardingSolver in the canonical Earn path).
contract MockBoringSolver {
    CoreMockToken public immutable asset;
    address public engine;
    uint256 public payout;

    constructor(CoreMockToken asset_) {
        asset = asset_;
    }

    function configure(address engine_, uint256 payout_) external {
        engine = engine_;
        payout = payout_;
    }

    function boringRedeemSolve(OnChainWithdraw[] calldata requests, address, bool coverDeficit) external {
        uint256 required;
        for (uint256 i = 0; i < requests.length; i++) {
            required += requests[i].amountOfAssets;
        }

        asset.mint(address(this), payout);
        if (payout < required) {
            require(coverDeficit, "CANNOT_COVER_DEFICIT");
            require(asset.transferFrom(msg.sender, address(this), required - payout), "TRANSFER_FROM");
        } else if (payout > required) {
            require(asset.transfer(msg.sender, payout - required), "TRANSFER_SURPLUS");
        }
        require(asset.transfer(engine, required), "TRANSFER_ENGINE");
    }
}

contract MockTrackingQueue {
    mapping(bytes32 requestId => OnChainWithdraw request) internal requests;
    bool public trackWithdrawsOnChain = true;

    function add(OnChainWithdraw memory request) external returns (bytes32 requestId) {
        requestId = keccak256(abi.encode(request));
        requests[requestId] = request;
    }

    function getOnChainWithdraw(bytes32 requestId) external view returns (OnChainWithdraw memory) {
        return requests[requestId];
    }

    function getRequestId(OnChainWithdraw calldata request) external pure returns (bytes32) {
        return keccak256(abi.encode(request));
    }
}

/// @dev Records the credit-and-forward call and returns the count the FS surfaces.
contract MockForwardEngine is IForwardingEngine {
    address public lastAsset;
    uint256 public lastDelta;
    uint256 public lastCount;
    address public requestQueue;

    function setRequestQueue(address requestQueue_) external {
        requestQueue = requestQueue_;
    }

    function claimQueue(bytes32) external view returns (address) {
        return requestQueue;
    }

    function forwardSolved(bytes32[] calldata requestIds, address asset, uint256 delta)
        external
        returns (uint256 claimed)
    {
        lastAsset = asset;
        lastDelta = delta;
        lastCount = requestIds.length;
        return requestIds.length;
    }
}

contract VedaForwardingSolverTest is Test {
    CoreMockToken asset;
    MockBoringSolver boringSolver;
    MockTrackingQueue queue;
    MockForwardEngine engine;
    VedaForwardingSolver fs;
    address owner = address(this);
    address solver = address(0x50);
    address teller = address(0x7E);

    function setUp() public {
        asset = new CoreMockToken("Solve Asset", "SOLVE", 6);
        boringSolver = new MockBoringSolver(asset);
        queue = new MockTrackingQueue();
        engine = new MockForwardEngine();
        fs = new VedaForwardingSolver(
            IBoringSolver(address(boringSolver)),
            IBoringQueue(address(queue)),
            teller,
            IForwardingEngine(address(engine)),
            owner,
            owner
        );
        engine.setRequestQueue(address(queue));
        boringSolver.configure(address(engine), 100);
        fs.setAuthorizedSolver(solver, true);
    }

    function testSolveAndForwardCreditsMeasuredDeltaAndFinalizes() public {
        bytes32[] memory requestIds = new bytes32[](2);
        requestIds[0] = queue.add(_request(address(asset), 60));
        requestIds[1] = queue.add(_request(address(asset), 40));

        vm.prank(solver);
        uint256 forwarded = fs.solveAndForward(requestIds, false);

        assertEq(forwarded, 2);
        assertEq(engine.lastAsset(), address(asset));
        assertEq(engine.lastDelta(), 100); // the measured balance delta the solve delivered
        assertEq(engine.lastCount(), 2);
    }

    function testSolveAndForwardFundsDeficitFromCallerAllowanceAndRefundsRemainder() public {
        bytes32[] memory requestIds = _singleId(queue.add(_request(address(asset), 100)));
        boringSolver.configure(address(engine), 94);
        asset.mint(solver, 10);

        vm.prank(solver);
        asset.approve(address(fs), 10);
        vm.prank(solver);
        uint256 forwarded = fs.solveAndForward(requestIds, true);

        assertEq(forwarded, 1);
        assertEq(engine.lastDelta(), 100);
        assertEq(asset.balanceOf(solver), 4);
        assertEq(asset.balanceOf(address(fs)), 0);
        assertEq(asset.allowance(solver, address(fs)), 0);
        assertEq(asset.allowance(address(fs), address(boringSolver)), 0);
    }

    function testSolveAndForwardPreservesExistingBalanceWhileRefundingUnusedFunding() public {
        bytes32[] memory requestIds = _singleId(queue.add(_request(address(asset), 100)));
        boringSolver.configure(address(engine), 94);
        asset.mint(address(fs), 7);
        asset.mint(solver, 10);

        vm.prank(solver);
        asset.approve(address(fs), 10);
        vm.prank(solver);
        fs.solveAndForward(requestIds, true);

        assertEq(asset.balanceOf(solver), 4);
        assertEq(asset.balanceOf(address(fs)), 7);
        assertEq(asset.allowance(address(fs), address(boringSolver)), 0);
    }

    function testSolveAndForwardKeepsFavorableSurplusSeparateFromFundingRefund() public {
        bytes32[] memory requestIds = _singleId(queue.add(_request(address(asset), 100)));
        boringSolver.configure(address(engine), 105);
        asset.mint(address(fs), 7);
        asset.mint(solver, 10);

        vm.prank(solver);
        asset.approve(address(fs), 10);
        vm.prank(solver);
        fs.solveAndForward(requestIds, true);

        assertEq(asset.balanceOf(solver), 10);
        assertEq(asset.balanceOf(address(fs)), 12);
        assertEq(asset.allowance(solver, address(fs)), 0);
        assertEq(asset.allowance(address(fs), address(boringSolver)), 0);
    }

    function testSolveAndForwardInsufficientApprovalRevertsAtomically() public {
        bytes32[] memory requestIds = _singleId(queue.add(_request(address(asset), 100)));
        boringSolver.configure(address(engine), 90);
        asset.mint(solver, 5);

        vm.prank(solver);
        asset.approve(address(fs), 5);
        vm.prank(solver);
        vm.expectRevert(bytes("ALLOWANCE"));
        fs.solveAndForward(requestIds, true);

        assertEq(asset.balanceOf(solver), 5);
        assertEq(asset.balanceOf(address(fs)), 0);
        assertEq(asset.balanceOf(address(engine)), 0);
        assertEq(asset.allowance(solver, address(fs)), 5);
        assertEq(asset.allowance(address(fs), address(boringSolver)), 0);
    }

    function testSolveAndForwardWithoutDeficitCoverageDoesNotConsumeApproval() public {
        bytes32[] memory requestIds = _singleId(queue.add(_request(address(asset), 100)));
        asset.mint(solver, 10);

        vm.prank(solver);
        asset.approve(address(fs), 10);
        vm.prank(solver);
        fs.solveAndForward(requestIds, false);

        assertEq(asset.balanceOf(solver), 10);
        assertEq(asset.allowance(solver, address(fs)), 10);
        assertEq(asset.allowance(address(fs), address(boringSolver)), 0);
    }

    function testSolveAndForwardIsAuthorizedSolverOnly() public {
        bytes32[] memory requestIds = _singleId(queue.add(_request(address(asset), 10)));

        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(VedaForwardingSolver.NotAuthorizedSolver.selector, address(0xDEAD)));
        fs.solveAndForward(requestIds, false);
    }

    function testSolveAndForwardRejectsMixedAssetOut() public {
        bytes32[] memory requestIds = new bytes32[](2);
        requestIds[0] = queue.add(_request(address(asset), 10));
        requestIds[1] = queue.add(_request(address(0xBEEF), 10));

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(VedaForwardingSolver.SolveAssetMismatch.selector, 1, address(asset), address(0xBEEF))
        );
        fs.solveAndForward(requestIds, false);
    }

    function _singleId(bytes32 requestId) internal pure returns (bytes32[] memory requestIds) {
        requestIds = new bytes32[](1);
        requestIds[0] = requestId;
    }

    function _request(address assetOut, uint128 shares) internal view returns (OnChainWithdraw memory) {
        return OnChainWithdraw({
            nonce: 1,
            user: address(engine),
            assetOut: assetOut,
            amountOfShares: shares,
            amountOfAssets: shares,
            creationTime: 1,
            secondsToMaturity: 0,
            secondsToDeadline: 3600
        });
    }
}
