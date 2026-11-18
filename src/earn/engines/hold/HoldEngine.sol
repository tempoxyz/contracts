// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IEarnEngine } from "../../../interfaces/earn/engines/IEarnEngine.sol";
import { IEarnEngineExactWithdraw } from "../../../interfaces/earn/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineRedeem } from "../../../interfaces/earn/engines/IEarnEngineRedeem.sol";
import { IEarnVault } from "../../../interfaces/earn/IEarnVault.sol";

/// @notice Venue-less engine that holds its EarnVault's base asset 1:1.
/// @dev One engine share is one raw unit of the base asset the engine holds, so `valueOf(s) == s` and the
///      EarnShare exchange rate moves only when backing arrives without supply: `EarnVault.contribute` or
///      absorbed surplus. Base asset sent directly to the engine is raw surplus the EarnVault quarantines.
///      There is no venue, oracle, or expiring valuation, so it does not advertise fee valuation.
/// Specs (docs/earn/modules/hold.md, docs/earn/integrations/engines.md):
/// The OpenZeppelin ReentrancyGuard lock (`_status` is 2 while entered) guards every fund flow.
/// @custom:reentrancy-guard _status == 2
/// @custom:lock-stable earnVault != address(0)
/// Ghost record of the engine's base-asset holding (its engine shares) before and after each call.
/// @custom:ghost uint256 heldBefore
/// @custom:ghost uint256 heldAfter
/// Solvency: every deposit, redemption and exact withdrawal reports exactly the measured change in the base
/// asset the engine holds, so the EarnVault's engine-share ledger moves with the holding.
contract HoldEngine is IEarnEngine, IEarnEngineExactWithdraw, IEarnEngineRedeem, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error NotEarnVault();
    error AlreadyBound();
    error InvalidAmount();
    error InvalidReceiver();
    error InexactTransfer();
    error InsufficientAssetsReceived();

    event EarnVaultInitialized(address indexed earnVault);
    event Deposited(address indexed earnVault, uint256 assets, uint256 engineShares);
    event Redeemed(address indexed receiver, uint256 engineShares, uint256 assets);
    event WithdrewExact(address indexed receiver, uint256 assets, uint256 engineSharesBurned);

    address public immutable asset;
    uint256 public immutable shareScale;
    string public name;
    string public symbol;
    address public earnVault;

    modifier onlyEarnVault() {
        if (msg.sender != earnVault || earnVault == address(0)) revert NotEarnVault();
        _;
    }

    /// @param asset_ The base asset; must have code and nonzero metadata decimals no greater than 77.
    /// @custom:ensures asset == asset_ && earnVault == address(0)
    constructor(address asset_, address owner_, string memory name_, string memory symbol_) Ownable(owner_) {
        if (asset_.code.length == 0 || bytes(name_).length == 0 || bytes(symbol_).length == 0) {
            revert InvalidConfiguration();
        }
        uint8 decimals = IERC20Metadata(asset_).decimals();
        if (decimals > 77) revert InvalidConfiguration();
        asset = asset_;
        shareScale = 10 ** uint256(decimals);
        name = name_;
        symbol = symbol_;
    }

    /// Only the owner binds, once, to an EarnVault with code and the same asset; ownership is unchanged.
    /// @custom:ensures old(owner()) == msg.sender && old(earnVault) == address(0) && earnVault == vault_
    function initializeEarnVault(address vault_) external onlyOwner {
        _bind(vault_);
    }

    /// Only the owner binds, once, and hands ownership to a nonzero final owner.
    /// @custom:ensures old(earnVault) == address(0) && earnVault == vault_ && owner() == finalOwner_
    function initializeEarnVault(address vault_, address finalOwner_) external onlyOwner {
        if (finalOwner_ == address(0)) revert InvalidConfiguration();
        _bind(vault_);
        _transferOwnership(finalOwner_);
    }

    function _bind(address vault_) private {
        if (earnVault != address(0)) revert AlreadyBound();
        if (vault_.code.length == 0 || IEarnVault(vault_).asset() != asset) revert InvalidConfiguration();
        earnVault = vault_;
        emit EarnVaultInitialized(vault_);
    }

    /// Advertises ERC-165, the engine, exact withdraw and redeem, and nothing else.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IEarnEngine).interfaceId
            || id == type(IEarnEngineExactWithdraw).interfaceId || id == type(IEarnEngineRedeem).interfaceId;
    }

    /// Raw custody: the base asset the engine holds, including any direct transfers the EarnVault quarantines.
    function totalShares() public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function totalAssets() external view returns (uint256) {
        return totalShares();
    }

    /// @custom:ensures result == engineShares
    function valueOf(uint256 engineShares) public pure returns (uint256) {
        return engineShares;
    }

    function previewRedeem(uint256 engineShares) external pure returns (uint256) {
        return engineShares;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        if (assets == 0) revert InvalidAmount();
        return assets;
    }

    /// @custom:ensures msg.sender == earnVault && assets > 0 && engineShares == assets
    /// @custom:ensures heldAfter == heldBefore + engineShares
    function deposit(uint256 assets) external nonReentrant onlyEarnVault returns (uint256 engineShares) {
        if (assets == 0) revert InvalidAmount();
        uint256 before = totalShares();
        /// @custom:ghost heldBefore = before
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        engineShares = totalShares() - before;
        /// @custom:ghost heldAfter = before + engineShares
        if (engineShares != assets) revert InexactTransfer();
        emit Deposited(msg.sender, assets, engineShares);
    }

    /// @custom:ensures msg.sender == earnVault && engineShares > 0 && assets >= minAssets
    /// @custom:ensures heldAfter + engineShares == heldBefore
    function redeem(uint256 engineShares, address receiver, uint256 minAssets)
        external
        nonReentrant
        onlyEarnVault
        returns (uint256 assets)
    {
        if (engineShares == 0 || engineShares > totalShares()) revert InvalidAmount();
        assets = _pay(engineShares, receiver);
        if (assets < minAssets) revert InsufficientAssetsReceived();
        emit Redeemed(receiver, engineShares, assets);
    }

    /// @custom:ensures msg.sender == earnVault && assets > 0 && engineShares == assets
    /// @custom:ensures heldAfter + engineShares == heldBefore
    function withdraw(uint256 assets, address receiver)
        external
        nonReentrant
        onlyEarnVault
        returns (uint256 engineShares)
    {
        if (assets == 0 || assets > totalShares()) revert InvalidAmount();
        if (_pay(assets, receiver) != assets) revert InexactTransfer();
        engineShares = assets;
        emit WithdrewExact(receiver, assets, engineShares);
    }

    /// Sends `amount` to `receiver` and returns the receiver's measured increase; the engine's holding must fall
    /// by exactly `amount`.
    function _pay(uint256 amount, address receiver) private returns (uint256 received) {
        if (receiver == address(0) || receiver == address(this)) revert InvalidReceiver();
        uint256 engineBefore = totalShares();
        /// @custom:ghost heldBefore = engineBefore
        uint256 receiverBefore = IERC20(asset).balanceOf(receiver);
        IERC20(asset).safeTransfer(receiver, amount);
        /// @custom:ghost heldAfter = totalShares()
        if (totalShares() != engineBefore - amount) revert InexactTransfer();
        received = IERC20(asset).balanceOf(receiver) - receiverBefore;
    }
}
