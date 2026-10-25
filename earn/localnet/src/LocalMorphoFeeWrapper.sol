// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IERC20Like } from "../../src/interfaces/external/IERC20Like.sol";

interface ILocalMorphoVault {
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}

/// @notice Disposable stand-in for a Morpho fee wrapper that allocates into the same ERC-4626
///         Morpho vault later wrapped directly by Tempo Earn.
/// @dev The fixture deliberately exposes only the ERC-20/ERC-4626 surface required by the migration
///      E2E. It is local test infrastructure, not a production vault or fee implementation.
contract LocalMorphoFeeWrapper {
    string public constant name = "Tempo Earn Local Morpho Fee Wrapper";
    string public constant symbol = "teMORPHOFEES";
    uint8 public constant decimals = 6;

    ILocalMorphoVault public immutable venue;
    address public immutable asset;
    uint256 public totalSupply;

    mapping(address account => uint256 shares) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    error AllowanceExceeded();
    error InsufficientOutput();
    error InsufficientShares();
    error TokenCallFailed();
    error TokenCallFalse();
    error ZeroAddress();
    error ZeroAmount();

    constructor(ILocalMorphoVault venue_) {
        if (address(venue_) == address(0)) revert ZeroAddress();
        address asset_ = venue_.asset();
        if (asset_ == address(0)) revert ZeroAddress();
        venue = venue_;
        asset = asset_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, amount);
        _transfer(from, to, amount);
        return true;
    }

    function totalAssets() public view returns (uint256) {
        return venue.convertToAssets(venue.balanceOf(address(this)));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        uint256 managedAssets = totalAssets();
        if (supply == 0 || managedAssets == 0) return assets;
        return Math.mulDiv(assets, supply, managedAssets);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return shares;
        return Math.mulDiv(shares, totalAssets(), supply);
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        shares = convertToShares(assets);
        if (shares == 0) revert InsufficientOutput();

        _safeTransferFrom(asset, msg.sender, address(this), assets);
        _safeApprove(asset, address(venue), 0);
        _safeApprove(asset, address(venue), assets);
        if (venue.deposit(assets, address(this)) == 0) revert InsufficientOutput();
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0) || owner == address(0)) revert ZeroAddress();

        uint256 supply = totalSupply;
        assets = convertToAssets(shares);
        if (assets == 0) revert InsufficientOutput();
        if (msg.sender != owner) _spendAllowance(owner, shares);
        _burn(owner, shares);

        if (shares == supply) {
            assets = venue.redeem(venue.balanceOf(address(this)), receiver, address(this));
        } else {
            venue.withdraw(assets, receiver, address(this));
        }
        if (assets == 0) revert InsufficientOutput();
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function _spendAllowance(address owner, uint256 amount) private {
        uint256 allowed = allowance[owner][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert AllowanceExceeded();
            allowance[owner][msg.sender] = allowed - amount;
            emit Approval(owner, msg.sender, allowance[owner][msg.sender]);
        }
    }

    function _mint(address to, uint256 amount) private {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) private {
        if (balanceOf[from] < amount) revert InsufficientShares();
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < amount) revert InsufficientShares();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _safeApprove(address token, address spender, uint256 amount) private {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Like.approve.selector, spender, amount));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        _callOptionalReturn(token, abi.encodeWithSelector(IERC20Like.transferFrom.selector, from, to, amount));
    }

    function _callOptionalReturn(address token, bytes memory data) private {
        (bool ok, bytes memory returnData) = token.call(data);
        if (!ok) revert TokenCallFailed();
        if (returnData.length != 0 && !abi.decode(returnData, (bool))) revert TokenCallFalse();
    }
}
