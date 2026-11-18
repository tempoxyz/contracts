// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20 } from "../interfaces/external/tempo/ITIP20.sol";

/// @notice Permissionless minter for a disposable hosted base/alternate TIP-20 fixture pair.
/// @dev Test scaffolding only. The fixture deployer creates both tokens and grants this contract
///      `ISSUER_ROLE`; anyone may then mint either token, so it must never issue a real asset.
contract DemoStablecoinFunder {
    address public immutable baseAsset;
    address public immutable alternateAsset;

    error InvalidToken();
    error SameToken();
    error ZeroAddress();
    error ZeroAmount();

    constructor(address baseAsset_, address alternateAsset_) {
        if (baseAsset_ == address(0) || alternateAsset_ == address(0)) revert ZeroAddress();
        if (baseAsset_ == alternateAsset_) revert SameToken();
        baseAsset = baseAsset_;
        alternateAsset = alternateAsset_;
    }

    /// @notice Mints `amount` of either fixture token to `receiver`.
    function fund(address token, address receiver, uint256 amount) external {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (token != baseAsset && token != alternateAsset) revert InvalidToken();
        ITIP20(token).mint(receiver, amount);
    }
}
