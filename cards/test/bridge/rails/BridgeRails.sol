// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IAllowanceTransfer } from "permit2/interfaces/IAllowanceTransfer.sol";

import { Funding, PullOutcome, RailCaps } from "../harness/SpendRail.sol";
import { RailDefaults } from "./RailDefaults.sol";

/// @notice What Bridge runs today: a debitor calls `SpenderFactory.transferToDestination` and the
///         program's spender clone pulls from a standing allowance. Returns, refunds and dispute
///         credits come back as stablecoin from Bridge liquidity (monorail's crypto return trip).
abstract contract BridgeRailBase is RailDefaults {
    address internal elsewhere = makeAddr("cardholder.elsewhere");

    function _bridgePull(bytes memory data) internal returns (PullOutcome) {
        vm.prank(bridgeDebitor);
        try bridgeFactory.transferToDestination(SPENDER_ID, settlement, data) {
            delete lastPullError;
            return PullOutcome.Settled;
        } catch (bytes memory err) {
            lastPullError = err;
            return PullOutcome.Rejected;
        }
    }

    function _railCredit(address user, uint256 amount, bytes32) internal virtual override {
        vm.prank(programWallet);
        usd.transfer(user, amount);
    }
}

/// @notice Bridge `SpenderErc20` ("EA"): stablecoin only.
abstract contract BridgeErc20Rail is BridgeRailBase {
    function _railName() internal pure override returns (string memory) {
        return "bridge.erc20 (EA)";
    }

    function _railCaps() internal pure override returns (RailCaps memory caps) { }

    function _railEnroll(address user, uint256 amount) internal override {
        require(_funding() == Funding.Stablecoin, "EA spends stablecoin only");
        _mintUsd(user, amount);
        vm.prank(user);
        usd.approve(spender, CARD_BUDGET);
    }

    function _railPull(address user, uint256 amount, bytes32) internal override returns (PullOutcome) {
        return _bridgePull(abi.encodePacked(PREFIX_ERC20, user, address(usd), amount));
    }

    function _railValue(address user) internal view override returns (uint256) {
        return usd.balanceOf(user);
    }

    /// @dev The only control is the allowance, which is a lifetime cap rather than a period cap.
    function _railSetSpendLimit(address user, uint256 limit) internal override {
        vm.prank(user);
        usd.approve(spender, limit);
    }

    function _railRevoke(address user) internal override {
        vm.prank(user);
        usd.approve(spender, 0);
    }

    function _railDrain(address user) internal override {
        uint256 bal = usd.balanceOf(user);
        vm.prank(user);
        usd.transfer(elsewhere, bal);
    }
}

/// @notice Bridge `SpenderPermit2` ("P2"): stablecoin through a Permit2 allowance. The wallet
///         approves Permit2 once, then grants the program's clone an amount that expires.
abstract contract BridgePermit2Rail is BridgeRailBase {
    uint48 internal constant PERMIT2_VALIDITY = 365 days;

    function _railName() internal pure override returns (string memory) {
        return "bridge.permit2 (P2)";
    }

    function _railCaps() internal pure override returns (RailCaps memory caps) { }

    function _railEnroll(address user, uint256 amount) internal override {
        require(_funding() == Funding.Stablecoin, "P2 spends stablecoin only");
        _mintUsd(user, amount);
        vm.prank(user);
        usd.approve(permit2, type(uint256).max);
        _permit(user, CARD_BUDGET);
    }

    function _railPull(address user, uint256 amount, bytes32) internal override returns (PullOutcome) {
        return _bridgePull(abi.encodePacked(PREFIX_PERMIT2, user, address(usd), amount));
    }

    function _railValue(address user) internal view override returns (uint256) {
        return usd.balanceOf(user);
    }

    /// @dev A Permit2 amount is spent down like an allowance: a cap until it expires, not a
    ///      period limit.
    function _railSetSpendLimit(address user, uint256 limit) internal override {
        _permit(user, limit);
    }

    function _railRevoke(address user) internal override {
        _permit(user, 0);
    }

    function _railDrain(address user) internal override {
        uint256 bal = usd.balanceOf(user);
        vm.prank(user);
        usd.transfer(elsewhere, bal);
    }

    function _permit(address user, uint256 amount) internal {
        uint48 expiration = uint48(block.timestamp) + PERMIT2_VALIDITY;
        vm.prank(user);
        IAllowanceTransfer(permit2).approve(address(usd), spender, uint160(amount), expiration);
    }
}

/// @notice Bridge `SpenderTEWF` ("TF"): Tempo Earn shares by user preference, else stablecoin.
abstract contract BridgeTewfRail is BridgeRailBase {
    function _railName() internal pure override returns (string memory) {
        return "bridge.tempo-earn (TF)";
    }

    function _railCaps() internal view override returns (RailCaps memory caps) {
        caps.earn = _funding() == Funding.Earn;
    }

    function _railEnroll(address user, uint256 amount) internal override {
        _mintUsd(user, amount);
        if (_funding() == Funding.Stablecoin) {
            vm.prank(user);
            usd.approve(spender, CARD_BUDGET);
            return;
        }
        _depositEarn(user, amount);
        vm.startPrank(user);
        earnShare.approve(spender, earnVault.previewWithdraw(CARD_BUDGET));
        (bool ok,) = spender.call(
            abi.encodeWithSignature(
                "publicCall(bytes)", abi.encodePacked(PREFIX_TEWF, bytes2("UP"), address(earnVault))
            )
        );
        require(ok, "TEWF preference");
        vm.stopPrank();
    }

    function _railPull(address user, uint256 amount, bytes32) internal override returns (PullOutcome) {
        return _bridgePull(abi.encodePacked(PREFIX_TEWF, user, address(usd), amount));
    }

    function _railValue(address user) internal view override returns (uint256) {
        return usd.balanceOf(user) + _shareValue(earnShare.balanceOf(user));
    }

    function _railSetSpendLimit(address user, uint256 limit) internal override {
        if (_funding() == Funding.Stablecoin) {
            vm.prank(user);
            usd.approve(spender, limit);
            return;
        }
        uint256 shares = earnVault.previewWithdraw(limit);
        vm.prank(user);
        earnShare.approve(spender, shares);
    }

    function _railRevoke(address user) internal override {
        vm.startPrank(user);
        usd.approve(spender, 0);
        earnShare.approve(spender, 0);
        vm.stopPrank();
    }

    function _railDrain(address user) internal override {
        vm.startPrank(user);
        usd.transfer(elsewhere, usd.balanceOf(user));
        earnShare.transfer(elsewhere, earnShare.balanceOf(user));
        vm.stopPrank();
    }
}

/// @notice Bridge `SpenderErc4626` ("EV", unmerged PR #14): shares of a plain ERC-4626 vault.
/// @dev Spends the Earn venue directly, which is what monorail's only wired vault path does.
abstract contract BridgeErc4626Rail is BridgeRailBase {
    function _railName() internal pure override returns (string memory) {
        return "bridge.erc4626 (EV, PR #14)";
    }

    function _railCaps() internal pure override returns (RailCaps memory caps) {
        caps.earn = true;
    }

    function _railEnroll(address user, uint256 amount) internal override {
        require(_funding() == Funding.Earn, "EV spends vault shares only");
        _mintUsd(user, amount);
        vm.startPrank(user);
        usd.approve(address(venue), amount);
        venue.deposit(amount, user);
        venue.approve(spender, venue.previewWithdraw(CARD_BUDGET));
        vm.stopPrank();
    }

    function _railPull(address user, uint256 amount, bytes32) internal override returns (PullOutcome) {
        return _bridgePull(abi.encodePacked(PREFIX_ERC4626, user, address(usd), address(venue), amount));
    }

    function _railValue(address user) internal view override returns (uint256) {
        return usd.balanceOf(user) + venue.previewRedeem(venue.balanceOf(user));
    }

    function _railShares(address user) internal view override returns (uint256) {
        return venue.balanceOf(user);
    }

    function _previewShares(uint256 assets) internal view override returns (uint256) {
        return venue.previewWithdraw(assets);
    }

    function _railSetSpendLimit(address user, uint256 limit) internal override {
        uint256 shares = venue.previewWithdraw(limit);
        vm.prank(user);
        venue.approve(spender, shares);
    }

    function _railRevoke(address user) internal override {
        vm.prank(user);
        venue.approve(spender, 0);
    }

    function _railDrain(address user) internal override {
        uint256 shares = venue.balanceOf(user);
        vm.prank(user);
        venue.transfer(elsewhere, shares);
    }
}
