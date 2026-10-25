// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Simple4626Vault } from "./Simple4626Vault.sol";

/// @notice Minimal fixture funder that mints or transfers `amount` of `token` to `receiver`.
interface ISeedFunder {
    function fund(address token, address receiver, uint256 amount) external;
}

/// @notice Hosted-demo vault with constructor-atomic, permanently locked initial liquidity.
/// @dev The funder delivers the seed directly to this contract before any third party can deposit.
contract SeededSimple4626Vault is Simple4626Vault {
    address private constant LOCKED_LIQUIDITY = 0x000000000000000000000000000000000000dEaD;

    error InvalidSeed();

    constructor(
        address asset_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        ISeedFunder funder_,
        uint256 seedAssets_
    ) Simple4626Vault(asset_, name_, symbol_, decimals_) {
        if (address(funder_) == address(0) || seedAssets_ == 0) revert InvalidSeed();
        funder_.fund(asset_, address(this), seedAssets_);
        if (totalAssets() != seedAssets_) revert InvalidSeed();
        uint256 seedShares = _scaleInitialAssetsToShares(seedAssets_);
        if (seedShares == 0) revert InvalidSeed();
        _mint(LOCKED_LIQUIDITY, seedShares);
        emit Deposit(msg.sender, LOCKED_LIQUIDITY, seedAssets_, seedShares);
    }
}
