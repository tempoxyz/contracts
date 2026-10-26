// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardProgram } from "../harness/CardProgram.sol";
import { Decline, PullOutcome } from "../harness/SpendRail.sol";

/// @notice Default hook implementations shared by every rail. Kept on the rail side of the
///         inheritance graph so scenario contracts and rails never both implement a hook.
abstract contract RailDefaults is CardProgram {
    function _railSetUp() internal virtual override { }

    function _giveStablecoin(address user, uint256 amount) internal virtual override {
        _mintUsd(user, amount);
    }

    function _previewShares(uint256 assets) internal view virtual override returns (uint256) {
        return earnVault.previewWithdraw(assets);
    }

    function _railShares(address user) internal view virtual override returns (uint256) {
        return earnShare.balanceOf(user);
    }

    function _railPullSplit(address, uint256, uint256, bytes32) internal virtual override returns (PullOutcome) {
        revert("split funding unsupported");
    }

    function _railDeclineError(Decline) internal view virtual override returns (bytes4) {
        return bytes4(0);
    }

    function _railZoneKeyWithdrawTo(address, address, uint256) internal virtual override returns (bool) {
        revert("no Zone access key");
    }
}
