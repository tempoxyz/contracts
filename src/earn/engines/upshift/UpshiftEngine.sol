// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IEarnEngine } from "../../../interfaces/earn/engines/IEarnEngine.sol";
import { IEarnEngineAsyncRedeem } from "../../../interfaces/earn/engines/IEarnEngineAsyncRedeem.sol";
import { IEarnEngineFeeValuation } from "../../../interfaces/earn/engines/IEarnEngineFeeValuation.sol";
import { IEarnEngineHeldDeposit } from "../../../interfaces/earn/engines/IEarnEngineHeldDeposit.sol";
import { IEarnEngineRedeem } from "../../../interfaces/earn/engines/IEarnEngineRedeem.sol";
import { IEarnVault } from "../../../interfaces/earn/IEarnVault.sol";
import { IUpshiftVault } from "../../../interfaces/external/upshift/IUpshiftVault.sol";
import { UpshiftRedeemReceiver } from "./UpshiftRedeemReceiver.sol";

/// @dev Callback the engine uses to hand a queued payout back to its single client (the `EarnVault`).
interface IEarnVaultFinalize {
    function finalizeRedeem(bytes32 requestId, address asset, uint256 amount) external;
}

/// @title UpshiftEngine
/// @notice Single-EarnVault engine for one Upshift (August) tokenized vault. It is the sole holder of the
///         vault's receipt tokens attributed to its EarnVault; one engine share is one raw receipt token.
///
/// @dev IMMEDIATE. `redeem` uses the vault's instant redemption, which pays the receiver net of the vault's
///      instant fee and reverts when the vault holds too little idle base asset. The receiver's measured
///      increase is checked against the caller's minimum.
///
/// @dev ASYNC. The vault queues redemptions per claim date and receiver, with no request ID and no
///      cancellation. `requestRedeem` therefore gives every request its own {UpshiftRedeemReceiver}, whose
///      address is the request ID, so the vault's total for that receiver is that request plus anything a
///      third party queued for the same receiver and date. The
///      vault prices a queued redemption when it is claimed, not when it is requested. {settleRedeem} claims
///      it when the vault has not already paid it, moves whatever the receiver holds to the EarnVault, and
///      finalizes the request with that measured amount. {cancelRedeem} always reverts.
///
/// @dev The base asset never rests on the engine: deposits go straight to the vault and payouts go from a
///      request's receiver to the EarnVault. Base asset sent to the engine, or to a receiver after its
///      request settled, is not recoverable.
/// Specs (docs/earn/modules/upshift.md, docs/earn/integrations/engines.md):
/// Fund flows are nonReentrant through the transient `_entered` flag.
/// @custom:reentrancy-guard _entered
/// Owner calls that stay open under the lock cannot unbind or rebind the EarnVault.
/// @custom:lock-stable earnVault != address(0)
/// The NAV age bound is never zero.
/// @custom:invariant maxNavAge > 0
/// A claim records queued shares exactly while it exists.
/// @custom:invariant forall bytes32 id :: _claims[id].status == ClaimStatus.None <==> _claims[id].engineShares == 0
/// Ghost record of the last measured decrease in the receipt tokens the engine holds.
/// @custom:ghost uint256 burnedShares
contract UpshiftEngine is
    IEarnEngine,
    IEarnEngineRedeem,
    IEarnEngineAsyncRedeem,
    IEarnEngineFeeValuation,
    IEarnEngineHeldDeposit,
    Ownable2Step
{
    using SafeERC20 for IERC20;

    enum ClaimStatus {
        None,
        Open,
        Settled
    }

    /// @dev One slot per request. The receiver is the request ID; the date selects the vault's queue entry.
    struct QueuedClaim {
        ClaimStatus status;
        uint16 year;
        uint8 month;
        uint8 day;
        uint128 engineShares;
    }

    IUpshiftVault public immutable vault;
    /// @notice The vault's receipt token, which the engine holds as backing.
    address public immutable shareToken;
    address public immutable baseAsset;
    /// @notice The contract every request's receiver is a minimal proxy of.
    address public immutable receiverImplementation;
    uint256 private immutable _shareScale;
    string private _name;
    string private _symbol;

    /// @notice The sole EarnVault client, set once after deployment.
    address public earnVault;
    /// @notice Maximum age of the vault's NAV report accepted for deposits and fee valuation.
    uint64 public maxNavAge;

    mapping(bytes32 requestId => QueuedClaim) private _claims;

    bool private transient _entered;

    event EarnVaultInitialized(address indexed earnVault);
    event MaxNavAgeUpdated(uint64 oldMaxNavAge, uint64 newMaxNavAge);
    event Deposited(address indexed earnVault, uint256 assets, uint256 engineShares);
    event Redeemed(address indexed receiver, uint256 engineShares, uint256 assets);
    event RedeemRequested(bytes32 indexed requestId, uint256 engineShares, uint256 claimableEpoch);
    event RedeemSettled(bytes32 indexed requestId, uint256 engineShares, uint256 assets);

    error AlreadyInitialized();
    error CancelUnsupported();
    error ClaimNotOpen(bytes32 requestId);
    error DepositsNotPaused();
    error EarnVaultNotSet();
    error EmptyMetadata();
    error InsufficientAssetsReceived(uint256 minimumAssets, uint256 actualAssets);
    error InvalidAsset(address expected, address actual);
    error InvalidEngineShares(uint256 engineShares);
    error InvalidMaxNavAge();
    error InvalidNavTimestamp(uint256 updatedAt, uint256 currentTime);
    error InvalidUpshiftVault(address account);
    error InvalidVenueShareDecimals();
    error NoVenueSharesReceived();
    error NotEarnVault(address caller);
    error ReentrantCall();
    error StaleNav(uint256 updatedAt, uint256 currentTime, uint256 maxAge);
    error UnexpectedAllowance(address spender, uint256 remaining);
    error UnexpectedClaimDate(uint256 year, uint256 month, uint256 day);
    error UnexpectedQueuedShares(uint256 expectedShares, uint256 actualShares);
    error UnexpectedRequestData();
    error UnexpectedVenueSharesBurned(uint256 expectedShares, uint256 actualShares);
    error ZeroAddress();

    modifier onlyEarnVault() {
        if (earnVault == address(0)) revert EarnVaultNotSet();
        if (msg.sender != earnVault) revert NotEarnVault(msg.sender);
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert ReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    /// @param vault_ The Upshift vault. Its reference asset becomes the engine's base asset.
    /// @param maxNavAge_ Nonzero maximum age of the vault's NAV report, in seconds.
    constructor(IUpshiftVault vault_, address owner_, uint64 maxNavAge_, string memory name_, string memory symbol_)
        Ownable(owner_)
    {
        if (maxNavAge_ == 0) revert InvalidMaxNavAge();
        maxNavAge = maxNavAge_;
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyMetadata();
        if (address(vault_).code.length == 0) revert InvalidUpshiftVault(address(vault_));
        address baseAsset_ = vault_.asset();
        address shareToken_ = vault_.lpTokenAddress();
        if (baseAsset_.code.length == 0) revert InvalidUpshiftVault(baseAsset_);
        if (shareToken_.code.length == 0) revert InvalidUpshiftVault(shareToken_);
        uint8 shareDecimals = IERC20Metadata(shareToken_).decimals();
        if (shareDecimals > 77) revert InvalidVenueShareDecimals();
        vault = vault_;
        shareToken = shareToken_;
        baseAsset = baseAsset_;
        receiverImplementation = address(new UpshiftRedeemReceiver());
        _shareScale = 10 ** uint256(shareDecimals);
        _name = name_;
        _symbol = symbol_;
    }

    /// @notice One-time binding of the sole client EarnVault. Owner-gated, set-once.
    /// @custom:ensures old(owner()) == msg.sender && old(earnVault) == address(0) && earnVault == earnVault_
    /// @custom:ensures earnVault_ != address(0) && owner() == old(owner())
    function initializeEarnVault(address earnVault_) external onlyOwner {
        _initializeEarnVault(earnVault_);
    }

    /// @notice One-time binding followed by an immediate ownership transfer during setup.
    /// @dev The atomic setup path intentionally bypasses the pending-owner acceptance step.
    /// @custom:ensures old(owner()) == msg.sender && old(earnVault) == address(0) && earnVault == earnVault_
    /// @custom:ensures earnVault_ != address(0) && owner() == finalOwner_ && finalOwner_ != address(0)
    function initializeEarnVault(address earnVault_, address finalOwner_) external onlyOwner {
        if (finalOwner_ == address(0)) revert ZeroAddress();
        _initializeEarnVault(earnVault_);
        _transferOwnership(finalOwner_);
    }

    function _initializeEarnVault(address earnVault_) private {
        if (earnVault != address(0)) revert AlreadyInitialized();
        if (earnVault_ == address(0)) revert ZeroAddress();
        address vaultAsset = IEarnVault(earnVault_).asset();
        if (vaultAsset != baseAsset) revert InvalidAsset(baseAsset, vaultAsset);
        earnVault = earnVault_;
        emit EarnVaultInitialized(earnVault_);
    }

    /// @notice Updates the maximum NAV report age. Once bound, only while the EarnVault's deposits are paused.
    /// @custom:ensures old(owner()) == msg.sender && maxNavAge == newMaxNavAge && newMaxNavAge != 0
    function setMaxNavAge(uint64 newMaxNavAge) external onlyOwner {
        if (newMaxNavAge == 0) revert InvalidMaxNavAge();
        if (earnVault != address(0) && !IEarnVault(earnVault).depositsPaused()) revert DepositsNotPaused();
        uint64 oldMaxNavAge = maxNavAge;
        maxNavAge = newMaxNavAge;
        emit MaxNavAgeUpdated(oldMaxNavAge, newMaxNavAge);
    }

    // ------------------------------------------------------------------
    // IEarnEngine
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

    /// @notice Raw receipt tokens the engine holds. Queued shares are excluded: the vault takes them when a
    ///         redemption is requested.
    function totalShares() public view returns (uint256) {
        return IERC20(shareToken).balanceOf(address(this));
    }

    function totalAssets() external view returns (uint256) {
        return valueOf(totalShares());
    }

    /// @notice What a lagged redemption of `engineShares` would pay now, net of the vault's withdrawal fee.
    function valueOf(uint256 engineShares) public view returns (uint256 assets) {
        (, assets) = vault.previewRedemption(engineShares, false);
    }

    /// @notice Pulls `assets` from the EarnVault and deposits them into the vault. Needs a fresh NAV report.
    /// @custom:ensures old(earnVault) != address(0) && msg.sender == old(earnVault)
    /// @custom:ensures engineShares > 0
    function deposit(uint256 assets) external onlyEarnVault nonReentrant returns (uint256 engineShares) {
        _requireFreshNav();
        IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), assets);
        engineShares = _depositToVenue(assets);
    }

    /// @notice Deposits `assets` the EarnVault already transferred here. Needs a fresh NAV report.
    /// @custom:ensures old(earnVault) != address(0) && msg.sender == old(earnVault)
    /// @custom:ensures engineShares > 0
    function depositHeld(uint256 assets) external onlyEarnVault nonReentrant returns (uint256 engineShares) {
        _requireFreshNav();
        engineShares = _depositToVenue(assets);
    }

    /// @dev The exact allowance bounds the vault's pull to `assets`; the allowance check proves it took all of it.
    function _depositToVenue(uint256 assets) private returns (uint256 engineShares) {
        IERC20(baseAsset).forceApprove(address(vault), assets);
        uint256 sharesBefore = totalShares();
        vault.deposit(baseAsset, assets, address(this));
        engineShares = totalShares() - sharesBefore;
        _requireNoAllowance(baseAsset);
        if (engineShares == 0) revert NoVenueSharesReceived();
        emit Deposited(msg.sender, assets, engineShares);
    }

    // ------------------------------------------------------------------
    // IEarnEngineRedeem
    // ------------------------------------------------------------------

    /// @notice What an instant redemption of `engineShares` would pay now, net of the vault's instant fee.
    function previewRedeem(uint256 engineShares) external view returns (uint256 assets) {
        (, assets) = vault.previewRedemption(engineShares, true);
    }

    /// @notice Instant redemption straight to `receiver`. Reverts when the vault cannot pay it in full.
    /// @custom:ensures old(earnVault) != address(0) && msg.sender == old(earnVault)
    /// @custom:ensures receiver != address(0) && assets >= minAssets
    /// The vault took exactly the requested engine shares, measured on the engine's balance.
    /// @custom:ensures burnedShares == engineShares
    function redeem(uint256 engineShares, address receiver, uint256 minAssets)
        external
        onlyEarnVault
        nonReentrant
        returns (uint256 assets)
    {
        if (receiver == address(0)) revert ZeroAddress();
        uint256 sharesBefore = totalShares();
        uint256 receiverBefore = IERC20(baseAsset).balanceOf(receiver);
        vault.instantRedeem(engineShares, receiver);
        _requireSharesLeft(sharesBefore, engineShares);
        uint256 receiverAfter = IERC20(baseAsset).balanceOf(receiver);
        if (receiverAfter > receiverBefore) assets = receiverAfter - receiverBefore;
        if (assets < minAssets) revert InsufficientAssetsReceived(minAssets, assets);
        emit Redeemed(receiver, engineShares, assets);
    }

    // ------------------------------------------------------------------
    // IEarnEngineAsyncRedeem
    // ------------------------------------------------------------------

    /// @notice Queues `engineShares` on the vault for a new receiver that only this engine can empty.
    /// @param requestData Must be empty: the vault takes no queue terms.
    /// @return requestId The new receiver's address.
    /// @custom:ensures old(earnVault) != address(0) && msg.sender == old(earnVault)
    /// The claim is Open for exactly the shares the vault took from the engine.
    /// @custom:ensures _claims[requestId].status == ClaimStatus.Open && _claims[requestId].engineShares == engineShares
    /// @custom:ensures burnedShares == engineShares
    function requestRedeem(uint256 engineShares, bytes calldata requestData)
        external
        onlyEarnVault
        nonReentrant
        returns (bytes32 requestId)
    {
        if (requestData.length != 0) revert UnexpectedRequestData();
        if (engineShares == 0 || engineShares > type(uint128).max) revert InvalidEngineShares(engineShares);

        address receiver = Clones.clone(receiverImplementation);
        requestId = bytes32(uint256(uint160(receiver)));

        uint256 sharesBefore = totalShares();
        IERC20(shareToken).forceApprove(address(vault), engineShares);
        (uint256 claimableEpoch, uint256 year, uint256 month, uint256 day) = vault.requestRedeem(engineShares, receiver);
        _requireSharesLeft(sharesBefore, engineShares);
        _requireNoAllowance(shareToken);
        if (year > type(uint16).max || month > type(uint8).max || day > type(uint8).max) {
            revert UnexpectedClaimDate(year, month, day);
        }
        // At least, not exactly: the receiver's address is predictable, so shares a third party queued for
        // it first must not block the request. They are paid to it at settlement.
        uint256 queued = vault.getBurnableAmountByReceiver(year, month, day, receiver);
        if (queued < engineShares) revert UnexpectedQueuedShares(engineShares, queued);

        // Bounded above, so the downcasts cannot truncate.
        // forge-lint: disable-next-item(unsafe-typecast)
        _claims[requestId] = QueuedClaim({
            status: ClaimStatus.Open,
            year: uint16(year),
            month: uint8(month),
            day: uint8(day),
            engineShares: uint128(engineShares)
        });
        emit RedeemRequested(requestId, engineShares, claimableEpoch);
    }

    /// @notice Always reverts: an Upshift vault cannot return queued shares.
    function cancelRedeem(bytes32) external pure returns (uint256) {
        revert CancelUnsupported();
    }

    /// @notice Pays an open request: claims it on the vault unless the vault already paid its receiver,
    ///         then forwards the receiver's whole base-asset balance through the EarnVault.
    /// @dev Permissionless: the payout only ever reaches the receiver the EarnVault stored at request time.
    ///      Reverts while the vault refuses the claim (before the claim date, or withdrawals paused) and when
    ///      the EarnVault cannot pay its stored receiver, leaving the request open either way.
    /// No double settlement: only an Open claim settles, once.
    /// @custom:ensures old(_claims[requestId].status) == ClaimStatus.Open
    /// @custom:ensures _claims[requestId].status == ClaimStatus.Settled
    function settleRedeem(bytes32 requestId) external nonReentrant returns (uint256 assets) {
        QueuedClaim storage c = _claims[requestId];
        if (c.status != ClaimStatus.Open) revert ClaimNotOpen(requestId);
        address receiver = address(uint160(uint256(requestId)));
        (uint256 year, uint256 month, uint256 day) = (c.year, c.month, c.day);
        uint256 engineShares = c.engineShares;

        if (vault.getBurnableAmountByReceiver(year, month, day, receiver) != 0) {
            vault.claim(year, month, day, receiver);
            uint256 remaining = vault.getBurnableAmountByReceiver(year, month, day, receiver);
            if (remaining != 0) revert UnexpectedQueuedShares(0, remaining);
        }
        c.status = ClaimStatus.Settled;

        address earnVault_ = earnVault;
        uint256 vaultBefore = IERC20(baseAsset).balanceOf(earnVault_);
        UpshiftRedeemReceiver(receiver).sweep(baseAsset, earnVault_);
        assets = IERC20(baseAsset).balanceOf(earnVault_) - vaultBefore;
        IEarnVaultFinalize(earnVault_).finalizeRedeem(requestId, baseAsset, assets);
        emit RedeemSettled(requestId, engineShares, assets);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Whether the vault's NAV report is recent enough to crystallize fee claims.
    function isFeeValuationFresh() external view returns (bool) {
        uint256 updatedAt = vault.assetsUpdatedOn();
        return updatedAt != 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxNavAge;
    }

    /// @notice A request's status, receiver, queued shares and the vault date it is claimable on.
    function getClaim(bytes32 requestId)
        external
        view
        returns (ClaimStatus status, address receiver, uint256 engineShares, uint256 year, uint256 month, uint256 day)
    {
        QueuedClaim storage c = _claims[requestId];
        if (c.status == ClaimStatus.None) return (ClaimStatus.None, address(0), 0, 0, 0, 0);
        return (c.status, address(uint160(uint256(requestId))), c.engineShares, c.year, c.month, c.day);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IEarnEngine).interfaceId
            || interfaceId == type(IEarnEngineRedeem).interfaceId
            || interfaceId == type(IEarnEngineAsyncRedeem).interfaceId
            || interfaceId == type(IEarnEngineFeeValuation).interfaceId
            || interfaceId == type(IEarnEngineHeldDeposit).interfaceId;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    /// @dev Deposit-only, so a late NAV report cannot freeze exits.
    function _requireFreshNav() private view {
        uint256 updatedAt = vault.assetsUpdatedOn();
        uint256 currentTime = block.timestamp;
        if (updatedAt == 0 || updatedAt > currentTime) revert InvalidNavTimestamp(updatedAt, currentTime);
        if (currentTime - updatedAt > maxNavAge) revert StaleNav(updatedAt, currentTime, maxNavAge);
    }

    /// @custom:ensures burnedShares == expectedShares
    function _requireSharesLeft(uint256 sharesBefore, uint256 expectedShares) private view {
        uint256 sharesAfter = totalShares();
        uint256 actualShares = sharesBefore >= sharesAfter ? sharesBefore - sharesAfter : 0;
        /// @custom:ghost burnedShares = actualShares
        if (sharesAfter > sharesBefore || actualShares != expectedShares) {
            revert UnexpectedVenueSharesBurned(expectedShares, actualShares);
        }
    }

    function _requireNoAllowance(address token) private view {
        uint256 remaining = IERC20(token).allowance(address(this), address(vault));
        if (remaining != 0) revert UnexpectedAllowance(address(vault), remaining);
    }
}
