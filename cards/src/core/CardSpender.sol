// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";
import { IERC20Allowance } from "zone-router/interfaces/IERC20Allowance.sol";
import { ISpendSettler } from "zone-router/interfaces/ISpendSettler.sol";

import { CardSpend } from "./CardSpend.sol";
import { ICardProvider, ICardProviderPayout } from "./interfaces/ICardProvider.sol";
import { ITempoEarnVault } from "./interfaces/ITempoEarnVault.sol";

/// @title CardSpender
/// @notice One card program on Tempo, for any provider: the stable address cardholders' access keys and a
///         Zone's router point at. It pays a spend from stablecoin, Tempo Earn shares, or both, to a
///         destination its provider authorizes, publicly (`spend`) or from a Zone withdrawal (`settle`, as the
///         router's settler). Specified in docs/cards/design.md.
/// @dev Deployed by `CardFactory` with a fixed provider and guardian, and never changed: a provider replaces a
///      program by deploying another. It holds nothing between spends. Two ways to pay, fixed by the provider:
///      - direct: the program moves the funds itself (Rain);
///      - payout: the provider supports `ICardProviderPayout`, and the program pays through its target as the
///        payer (Bridge, through its spender clone and "TS" handler, so Bridge's factory governs the spend).
///      Either way it checks the destination got exactly the amount, and a payout can use at most the
///      spend's input: what the payer approved (public) or the withdrawal's `maxInput` (private).
contract CardSpender is ISpendSettler {
    /// @dev Solady's `TransferFailed()` and `ApproveFailed()`.
    bytes4 private constant TRANSFER_FAILED = 0x90b8ec18;
    bytes4 private constant APPROVE_FAILED = 0x3e3f8f73;

    ICardProvider public immutable PROVIDER;
    /// @notice The only account that can pause this program; zero for none.
    address public immutable GUARDIAN;
    /// @notice The provider's payout target, or zero when the program pays directly.
    address public immutable PAYOUT_TARGET;

    /// @notice Whether the guardian has stopped every spend.
    bool public guardianPaused;

    bool private transient _locked;

    error DestinationNotAuthorized(address destination);
    error DestinationNotCredited();
    error IncorrectAssetForVault();
    error InsufficientInput();
    error InvalidAmount();
    error NotGuardian();
    error NotProvider();
    error NothingSettled();
    error ProgramPaused();
    error Reentrancy();
    error ResidualBalance(address token);
    error ShareCostExceeded(uint256 required, uint256 maxShares);
    error VaultNotAllowed(address vault);
    error WrongInputToken(address token);
    error WrongProgram(address program);
    error ZeroAddress();

    /// @dev `payer` is the cardholder's account for a public spend and the router for a private one, so a
    ///      private spend's events name no cardholder. `sharesUsed` is the EarnShare the spend consumed.
    event CardSpent(
        bytes32 indexed ref,
        address indexed payer,
        address indexed destination,
        address token,
        uint256 amount,
        uint256 fromVault,
        uint256 sharesUsed,
        bool isPrivate
    );
    /// @dev A private spend's input accounting, as the Zone router sees it. No cardholder or `senderTag`.
    event SpendSettled(bytes32 indexed ref, address inputToken, uint256 inputConsumed, uint256 inputReturned);
    event GuardianPausedSet(bool paused);

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    /// @param guardian_ The account that can pause this program, or zero for none.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(ICardProvider provider_, address guardian_) {
        if (address(provider_) == address(0)) revert ZeroAddress();
        if (!ERC165Checker.supportsInterface(address(provider_), type(ICardProvider).interfaceId)) {
            revert NotProvider();
        }
        PROVIDER = provider_;
        GUARDIAN = guardian_;
        if (ERC165Checker.supportsInterface(address(provider_), type(ICardProviderPayout).interfaceId)) {
            address target = ICardProviderPayout(address(provider_)).payoutTarget();
            if (target == address(0)) revert ZeroAddress();
            PAYOUT_TARGET = target;
        }
    }

    // ------------------------------------------------------------------
    // Spends
    // ------------------------------------------------------------------

    /// @notice A public spend: pays `s.amount` of `s.token` to `s.destination`, `s.amount - s.fromVault`
    ///         from the caller's `s.token` and `s.fromVault` redeemed from the caller's shares in `s.vault`.
    ///         The caller approves this program for both first.
    function spend(CardSpend calldata s) external nonReentrant {
        _check(s, msg.sender, false);
        uint256 destinationBefore = IERC20Like(s.token).balanceOf(s.destination);
        uint256 sharesUsed = PAYOUT_TARGET == address(0) ? _payDirect(s, msg.sender) : _payThroughPublic(s);
        if (IERC20Like(s.token).balanceOf(s.destination) != destinationBefore + s.amount) {
            revert DestinationNotCredited();
        }
        emit CardSpent(s.ref, msg.sender, s.destination, s.token, s.amount, s.fromVault, sharesUsed, false);
    }

    /// @inheritdoc ISpendSettler
    /// @notice A private spend, as a Zone router's settler: pays `abi.decode(data, (CardSpend))` from the
    ///         `maxInput` of `token` the caller transferred first, and returns the rest in the same call.
    /// @dev Permissionless: the router authenticates the Zone withdrawal and caps the input; anyone else can
    ///      only pay a destination the provider allows for a private spend, from their own funds. One
    ///      withdrawal carries one token: the stablecoin, or the shares of the vault that funds all of it.
    function settle(address token, uint256 maxInput, bytes calldata data) external override nonReentrant {
        CardSpend memory s = abi.decode(data, (CardSpend));
        if (maxInput == 0 || maxInput > type(uint128).max) revert InvalidAmount();
        address input;
        if (s.fromVault == 0) {
            input = s.token;
        } else if (s.fromVault == s.amount && s.vault != address(0)) {
            input = ITempoEarnVault(s.vault).earnShare();
        }
        if (input == address(0) || input != token) revert WrongInputToken(token);
        _check(s, msg.sender, true);

        // The caller sent maxInput before this call; whatever else the program holds is the baseline, and
        // nothing beyond it may stay behind.
        uint256 balance = IERC20Like(token).balanceOf(address(this));
        if (balance < maxInput) revert InsufficientInput();
        uint256 baseline = balance - maxInput;
        uint256 destinationBefore = IERC20Like(s.token).balanceOf(s.destination);

        if (PAYOUT_TARGET == address(0)) {
            _settleDirect(s, maxInput);
        } else {
            _payout(s, token, address(0));
        }

        // Reverts if the payout took more than maxInput, since the balance would be below the baseline.
        uint256 unused = IERC20Like(token).balanceOf(address(this)) - baseline;
        if (unused >= maxInput) revert NothingSettled();
        if (IERC20Like(s.token).balanceOf(s.destination) != destinationBefore + s.amount) {
            revert DestinationNotCredited();
        }
        if (unused != 0) _tokenCall(token, IERC20Like.transfer.selector, msg.sender, unused, TRANSFER_FAILED);
        if (IERC20Like(token).balanceOf(address(this)) != baseline) revert ResidualBalance(token);

        uint256 consumed = maxInput - unused;
        emit CardSpent(
            s.ref, msg.sender, s.destination, s.token, s.amount, s.fromVault, s.fromVault == 0 ? 0 : consumed, true
        );
        emit SpendSettled(s.ref, token, consumed, unused);
    }

    // ------------------------------------------------------------------
    // Pause and views
    // ------------------------------------------------------------------

    /// @notice Whether spends are stopped, by the guardian or by the provider's own contracts.
    function paused() public view returns (bool) {
        return guardianPaused || PROVIDER.paused();
    }

    /// @notice Stops (`true`) or resumes (`false`) every spend. Only `GUARDIAN`; nothing else changes.
    function setPaused(bool paused_) external {
        if (msg.sender != GUARDIAN || GUARDIAN == address(0)) revert NotGuardian();
        guardianPaused = paused_;
        emit GuardianPausedSet(paused_);
    }

    /// @notice Sets the program's standing approval of `token` to its payout target before the first spend,
    ///         which would otherwise create the allowance slot in a spend (TIP-1000). Permissionless: the
    ///         program holds nothing between spends. Does nothing for a program that pays directly.
    function warm(address token) external {
        if (PAYOUT_TARGET != address(0)) _approve(token, PAYOUT_TARGET, type(uint256).max);
    }

    /// @notice `from`'s balance of `token`, plus the value of its shares in `vault` when the provider allows
    ///         it and it holds `token`. Pass `vault` zero for the stablecoin alone.
    function availableBalance(address from, address token, address vault) external view returns (uint256 total) {
        total = IERC20Like(token).balanceOf(from);
        if (vault == address(0) || !PROVIDER.isAllowedVault(vault)) return total;
        (bool ok, uint256 word) = _readWord(vault, abi.encodeCall(ITempoEarnVault.asset, ()));
        if (!ok || word != uint256(uint160(token))) return total;
        (ok, word) = _readWord(vault, abi.encodeCall(ITempoEarnVault.earnShare, ()));
        if (!ok || word >> 160 != 0) return total;
        uint256 shares;
        // casting to 'uint160' is safe because the word was just checked to have no bits above 160
        // forge-lint: disable-next-line(unsafe-typecast)
        (ok, shares) = _readWord(address(uint160(word)), abi.encodeCall(IERC20Like.balanceOf, (from)));
        if (!ok || shares == 0) return total;
        (ok, word) = _readWord(vault, abi.encodeCall(ITempoEarnVault.previewRedeem, (shares)));
        if (ok) total += word;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _check(CardSpend memory s, address payer, bool isPrivate) private view {
        if (s.program != address(this)) revert WrongProgram(s.program);
        if (paused()) revert ProgramPaused();
        if (s.amount == 0 || s.fromVault > s.amount) revert InvalidAmount();
        if (!PROVIDER.isAuthorizedDestination(payer, s.destination, s.token, s.destinationHint, isPrivate)) {
            revert DestinationNotAuthorized(s.destination);
        }
        if (s.fromVault != 0) {
            if (!PROVIDER.isAllowedVault(s.vault)) revert VaultNotAllowed(s.vault);
            if (ITempoEarnVault(s.vault).asset() != s.token) revert IncorrectAssetForVault();
        }
    }

    /// @dev A direct public spend: stablecoin straight from the payer, shares pulled, redeemed for the
    ///      destination and the rest returned.
    function _payDirect(CardSpend calldata s, address payer) private returns (uint256 sharesUsed) {
        uint256 fromStable = s.amount - s.fromVault;
        if (fromStable != 0) SafeTransferLib.safeTransferFrom(s.token, payer, s.destination, fromStable);
        if (s.fromVault == 0) return 0;
        ITempoEarnVault v = ITempoEarnVault(s.vault);
        uint256 required = v.previewWithdraw(s.fromVault);
        if (s.maxShares != 0 && required > s.maxShares) revert ShareCostExceeded(required, s.maxShares);
        address share = v.earnShare();
        SafeTransferLib.safeTransferFrom(share, payer, address(this), required);
        sharesUsed = _redeem(v, share, s.fromVault, s.destination, required);
        if (sharesUsed < required) SafeTransferLib.safeTransfer(share, payer, required - sharesUsed);
    }

    /// @dev A direct private spend, from the `maxInput` the router sent.
    function _settleDirect(CardSpend memory s, uint256 maxInput) private {
        if (s.fromVault == 0) {
            if (s.amount > maxInput) revert InsufficientInput();
            SafeTransferLib.safeTransfer(s.token, s.destination, s.amount);
            return;
        }
        ITempoEarnVault v = ITempoEarnVault(s.vault);
        uint256 required = v.previewWithdraw(s.fromVault);
        if (s.maxShares != 0 && required > s.maxShares) revert ShareCostExceeded(required, s.maxShares);
        if (required > maxInput) revert InsufficientInput();
        _redeem(v, v.earnShare(), s.fromVault, s.destination, required);
    }

    /// @dev Burns at most `required` of the program's shares for exactly `assets` to `receiver`. The approval
    ///      to the vault is a standing maximum (TIP-1000); the provider decides on every spend which vaults may
    ///      be used, and the program holds no shares between spends.
    function _redeem(ITempoEarnVault v, address share, uint256 assets, address receiver, uint256 required)
        private
        returns (uint256 burned)
    {
        _approve(share, address(v), required);
        // Every entry point holds the transient lock for this whole call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        burned = v.withdrawExact(assets, receiver, required);
    }

    /// @dev A public spend through the provider's payout target: pulls the stablecoin part and the share quote
    ///      from the payer, pays through the target, and returns whatever the target did not use.
    function _payThroughPublic(CardSpend calldata s) private returns (uint256 sharesUsed) {
        uint256 fromStable = s.amount - s.fromVault;
        address share;
        uint256 shareIn;
        if (s.fromVault != 0) {
            ITempoEarnVault v = ITempoEarnVault(s.vault);
            share = v.earnShare();
            // The live cost, as the target computes it in this same call: pulling the `maxShares` cap instead
            // would decline a payer whose shares cover the cost but not the cap.
            shareIn = v.previewWithdraw(s.fromVault);
            if (s.maxShares != 0 && shareIn > s.maxShares) revert ShareCostExceeded(shareIn, s.maxShares);
        }
        uint256 stableBase = IERC20Like(s.token).balanceOf(address(this));
        uint256 shareBase = share == address(0) ? 0 : IERC20Like(share).balanceOf(address(this));
        if (fromStable != 0) SafeTransferLib.safeTransferFrom(s.token, msg.sender, address(this), fromStable);
        if (shareIn != 0) SafeTransferLib.safeTransferFrom(share, msg.sender, address(this), shareIn);

        _payout(s, fromStable != 0 ? s.token : address(0), share);

        // Each reverts if the target took more than the payer put in.
        uint256 stableLeft = IERC20Like(s.token).balanceOf(address(this)) - stableBase;
        if (stableLeft != 0) SafeTransferLib.safeTransfer(s.token, msg.sender, stableLeft);
        if (share != address(0)) {
            uint256 shareLeft = IERC20Like(share).balanceOf(address(this)) - shareBase;
            sharesUsed = shareIn - shareLeft;
            if (shareLeft != 0) SafeTransferLib.safeTransfer(share, msg.sender, shareLeft);
        }
    }

    /// @dev Approves the payout target for the input tokens (standing maxima, TIP-1000) and calls it with the
    ///      provider's payout data, bubbling up its revert.
    function _payout(CardSpend memory s, address tokenA, address tokenB) private {
        address target = PAYOUT_TARGET;
        if (tokenA != address(0)) _approve(tokenA, target, type(uint128).max);
        if (tokenB != address(0)) _approve(tokenB, target, type(uint128).max);
        bytes memory data = ICardProviderPayout(address(PROVIDER)).payoutData(s);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @dev Sets a standing maximum approval of `token` to `spender` when it is below `amount`.
    function _approve(address token, address spender, uint256 amount) private {
        if (IERC20Allowance(token).allowance(address(this), spender) < amount) {
            _tokenCall(token, IERC20Like.approve.selector, spender, type(uint256).max, APPROVE_FAILED);
        }
    }

    /// @dev `approve` or `transfer` on `token`, reverting with `failure` alone unless it returns `true`, or
    ///      returns nothing from an address with code.
    function _tokenCall(address token, bytes4 selector, address to, uint256 amount, bytes4 failure) private {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), to)
            mstore(add(m, 0x24), amount)
            mstore(0x00, 0)
            let success := call(gas(), token, 0, m, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    mstore(0x00, failure)
                    revert(0x00, 0x04)
                }
            }
        }
    }

    /// @dev False unless `target` has code, the call succeeds and returns at least one word.
    function _readWord(address target, bytes memory data) private view returns (bool ok, uint256 word) {
        if (target.code.length == 0) return (false, 0);
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }
}
