// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IBoringSolver } from "../../interfaces/external/veda/IBoringSolver.sol";
import { IBoringQueue } from "../../interfaces/external/veda/IBoringQueue.sol";
import { OnChainWithdraw } from "../../interfaces/external/veda/VedaTypes.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @dev Forward slice of the `VedaEngine` (the `forwardSolved` target).
interface IForwardingEngine {
    function forwardSolved(bytes32[] calldata requestIds, address asset, uint256 delta)
        external
        returns (uint256 claimed);
    function claimQueue(bytes32 requestId) external view returns (address);
}

/// @dev IERC20 balance slice — the FS measures the engine's `assetOut` balance across the solve so it
///      credits the engine EXACTLY what the queue just delivered for this batch (never more).
interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev ERC-20 funding slice used to bridge a solver EOA's per-solve approval into the stock
///      BoringSolver's `solverOrigin` pull. The caller's allowance is the funding bound; there is no
///      duplicate max-deficit argument.
interface IERC20SolverFunding is IERC20Balance {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title VedaForwardingSolver
/// @notice The atomic solve->forward sequencer wired to the `VedaEngine`. In ONE tx it drives the
///         STOCK Veda BoringSolver (whose queue payout loop pays request.user == the engine), then
///         credits the MEASURED solve-delta into the engine and calls engine.forwardSolved so every
///         tracked amount is finalized through the EarnVault to every stored receiver before the tx
///         returns. Solvers submit request IDs; complete structs are read from the tracking Queue.
///
/// @dev ZERO Veda changes; never holds shares or user assets at rest. Auth is two layers: (1) an
///      owner-managed `onlyAuthorizedSolver` allowlist (the wallet solver seat) gates WHO may trigger;
///      (2) this contract must hold the Veda solver role on the shared RolesAuthority to call the stock
///      solver (granted at deploy, not managed here). Needs NO raw-share hook entry.
contract VedaForwardingSolver is Ownable2Step {
    IBoringSolver public immutable boringSolver;
    IBoringQueue public immutable queue;
    address public immutable teller;
    IForwardingEngine public immutable engine;

    address public treasury;

    mapping(address solver => bool authorized) public isAuthorizedSolver;

    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);
    event AuthorizedSolverChanged(address indexed account, bool authorized);
    event SolvedAndForwarded(uint256 requestCount, uint256 forwardedCount, address indexed caller);
    event DeficitFundingSettled(
        address indexed solver, address indexed asset, uint256 funded, uint256 used, uint256 refunded
    );
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error NotAuthorizedSolver(address caller);
    error ZeroAddress();
    error NoRequests();
    error InvalidTrackedRequest(uint256 index, bytes32 requestId);
    error QueueTrackingDisabled(address queue);
    error ReentrantCall();
    error RequestQueueMismatch(uint256 index, address expected, address actual);
    error SolveAssetMismatch(uint256 index, address expected, address got);
    error TokenCallFailed();
    error TreasuryNotSet();
    error RescueFailed();

    bool private transient _entered;

    modifier onlyAuthorizedSolver() {
        if (!isAuthorizedSolver[msg.sender]) revert NotAuthorizedSolver(msg.sender);
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    constructor(
        IBoringSolver boringSolver_,
        IBoringQueue queue_,
        address teller_,
        IForwardingEngine engine_,
        address owner_,
        address treasury_
    ) Ownable(owner_) {
        if (
            address(boringSolver_) == address(0) || address(queue_) == address(0) || teller_ == address(0)
                || address(engine_) == address(0) || treasury_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (!queue_.trackWithdrawsOnChain()) revert QueueTrackingDisabled(address(queue_));
        boringSolver = boringSolver_;
        queue = queue_;
        teller = teller_;
        engine = engine_;
        treasury = treasury_;
        emit TreasuryChanged(address(0), treasury);
    }

    /// @notice Solve a batch of matured tracked requests by ID and forward proceeds to end receivers,
    ///         ALL in one tx. Complete structs are read from the immutable tracking Queue and verified
    ///         against both their IDs and the originating Queue stored by the engine.
    function solveAndForward(bytes32[] calldata requestIds, bool coverDeficit)
        external
        onlyAuthorizedSolver
        nonReentrant
        returns (uint256 forwarded)
    {
        uint256 n = requestIds.length;
        if (n == 0) revert NoRequests();

        OnChainWithdraw[] memory requests = new OnChainWithdraw[](n);
        address expectedQueue = address(queue);
        address asset;
        for (uint256 i = 0; i < n; i++) {
            bytes32 requestId = requestIds[i];
            address actualQueue = engine.claimQueue(requestId);
            if (actualQueue != expectedQueue) revert RequestQueueMismatch(i, expectedQueue, actualQueue);
            OnChainWithdraw memory request = queue.getOnChainWithdraw(requestId);
            if (queue.getRequestId(request) != requestId || request.user != address(engine)) {
                revert InvalidTrackedRequest(i, requestId);
            }
            requests[i] = request;
            if (i == 0) asset = request.assetOut;
            else if (request.assetOut != asset) revert SolveAssetMismatch(i, asset, request.assetOut);
        }

        // STEP 1 — when deficit coverage is enabled, consume the solver's complete per-solve
        // allowance as the funding bound. The stock BoringSolver records this forwarder as
        // `solverOrigin`, so bridge the caller's funds here and grant only a temporary downstream
        // allowance. A failed solve rolls every transfer and approval back atomically.
        IERC20SolverFunding token = IERC20SolverFunding(asset);
        uint256 forwarderBalanceBefore;
        uint256 funding;
        if (coverDeficit) {
            forwarderBalanceBefore = token.balanceOf(address(this));
            funding = token.allowance(msg.sender, address(this));
            if (funding != 0) {
                _pull(token, msg.sender, funding);
                _approveFromZero(token, address(boringSolver), funding);
            }
        }

        // STEP 2 — stock solve. The queue pays request.user == the engine. Measure the engine's `asset`
        // balance delta so the credit below is EXACTLY what was delivered.
        uint256 pre = IERC20Balance(asset).balanceOf(address(engine));
        boringSolver.boringRedeemSolve(requests, teller, coverDeficit);
        uint256 delta = IERC20Balance(asset).balanceOf(address(engine)) - pre;

        // STEP 3 — clear the stock solver's residual allowance and refund only unused caller funding.
        // Pre-existing forwarder balance and favorable solve surplus remain separate and rescueable to
        // treasury. Because funding is pulled in full, a standard ERC-20 caller allowance returns to zero.
        if (funding != 0) {
            _approveFromZero(token, address(boringSolver), 0);
            uint256 forwarderBalanceAfter = token.balanceOf(address(this));
            uint256 availableRefund =
                forwarderBalanceAfter > forwarderBalanceBefore ? forwarderBalanceAfter - forwarderBalanceBefore : 0;
            uint256 refunded = availableRefund < funding ? availableRefund : funding;
            if (refunded != 0) _push(token, msg.sender, refunded);
            emit DeficitFundingSettled(msg.sender, asset, funding, funding - refunded, refunded);
        }

        // STEP 4 — credit the measured delta and finalize each funded request through the EarnVault.
        forwarded = engine.forwardSolved(requestIds, asset, delta);
        emit SolvedAndForwarded(n, forwarded, msg.sender);
    }

    function setAuthorizedSolver(address account, bool authorized) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isAuthorizedSolver[account] = authorized;
        emit AuthorizedSolverChanged(account, authorized);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @notice Owner-only rescue for the only value that can accumulate here: Veda's non-self-solve
    ///         excess/discount surplus (rounding dust). Constrained to the pre-set treasury.
    function rescue(address token, uint256 amount) external onlyOwner {
        address to = treasury;
        if (to == address(0)) revert TreasuryNotSet();
        if (!IERC20Balance(token).transfer(to, amount)) revert RescueFailed();
        emit Rescued(token, to, amount);
    }

    function _pull(IERC20SolverFunding token, address from, uint256 amount) private {
        if (!token.transferFrom(from, address(this), amount)) revert TokenCallFailed();
    }

    function _push(IERC20SolverFunding token, address to, uint256 amount) private {
        if (!token.transfer(to, amount)) revert TokenCallFailed();
    }

    /// @dev Every downstream approval is zero at rest. A reverted frame also rolls the temporary
    ///      allowance back, so direct set/clear calls are sufficient and preserve bool-return checks.
    function _approveFromZero(IERC20SolverFunding token, address spender, uint256 amount) private {
        if (!token.approve(spender, amount)) revert TokenCallFailed();
    }
}
