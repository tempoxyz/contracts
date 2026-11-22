// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../interfaces/earn/IEarnVault.sol";
import { IERC20Like } from "../../interfaces/external/IERC20Like.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title EarnMerkleRewardDistributor
/// @notice EarnShare-only settlement rail for cumulative, offchain-computed public-holder rewards.
/// @dev The owner may pull an approved base-asset budget from a selected funder and deposit it through
///      the immutable EarnVault. Only that EarnVault mints the fully backed EarnShare held here. Root-valid
///      pushes and claims are permissionless because every transfer is fixed to its committed recipient.
///      Payouts are recorded per leaf index, which the root binds to one recipient for the campaign's life.
/// Specs for solar-verify (docs/earn/modules/rewards.md, earn/src/AGENTS.md "Reward periphery"):
/// The transient `_entered` lock guards funding, pushes, claims and returns.
/// @custom:reentrancy-guard _entered
/// Ghost sum of every leaf index's cumulativePaid, updated at each cumulativePaid write.
/// @custom:ghost uint256 sumPaid
/// Ghost record of the EarnShare balance _publishRoot measured.
/// @custom:ghost uint256 measuredBalance
/// Ghost snapshots of the root total and version taken by fundAndPublishRoot and pushBatch.
/// @custom:ghost uint256 minTotal
/// @custom:ghost uint256 minVersion
/// Owner calls that stay open under the lock (publishRoot) never lower the root total or version.
/// @custom:lock-stable _rootTotalEntitlement >= minTotal
/// @custom:lock-stable rootVersion >= minVersion
/// Measured solvency against entitlement: paid never exceeds the published cumulative root total.
/// @custom:invariant _totalPaid <= _rootTotalEntitlement
/// Conservation: totalPaid is the sum of every leaf index's cumulativePaid, so no index has more, and
/// every record fits its uint128 lane (the root total fits uint120).
/// @custom:invariant sumPaid == _totalPaid
/// @custom:invariant forall uint256 i :: cumulativePaid(i) <= _totalPaid
/// A root exists exactly when a version was published; before any root nothing is owed.
/// @custom:invariant rootVersion == 0 <==> merkleRoot == bytes32(0)
/// @custom:invariant rootVersion == 0 <==> statementHash == bytes32(0)
/// @custom:invariant rootVersion == 0 ==> _rootTotalEntitlement == 0
/// The vault, its asset and EarnShare, the treasury and the campaign are fixed and nonzero.
/// @custom:invariant address(earnVault) != address(0) && asset != address(0) && earnShare != address(0)
/// @custom:invariant treasury != address(0) && campaignId != bytes32(0)
/// Ghost model of the EarnShare inventory: the balance _publishRoot measured, less every payout since.
/// @custom:ghost uint256 heldShares
/// Ghost flag set once returnUnspent ends the campaign and sends the remaining inventory to the treasury.
/// @custom:ghost bool unspentReturned
/// Solvency: until the campaign's inventory is returned, the modelled inventory covers everything the
/// published root still owes (rootTotalEntitlement - totalPaid).
/// @custom:invariant !unspentReturned ==> _rootTotalEntitlement - _totalPaid <= heldShares
/// Not proved: that the distributor's actual EarnShare balance follows heldShares. Payouts trust the
/// transfer's return value and do not measure the distributor's or the recipient's balance change.
/// Not proved: the per-holder principal cap on EarnShare eligibility. It is applied offchain when the
/// cumulative root is computed; onchain, only the root total bounds what is paid.
/// Not proved: that each leaf index belongs to one recipient. The owner's root binds an index to its
/// recipient; the statement builder assigns indexes insert-only, and aliasing stays within the root total.
contract EarnMerkleRewardDistributor is Ownable2Step {
    error OwnershipRenunciationDisabled();
    enum SkipReason {
        ZeroRecipient,
        NothingOwed,
        RootTotalExceeded,
        TransferFailed
    }

    /// @dev Two leaf indexes share one payout slot: index 2k in the low 128 bits (lane 0) and index
    ///      2k + 1 in the high 128 bits (lane 1). Tempo charges every zero-to-nonzero slot write as a new
    ///      slot, so the second index of a pair costs no new slot.
    struct PaidLanes {
        uint128 lane0;
        uint128 lane1;
    }

    IEarnVault public immutable earnVault;
    address public immutable asset;
    address public immutable earnShare;
    address public immutable treasury;
    bytes32 public immutable campaignId;
    uint40 public immutable claimDeadline;

    bytes32 public merkleRoot;
    bytes32 public statementHash;
    // One slot with the pause flag, so a claim's pause check reads the slot its payout updates. Every
    // per-index amount is bounded by the root total, so all of them fit uint120.
    uint120 private _rootTotalEntitlement;
    uint120 private _totalPaid;
    bool public paused;
    uint64 public rootVersion;

    mapping(uint256 slot => PaidLanes lanes) private _paid;
    /// @notice The settlement ID of the latest fundAndPublishRoot; the same ID is refused next time.
    bytes32 public lastSettlementId;

    bool private transient _entered;

    event AssetsFunded(address indexed funder, uint256 assets, uint256 earnShares);
    event RootPublished(
        uint64 indexed version, bytes32 indexed root, bytes32 indexed statementHash, uint256 totalEntitlement
    );
    event SettlementPublished(bytes32 indexed settlementId, uint64 indexed version);
    event RewardClaimed(address indexed recipient, uint256 amount, uint256 cumulativeAmount);
    event PayoutSkipped(address indexed recipient, uint256 cumulativeAmount, SkipReason reason);
    event BatchPushed(
        uint64 indexed version,
        bytes32 indexed batchHash,
        uint256 attemptedCount,
        uint256 paidCount,
        uint256 paidEarnShares,
        uint256 skippedCount
    );
    event PausedSet(bool paused);
    event UnspentReturned(address indexed treasury, uint256 earnShares);

    error ClaimsExpired();
    error ClaimsNotExpired();
    /// @dev Raised by the EarnVault's deposit, which funding calls, while its deposits are paused.
    error DepositsPaused();
    error EntitlementTooLarge(uint256 totalEntitlement);
    error InsufficientFunding(uint256 requiredBalance, uint256 actualBalance);
    error InvalidArrayLengths();
    error InvalidEarnVault();
    error InvalidMultiproof();
    error NothingOwed();
    error Paused();
    error PausedLiabilityIncrease();
    error RootTotalExceeded(uint256 requestedAmount, uint256 remainingEntitlement);
    error RootTotalDecreased(uint256 previousTotal, uint256 nextTotal);
    error ReentrantCall();
    error SettlementAlreadyConsumed(bytes32 settlementId);
    error ZeroSettlementId();
    error StaleRootVersion(uint64 expected, uint64 actual);
    error TokenCallFailed();
    error TokenCallFalse();
    error UnexpectedEarnShares(uint256 reported, uint256 measured);
    error UnexpectedRetainedAssets(uint256 beforeBalance, uint256 afterBalance);
    error ZeroAddress();
    error ZeroAmount();
    error ZeroCampaignId();
    error ZeroDeadline();
    error ZeroMinimumEarnShares();
    error ZeroRoot();
    error ZeroStatementHash();

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    /// The claim window ends in the future.
    /// @custom:ensures claimDeadline == claimDeadline_ && claimDeadline_ > block.timestamp
    /// @custom:ensures earnVault == earnVault_ && treasury == treasury_ && campaignId == campaignId_
    constructor(IEarnVault earnVault_, address treasury_, bytes32 campaignId_, uint40 claimDeadline_, address owner_)
        Ownable(owner_)
    {
        if (address(earnVault_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (address(earnVault_).code.length == 0) revert InvalidEarnVault();
        if (campaignId_ == bytes32(0)) revert ZeroCampaignId();
        // forge-lint: disable-next-line(block-timestamp)
        if (claimDeadline_ <= block.timestamp) revert ZeroDeadline();

        address asset_ = earnVault_.asset();
        address earnShare_ = earnVault_.earnShare();
        if (asset_ == address(0) || earnShare_ == address(0)) revert InvalidEarnVault();
        if (asset_.code.length == 0 || earnShare_.code.length == 0) revert InvalidEarnVault();

        earnVault = earnVault_;
        asset = asset_;
        earnShare = earnShare_;
        treasury = treasury_;
        campaignId = campaignId_;
        claimDeadline = claimDeadline_;
        // A standing maximum allowance for the immutable EarnVault, set once: Tempo charges every zero-to-nonzero
        // allowance as a new storage slot, and the distributor holds pulled base asset only within a funding
        // call, which checks that none is retained.
        _safeApprove(asset_, address(earnVault_), type(uint256).max);
    }

    /// @notice Atomically funds a conservatively bounded interval and publishes its solvent root.
    /// @dev `minEarnShares` is a lower bound, not an exact quote. Any excess mint remains available
    ///      to fund later cumulative roots. The final solvency check accounts for both that inventory
    ///      and the shares minted by this call. The expected root version, which rises on every
    ///      publication, refuses a retry at the old version, and the previous settlement ID is refused
    ///      at any version. Only that one ID is kept; older IDs are logged by SettlementPublished.
    /// Only the owner funds and publishes, with a positive measured mint, while claims are active.
    /// @custom:ensures old(owner()) == msg.sender && !old(paused) && earnShares > 0
    /// Replay protection: the settlement ID is nonzero and differs from the previous one, which it replaces;
    /// the expected version matched and the version strictly increased, so a retry at the same expected
    /// version, or of the same settlement at a refreshed version, reverts.
    /// @custom:ensures settlementId != bytes32(0) && settlementId != old(lastSettlementId)
    /// @custom:ensures lastSettlementId == settlementId
    /// @custom:ensures old(rootVersion) == expectedRootVersion && rootVersion > old(rootVersion) && version == rootVersion
    /// The published root, statement and total are the arguments; the total fits uint120 and never decreases.
    /// @custom:ensures merkleRoot == root && statementHash == statementHash_ && _rootTotalEntitlement == totalEntitlement
    /// @custom:ensures totalEntitlement <= type(uint120).max
    /// @custom:ensures _rootTotalEntitlement >= old(_rootTotalEntitlement)
    /// Measured solvency: the outstanding liability is covered by the EarnShare balance measured at publication.
    /// @custom:ensures _rootTotalEntitlement - _totalPaid <= measuredBalance
    /// Funding never touches payout bookkeeping.
    /// @custom:ensures _totalPaid == old(_totalPaid)
    /// @custom:ensures forall uint256 i :: cumulativePaid(i) == old(cumulativePaid(i))
    function fundAndPublishRoot(
        bytes32 settlementId,
        uint64 expectedRootVersion,
        address funder,
        uint256 assets,
        uint256 minEarnShares,
        bytes32 root,
        uint256 totalEntitlement,
        bytes32 statementHash_
    ) external onlyOwner nonReentrant returns (uint256 earnShares, uint64 version) {
        if (settlementId == bytes32(0)) revert ZeroSettlementId();
        if (settlementId == lastSettlementId) revert SettlementAlreadyConsumed(settlementId);
        _requireRootVersion(expectedRootVersion);
        /// @custom:ghost minTotal = _rootTotalEntitlement
        /// @custom:ghost minVersion = rootVersion
        lastSettlementId = settlementId;
        uint256 earnShareBalance;
        (earnShares, earnShareBalance) = _fundWithAssets(funder, assets, minEarnShares);
        version = _publishRoot(root, totalEntitlement, statementHash_, earnShareBalance);
        emit SettlementPublished(settlementId, version);
    }

    /// @dev Returns the measured mint and the EarnShare balance measured after it. The EarnVault's deposit
    ///      refuses while its deposits are paused (DepositsPaused), which reverts the pull with it.
    function _fundWithAssets(address funder, uint256 assets, uint256 minEarnShares)
        private
        returns (uint256 earnShares, uint256 earnShareBalance)
    {
        _requireClaimsActive();
        if (funder == address(0)) revert ZeroAddress();
        if (assets == 0) revert ZeroAmount();
        if (minEarnShares == 0) revert ZeroMinimumEarnShares();

        uint256 assetBalanceBefore = IERC20Like(asset).balanceOf(address(this));
        uint256 earnShareBalanceBefore = IERC20Like(earnShare).balanceOf(address(this));
        _safeTransferFrom(asset, funder, address(this), assets);
        // The EarnVault pulls through the standing maximum allowance set at construction.
        uint256 reportedEarnShares = earnVault.deposit(assets, address(this), minEarnShares);

        uint256 assetBalanceAfter = IERC20Like(asset).balanceOf(address(this));
        if (assetBalanceAfter != assetBalanceBefore) {
            revert UnexpectedRetainedAssets(assetBalanceBefore, assetBalanceAfter);
        }
        earnShareBalance = IERC20Like(earnShare).balanceOf(address(this));
        earnShares = earnShareBalance - earnShareBalanceBefore;
        if (earnShares == 0) revert ZeroAmount();
        if (earnShares != reportedEarnShares) revert UnexpectedEarnShares(reportedEarnShares, earnShares);
        emit AssetsFunded(funder, assets, earnShares);
    }

    /// @notice Publishes a cumulative EarnShare entitlement root whose outstanding liability is funded.
    /// @dev While paused, only a same-total corrective statement may replace the current root.
    /// Only the owner publishes; the expected version matched and the version rose by one.
    /// @custom:ensures old(owner()) == msg.sender
    /// @custom:ensures old(rootVersion) == expectedRootVersion && rootVersion == old(rootVersion) + 1
    /// The total fits uint120 and never decreases, and while paused it stays the same.
    /// @custom:ensures totalEntitlement <= type(uint120).max
    /// @custom:ensures _rootTotalEntitlement >= old(_rootTotalEntitlement)
    /// @custom:ensures paused ==> _rootTotalEntitlement == old(_rootTotalEntitlement)
    /// @custom:ensures merkleRoot == root && root != bytes32(0) && _rootTotalEntitlement == totalEntitlement
    /// @custom:ensures statementHash == statementHash_ && statementHash_ != bytes32(0)
    /// @custom:ensures _rootTotalEntitlement - _totalPaid <= measuredBalance
    /// Payout bookkeeping and the last settlement ID are untouched.
    /// @custom:ensures _totalPaid == old(_totalPaid) && lastSettlementId == old(lastSettlementId)
    /// @custom:ensures forall uint256 i :: cumulativePaid(i) == old(cumulativePaid(i))
    function publishRoot(uint64 expectedRootVersion, bytes32 root, uint256 totalEntitlement, bytes32 statementHash_)
        external
        onlyOwner
    {
        _requireRootVersion(expectedRootVersion);
        _publishRoot(root, totalEntitlement, statementHash_, IERC20Like(earnShare).balanceOf(address(this)));
    }

    /// @dev balance is the distributor's EarnShare balance, measured by the caller after any funding.
    function _publishRoot(bytes32 root, uint256 totalEntitlement, bytes32 statementHash_, uint256 balance)
        private
        returns (uint64 version)
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > claimDeadline) revert ClaimsExpired();
        if (root == bytes32(0)) revert ZeroRoot();
        if (statementHash_ == bytes32(0)) revert ZeroStatementHash();
        if (totalEntitlement > type(uint120).max) revert EntitlementTooLarge(totalEntitlement);
        uint256 previousTotal = _rootTotalEntitlement;
        if (totalEntitlement < previousTotal) revert RootTotalDecreased(previousTotal, totalEntitlement);
        if (paused && totalEntitlement != previousTotal) revert PausedLiabilityIncrease();
        uint256 outstanding = totalEntitlement - _totalPaid;
        if (balance < outstanding) revert InsufficientFunding(outstanding, balance);

        /// @custom:ghost measuredBalance = balance
        /// @custom:ghost heldShares = balance
        merkleRoot = root;
        statementHash = statementHash_;
        // Checked above to fit.
        // forge-lint: disable-next-line(unsafe-typecast)
        _rootTotalEntitlement = uint120(totalEntitlement);
        rootVersion += 1;
        version = rootVersion;
        emit RootPublished(version, root, statementHash_, totalEntitlement);
    }

    /// @notice Pays a root-valid multiproof batch. Anyone may relay it because funds always go to
    ///         the recipients committed by the current root.
    /// totalPaid grows by exactly the shares the batch reports paid.
    /// @custom:ensures _totalPaid == old(_totalPaid) + paidEarnShares
    /// cumulativePaid never decreases, and only batch indexes change, each to one of its leaf amounts.
    /// @custom:ensures forall uint256 x :: cumulativePaid(x) >= old(cumulativePaid(x))
    /// @custom:ensures forall uint256 x :: cumulativePaid(x) != old(cumulativePaid(x)) ==> (exists uint256 j :: j < indexes.length && indexes[j] == x && cumulativeAmounts[j] == cumulativePaid(x))
    /// Every entry is paid or skipped; a stale version or a paused campaign is refused.
    /// @custom:ensures paidCount + skippedCount == indexes.length && old(rootVersion) == expectedRootVersion
    /// @custom:ensures !old(paused)
    /// Not proved: that a recipient counted as paid received exactly its amount (its EarnShare balance rose
    /// by cumulativeAmount - the index's previous cumulativePaid); a short or redirected delivery is counted as paid.
    /// Not proved: liveness. With claims active, the current version and equal nonempty arrays, a batch whose
    /// multiproof matches the root returns normally, skipping rather than reverting on any entry it cannot
    /// pay; the multiproof's validity over the computed leaves cannot be stated as a precondition here.
    function pushBatch(
        uint64 expectedRootVersion,
        uint256[] calldata indexes,
        address[] calldata recipients,
        uint256[] calldata cumulativeAmounts,
        bytes32[] calldata multiproof,
        bool[] calldata proofFlags
    ) external nonReentrant returns (uint256 paidCount, uint256 paidEarnShares, uint256 skippedCount) {
        _requireClaimsActive();
        uint64 currentVersion = rootVersion;
        if (expectedRootVersion != currentVersion) revert StaleRootVersion(expectedRootVersion, currentVersion);
        uint256 length = indexes.length;
        if (length == 0 || length != recipients.length || length != cumulativeAmounts.length) {
            revert InvalidArrayLengths();
        }

        bytes32[] memory leaves = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            leaves[i] = leaf(indexes[i], recipients[i], cumulativeAmounts[i]);
        }
        // The memory implementation avoids a solc via-IR stack-allocation failure exercised by
        // the repository's coverage profile. The proof is still verified in full before payment.
        if (!MerkleProof.multiProofVerify(multiproof, proofFlags, merkleRoot, leaves)) {
            revert InvalidMultiproof();
        }

        /// @custom:invariant i <= length && length == indexes.length && length == recipients.length && length == cumulativeAmounts.length
        /// @custom:invariant paidCount + skippedCount == i
        /// @custom:invariant _totalPaid == old(_totalPaid) + paidEarnShares
        /// @custom:invariant sumPaid == _totalPaid && _totalPaid <= _rootTotalEntitlement
        /// @custom:invariant !unspentReturned ==> _rootTotalEntitlement - _totalPaid <= heldShares
        /// @custom:invariant forall uint256 x :: cumulativePaid(x) <= _totalPaid
        /// @custom:invariant rootVersion == 0 <==> merkleRoot == bytes32(0)
        /// @custom:invariant rootVersion == 0 <==> statementHash == bytes32(0)
        /// @custom:invariant rootVersion == 0 ==> _rootTotalEntitlement == 0
        /// @custom:invariant forall uint256 x :: cumulativePaid(x) >= old(cumulativePaid(x))
        /// @custom:invariant forall uint256 x :: cumulativePaid(x) != old(cumulativePaid(x)) ==> (exists uint256 j :: j < i && indexes[j] == x && cumulativeAmounts[j] == cumulativePaid(x))
        for (uint256 i; i < length; ++i) {
            /// @custom:ghost minTotal = _rootTotalEntitlement
            uint256 index = indexes[i];
            address recipient = recipients[i];
            uint256 cumulativeAmount = cumulativeAmounts[i];
            SkipReason reason;
            bool skip;
            if (recipient == address(0)) {
                reason = SkipReason.ZeroRecipient;
                skip = true;
            } else {
                uint256 alreadyPaid = cumulativePaid(index);
                if (cumulativeAmount <= alreadyPaid) {
                    reason = SkipReason.NothingOwed;
                    skip = true;
                } else {
                    uint256 amount = cumulativeAmount - alreadyPaid;
                    uint256 paidBefore = _totalPaid;
                    if (amount > _rootTotalEntitlement - paidBefore) {
                        reason = SkipReason.RootTotalExceeded;
                        skip = true;
                    } else if (!_tryTransfer(earnShare, recipient, amount)) {
                        /// A failed push leaves the entitlement unpaid, so a later claim recovers it.
                        /// @custom:assert cumulativePaid(index) == alreadyPaid
                        reason = SkipReason.TransferFailed;
                        skip = true;
                    } else {
                        /// @custom:assert paidBefore <= minTotal && minTotal <= _rootTotalEntitlement
                        _recordPayout(index, cumulativeAmount, paidBefore + amount);
                        paidCount += 1;
                        paidEarnShares += amount;
                    }
                }
            }
            if (skip) {
                skippedCount += 1;
                emit PayoutSkipped(recipient, cumulativeAmount, reason);
            }
        }

        bytes32 batchHash = keccak256(abi.encode(currentVersion, indexes, recipients, cumulativeAmounts));
        emit BatchPushed(currentVersion, batchHash, length, paidCount, paidEarnShares, skippedCount);
    }

    /// @notice Pays the amount newly owed to a leaf index under the current cumulative root. Anyone may
    ///         submit the proof; the EarnShare always goes to the leaf's recipient.
    /// No double claim: pays exactly the newly owed cumulative delta and records the leaf's amount.
    /// @custom:ensures amount > 0 && amount == cumulativeAmount - old(cumulativePaid(index))
    /// @custom:ensures cumulativePaid(index) == cumulativeAmount
    /// @custom:ensures _totalPaid == old(_totalPaid) + amount
    /// @custom:ensures forall uint256 x :: x != index ==> cumulativePaid(x) == old(cumulativePaid(x))
    /// A claim never exceeds the remaining root liability, and claims stop while paused.
    /// @custom:ensures amount <= old(_rootTotalEntitlement) - old(_totalPaid)
    /// @custom:ensures !old(paused) && recipient != address(0)
    /// Not proved: liveness. With claims active, a proof of the leaf under the current root, a cumulative amount
    /// above what was paid and the newly owed amount within the root's remaining liability, the claim returns
    /// normally once the EarnShare transfer succeeds; the proof's validity cannot be stated as a precondition here.
    /// Not proved: that the recipient's EarnShare balance rose by exactly amount; the transfer's
    /// return value is trusted and the delivery is not measured.
    function claim(uint256 index, address recipient, uint256 cumulativeAmount, bytes32[] calldata proof)
        external
        nonReentrant
        returns (uint256 amount)
    {
        _requireClaimsActive();
        if (recipient == address(0)) revert ZeroAddress();
        uint256 alreadyPaid = cumulativePaid(index);
        if (cumulativeAmount <= alreadyPaid) revert NothingOwed();
        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leaf(index, recipient, cumulativeAmount))) {
            revert InvalidMultiproof();
        }

        amount = cumulativeAmount - alreadyPaid;
        uint256 paidBefore = _totalPaid;
        uint256 remaining = _rootTotalEntitlement - paidBefore;
        if (amount > remaining) revert RootTotalExceeded(amount, remaining);
        _recordPayout(index, cumulativeAmount, paidBefore + amount);
        _safeTransfer(earnShare, recipient, amount);
        emit RewardClaimed(recipient, amount, cumulativeAmount);
    }

    /// Only the owner pauses; roots and payouts are unchanged.
    /// @custom:ensures old(owner()) == msg.sender && paused == paused_
    /// @custom:ensures merkleRoot == old(merkleRoot) && rootVersion == old(rootVersion)
    /// @custom:ensures _rootTotalEntitlement == old(_rootTotalEntitlement) && _totalPaid == old(_totalPaid)
    function setPaused(bool paused_) external onlyOwner {
        if (paused == paused_) return;
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @dev Campaign ownership may be rotated with Ownable2Step but cannot be abandoned.
    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    /// @notice Returns remaining EarnShare inventory to the treasury after the claim window.
    /// Only after the claim window; payout bookkeeping is unchanged.
    /// @custom:ensures block.timestamp > claimDeadline
    /// @custom:ensures _totalPaid == old(_totalPaid)
    /// @custom:ensures forall uint256 x :: cumulativePaid(x) == old(cumulativePaid(x))
    function returnUnspent() external nonReentrant returns (uint256 earnShares) {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= claimDeadline) revert ClaimsNotExpired();
        /// @custom:ghost unspentReturned = true
        earnShares = IERC20Like(earnShare).balanceOf(address(this));
        if (earnShares != 0) _safeTransfer(earnShare, treasury, earnShares);
        emit UnspentReturned(treasury, earnShares);
    }

    /// @notice The cumulative EarnShare root total the current root commits.
    function rootTotalEntitlement() external view returns (uint256) {
        return _rootTotalEntitlement;
    }

    /// @notice The EarnShare paid across every leaf index.
    function totalPaid() external view returns (uint256) {
        return _totalPaid;
    }

    /// @notice The cumulative EarnShare paid to a leaf index.
    function cumulativePaid(uint256 index) public view returns (uint256) {
        return index % 2 == 0 ? _paid[index / 2].lane0 : _paid[index / 2].lane1;
    }

    /// @notice The leaf format this distributor verifies; version 1 distributors have no such function.
    function leafVersion() external pure returns (uint256) {
        return 2;
    }

    /// @notice The leaf committing `cumulativeAmount` to `recipient` at leaf `index` of this campaign.
    function leaf(uint256 index, address recipient, uint256 cumulativeAmount) public view returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(block.chainid, address(this), campaignId, index, recipient, cumulativeAmount))
            )
        );
    }

    /// Records a payout: the index's cumulative amount within uint128 and the new total within uint120. Callers hold
    /// the contract invariant that no index's record exceeds totalPaid.
    /// @custom:requires cumulativePaid(index) <= _totalPaid
    /// @custom:requires nextTotalPaid == _totalPaid + (cumulativeAmount - cumulativePaid(index))
    /// @custom:requires cumulativeAmount > cumulativePaid(index) && nextTotalPaid <= _rootTotalEntitlement
    /// @custom:ensures cumulativePaid(index) == cumulativeAmount && _totalPaid == nextTotalPaid
    /// @custom:ensures cumulativeAmount <= _totalPaid
    /// @custom:ensures forall uint256 x :: x != index ==> cumulativePaid(x) == old(cumulativePaid(x))
    /// @custom:ensures sumPaid == old(sumPaid) - old(cumulativePaid(index)) + cumulativeAmount
    /// @custom:ensures heldShares == old(heldShares) - (nextTotalPaid - old(_totalPaid))
    function _recordPayout(uint256 index, uint256 cumulativeAmount, uint256 nextTotalPaid) private {
        // The index's record is part of totalPaid, so cumulativeAmount <= nextTotalPaid <= the root total.
        /// @custom:assert cumulativeAmount <= nextTotalPaid && nextTotalPaid <= type(uint120).max
        /// @custom:ghost sumPaid = sumPaid - cumulativePaid(index) + cumulativeAmount
        /// @custom:ghost heldShares = heldShares - (nextTotalPaid - _totalPaid)
        PaidLanes storage lanes = _paid[index / 2];
        // forge-lint: disable-next-line(unsafe-typecast)
        if (index % 2 == 0) lanes.lane0 = uint128(cumulativeAmount);
        // forge-lint: disable-next-line(unsafe-typecast)
        else lanes.lane1 = uint128(cumulativeAmount);
        // forge-lint: disable-next-line(unsafe-typecast)
        _totalPaid = uint120(nextTotalPaid);
    }

    function _requireClaimsActive() private view {
        if (paused) revert Paused();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > claimDeadline) revert ClaimsExpired();
    }

    function _requireRootVersion(uint64 expectedRootVersion) private view {
        uint64 currentVersion = rootVersion;
        if (expectedRootVersion != currentVersion) revert StaleRootVersion(expectedRootVersion, currentVersion);
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        if (!_tryTransfer(token, to, amount)) revert TokenCallFailed();
    }

    function _tryTransfer(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory result) = token.call(abi.encodeCall(IERC20Like.transfer, (to, amount)));
        if (!ok) return false;
        return _successfulReturn(result);
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory result) = token.call(abi.encodeCall(IERC20Like.transferFrom, (from, to, amount)));
        if (!ok) revert TokenCallFailed();
        if (!_successfulReturn(result)) revert TokenCallFalse();
    }

    function _safeApprove(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory result) = token.call(abi.encodeCall(IERC20Like.approve, (spender, amount)));
        if (!ok) revert TokenCallFailed();
        if (!_successfulReturn(result)) revert TokenCallFalse();
    }

    function _successfulReturn(bytes memory result) private pure returns (bool) {
        if (result.length == 0) return true;
        if (result.length != 32) return false;
        uint256 returnValue;
        assembly ("memory-safe") {
            returnValue := mload(add(result, 0x20))
        }
        return returnValue == 1;
    }
}
