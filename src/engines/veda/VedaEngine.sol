// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IERC20Like } from "../../interfaces/external/IERC20Like.sol";
import { IEarnEngine } from "../../interfaces/engines/IEarnEngine.sol";
import { IEarnEngineAsyncRedeem } from "../../interfaces/engines/IEarnEngineAsyncRedeem.sol";
import { IEarnEngineExactWithdraw } from "../../interfaces/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineFeeValuation } from "../../interfaces/engines/IEarnEngineFeeValuation.sol";
import { IEarnEngineRedeem } from "../../interfaces/engines/IEarnEngineRedeem.sol";
import {
    IAccountant,
    IStepAccountant,
    IYieldStreamingAccountant
} from "../../interfaces/external/veda/IAccountant.sol";
import { IBoringQueue } from "../../interfaces/external/veda/IBoringQueue.sol";
import { IBoringVault } from "../../interfaces/external/veda/IBoringVault.sol";
import { ITeller } from "../../interfaces/external/veda/ITeller.sol";
import { IVedaPeripheryRegistry } from "../../interfaces/external/veda/IVedaPeripheryRegistry.sol";
import { OnChainWithdraw, VedaRedeemRequest } from "../../interfaces/external/veda/VedaTypes.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev Callback the engine uses to hand solved assets back to its single client (the `EarnVault`).
interface IEarnVaultFinalize {
    function finalizeRedeem(bytes32 requestId, address asset, uint256 amount) external;
}

/// @dev Runtime periphery rotation is coordinated with the EarnVault's deposit-only pause. Exit and
///      claim paths remain available while the engine owner validates replacement Veda modules.
interface IEarnVaultPause {
    function depositsPaused() external view returns (bool);
}

/// @title VedaEngine
/// @notice The optionally async-capable engine behind the `IEarnEngine` seam, wrapping the REAL,
///         UNMODIFIED Veda BoringVault/Teller/optional Queue/Accountant. It is the SOLE holder of raw
///         BoringVault shares attributed to its single client (the `EarnVault`) and the only address
///         granted the Veda depositor role (Teller deposit + immediate withdraw). It is single-client
///         by construction: every `IEarnEngine`/`IEarnEngineAsyncRedeem` mutating call is `onlyEarnVault`,
///         and `forwardSolved` is `onlyForwarder` (the `VedaForwardingSolver`).
///
/// @dev IMMEDIATE. `withdraw` synthesizes an exact-asset exit: engineShares =
///      mulDivUp(assets, shareScale,
///      getRateInQuoteSafe(asset)), where shareScale is `10 ** vault.decimals()`, then calls the Teller
///      with `minimumAssets = assets` as an underpay-impossible backstop; the exit lands on the engine
///      and exactly `assets` is forwarded
///      to the receiver, so sub-1-share rounding dust stays here (owner-sweepable) and the receiver is
///      never overpaid.
///
/// @dev ASYNC (when a Queue is active). `requestRedeem` files the tracking queue AS THE ENGINE
///      (request.user == engine, so Veda never learns end users exist), reads the canonical request
///      back by ID, and stores only the two amounts needed for Tempo accounting. Cancellation is
///      request-ID based; Tempo never reconstructs a Queue request from off-chain event data.
///      `forwardSolved` (FS-only) credits a MEASURED, balance-bounded per-asset settled ledger, then
///      finalizes each funded request by transferring its assets to the EarnVault and calling
///      earnVault.finalizeRedeem, with the no-cross-solve-residue un-earmark and the
///      degrade-to-skip-on-unpayable-receiver guard. Owner recovery handles a
///      Queue payout delivered by another authorized Veda solver without making that balance sweepable.
contract VedaEngine is
    IEarnEngine,
    IEarnEngineRedeem,
    IEarnEngineExactWithdraw,
    IEarnEngineFeeValuation,
    IEarnEngineAsyncRedeem,
    Ownable2Step
{
    // The registry is owned through the underlying BoringVault administration. This engine's owner
    // can activate only a tuple published there, while retaining control of wrapper-local settings.
    IVedaPeripheryRegistry public immutable peripheryRegistry;
    IBoringVault public immutable vault;
    ITeller public teller;
    IBoringQueue public queue;
    IAccountant public accountant;
    uint64 public peripheryVersion;
    /// @notice Maximum age of the latest Veda Accountant rate report accepted for new deposits.
    uint64 public maxRateAge;
    /// @dev Transaction-scoped rate checkpoint. Transient storage is cleared automatically after the
    ///      transaction, so unrelated operations in the same block may consume a newly posted rate.
    bool private transient _rateCheckpointed;
    uint256 private transient _rateAtTransaction;
    /// @dev Raw units in one BoringVault share, derived once from the immutable vault.
    uint256 internal immutable _shareScale;

    /// @notice The single seam asset (Veda base / queue asset). The earnVault is single-asset; multi-asset
    ///         richness lives at the scoped router via swaps.
    address public immutable baseAsset;
    string internal _name;
    string internal _symbol;

    /// @notice The sole EarnVault client. Set once, post-deploy (the factory creates the EarnVault after
    ///         the engine exists), then immutable.
    address public earnVault;

    enum ClaimStatus {
        None,
        // Reserved so Open/Claimable/Paid/Cancelled retain their existing ABI values.
        LegacyAwaitingDetails,
        Open,
        Claimable,
        Paid,
        Cancelled
    }

    struct QueueClaim {
        // Slot 0: the originating tracking queue plus lifecycle status.
        IBoringQueue requestQueue;
        ClaimStatus status;
        // Slot 1: the two amounts Tempo needs for cancellation and settlement accounting.
        uint128 amountOfShares;
        uint128 amountOfAssets;
    }

    mapping(bytes32 requestId => QueueClaim) private _claims;

    /// @notice Unresolved engine claims grouped by their originating Queue. Operators keep an old
    ///         Queue and solve path available until this count reaches zero.
    mapping(address requestQueue => uint256 count) public openClaimsByQueue;

    /// @notice Total claims that have not finalized or cancelled. While nonzero, the base asset is
    ///         never sweepable because an authorized Veda solver may have paid the engine without
    ///         routing through {VedaForwardingSolver} and therefore without crediting {settled}.
    uint256 public unresolvedClaimCount;

    /// @notice Aggregate per-asset funding ledger. A request is finalizable only from assets explicitly
    ///         earmarked here, never the engine's raw balance. Each measured credit must independently
    ///         cover its current solved batch; retained amounts belong only to exact requests marked
    ///         claimable after a failed payout.
    mapping(address asset => uint256 amount) public settled;

    /// @notice The `VedaForwardingSolver`(s) permitted to credit-and-forward. Owner-managed; NOT custody.
    mapping(address forwarder => bool authorized) public authorizedForwarder;

    bool private transient _entered;

    event EarnVaultInitialized(address indexed earnVault);
    /// @notice Initial active periphery and freshness policy captured by this engine.
    event VedaEngineInitialized(
        address indexed teller,
        address indexed queue,
        address indexed accountant,
        uint64 peripheryVersion,
        uint64 maxRateAge
    );
    event VedaPeripheryUpdated(
        uint64 indexed registryVersion,
        address indexed oldTeller,
        address indexed oldQueue,
        address oldAccountant,
        address newTeller,
        address newQueue,
        address newAccountant,
        uint256 validatedRate
    );
    event AuthorizedForwarderChanged(address indexed account, bool authorized);
    event MaxRateAgeUpdated(uint64 oldMaxRateAge, uint64 newMaxRateAge);
    event Deposited(address indexed earnVault, uint256 assets, uint256 engineShares);
    event Redeemed(address indexed receiver, uint256 engineShares, uint256 assets);
    event WithdrewExact(address indexed receiver, uint256 assets, uint256 engineSharesBurned);
    event RedeemRequested(bytes32 indexed requestId, address indexed assetOut, uint128 engineShares);
    event RedeemCancelledOnQueue(bytes32 indexed requestId, uint128 engineShares);
    event Settled(address indexed asset, uint256 amount, uint256 newTotal);
    event Unearmarked(address indexed asset, uint256 amount, uint256 newTotal);
    event Finalized(bytes32 indexed requestId, address indexed asset, uint256 amount);
    /// @notice A solved and tracked request whose payout transfer REVERTED (for example a frozen direct
    ///         receiver). Its funds stay earmarked in {settled} and the claim stays open so it degrades
    ///         to SKIP (never bricking the batch) and is recoverable via {claimRedeem} once payable.
    event FinalizeFailed(bytes32 indexed requestId, address indexed asset, uint256 amount);
    event RedeemClaimed(bytes32 indexed requestId, address indexed asset, uint256 amount);
    event ExternalSettlementRecovered(uint256 requestCount, uint256 recoveredAssets, uint256 claimed);
    event DustSwept(address indexed token, address indexed to, uint256 amount);

    error AlreadyInitialized();
    error AssetsNotArrived(bytes32 requestId);
    error BaseAssetSweepBlocked(uint256 unresolvedClaims);
    error CannotSweepEngineBacking();
    error ClaimNotClaimable(bytes32 requestId);
    error ClaimNotOpen(bytes32 requestId);
    error EarnVaultNotSet();
    error CreditExceedsBalance(address asset, uint256 have, uint256 wantTotal);
    error InvalidVenueShareDecimals();
    error InsufficientAssetsReceived(uint256 minimumAssets, uint256 actualAssets);
    error DepositsNotPaused();
    error DuplicateRequest(bytes32 requestId);
    error EmptyMetadata();
    error InvalidAsset(address expected, address actual);
    error InvalidMaxRateAge();
    error InvalidRateTimestamp(uint256 updatedAt, uint256 currentTime);
    error InvalidVedaPeriphery(address account);
    error InvalidVedaPeripheryWiring(address component, address expected, address actual);
    error InvalidTrackedRequest(bytes32 requestId);
    error InvalidVedaRateBounds(uint256 minRate, uint256 maxRate);
    error NoPublishedVedaPeriphery();
    error NoRecoverableClaims();
    error NoVenueSharesReceived();
    error NotAuthorizedForwarder(address caller);
    error NotEarnVault(address caller);
    error NotSelf();
    error QueueUnavailable();
    error QueueTrackingDisabled(address queue);
    error QueuedAssetsBelowMinimum(uint256 minimumAssets, uint256 actualAssets);
    error ReentrantCall();
    error RateChangedWithinTransaction(uint256 expected, uint256 actual);
    error RegistryEngineMismatch(address expected, address actual);
    error EngineSharesTooLarge(uint256 engineShares);
    error SolveUnderfunded(address asset, uint256 delivered, uint256 required);
    error StaleAccountantRate(uint256 updatedAt, uint256 currentTime, uint256 maxAge);
    error SweepExceedsAvailableBalance(address token, uint256 available, uint256 requested);
    error TransferFailed();
    error UnsupportedAccountantFreshness(address accountant);
    error UnexpectedAssetsReceived(uint256 expectedAssets, uint256 actualAssets);
    error UnexpectedVenueSharesQueued(uint256 expectedShares, uint256 actualShares);
    error UnexpectedVenueSharesBurned(uint256 expectedShares, uint256 actualShares);
    error VedaRateOutOfBounds(uint256 rate, uint256 minRate, uint256 maxRate);
    error ZeroAddress();
    error ZeroMinimumQueuedAssets();

    modifier onlyEarnVault() {
        if (earnVault == address(0)) revert EarnVaultNotSet();
        if (msg.sender != earnVault) revert NotEarnVault(msg.sender);
        _;
    }

    modifier onlyForwarder() {
        if (!authorizedForwarder[msg.sender]) revert NotAuthorizedForwarder(msg.sender);
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    constructor(
        IVedaPeripheryRegistry peripheryRegistry_,
        address owner_,
        uint64 maxRateAge_,
        string memory name_,
        string memory symbol_
    ) Ownable(owner_) {
        if (maxRateAge_ == 0) revert InvalidMaxRateAge();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyMetadata();
        _validateContract(address(peripheryRegistry_));
        IBoringVault vault_ = peripheryRegistry_.vault();
        address baseAsset_ = peripheryRegistry_.baseAsset();
        _validateContract(address(vault_));
        _validateContract(baseAsset_);
        uint64 version_ = peripheryRegistry_.version();
        if (version_ == 0) revert NoPublishedVedaPeriphery();
        ITeller teller_ = peripheryRegistry_.teller();
        IBoringQueue queue_ = peripheryRegistry_.queue();
        IAccountant accountant_ = peripheryRegistry_.accountant();
        _validateVedaPeriphery(vault_, baseAsset_, teller_, queue_, accountant_, maxRateAge_, 1, type(uint256).max);
        peripheryRegistry = peripheryRegistry_;
        vault = vault_;
        teller = teller_;
        queue = queue_;
        accountant = accountant_;
        peripheryVersion = version_;
        maxRateAge = maxRateAge_;
        uint8 shareDecimals = vault_.decimals();
        if (shareDecimals > 77) revert InvalidVenueShareDecimals();
        _shareScale = 10 ** uint256(shareDecimals);
        baseAsset = baseAsset_;
        _name = name_;
        _symbol = symbol_;

        emit VedaEngineInitialized(address(teller_), address(queue_), address(accountant_), version_, maxRateAge_);
    }

    /// @notice One-time binding of the sole client earnVault (the factory deploys the EarnVault after the
    ///         engine). Owner-gated, set-once.
    function initializeEarnVault(address earnVault_) external onlyOwner {
        _initializeEarnVault(earnVault_);
    }

    /// @notice One-time binding followed by an immediate ownership transfer during setup.
    /// @dev The atomic setup path intentionally bypasses the pending-owner acceptance step.
    function initializeEarnVault(address earnVault_, address finalOwner_) external onlyOwner {
        if (finalOwner_ == address(0)) revert ZeroAddress();
        _initializeEarnVault(earnVault_);
        _transferOwnership(finalOwner_);
    }

    function _initializeEarnVault(address earnVault_) internal {
        if (earnVault != address(0)) revert AlreadyInitialized();
        if (earnVault_ == address(0)) revert ZeroAddress();
        address registeredEngine = peripheryRegistry.engine();
        if (registeredEngine != address(this)) {
            revert RegistryEngineMismatch(address(this), registeredEngine);
        }
        earnVault = earnVault_;
        emit EarnVaultInitialized(earnVault_);
    }

    /// @notice Activates the latest Teller, optional Queue, and Accountant published by the immutable registry.
    /// @dev The BoringVault owner chooses the tuple in the dedicated registry. The wrapper owner can only
    ///      coordinate activation after pausing deposits and applying wrapper-specific safe-rate bounds.
    ///      Existing claims remain bound to their originating Queue.
    function syncVedaPeriphery(uint256 minRate, uint256 maxRate) external onlyOwner nonReentrant {
        _requireDepositsPaused();
        uint64 newVersion = peripheryRegistry.version();
        if (newVersion == 0) revert NoPublishedVedaPeriphery();
        ITeller newTeller = peripheryRegistry.teller();
        IBoringQueue newQueue = peripheryRegistry.queue();
        IAccountant newAccountant = peripheryRegistry.accountant();
        uint256 validatedRate = _validateVedaPeriphery(
            vault, baseAsset, newTeller, newQueue, newAccountant, maxRateAge, minRate, maxRate
        );

        ITeller oldTeller = teller;
        IBoringQueue oldQueue = queue;
        IAccountant oldAccountant = accountant;
        if (address(oldQueue) != address(0) && address(oldQueue) != address(newQueue)) {
            _forceApprove(address(vault), address(oldQueue), 0);
        }

        teller = newTeller;
        queue = newQueue;
        accountant = newAccountant;
        peripheryVersion = newVersion;
        _checkpointRate(validatedRate);
        emit VedaPeripheryUpdated(
            newVersion,
            address(oldTeller),
            address(oldQueue),
            address(oldAccountant),
            address(newTeller),
            address(newQueue),
            address(newAccountant),
            validatedRate
        );
    }

    /// @notice Updates the maximum age accepted for the Accountant's latest rate report.
    /// @dev The wrapper owner may change this policy only while new exposure is paused.
    function setMaxRateAge(uint64 newMaxRateAge) external onlyOwner {
        if (newMaxRateAge == 0) revert InvalidMaxRateAge();
        _requireDepositsPaused();
        uint64 oldMaxRateAge = maxRateAge;
        maxRateAge = newMaxRateAge;
        emit MaxRateAgeUpdated(oldMaxRateAge, newMaxRateAge);
    }

    /// @notice Manage the `VedaForwardingSolver`(s) allowed to credit-and-forward. Owner-managed (NOT
    ///         set-once) BY DESIGN: the wallet solver seat + third-party seats sit behind a SINGLE
    ///         engine forwarder (the FS, which itself gates WHO may trigger via its own
    ///         `isAuthorizedSolver` allowlist), and the FS can be rotated/upgraded as a migration event
    ///         without redeploying the engine (the engine is deployed BEFORE the FS, so the FS cannot be
    ///         an immutable constructor arg).
    /// @dev TRUST NOTE (accepted within the operator-trust envelope): a malicious or mis-set forwarder
    ///      cannot STEAL — {forwardSolved} credits are bounded by the real balance and every payout goes
    ///      to the RECEIVER stored at request time by the EarnVault, never to the caller. The residual power
    ///      (authorizing an EOA forwarder to credit {settled} from donated/inert balance and decouple
    ///      payout from a real solve) is exactly why `owner` MUST be a timelock/multisig. Keep this seat,
    ///      {cancelRedeem} on the EarnVault, the forwarding solver owner, and the Veda RolesAuthority
    ///      admin under the SAME owner-managed key set.
    function setAuthorizedForwarder(address account, bool authorized) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        authorizedForwarder[account] = authorized;
        emit AuthorizedForwarderChanged(account, authorized);
    }

    // ------------------------------------------------------------------
    // IEarnEngine immediate execution — onlyEarnVault
    // ------------------------------------------------------------------

    function asset() external view returns (address) {
        return baseAsset;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function shareScale() external view returns (uint256) {
        return _shareScale;
    }

    /// @notice Raw BoringVault shares held by the engine for the EarnVault. Queued shares are excluded
    ///         automatically (they leave the engine's vault balance when filed).
    function totalShares() public view returns (uint256) {
        return vault.balanceOf(address(this));
    }

    /// @notice Pull `assets` of base asset from the EarnVault, route through the Teller's permissioned
    ///         bulk-deposit path so RAW SHARES mint to THIS engine without a holder share lock, and
    ///         return the measured raw-share delta. The earnVault converts that delta through its normalized
    ///         anchor rather than treating raw share units as EarnShare units.
    function deposit(uint256 assets) external onlyEarnVault nonReentrant returns (uint256 engineShares) {
        _requireFreshAccountantRate(accountant, maxRateAge);
        _checkpointRate();
        _pull(baseAsset, msg.sender, assets);
        // enter() pulls from the engine into the vault, so approve the VAULT (not the teller).
        _approveFromZero(baseAsset, address(vault), assets);

        uint256 before = vault.balanceOf(address(this));
        // Permissioned bulk deposit: pull from msg.sender == engine, mint unlocked raw shares to
        // `to` == engine. The engine must hold Veda's external bulk-deposit authority.
        teller.bulkDeposit(baseAsset, assets, 0, address(this));
        engineShares = vault.balanceOf(address(this)) - before;
        _forceApprove(baseAsset, address(vault), 0);
        if (engineShares == 0) revert NoVenueSharesReceived();
        emit Deposited(msg.sender, assets, engineShares);
    }

    /// @notice Immediate buffer exit through Veda's permissioned bulk path. Burns `engineShares` raw
    ///         venue shares from the engine and pushes base asset STRAIGHT to `receiver`.
    ///         Hard-reverts when the buffer is dry (no partial fill).
    function redeem(uint256 engineShares, address receiver, uint256 minAssets)
        external
        onlyEarnVault
        nonReentrant
        returns (uint256 assets)
    {
        if (receiver == address(0)) revert ZeroAddress();
        _checkpointRate();
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 receiverAssetsBefore = IERC20Like(baseAsset).balanceOf(receiver);
        teller.bulkWithdraw(baseAsset, engineShares, minAssets, receiver);
        _requireVenueSharesBurned(sharesBefore, engineShares);
        assets = _balanceIncrease(baseAsset, receiver, receiverAssetsBefore);
        if (assets < minAssets) revert InsufficientAssetsReceived(minAssets, assets);
        emit Redeemed(receiver, engineShares, assets);
    }

    /// @notice Exact-asset synthesized exit. Computes engine shares needed for exactly `assets`, exits to
    ///         the engine with `minimumAssets = assets` as an underpay-impossible backstop, then
    ///         forwards EXACTLY `assets` to `receiver` (sub-1-share dust stays on the engine, sweepable).
    function withdraw(uint256 assets, address receiver)
        external
        onlyEarnVault
        nonReentrant
        returns (uint256 engineShares)
    {
        if (receiver == address(0)) revert ZeroAddress();
        uint256 currentRate = _checkpointRate();
        engineShares = _engineSharesForAssets(assets, currentRate);
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 engineAssetsBefore = IERC20Like(baseAsset).balanceOf(address(this));
        // to == engine so any over-delivery (dust) rests here; receiver gets exactly `assets`.
        teller.bulkWithdraw(baseAsset, engineShares, assets, address(this));
        _requireVenueSharesBurned(sharesBefore, engineShares);
        uint256 deliveredAssets = _balanceIncrease(baseAsset, address(this), engineAssetsBefore);
        if (deliveredAssets < assets) revert InsufficientAssetsReceived(assets, deliveredAssets);

        uint256 receiverAssetsBefore = IERC20Like(baseAsset).balanceOf(receiver);
        _push(baseAsset, receiver, assets);
        uint256 receivedAssets = _balanceIncrease(baseAsset, receiver, receiverAssetsBefore);
        if (receivedAssets != assets) revert UnexpectedAssetsReceived(assets, receivedAssets);
        emit WithdrewExact(receiver, assets, engineShares);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256 engineShares) {
        return _engineSharesForAssets(assets);
    }

    function previewRedeem(uint256 engineShares) external view returns (uint256 assets) {
        return Math.mulDiv(engineShares, accountant.getRateInQuoteSafe(baseAsset), _shareScale);
    }

    function valueOf(uint256 engineShares) external view returns (uint256 assets) {
        return Math.mulDiv(engineShares, accountant.getRateInQuoteSafe(baseAsset), _shareScale);
    }

    function totalAssets() external view returns (uint256 assets) {
        return Math.mulDiv(vault.balanceOf(address(this)), accountant.getRateInQuoteSafe(baseAsset), _shareScale);
    }

    // ------------------------------------------------------------------
    // IEarnEngineAsyncRedeem — requestRedeem / cancelRedeem onlyEarnVault; forwardSolved onlyForwarder
    // ------------------------------------------------------------------

    /// @notice File a queued exit AS THE ENGINE (request.user == engine). Approves the tracking queue on
    ///         the raw vault, requests the withdrawal, reads the canonical request back by ID, and stores
    ///         only the amounts Tempo needs for cancellation and settlement accounting.
    function requestRedeem(uint256 engineShares, bytes calldata requestData)
        external
        onlyEarnVault
        nonReentrant
        returns (bytes32 requestId)
    {
        if (engineShares > type(uint128).max) revert EngineSharesTooLarge(engineShares);
        VedaRedeemRequest memory request = abi.decode(requestData, (VedaRedeemRequest));
        if (request.assetOut != baseAsset) revert InvalidAsset(baseAsset, request.assetOut);
        if (request.minQueuedAssets == 0) revert ZeroMinimumQueuedAssets();
        // Bounded above, so the downcast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 queueShares = uint128(engineShares);
        IBoringQueue requestQueue = queue;
        if (address(requestQueue) == address(0)) revert QueueUnavailable();
        _checkpointRate();
        uint256 sharesBefore = vault.balanceOf(address(this));
        _approveFromZero(address(vault), address(requestQueue), queueShares);
        requestId = requestQueue.requestOnChainWithdraw(
            request.assetOut, queueShares, request.discountBps, request.secondsToDeadline
        );
        _requireVenueSharesQueued(sharesBefore, queueShares);
        OnChainWithdraw memory trackedRequest = requestQueue.getOnChainWithdraw(requestId);
        if (
            requestQueue.getRequestId(trackedRequest) != requestId || trackedRequest.user != address(this)
                || trackedRequest.assetOut != request.assetOut || trackedRequest.amountOfShares != queueShares
                || trackedRequest.secondsToDeadline != request.secondsToDeadline
        ) {
            revert InvalidTrackedRequest(requestId);
        }
        // Queue entry transfers existing BoringVault shares without changing total supply, so unlike
        // Teller mint/burn paths the safe rate must remain identical across the external call.
        _checkpointRate();
        _forceApprove(address(vault), address(requestQueue), 0);
        if (trackedRequest.amountOfAssets < request.minQueuedAssets) {
            revert QueuedAssetsBelowMinimum(request.minQueuedAssets, trackedRequest.amountOfAssets);
        }

        QueueClaim storage c = _claims[requestId];
        // Queue nonces are deployment-local, so a replacement Queue can derive a historical ID.
        // Never reuse an ID: the paired EarnVault also keys persistent claim accounting by requestId.
        if (address(c.requestQueue) != address(0)) revert DuplicateRequest(requestId);
        c.status = ClaimStatus.Open;
        c.requestQueue = requestQueue;
        openClaimsByQueue[address(requestQueue)]++;
        unresolvedClaimCount++;
        c.amountOfShares = queueShares;
        c.amountOfAssets = trackedRequest.amountOfAssets;
        emit RedeemRequested(requestId, request.assetOut, queueShares);
    }

    /// @notice Cancel by request ID through the tracking queue so raw shares return to the engine. The
    ///         EarnVault mints a measured current-value re-entry to the request's stored receiver.
    function cancelRedeem(bytes32 requestId) external onlyEarnVault nonReentrant returns (uint256 engineShares) {
        QueueClaim storage c = _claims[requestId];
        ClaimStatus status = c.status;
        if (status != ClaimStatus.Open) revert ClaimNotOpen(requestId);
        _checkpointRate();
        c.status = ClaimStatus.Cancelled;
        c.requestQueue.cancelOnChainWithdrawUsingRequestId(requestId);
        // Cancellation returns existing shares and must not mutate the transaction's valuation.
        _checkpointRate();
        _closeClaim(c);
        engineShares = c.amountOfShares;
        emit RedeemCancelledOnQueue(requestId, c.amountOfShares);
    }

    /// @notice ATOMIC credit-and-forward, called ONLY by an authorized `VedaForwardingSolver` in the same
    ///         tx it drove the stock solve. Requires the MEASURED balance delta to fund every open,
    ///         tracked request in this solved batch, credits it into {settled} (bounded by the real
    ///         balance), then finalizes each request through the EarnVault.
    ///         Un-earmarks only TRUE surplus so `settled` never funds an unrelated claim, but PRESERVES
    ///         the earmark for any request that stayed open.
    ///
    /// @dev UN-PAYABLE-RECEIVER DEGRADE-TO-SKIP: each finalize runs in a try/catch (via a self-`external`
    ///      call) so a reverting payout transfer — for example a frozen DIRECT receiver — leaves that one
    ///      claim OPEN with its funds still earmarked and only that id skipped (FinalizeFailed), instead
    ///      of reverting the whole batch and un-doing the solve for every honest user. The stuck claim is
    ///      later recoverable via {claimRedeem} once payable.
    function forwardSolved(bytes32[] calldata requestIds, address asset_, uint256 delta)
        external
        onlyForwarder
        nonReentrant
        returns (uint256 claimed)
    {
        // Preserve the historical no-op behavior for a non-base asset. The authorized forwarder
        // should never take this path, but balance-bound any claimed delta exactly as before.
        if (asset_ != baseAsset) {
            if (delta != 0) {
                uint256 reserved = settled[asset_];
                uint256 want = reserved + delta;
                uint256 aggregateBalance = IERC20Like(asset_).balanceOf(address(this));
                if (want > aggregateBalance) revert CreditExceedsBalance(asset_, aggregateBalance, want);
                emit Settled(asset_, delta, want);
                emit Unearmarked(asset_, delta, reserved);
            }
            return 0;
        }
        uint256 required = _requiredAssets(requestIds);
        if (delta < required) revert SolveUnderfunded(asset_, delta, required);

        claimed = _creditAndFinalize(requestIds, asset_, delta);
    }

    /// @notice Owner recovery for Queue payouts delivered directly to this engine by an externally
    ///         authorized Veda solver that bypassed {VedaForwardingSolver}. The amount credited is
    ///         derived exclusively from the tracked open claims and remains balance-bounded.
    /// @dev The stock Queue does not expose a request-specific active-state proof. The owner must
    ///      verify the Queue's solve event before calling; this adds no authority beyond the owner's
    ///      existing ability to authorize a forwarder, but makes the exceptional recovery explicit.
    function recoverExternalSettlement(bytes32[] calldata requestIds)
        external
        onlyOwner
        nonReentrant
        returns (uint256 claimed)
    {
        uint256 required = _requiredAssets(requestIds);
        if (required == 0) revert NoRecoverableClaims();
        claimed = _creditAndFinalize(requestIds, baseAsset, required);
        emit ExternalSettlementRecovered(requestIds.length, required, claimed);
    }

    function _creditAndFinalize(bytes32[] calldata requestIds, address asset_, uint256 delta)
        private
        returns (uint256 claimed)
    {
        if (delta != 0) {
            uint256 have = IERC20Like(asset_).balanceOf(address(this));
            uint256 want = settled[asset_] + delta;
            if (have < want) revert CreditExceedsBalance(asset_, have, want);
            settled[asset_] = want;
            emit Settled(asset_, delta, want);
        }
        uint256 consumed;
        uint256 stillOwed; // amounts owed to solved batch requests whose payout failed
        for (uint256 i = 0; i < requestIds.length; i++) {
            bytes32 id = requestIds[i];
            QueueClaim storage c = _claims[id];
            if (c.status != ClaimStatus.Open) continue;
            uint256 amt = c.amountOfAssets;
            // DEGRADE-TO-SKIP: finalize in a self-`external` call so a reverting payout is caught and the
            // claim is left open with its funds still earmarked (nothing in this frame commits on revert).
            try this.finalizeOneExternal(id) {
                consumed += amt;
                claimed++;
            } catch {
                stillOwed += amt;
                c.status = ClaimStatus.Claimable;
                emit FinalizeFailed(id, asset_, amt);
            }
        }
        // NO-CROSS-SOLVE-RESIDUE: un-earmark this batch's own un-consumed surplus back to inert
        // (sweepable) balance so `settled` only ever reflects funds owed to open requests — BUT keep the
        // earmark for `stillOwed` (solved requests whose payout failed) so {claimRedeem} can pay them later.
        uint256 keep = consumed + stillOwed;
        if (delta > keep) {
            uint256 residue = delta - keep;
            settled[asset_] -= residue;
            emit Unearmarked(asset_, residue, settled[asset_]);
        }
    }

    /// @notice Self-only finalize shim: performs the asset push + earnVault.finalizeRedeem for ONE
    ///         tracked and funded request in a distinct call frame so {forwardSolved} can try/catch a
    ///         reverting payout without committing any partial state. Not callable externally.
    function finalizeOneExternal(bytes32 requestId) external {
        if (msg.sender != address(this)) revert NotSelf();
        _commitFinalize(requestId);
    }

    /// @notice DECOUPLED RECOVERY: pays a still-open, tracked, explicitly claimable claim out of {settled}.
    ///         Used to drain a claim that {forwardSolved} left open because its payout reverted (for
    ///         example a receiver that has since been un-frozen). PERMISSIONLESS by design: it only ever
    ///         pays the stored receiver the tracked amount out of already-earmarked funds, so a caller
    ///         gains nothing. HARD-reverts (unlike the batch path's skip) so a single-claim caller learns
    ///         why it is not yet claimable.
    function claimRedeem(bytes32 requestId) external nonReentrant returns (uint256 amount) {
        QueueClaim storage c = _claims[requestId];
        if (c.status == ClaimStatus.Open) revert ClaimNotClaimable(requestId);
        if (c.status != ClaimStatus.Claimable) revert ClaimNotOpen(requestId);
        if (settled[baseAsset] < c.amountOfAssets) revert AssetsNotArrived(requestId);
        amount = c.amountOfAssets;
        _commitFinalize(requestId);
        emit RedeemClaimed(requestId, baseAsset, amount);
    }

    // ------------------------------------------------------------------
    // Owner ops
    // ------------------------------------------------------------------

    /// @notice Sweep sub-1-share exact-withdraw dust, or an un-earmarked payout-asset surplus, or any
    ///         stray token. Three bounds: (1) the engine's BACKING — the BoringVault share token — can
    ///         NEVER be swept; (2) the base asset cannot be swept while any claim is unresolved; and
    ///         (3) every other token remains bounded by funds earmarked in {settled}.
    function sweepDust(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        // Backing custody: raw BoringVault shares are the engine's entire backing and are NEVER dust.
        if (token == address(vault)) revert CannotSweepEngineBacking();
        // The Queue can pay `request.user == engine` through any authorized Veda solver. Until every
        // claim closes, an unearmarked base-asset balance may therefore be an externally solved payout.
        uint256 unresolved = unresolvedClaimCount;
        if (token == baseAsset && unresolved != 0) revert BaseAssetSweepBlocked(unresolved);
        uint256 have = IERC20Like(token).balanceOf(address(this));
        // Never touch aggregate funds earmarked to request-level claimable failed payouts.
        uint256 reserved = settled[token];
        uint256 available = have > reserved ? have - reserved : 0;
        if (amount > available) revert SweepExceedsAvailableBalance(token, available, amount);
        _push(token, to, amount);
        emit DustSwept(token, to, amount);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function rate() external view returns (uint256) {
        return accountant.getRateInQuoteSafe(baseAsset);
    }

    /// @notice Timestamp used by the deposit freshness guard for the active Accountant.
    /// @dev Supports Veda YieldStreaming and step-accounting Accountants and fails closed for any
    ///      other freshness ABI. Operational validators should read this view so they exercise the
    ///      same compatibility path as deposits and periphery activation.
    function accountantRateUpdatedAt() external view returns (uint64) {
        return _accountantRateUpdatedAt(accountant);
    }

    /// @notice Whether the active Accountant report satisfies this wrapper's fee-valuation age policy.
    function isFeeValuationFresh() external view returns (bool) {
        uint256 updatedAt = _accountantRateUpdatedAt(accountant);
        uint256 currentTime = block.timestamp;
        return updatedAt != 0 && updatedAt <= currentTime && currentTime - updatedAt <= maxRateAge;
    }

    function getClaim(bytes32 requestId) external view returns (ClaimStatus status, OnChainWithdraw memory request) {
        QueueClaim storage c = _claims[requestId];
        if (c.status == ClaimStatus.None) return (ClaimStatus.None, request);
        return (c.status, c.requestQueue.getOnChainWithdraw(requestId));
    }

    /// @notice Queue deployment that created `requestId`; retained across periphery rotations.
    function claimQueue(bytes32 requestId) external view returns (address) {
        return address(_claims[requestId].requestQueue);
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IEarnEngine).interfaceId
            || interfaceId == type(IEarnEngineRedeem).interfaceId
            || interfaceId == type(IEarnEngineExactWithdraw).interfaceId
            || interfaceId == type(IEarnEngineFeeValuation).interfaceId
            || (interfaceId == type(IEarnEngineAsyncRedeem).interfaceId && address(queue) != address(0));
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    /// @dev shares = ceil(assets * shareScale / rateInAsset). Matches the teller's shares-for-assets so
    ///      `minimumAssets = assets` is always satisfiable and the receiver is never underpaid.
    function _engineSharesForAssets(uint256 assets) internal view returns (uint256) {
        uint256 r = accountant.getRateInQuoteSafe(baseAsset);
        return _engineSharesForAssets(assets, r);
    }

    function _engineSharesForAssets(uint256 assets, uint256 r) private view returns (uint256) {
        if (r == 0) return 0;
        return Math.mulDiv(assets, _shareScale, r, Math.Rounding.Ceil);
    }

    /// @dev Pins wrapper entry/exit to one safe Accountant quote per transaction. Transient storage
    ///      persists across every call frame in the transaction and clears automatically afterward.
    ///      Each economic operation checkpoints before calling Veda. Do not checkpoint again after
    ///      Teller: a yield-streaming Accountant derives its live rate from BoringVault total supply,
    ///      so a legitimate mint or burn can change the quote as part of that same operation. A later
    ///      engine operation in the transaction still observes the change and reverts atomically.
    function _checkpointRate() internal returns (uint256 currentRate) {
        currentRate = accountant.getRateInQuoteSafe(baseAsset);
        _checkpointRate(currentRate);
    }

    function _checkpointRate(uint256 currentRate) private {
        if (_rateCheckpointed) {
            if (_rateAtTransaction != currentRate) {
                revert RateChangedWithinTransaction(_rateAtTransaction, currentRate);
            }
        } else {
            _rateCheckpointed = true;
            _rateAtTransaction = currentRate;
        }
    }

    function _requireVenueSharesBurned(uint256 sharesBefore, uint256 expectedShares) private view {
        uint256 sharesAfter = vault.balanceOf(address(this));
        uint256 actualShares = sharesBefore >= sharesAfter ? sharesBefore - sharesAfter : 0;
        if (sharesAfter > sharesBefore || actualShares != expectedShares) {
            revert UnexpectedVenueSharesBurned(expectedShares, actualShares);
        }
    }

    function _requireVenueSharesQueued(uint256 sharesBefore, uint256 expectedShares) private view {
        uint256 sharesAfter = vault.balanceOf(address(this));
        uint256 actualShares = sharesBefore >= sharesAfter ? sharesBefore - sharesAfter : 0;
        if (sharesAfter > sharesBefore || actualShares != expectedShares) {
            revert UnexpectedVenueSharesQueued(expectedShares, actualShares);
        }
    }

    function _balanceIncrease(address token, address account, uint256 balanceBefore)
        private
        view
        returns (uint256 increase)
    {
        uint256 balanceAfter = IERC20Like(token).balanceOf(account);
        if (balanceAfter > balanceBefore) increase = balanceAfter - balanceBefore;
    }

    /// @dev Latch the claim, decrement the earmark, hand the solved assets to the EarnVault, and call
    ///      earnVault.finalizeRedeem (which pays the stored receiver; EarnShare burned at request). Always entered via
    ///      a frame that fully reverts on failure ({finalizeOneExternal} in a try/catch, or {claimRedeem}
    ///      directly) so a reverting payout leaves NO partial state. Callers MUST pre-check
    ///      open/request-level entitlement/aggregate funding as appropriate for their path.
    function _commitFinalize(bytes32 requestId) private {
        QueueClaim storage c = _claims[requestId];
        ClaimStatus status = c.status;
        if (status != ClaimStatus.Open && status != ClaimStatus.Claimable) revert ClaimNotOpen(requestId);
        uint256 amount = c.amountOfAssets;
        address assetOut = baseAsset;
        settled[assetOut] -= amount;
        c.status = ClaimStatus.Paid;
        _closeClaim(c);

        // Hand solved assets to the EarnVault, which pays the stored receiver and closes the claim.
        _push(assetOut, earnVault, amount);
        IEarnVaultFinalize(earnVault).finalizeRedeem(requestId, assetOut, amount);
        emit Finalized(requestId, assetOut, amount);
    }

    function _requiredAssets(bytes32[] calldata requestIds) private view returns (uint256 required) {
        for (uint256 i = 0; i < requestIds.length; i++) {
            bytes32 id = requestIds[i];
            QueueClaim storage c = _claims[id];
            if (c.status != ClaimStatus.Open) continue;
            required += c.amountOfAssets;
        }
    }

    function _closeClaim(QueueClaim storage c) private {
        openClaimsByQueue[address(c.requestQueue)]--;
        unresolvedClaimCount--;
    }

    function _validateContract(address account) private view {
        if (account == address(0)) revert ZeroAddress();
        if (account.code.length == 0) revert InvalidVedaPeriphery(account);
    }

    function _validateVedaPeriphery(
        IBoringVault expectedVault,
        address expectedBaseAsset,
        ITeller newTeller,
        IBoringQueue newQueue,
        IAccountant newAccountant,
        uint64 maxRateAge_,
        uint256 minRate,
        uint256 maxRate
    ) private view returns (uint256 validatedRate) {
        if (minRate == 0 || minRate > maxRate) revert InvalidVedaRateBounds(minRate, maxRate);
        _validateContract(address(newTeller));
        _validateContract(address(newAccountant));

        address expectedVaultAddress = address(expectedVault);
        _requireWiring(address(newTeller), expectedVaultAddress, newTeller.vault());
        _requireWiring(address(newTeller), address(newAccountant), newTeller.accountant());
        if (address(newQueue) != address(0)) {
            _validateContract(address(newQueue));
            _requireWiring(address(newQueue), expectedVaultAddress, newQueue.boringVault());
            _requireWiring(address(newQueue), address(newAccountant), newQueue.accountant());
            if (!newQueue.trackWithdrawsOnChain()) revert QueueTrackingDisabled(address(newQueue));
        }
        _requireWiring(address(newAccountant), expectedVaultAddress, newAccountant.vault());
        _requireWiring(address(newAccountant), expectedBaseAsset, newAccountant.base());

        _requireFreshAccountantRate(newAccountant, maxRateAge_);
        validatedRate = newAccountant.getRateInQuoteSafe(expectedBaseAsset);
        if (validatedRate < minRate || validatedRate > maxRate) {
            revert VedaRateOutOfBounds(validatedRate, minRate, maxRate);
        }
    }

    function _requireWiring(address component, address expected, address actual) private pure {
        if (actual != expected) revert InvalidVedaPeripheryWiring(component, expected, actual);
    }

    function _requireDepositsPaused() private view {
        if (earnVault != address(0) && !IEarnVaultPause(earnVault).depositsPaused()) revert DepositsNotPaused();
    }

    /// @dev Fail closed on a missing, future, or older-than-policy rate report. This guard is
    ///      deposit-only so stale reporting cannot freeze immediate or queued exits. YieldStreaming
    ///      exposes a dedicated strategist timestamp; step accounting exposes the rate update in its
    ///      canonical AccountantState tuple.
    function _requireFreshAccountantRate(IAccountant accountant_, uint64 maxRateAge_) private view {
        uint256 updatedAt = _accountantRateUpdatedAt(accountant_);
        uint256 currentTime = block.timestamp;
        if (updatedAt == 0 || updatedAt > currentTime) revert InvalidRateTimestamp(updatedAt, currentTime);
        if (currentTime - updatedAt > maxRateAge_) {
            revert StaleAccountantRate(updatedAt, currentTime, maxRateAge_);
        }
    }

    function _accountantRateUpdatedAt(IAccountant accountant_) private view returns (uint64 updatedAt) {
        (bool success, bytes memory result) = address(accountant_)
            .staticcall(abi.encodeWithSelector(IYieldStreamingAccountant.lastStrategistUpdateTimestamp.selector));
        if (success && result.length == 32) return abi.decode(result, (uint64));

        (success, result) =
            address(accountant_).staticcall(abi.encodeWithSelector(IStepAccountant.accountantState.selector));
        if (!success || result.length != 12 * 32) revert UnsupportedAccountantFreshness(address(accountant_));

        (,,,,,,, updatedAt,,,,) = abi.decode(
            result, (address, uint96, uint128, uint128, uint96, uint16, uint16, uint64, bool, uint24, uint16, uint16)
        );
    }

    function _pull(address token, address from, uint256 amount) private {
        if (!IERC20Like(token).transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _push(address token, address to, uint256 amount) private {
        if (!IERC20Like(token).transfer(to, amount)) revert TransferFailed();
    }

    /// @dev Every mutable approval is cleared before the successful frame returns. A reverted frame
    ///      also rolls the approval back, so the zero-at-rest invariant permits a direct exact set.
    function _approveFromZero(address token, address spender, uint256 amount) private {
        if (!IERC20Like(token).approve(spender, amount)) revert TransferFailed();
    }

    /// @dev Zero-then-set safe approve with bool checks (USDT-style).
    function _forceApprove(address token, address spender, uint256 amount) private {
        if (!IERC20Like(token).approve(spender, 0)) revert TransferFailed();
        if (amount != 0) {
            if (!IERC20Like(token).approve(spender, amount)) revert TransferFailed();
        }
    }
}
