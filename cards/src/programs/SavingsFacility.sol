// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";

/// @title SavingsFacility
/// @notice The payee of a card program's savings legs: holds on a cardholder's Tempo Earn shares. When the hold's
///         placer captures through it, the facility captures the shares as payee, redeems them and pays their value
///         to the settlement account in the same call. A refund deposits the issuer's cash back into the vault and
///         refunds the shares it mints to the cardholder. Specified in docs/cards/design.md (Card programs).
/// @dev Deployed with a fixed vault, settlement account and funder, and never changed. Only a hold's own placer
///      drives it, so a program captures and refunds only the legs it placed. It keeps a standing approval of
///      both tokens to its vault and writes no storage per capture: the placer bounds refunds by what it captured.
///      When the vault quotes but cannot redeem at once, the float pays the settlement account and the shares wait
///      here for the funder's `redeemHeld`. Without a quote a capture reverts.
/// @custom:reentrancy-guard _locked
/// @custom:invariant address(VAULT) != address(0) && SETTLEMENT_ACCOUNT != address(0) && FUNDER != address(0)
contract SavingsFacility {
    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);

    IEarnVault public immutable VAULT;
    /// @notice The vault's Earn share, the token of the holds this facility is payee of.
    address public immutable SHARE;
    /// @notice The vault's base asset, which settlements and refunds use.
    address public immutable ASSET;
    /// @notice Where every capture is paid.
    address public immutable SETTLEMENT_ACCOUNT;
    /// @notice Supplies the float and may withdraw it and redeem shares that deferred redemptions left.
    address public immutable FUNDER;

    /// @notice Shares left here by deferred redemptions and refund surpluses, the only shares the funder may take.
    uint256 public heldShares;

    bool private transient _locked;

    event Captured(address indexed owner, bytes32 indexed id, uint256 shares, uint256 assets, bool deferred);
    event Refunded(address indexed owner, bytes32 indexed id, uint256 assets, uint256 shares, uint256 surplus);
    event Redeemed(uint256 shares, uint256 assets);

    error ExceedsHeld(uint256 shares, uint256 held);
    error ExceedsHeldShares(uint256 shares, uint256 held);
    error InsufficientFloat(uint256 assets, uint256 float_);
    error NoQuote();
    error NotFacilityHold();
    error NotFunder();
    error NotPlacer();
    error NothingToRefund();
    error Reentrancy();
    error ZeroAddress();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    /// @custom:ensures VAULT == vault && SETTLEMENT_ACCOUNT == settlementAccount && FUNDER == funder
    constructor(IEarnVault vault, address settlementAccount, address funder) {
        if (address(vault) == address(0) || settlementAccount == address(0) || funder == address(0)) {
            revert ZeroAddress();
        }
        VAULT = vault;
        SHARE = vault.earnShare();
        ASSET = vault.asset();
        SETTLEMENT_ACCOUNT = settlementAccount;
        FUNDER = funder;
        // Standing approvals, so captures and refunds write no allowance slots.
        SafeTransferLib.safeApproveWithRetry(SHARE, address(vault), type(uint256).max);
        SafeTransferLib.safeApproveWithRetry(ASSET, address(vault), type(uint256).max);
    }

    /// @notice Captures `shares` of `owner`'s savings leg `id` as payee, redeems them and pays the settlement
    ///         account. Only the hold's placer may call it, and only up to what the hold still reserves.
    /// @return assets What the settlement account was paid.
    function capture(address owner, bytes32 id, uint128 shares, bool isFinal)
        external
        nonReentrant
        returns (uint256 assets)
    {
        // The core keys the leg by its placer, so only the program that placed it finds it here.
        IReservationCore.HoldRecord memory h = CORE.getHold(owner, msg.sender, id);
        _checkHold(h);
        // Nothing beyond the hold: an excess could become owner debt to this facility, which no one has paid for.
        if (shares > h.held) revert ExceedsHeld(shares, h.held);
        /// @custom:assert shares <= h.held
        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        CORE.capture(owner, msg.sender, id, shares, isFinal);
        if (shares == 0) return 0;

        uint256 quote = VAULT.previewRedeem(shares);
        if (quote == 0) revert NoQuote();
        bool deferred;
        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        try VAULT.redeem(shares, SETTLEMENT_ACCOUNT, quote) returns (uint256 redeemed) {
            assets = redeemed;
        } catch {
            // The vault quotes but cannot redeem now: the float pays and the shares wait for the funder.
            uint256 float_ = IERC20Like(ASSET).balanceOf(address(this));
            if (float_ < quote) revert InsufficientFloat(quote, float_);
            heldShares += shares;
            assets = quote;
            deferred = true;
            SafeTransferLib.safeTransfer(ASSET, SETTLEMENT_ACCOUNT, quote);
        }
        emit Captured(owner, id, shares, assets, deferred);
    }

    /// @notice Refunds `owner`'s savings leg `id` with `assets` of the base asset pulled from the caller: deposits
    ///         them into the vault and refunds the minted shares, up to `maxShares`, what the caller (the leg's placer)
    ///         records as still refundable. The core forgets a settled leg, so the placer keeps that bound. Shares
    ///         minted beyond it stay here for the funder.
    /// @return shares The shares refunded to `owner`.
    function refund(address owner, bytes32 id, uint256 assets, uint256 maxShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (maxShares == 0 || assets == 0) revert NothingToRefund();
        SafeTransferLib.safeTransferFrom(ASSET, msg.sender, address(this), assets);
        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        uint256 minted = VAULT.deposit(assets, address(this), 1);
        shares = minted < maxShares ? minted : maxShares;
        uint256 surplus = minted - shares;
        if (surplus != 0) heldShares += surplus;
        // The facility pays the refund from the shares the assets minted, onto the caller's leg.
        // forge-lint: disable-next-line(unsafe-typecast, reentrancy-no-eth)
        if (shares != 0) CORE.refund(owner, SHARE, msg.sender, id, uint128(shares));
        emit Refunded(owner, id, assets, shares, surplus);
    }

    /// @notice Redeems shares left here into the float.
    function redeemHeld(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        if (msg.sender != FUNDER) revert NotFunder();
        _takeHeld(shares);
        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        assets = VAULT.redeem(shares, address(this), minAssets);
        emit Redeemed(shares, assets);
    }

    /// @notice Withdraws float or held shares to `to`.
    function withdraw(address token, address to, uint256 amount) external nonReentrant {
        if (msg.sender != FUNDER) revert NotFunder();
        if (token == SHARE) _takeHeld(amount);
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    /// @notice The base asset available to pay deferred redemptions.
    function float() external view returns (uint256) {
        return IERC20Like(ASSET).balanceOf(address(this));
    }

    function _checkHold(IReservationCore.HoldRecord memory h) private view {
        if (h.token == address(0)) revert NotPlacer();
        if (h.token != SHARE || h.payee != address(this)) revert NotFacilityHold();
    }

    function _takeHeld(uint256 shares) private {
        uint256 held = heldShares;
        if (shares > held) revert ExceedsHeldShares(shares, held);
        heldShares = held - shares;
    }
}
