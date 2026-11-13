// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20Like } from "../interfaces/external/IERC20Like.sol";
import { IEarnEngine } from "../interfaces/engines/IEarnEngine.sol";
import { IEarnEngineExactWithdraw } from "../interfaces/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineInKindDeposit } from "../interfaces/engines/IEarnEngineInKindDeposit.sol";
import { IEarnEngineRedeem } from "../interfaces/engines/IEarnEngineRedeem.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IERC4626Vault {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function balanceOf(address account) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256 venueShares);
    function previewRedeem(uint256 venueShares) external view returns (uint256 assets);
    function deposit(uint256 assets, address receiver) external returns (uint256 venueShares);
    function redeem(uint256 venueShares, address receiver, address owner) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 venueShares);
}

/// @title ERC4626Engine
/// @notice Single-EarnVault engine for an immediate-execution ERC-4626 venue.
/// @dev The engine is the sole holder of venue shares backing its paired `EarnVault`.
/// Specs for solar-verify (docs/earn/modules/erc4626-engine.md, docs/earn/integrations/engines.md):
/// Every venue entry point is nonReentrant (`locked` is 1 when free and 2 while held).
/// @custom:reentrancy-guard locked != 1
/// @custom:invariant locked == 1 || locked == 2
/// Owner calls that stay open under the lock cannot unbind or rebind the EarnVault.
/// @custom:lock-stable earnVault != address(0)
/// The venue and its base asset are fixed and nonzero.
/// @custom:invariant address(vault) != address(0) && baseAsset != address(0)
/// The effective name and symbol are never empty.
/// @custom:invariant bytes(_name).length > 0 && bytes(_symbol).length > 0
/// Ghost records of the last redemption's measured venue-share burn and the last exact withdrawal's measured
/// receiver increase.
/// @custom:ghost uint256 burnedShares
/// @custom:ghost uint256 measuredReceived
/// Solvency: deposits credit the measured venue-share increase, and every exit reports the measured decrease,
/// so the EarnVault's engine-share ledger moves with the shares this engine holds (see their ensures).
/// Not proved: that the venue shares held cover the engine shares the EarnVault records; shares can move
/// outside these calls.
contract ERC4626Engine is
    IEarnEngine,
    IEarnEngineRedeem,
    IEarnEngineExactWithdraw,
    IEarnEngineInKindDeposit,
    Ownable2Step
{
    IERC4626Vault public immutable vault;
    address public immutable baseAsset;
    uint256 private immutable _shareScale;
    string internal _name;
    string internal _symbol;

    address public earnVault;
    uint256 private locked = 1;

    event EarnVaultInitialized(address indexed earnVault);
    event Deposited(address indexed earnVault, uint256 assets, uint256 engineShares);
    event VenueSharesDeposited(address indexed from, uint256 requestedVenueShares, uint256 receivedEngineShares);
    event Redeemed(address indexed receiver, uint256 engineShares, uint256 assets);
    event WithdrewExact(address indexed receiver, uint256 assets, uint256 engineSharesBurned);

    error AlreadyInitialized();
    error EarnVaultNotSet();
    error EmptyMetadata();
    error InvalidVenueShareDecimals();
    error InsufficientAssetsReceived(uint256 minimumAssets, uint256 actualAssets);
    error NoVenueSharesReceived();
    error NotEarnVault(address caller);
    error ReentrantCall();
    error TransferFailed();
    error UnexpectedAssetsReceived(uint256 expectedAssets, uint256 actualAssets);
    error UnexpectedVenueSharesBurned(uint256 expectedShares, uint256 actualShares);
    error ZeroAddress();

    modifier onlyEarnVault() {
        if (earnVault == address(0)) revert EarnVaultNotSet();
        if (msg.sender != earnVault) revert NotEarnVault(msg.sender);
        _;
    }

    modifier nonReentrant() {
        if (locked != 1) revert ReentrantCall();
        locked = 2;
        _;
        locked = 1;
    }

    /// A nonempty override wins; otherwise the vault's own name and symbol are used.
    /// @custom:ensures bytes(nameOverride_).length > 0 ==> keccak256(bytes(_name)) == keccak256(bytes(nameOverride_))
    /// @custom:ensures bytes(symbolOverride_).length > 0 ==> keccak256(bytes(_symbol)) == keccak256(bytes(symbolOverride_))
    /// @custom:ensures vault == vault_ && earnVault == address(0) && owner() == owner_
    constructor(IERC4626Vault vault_, address owner_, string memory nameOverride_, string memory symbolOverride_)
        Ownable(owner_)
    {
        if (address(vault_) == address(0)) revert ZeroAddress();
        address asset_ = vault_.asset();
        if (asset_ == address(0)) revert ZeroAddress();
        uint8 shareDecimals = vault_.decimals();
        if (shareDecimals > 77) revert InvalidVenueShareDecimals();
        vault = vault_;
        baseAsset = asset_;
        _shareScale = 10 ** uint256(shareDecimals);
        _name = bytes(nameOverride_).length == 0 ? vault_.name() : nameOverride_;
        _symbol = bytes(symbolOverride_).length == 0 ? vault_.symbol() : symbolOverride_;
        if (bytes(_name).length == 0 || bytes(_symbol).length == 0) revert EmptyMetadata();
    }

    /// Only the owner binds, once, to a nonzero EarnVault; ownership is unchanged.
    /// @custom:ensures old(owner()) == msg.sender && old(earnVault) == address(0)
    /// @custom:ensures earnVault == earnVault_ && earnVault_ != address(0)
    /// @custom:ensures owner() == old(owner()) && pendingOwner() == old(pendingOwner())
    function initializeEarnVault(address earnVault_) external onlyOwner {
        _initializeEarnVault(earnVault_);
    }

    /// @notice One-time binding followed by an immediate ownership transfer during setup.
    /// @dev The atomic setup path intentionally bypasses the pending-owner acceptance step.
    /// Only the owner binds, once, to a nonzero EarnVault, and hands ownership to a nonzero final owner.
    /// @custom:ensures old(owner()) == msg.sender && old(earnVault) == address(0)
    /// @custom:ensures earnVault == earnVault_ && earnVault_ != address(0)
    /// @custom:ensures owner() == finalOwner_ && finalOwner_ != address(0) && pendingOwner() == address(0)
    function initializeEarnVault(address earnVault_, address finalOwner_) external onlyOwner {
        if (finalOwner_ == address(0)) revert ZeroAddress();
        _initializeEarnVault(earnVault_);
        _transferOwnership(finalOwner_);
    }

    /// @custom:ensures old(earnVault) == address(0) && earnVault_ != address(0) && earnVault == earnVault_
    function _initializeEarnVault(address earnVault_) internal {
        if (earnVault != address(0)) revert AlreadyInitialized();
        if (earnVault_ == address(0)) revert ZeroAddress();
        earnVault = earnVault_;
        emit EarnVaultInitialized(earnVault_);
    }

    /// @custom:ensures result == baseAsset
    function asset() external view returns (address) {
        return baseAsset;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /// @custom:ensures result == _shareScale
    function shareScale() external view returns (uint256) {
        return _shareScale;
    }

    function totalShares() public view returns (uint256) {
        return vault.balanceOf(address(this));
    }

    /// Only the bound EarnVault calls it.
    /// @custom:ensures old(earnVault) != address(0) && msg.sender == old(earnVault)
    // Not proved: the binding and lock release after deposit are not stated here, because the
    // verifier havocs all storage across a call on the right of && under the lock (_forceApprove).
    /// A deposit credits a positive measured venue-share delta.
    /// @custom:ensures engineShares > 0
    /// Not proved: liveness. A deposit also needs the token pull and the venue's deposit to mint shares,
    /// outside this contract.
    function deposit(uint256 assets) external onlyEarnVault nonReentrant returns (uint256 engineShares) {
        _pull(baseAsset, msg.sender, assets);
        _forceApprove(baseAsset, address(vault), assets);

        uint256 beforeBalance = vault.balanceOf(address(this));
        vault.deposit(assets, address(this));
        engineShares = vault.balanceOf(address(this)) - beforeBalance;

        /// The measured delta on top of the balance before is the balance after, a uint256.
        /// @custom:assert beforeBalance + engineShares <= type(uint256).max
        _forceApprove(baseAsset, address(vault), 0);
        if (engineShares == 0) revert NoVenueSharesReceived();
        emit Deposited(msg.sender, assets, engineShares);
    }

    /// Only the bound EarnVault calls it; the binding and the lock survive the call.
    /// @custom:ensures old(earnVault) != address(0) && msg.sender == old(earnVault)
    /// @custom:ensures earnVault != address(0) && locked == 1
    /// In-kind entry pulls from a nonzero holder and credits a positive measured venue-share delta.
    /// @custom:ensures from != address(0) && engineSharesReceived > 0
    function depositInKind(uint256 venueShares, address from)
        external
        onlyEarnVault
        nonReentrant
        returns (uint256 engineSharesReceived)
    {
        if (from == address(0)) revert ZeroAddress();
        uint256 beforeBalance = vault.balanceOf(address(this));
        _pull(address(vault), from, venueShares);
        engineSharesReceived = vault.balanceOf(address(this)) - beforeBalance;
        /// The measured delta on top of the balance before is the balance after, a uint256.
        /// @custom:assert beforeBalance + engineSharesReceived <= type(uint256).max
        if (engineSharesReceived == 0) revert NoVenueSharesReceived();
        emit VenueSharesDeposited(from, venueShares, engineSharesReceived);
    }

    /// Only the bound EarnVault calls it; the binding and the lock survive the call.
    /// @custom:ensures old(earnVault) != address(0) && msg.sender == old(earnVault)
    /// @custom:ensures earnVault != address(0) && locked == 1
    /// The receiver is nonzero and its measured increase meets the caller's minimum.
    /// @custom:ensures receiver != address(0) && assets >= minAssets
    /// The venue burned exactly the requested shares, measured on the engine's balance.
    /// @custom:ensures burnedShares == engineShares
    /// Not proved: liveness. A redemption also needs the venue's redeem to succeed and pay at least
    /// minAssets, outside this contract.
    function redeem(uint256 engineShares, address receiver, uint256 minAssets)
        external
        onlyEarnVault
        nonReentrant
        returns (uint256 assets)
    {
        if (receiver == address(0)) revert ZeroAddress();
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 receiverAssetsBefore = IERC20Like(baseAsset).balanceOf(receiver);
        vault.redeem(engineShares, receiver, address(this));

        uint256 sharesBurned = _balanceDecrease(address(vault), address(this), sharesBefore);
        /// @custom:ghost burnedShares = sharesBurned
        if (sharesBurned != engineShares) revert UnexpectedVenueSharesBurned(engineShares, sharesBurned);
        /// The venue burned exactly the requested shares.
        /// @custom:assert sharesBurned == engineShares
        assets = _balanceIncrease(baseAsset, receiver, receiverAssetsBefore);
        if (assets < minAssets) revert InsufficientAssetsReceived(minAssets, assets);
        emit Redeemed(receiver, engineShares, assets);
    }

    /// Only the bound EarnVault calls it; the binding and the lock survive the call.
    /// @custom:ensures old(earnVault) != address(0) && msg.sender == old(earnVault)
    /// @custom:ensures earnVault != address(0) && locked == 1
    /// @custom:ensures receiver != address(0)
    /// The receiver's measured increase is exactly the requested assets.
    /// @custom:ensures measuredReceived == assets
    /// Not proved: liveness. An exact withdrawal also needs the venue's withdraw to succeed, outside this contract.
    function withdraw(uint256 assets, address receiver)
        external
        onlyEarnVault
        nonReentrant
        returns (uint256 engineShares)
    {
        if (receiver == address(0)) revert ZeroAddress();
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 receiverAssetsBefore = IERC20Like(baseAsset).balanceOf(receiver);
        vault.withdraw(assets, receiver, address(this));

        engineShares = _balanceDecrease(address(vault), address(this), sharesBefore);
        uint256 receivedAssets = _balanceIncrease(baseAsset, receiver, receiverAssetsBefore);
        /// @custom:ghost measuredReceived = receivedAssets
        if (receivedAssets != assets) revert UnexpectedAssetsReceived(assets, receivedAssets);
        /// The receiver's measured increase is exactly the requested assets.
        /// @custom:assert receivedAssets == assets
        emit WithdrewExact(receiver, assets, engineShares);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256 engineShares) {
        return vault.previewWithdraw(assets);
    }

    function previewRedeem(uint256 engineShares) external view returns (uint256 assets) {
        return vault.previewRedeem(engineShares);
    }

    function valueOf(uint256 engineShares) external view returns (uint256 assets) {
        return vault.previewRedeem(engineShares);
    }

    function totalAssets() external view returns (uint256 assets) {
        return vault.previewRedeem(totalShares());
    }

    /// Advertises ERC-165, the engine, redeem, exact withdraw and in-kind entry, and nothing else.
    /// @custom:ensures interfaceId == type(IERC165).interfaceId ==> result
    /// @custom:ensures interfaceId == type(IEarnEngine).interfaceId ==> result
    /// @custom:ensures interfaceId == type(IEarnEngineRedeem).interfaceId ==> result
    /// @custom:ensures interfaceId == type(IEarnEngineExactWithdraw).interfaceId ==> result
    /// @custom:ensures interfaceId == type(IEarnEngineInKindDeposit).interfaceId ==> result
    /// @custom:ensures result ==> _isAdvertised(interfaceId)
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IEarnEngine).interfaceId
            || interfaceId == type(IEarnEngineRedeem).interfaceId
            || interfaceId == type(IEarnEngineExactWithdraw).interfaceId
            || interfaceId == type(IEarnEngineInKindDeposit).interfaceId;
    }

    /// @custom:spec
    function _isAdvertised(bytes4 interfaceId) internal pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IEarnEngine).interfaceId
            || interfaceId == type(IEarnEngineRedeem).interfaceId
            || interfaceId == type(IEarnEngineExactWithdraw).interfaceId
            || interfaceId == type(IEarnEngineInKindDeposit).interfaceId;
    }

    function _pull(address token, address from, uint256 amount) private {
        if (!IERC20Like(token).transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _forceApprove(address token, address spender, uint256 amount) private {
        if (!IERC20Like(token).approve(spender, 0)) revert TransferFailed();
        if (amount != 0 && !IERC20Like(token).approve(spender, amount)) revert TransferFailed();
    }

    /// The increase is zero or a real increase over `balanceBefore`: before plus increase is the balance after.
    /// @custom:ensures balanceBefore + increase <= type(uint256).max
    function _balanceIncrease(address token, address account, uint256 balanceBefore)
        private
        view
        returns (uint256 increase)
    {
        uint256 balanceAfter = IERC20Like(token).balanceOf(account);
        if (balanceAfter > balanceBefore) increase = balanceAfter - balanceBefore;
    }

    /// The decrease is zero or a real decrease from `balanceBefore`.
    /// @custom:ensures decrease <= balanceBefore
    function _balanceDecrease(address token, address account, uint256 balanceBefore)
        private
        view
        returns (uint256 decrease)
    {
        uint256 balanceAfter = IERC20Like(token).balanceOf(account);
        if (balanceBefore > balanceAfter) decrease = balanceBefore - balanceAfter;
    }
}
