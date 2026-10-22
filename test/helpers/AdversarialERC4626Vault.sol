// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20Like } from "../../src/interfaces/external/IERC20Like.sol";

/// @dev ERC-4626-shaped venue that can make its return values disagree with its custody effects.
contract AdversarialERC4626Vault {
    string public name = "Adversarial Venue";
    string public symbol = "advVEN";
    uint8 public constant decimals = 18;
    address public immutable asset;

    uint256 public totalSupply;
    uint256 public reportedRedeemAssets;
    uint256 public deliveredRedeemAssets;
    uint256 public burnedRedeemShares;
    uint256 public reportedWithdrawShares;
    uint256 public burnedWithdrawShares;
    uint256 public deliveredWithdrawAssets;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address asset_) {
        asset = asset_;
    }

    function setRedeemBehavior(uint256 reportedAssets, uint256 deliveredAssets, uint256 burnedShares) external {
        reportedRedeemAssets = reportedAssets;
        deliveredRedeemAssets = deliveredAssets;
        burnedRedeemShares = burnedShares;
    }

    function setWithdrawBehavior(uint256 reportedShares, uint256 burnedShares, uint256 deliveredAssets) external {
        reportedWithdrawShares = reportedShares;
        burnedWithdrawShares = burnedShares;
        deliveredWithdrawAssets = deliveredAssets;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) {
            require(approved >= value, "ALLOWANCE");
            allowance[from][msg.sender] = approved - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256 venueShares) {
        return assets;
    }

    function previewRedeem(uint256 venueShares) external pure returns (uint256 assets) {
        return venueShares;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 venueShares) {
        require(IERC20Like(asset).transferFrom(msg.sender, address(this), assets), "ASSET_TRANSFER_FROM");
        venueShares = assets;
        totalSupply += venueShares;
        balanceOf[receiver] += venueShares;
    }

    function redeem(uint256 venueShares, address receiver, address owner) external returns (uint256 assets) {
        uint256 sharesToBurn = burnedRedeemShares == 0 ? venueShares : burnedRedeemShares;
        _spendAllowance(owner, sharesToBurn);
        _burn(owner, sharesToBurn);

        uint256 deliveredAssets = deliveredRedeemAssets == 0 ? venueShares : deliveredRedeemAssets;
        require(IERC20Like(asset).transfer(receiver, deliveredAssets), "ASSET_TRANSFER");
        assets = reportedRedeemAssets == 0 ? deliveredAssets : reportedRedeemAssets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 venueShares) {
        uint256 sharesToBurn = burnedWithdrawShares == 0 ? assets : burnedWithdrawShares;
        _spendAllowance(owner, sharesToBurn);
        _burn(owner, sharesToBurn);

        uint256 deliveredAssets = deliveredWithdrawAssets == 0 ? assets : deliveredWithdrawAssets;
        require(IERC20Like(asset).transfer(receiver, deliveredAssets), "ASSET_TRANSFER");
        venueShares = reportedWithdrawShares == 0 ? sharesToBurn : reportedWithdrawShares;
    }

    function _spendAllowance(address owner, uint256 shares) private {
        if (msg.sender == owner) return;
        uint256 approved = allowance[owner][msg.sender];
        if (approved != type(uint256).max) {
            require(approved >= shares, "SHARE_ALLOWANCE");
            allowance[owner][msg.sender] = approved - shares;
        }
    }

    function _burn(address owner, uint256 shares) private {
        require(balanceOf[owner] >= shares, "SHARE_BALANCE");
        balanceOf[owner] -= shares;
        totalSupply -= shares;
    }

    function _transfer(address from, address to, uint256 value) private {
        require(to != address(0), "ZERO_TO");
        require(balanceOf[from] >= value, "SHARE_BALANCE");
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }
}
