// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

import { CARDS_ADDRESS, ICards } from "./interfaces/ICards.sol";
import { IReservations, RESERVATIONS_ADDRESS } from "./interfaces/IReservations.sol";

/// @title SavingsFacility
/// @notice Pays a card issuer at once, in cash, for Tempo Earn shares a cardholder's hold captured, and redeems
///         those shares to refill its float. It is the payee of every share hold its program places, so a hold
///         that spans cash and savings settles as a cash capture to the issuer plus a share capture here. It
///         also pays out, in cash, shares an account's sweep (closure, estate or unclaimed property) paid in.
///         Specified in docs/cards/design.md (Spend from savings).
/// @dev Deployed per program with a fixed vault, issuer, settlement account and funder, and never changed. The
///      funder supplies the float and owns what is left in it. Shares are settled once per hold, for what the
///      precompile records as captured; share holds take no refunds (refunds go through the cash path).
///      Settlement prices shares with `previewRedeem`, so it needs a vault that can quote one; while it cannot (an
///      async-only engine, a paused or stale price), `settle` reverts and the shares wait here. Redemption is best
///      effort: when the vault quotes but cannot redeem at once, or would return less than the issuer is paid,
///      the shares stay here, the float pays the issuer, and the funder redeems them later with `redeemHeld`.
contract SavingsFacility {
    IReservations internal constant RESERVATIONS = IReservations(RESERVATIONS_ADDRESS);
    ICards internal constant CARDS = ICards(CARDS_ADDRESS);

    IEarnVault public immutable VAULT;
    /// @notice The vault's Earn share, the token of the holds this facility settles.
    address public immutable SHARE;
    /// @notice The vault's base asset, which the facility pays out.
    address public immutable ASSET;
    /// @notice The only caller of `settle`: the program's issuer.
    address public immutable ISSUER;
    /// @notice Where every settlement is paid.
    address public immutable SETTLEMENT_ACCOUNT;
    /// @notice Supplies the float and may withdraw it and redeem shares left after a deferred redemption.
    address public immutable FUNDER;

    /// @notice Captured shares already settled, per owner and hold id.
    mapping(address owner => mapping(bytes32 id => uint256 shares)) public settled;
    /// @notice Swept shares already paid out, per owner.
    mapping(address owner => uint256 shares) public paidOut;

    bool private transient _locked;

    event Settled(address indexed owner, bytes32 indexed id, uint256 shares, uint256 assets);
    event PaidOut(address indexed owner, address indexed to, uint256 shares, uint256 assets);
    event Redeemed(uint256 shares, uint256 assets);
    event RedemptionDeferred(uint256 shares);

    error AssetsBelowMinimum(uint256 assets, uint256 minAssets);
    error NotFacilityHold();
    error NotFunder();
    error NotIssuer();
    error NothingToSettle();
    error OwnerOwesShares(uint256 debt);
    error Reentrancy();
    error ZeroAddress();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(IEarnVault vault, address issuer, address settlementAccount, address funder) {
        if (
            address(vault) == address(0) || issuer == address(0) || settlementAccount == address(0)
                || funder == address(0)
        ) revert ZeroAddress();
        VAULT = vault;
        SHARE = vault.earnShare();
        ASSET = vault.asset();
        ISSUER = issuer;
        SETTLEMENT_ACCOUNT = settlementAccount;
        FUNDER = funder;
    }

    /// @notice Settles the shares `owner`'s hold `id` captured since its last settlement: pays their current value
    ///         in the base asset to the settlement account and redeems them.
    /// @param minAssets The least the issuer accepts for the shares; reverts below it.
    /// @return shares The shares settled.
    /// @return assets What the settlement account was paid.
    function settle(address owner, bytes32 id, uint256 minAssets)
        external
        nonReentrant
        returns (uint256 shares, uint256 assets)
    {
        if (msg.sender != ISSUER) revert NotIssuer();
        IReservations.Hold memory hold = RESERVATIONS.getHold(owner, id);
        if (hold.token != SHARE || hold.payee != address(this)) revert NotFacilityHold();
        // A capture beyond the hold may be partly debt to this facility, which `captured` still counts as paid.
        // Debt is per owner, not per hold, so no hold of a debtor settles until the debt is repaid.
        (address creditor, uint128 debt) = RESERVATIONS.debtOf(owner, SHARE);
        if (creditor == address(this) && debt != 0) revert OwnerOwesShares(debt);
        (uint128 captured,) = RESERVATIONS.captured(owner, id);
        uint256 done = settled[owner][id];
        if (captured <= done) revert NothingToSettle();
        shares = captured - done;
        settled[owner][id] = captured;

        // Without a quote there is no safe price to pay, so this reverts rather than trusting a caller value.
        assets = VAULT.previewRedeem(shares);
        if (assets < minAssets) revert AssetsBelowMinimum(assets, minAssets);
        // Redeem for at least what the issuer is paid, so a settlement never shrinks the float.
        _redeem(shares, assets);
        SafeTransferLib.safeTransfer(ASSET, SETTLEMENT_ACCOUNT, assets);
        emit Settled(owner, id, shares, assets);
    }

    /// @notice Pays out shares that sweeps of `owner`'s account paid in since the last payout: their current value
    ///         in the base asset goes to the recipient the card records name, and the shares are redeemed. Anyone
    ///         may call it, since the records alone decide who is paid.
    /// @return shares The shares paid out.
    /// @return assets What the recipient was paid.
    function payOut(address owner) external nonReentrant returns (uint256 shares, uint256 assets) {
        (address to, uint128 swept) = CARDS.payoutOf(owner, SHARE, address(this));
        if (to == address(0)) revert ZeroAddress();
        uint256 done = paidOut[owner];
        if (swept <= done) revert NothingToSettle();
        shares = swept - done;
        paidOut[owner] = swept;
        // As in `settle`: priced by the vault's quote, and redeemed for at least what is paid.
        assets = VAULT.previewRedeem(shares);
        _redeem(shares, assets);
        SafeTransferLib.safeTransfer(ASSET, to, assets);
        emit PaidOut(owner, to, shares, assets);
    }

    /// @notice Redeems shares a deferred redemption left here, into the float.
    function redeemHeld(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        if (msg.sender != FUNDER) revert NotFunder();
        SafeTransferLib.safeApprove(SHARE, address(VAULT), shares);
        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        assets = VAULT.redeem(shares, address(this), minAssets);
        emit Redeemed(shares, assets);
    }

    /// @notice Withdraws float or held shares to `to`.
    function withdraw(address token, address to, uint256 amount) external nonReentrant {
        if (msg.sender != FUNDER) revert NotFunder();
        SafeTransferLib.safeTransfer(token, to, amount);
    }

    /// @notice The base asset available to pay settlements.
    function float() external view returns (uint256) {
        return IERC20Like(ASSET).balanceOf(address(this));
    }

    /// @dev Redeems into the float, or leaves the shares here when the vault cannot redeem them now.
    function _redeem(uint256 shares, uint256 minAssets) private {
        // The vault pulls the shares; approve exactly them and clear what a failed redemption left.
        SafeTransferLib.safeApprove(SHARE, address(VAULT), shares);
        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        try VAULT.redeem(shares, address(this), minAssets) returns (uint256 assets) {
            emit Redeemed(shares, assets);
        } catch {
            SafeTransferLib.safeApprove(SHARE, address(VAULT), 0);
            emit RedemptionDeferred(shares);
        }
    }
}
