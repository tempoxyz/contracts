// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../interfaces/core/IEarnVault.sol";
import { IERC20Like } from "../interfaces/external/IERC20Like.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EarnMerkleRewardDistributor
/// @notice EarnShare-only settlement rail for cumulative, offchain-computed public-holder rewards.
/// @dev The owner may pull an approved base-asset budget from a selected funder and deposit it through
///      the immutable EarnVault. Only that EarnVault mints the fully backed EarnShare held here. Root-valid
///      pushes and claims are permissionless because every transfer is fixed to its committed recipient.
contract EarnMerkleRewardDistributor is Ownable2Step, ReentrancyGuard {
    error OwnershipRenunciationDisabled();
    enum SkipReason {
        ZeroRecipient,
        NothingOwed,
        RootTotalExceeded,
        TransferFailed
    }

    IEarnVault public immutable earnVault;
    address public immutable asset;
    address public immutable earnShare;
    address public immutable treasury;
    bytes32 public immutable campaignId;
    uint40 public immutable claimDeadline;

    bytes32 public merkleRoot;
    bytes32 public statementHash;
    uint256 public rootTotalEntitlement;
    uint256 public totalPaid;
    uint64 public rootVersion;
    bool public paused;

    mapping(address recipient => uint256 cumulativeAmount) public cumulativePaid;
    mapping(bytes32 settlementId => bool consumed) public consumedSettlements;

    event AssetsFunded(address indexed funder, uint256 assets, uint256 earnShares);
    event RootPublished(
        uint64 indexed version, bytes32 indexed root, bytes32 indexed statementHash, uint256 totalEntitlement
    );
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
    error DepositsPaused();
    error InsufficientFunding(uint256 requiredBalance, uint256 actualBalance);
    error InvalidArrayLengths();
    error InvalidEarnVault();
    error InvalidMultiproof();
    error NothingOwed();
    error Paused();
    error PausedLiabilityIncrease();
    error RootTotalExceeded(uint256 requestedAmount, uint256 remainingEntitlement);
    error RootTotalDecreased(uint256 previousTotal, uint256 nextTotal);
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
    }

    /// @notice Atomically funds a conservatively bounded interval and publishes its solvent root.
    /// @dev `minEarnShares` is a lower bound, not an exact quote. Any excess mint remains available
    ///      to fund later cumulative roots. The final solvency check accounts for both that inventory
    ///      and the shares minted by this call.
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
        if (consumedSettlements[settlementId]) revert SettlementAlreadyConsumed(settlementId);
        _requireRootVersion(expectedRootVersion);
        consumedSettlements[settlementId] = true;
        earnShares = _fundWithAssets(funder, assets, minEarnShares);
        version = _publishRoot(root, totalEntitlement, statementHash_);
    }

    function _fundWithAssets(address funder, uint256 assets, uint256 minEarnShares)
        private
        returns (uint256 earnShares)
    {
        _requireClaimsActive();
        if (funder == address(0)) revert ZeroAddress();
        if (assets == 0) revert ZeroAmount();
        if (minEarnShares == 0) revert ZeroMinimumEarnShares();
        if (earnVault.depositsPaused()) revert DepositsPaused();

        uint256 assetBalanceBefore = IERC20Like(asset).balanceOf(address(this));
        uint256 earnShareBalanceBefore = IERC20Like(earnShare).balanceOf(address(this));
        _safeTransferFrom(asset, funder, address(this), assets);
        _safeApprove(asset, address(earnVault), 0);
        _safeApprove(asset, address(earnVault), assets);
        uint256 reportedEarnShares = earnVault.deposit(assets, address(this), minEarnShares);
        _safeApprove(asset, address(earnVault), 0);

        uint256 assetBalanceAfter = IERC20Like(asset).balanceOf(address(this));
        if (assetBalanceAfter != assetBalanceBefore) {
            revert UnexpectedRetainedAssets(assetBalanceBefore, assetBalanceAfter);
        }
        earnShares = IERC20Like(earnShare).balanceOf(address(this)) - earnShareBalanceBefore;
        if (earnShares == 0) revert ZeroAmount();
        if (earnShares != reportedEarnShares) revert UnexpectedEarnShares(reportedEarnShares, earnShares);
        emit AssetsFunded(funder, assets, earnShares);
    }

    /// @notice Publishes a cumulative EarnShare entitlement root whose outstanding liability is funded.
    /// @dev While paused, only a same-total corrective statement may replace the current root.
    function publishRoot(uint64 expectedRootVersion, bytes32 root, uint256 totalEntitlement, bytes32 statementHash_)
        external
        onlyOwner
    {
        _requireRootVersion(expectedRootVersion);
        _publishRoot(root, totalEntitlement, statementHash_);
    }

    function _publishRoot(bytes32 root, uint256 totalEntitlement, bytes32 statementHash_)
        private
        returns (uint64 version)
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > claimDeadline) revert ClaimsExpired();
        if (root == bytes32(0)) revert ZeroRoot();
        if (statementHash_ == bytes32(0)) revert ZeroStatementHash();
        if (totalEntitlement < rootTotalEntitlement) {
            revert RootTotalDecreased(rootTotalEntitlement, totalEntitlement);
        }
        if (paused && totalEntitlement != rootTotalEntitlement) revert PausedLiabilityIncrease();
        uint256 outstanding = totalEntitlement - totalPaid;
        uint256 balance = IERC20Like(earnShare).balanceOf(address(this));
        if (balance < outstanding) revert InsufficientFunding(outstanding, balance);

        merkleRoot = root;
        statementHash = statementHash_;
        rootTotalEntitlement = totalEntitlement;
        rootVersion += 1;
        version = rootVersion;
        emit RootPublished(version, root, statementHash_, totalEntitlement);
    }

    /// @notice Pays a root-valid multiproof batch. Anyone may relay it because funds always go to
    ///         the recipients committed by the current root.
    function pushBatch(
        uint64 expectedRootVersion,
        address[] calldata recipients,
        uint256[] calldata cumulativeAmounts,
        bytes32[] calldata multiproof,
        bool[] calldata proofFlags
    ) external nonReentrant returns (uint256 paidCount, uint256 paidEarnShares, uint256 skippedCount) {
        _requireClaimsActive();
        uint64 currentVersion = rootVersion;
        if (expectedRootVersion != currentVersion) revert StaleRootVersion(expectedRootVersion, currentVersion);
        uint256 length = recipients.length;
        if (length == 0 || length != cumulativeAmounts.length) revert InvalidArrayLengths();

        bytes32[] memory leaves = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            leaves[i] = leaf(recipients[i], cumulativeAmounts[i]);
        }
        // The memory implementation avoids a solc via-IR stack-allocation failure exercised by
        // the repository's coverage profile. The proof is still verified in full before payment.
        if (!MerkleProof.multiProofVerify(multiproof, proofFlags, merkleRoot, leaves)) {
            revert InvalidMultiproof();
        }

        for (uint256 i; i < length; ++i) {
            address recipient = recipients[i];
            uint256 cumulativeAmount = cumulativeAmounts[i];
            SkipReason reason;
            bool skip;
            if (recipient == address(0)) {
                reason = SkipReason.ZeroRecipient;
                skip = true;
            } else {
                uint256 alreadyPaid = cumulativePaid[recipient];
                if (cumulativeAmount <= alreadyPaid) {
                    reason = SkipReason.NothingOwed;
                    skip = true;
                } else {
                    uint256 amount = cumulativeAmount - alreadyPaid;
                    if (amount > rootTotalEntitlement - totalPaid) {
                        reason = SkipReason.RootTotalExceeded;
                        skip = true;
                    } else if (!_tryTransfer(earnShare, recipient, amount)) {
                        reason = SkipReason.TransferFailed;
                        skip = true;
                    } else {
                        uint256 nextTotalPaid = totalPaid + amount;
                        cumulativePaid[recipient] = cumulativeAmount;
                        totalPaid = nextTotalPaid;
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

        bytes32 batchHash = keccak256(abi.encode(currentVersion, recipients, cumulativeAmounts));
        emit BatchPushed(currentVersion, batchHash, length, paidCount, paidEarnShares, skippedCount);
    }

    /// @notice Pays the amount newly owed under the current cumulative root. Anyone may submit the proof.
    function claim(address recipient, uint256 cumulativeAmount, bytes32[] calldata proof)
        external
        nonReentrant
        returns (uint256 amount)
    {
        _requireClaimsActive();
        if (recipient == address(0)) revert ZeroAddress();
        uint256 alreadyPaid = cumulativePaid[recipient];
        if (cumulativeAmount <= alreadyPaid) revert NothingOwed();
        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leaf(recipient, cumulativeAmount))) {
            revert InvalidMultiproof();
        }

        amount = cumulativeAmount - alreadyPaid;
        if (amount > rootTotalEntitlement - totalPaid) {
            revert RootTotalExceeded(amount, rootTotalEntitlement - totalPaid);
        }
        uint256 nextTotalPaid = totalPaid + amount;
        cumulativePaid[recipient] = cumulativeAmount;
        totalPaid = nextTotalPaid;
        _safeTransfer(earnShare, recipient, amount);
        emit RewardClaimed(recipient, amount, cumulativeAmount);
    }

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
    function returnUnspent() external nonReentrant returns (uint256 earnShares) {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= claimDeadline) revert ClaimsNotExpired();
        earnShares = IERC20Like(earnShare).balanceOf(address(this));
        if (earnShares != 0) _safeTransfer(earnShare, treasury, earnShares);
        emit UnspentReturned(treasury, earnShares);
    }

    function leaf(address recipient, uint256 cumulativeAmount) public view returns (bytes32) {
        return keccak256(
            bytes.concat(keccak256(abi.encode(block.chainid, address(this), campaignId, recipient, cumulativeAmount)))
        );
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
