// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The address one queued Upshift redemption is paid to. {UpshiftEngine} deploys a minimal proxy of
///         this contract per request, so the vault's per-receiver queue holds exactly one request.
/// @dev The engine that deployed the implementation is the only caller, for every proxy.
contract UpshiftRedeemReceiver {
    using SafeERC20 for IERC20;

    error NotEngine();

    address public immutable engine;

    constructor() {
        engine = msg.sender;
    }

    /// @notice Sends this receiver's whole `token` balance to `to`.
    function sweep(address token, address to) external returns (uint256 amount) {
        if (msg.sender != engine) revert NotEngine();
        amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) IERC20(token).safeTransfer(to, amount);
    }
}
