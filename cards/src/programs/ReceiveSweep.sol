// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

interface ITIP20Memo {
    function transferFromWithMemo(address from, address to, uint256 amount, bytes32 memo) external returns (bool);
}

/// @title ReceiveSweep
/// @notice An owner's receive policy: money paid to it through `pay` first lands as a normal credit, so the core
///         repays the owner's capped debt from it, and what is left goes into the owner's chosen savings vault as
///         shares in the owner's name. The owner sets the vault and approves this contract to move the token; a plain
///         transfer to the owner skips the policy.
contract ReceiveSweep {
    using SafeTransferLib for address;

    /// @notice The vault an owner sweeps `token` into; zero means no sweep.
    mapping(address owner => mapping(address token => IEarnVault)) public sweepOf;

    event SweepSet(address indexed owner, address indexed token, address vault);
    event Swept(address indexed owner, address indexed token, address indexed vault, uint256 assets, uint256 shares);
    /// @notice The owner's vault refused the deposit, so the payment stayed with the owner as cash.
    event SweepRefused(address indexed owner, address indexed token, address indexed vault, uint256 assets);

    error InvalidVault();

    /// @notice Sets where the caller's incoming `token` goes after debt; the zero vault turns the sweep off.
    function setSweep(address token, IEarnVault vault) external {
        if (address(vault) != address(0) && vault.asset() != token) revert InvalidVault();
        sweepOf[msg.sender][token] = vault;
        emit SweepSet(msg.sender, token, address(vault));
    }

    /// @notice Pays `amount` of `token` from the caller to `owner` with `memo`, then sweeps what the credit left
    ///         after debt repayment into the owner's vault. A vault that refuses the deposit leaves it with the owner
    ///         as cash. Returns the assets swept.
    function pay(address owner, address token, uint256 amount, bytes32 memo) external returns (uint256 swept) {
        uint256 before = IERC20Like(token).balanceOf(owner);
        ITIP20Memo(token).transferFromWithMemo(msg.sender, owner, amount, memo);
        IEarnVault vault = sweepOf[owner][token];
        if (address(vault) == address(0)) return 0;
        uint256 landed = IERC20Like(token).balanceOf(owner);
        // The core repays debt out of the credit, so only the rise in the owner's balance is the owner's to sweep.
        swept = landed > before ? landed - before : 0;
        if (swept == 0) return 0;
        // Moves only what the caller's own payment added, from an owner that opted in, into a vault in its own name.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        token.safeTransferFrom(owner, address(this), swept);
        token.safeApprove(address(vault), swept);
        try vault.deposit(swept, owner, 1) returns (uint256 shares) {
            emit Swept(owner, token, address(vault), swept, shares);
        } catch {
            // A paused or full vault must not fail the payment: the owner keeps the tokens.
            token.safeApprove(address(vault), 0);
            token.safeTransfer(owner, swept);
            emit SweepRefused(owner, token, address(vault), swept);
            swept = 0;
        }
    }
}
