// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";
import { IERC20Allowance } from "zone-router/interfaces/IERC20Allowance.sol";

import { CardSettler, ICardSpenderPrivate } from "./CardSettler.sol";
import { CardSpend } from "./CardSpend.sol";
import { ICardProgram } from "./interfaces/ICardProgram.sol";
import { ITempoEarnVault } from "./interfaces/ITempoEarnVault.sol";

/// @title CardSpender
/// @notice Pays one card spend to a destination its program authorizes, from stablecoin, Tempo Earn
///         shares, or both, for any card provider. Specified in docs/cards/design.md.
/// @dev One deployment serves one program (`PROGRAM`), so one program's approval can never pay through
///      another's. It has no owner and holds nothing between spends. The payer is `msg.sender`:
///      - public spend (`spend`): the cardholder's account, in one transaction signed by the provider's
///        access key that approves the exact amount, calls `spend` and clears the approval;
///      - private spend (`spendPrivate`): only the `CardSettler` this spender deploys for itself
///        (`SETTLER`), from the input a Zone withdrawal's router sends it.
///      The spender tells the program which of the two each spend is, and checks its pause on every one.
///      A spend settles in the stablecoin the funds are held in. Earn shares redeem into the vault's own
///      asset, so a spend from Earn names that asset as `token`.
contract CardSpender {
    ICardProgram public immutable PROGRAM;
    /// @notice The only payer whose spends are private: the program's settler, deployed by this constructor.
    address public immutable SETTLER;

    bool private transient _locked;

    error DestinationNotAuthorized(address destination);
    error DestinationNotCredited();
    error IncorrectAssetForVault();
    error InvalidAmount();
    error NotSettler();
    error ProgramPaused();
    error Reentrancy();
    error ShareCostExceeded(uint256 required, uint256 maxShares);
    error VaultNotAllowed(address vault);
    error WrongProgram(address program);
    error ZeroAddress();

    event CardSpent(
        bytes32 indexed ref,
        address indexed payer,
        address indexed destination,
        address token,
        uint256 amount,
        uint256 fromStable,
        uint256 fromVault,
        uint256 sharesBurned,
        bool isPrivate
    );

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(ICardProgram program_) {
        if (address(program_) == address(0)) revert ZeroAddress();
        PROGRAM = program_;
        SETTLER = address(new CardSettler(ICardSpenderPrivate(address(this)), address(program_)));
    }

    /// @notice A public spend: pays `s.amount` of `s.token` to `s.destination`, `s.amount - s.fromVault`
    ///         from the caller's `s.token` and `s.fromVault` redeemed from the caller's shares in `s.vault`.
    function spend(CardSpend calldata s) external nonReentrant {
        _spend(s, false);
    }

    /// @notice A private spend, as `spend` but paid by the program's settler from a Zone withdrawal.
    function spendPrivate(CardSpend calldata s) external nonReentrant {
        if (msg.sender != SETTLER) revert NotSettler();
        _spend(s, true);
    }

    function _spend(CardSpend calldata s, bool isPrivate) private {
        if (s.program != address(PROGRAM)) revert WrongProgram(s.program);
        if (PROGRAM.paused()) revert ProgramPaused();
        if (s.amount == 0 || s.fromVault > s.amount) revert InvalidAmount();
        if (!PROGRAM.isAuthorizedDestination(msg.sender, s.destination, s.token, s.destinationHint, isPrivate)) {
            revert DestinationNotAuthorized(s.destination);
        }

        uint256 fromStable = s.amount - s.fromVault;
        uint256 before = IERC20Like(s.token).balanceOf(s.destination);
        if (fromStable != 0) SafeTransferLib.safeTransferFrom(s.token, msg.sender, s.destination, fromStable);
        uint256 sharesBurned;
        if (s.fromVault != 0) {
            if (!PROGRAM.isAllowedVault(s.vault)) revert VaultNotAllowed(s.vault);
            if (ITempoEarnVault(s.vault).asset() != s.token) revert IncorrectAssetForVault();
            sharesBurned = _withdrawFromEarn(s.vault, s.destination, s.fromVault, s.maxShares);
        }
        if (IERC20Like(s.token).balanceOf(s.destination) != before + s.amount) revert DestinationNotCredited();

        emit CardSpent(
            s.ref, msg.sender, s.destination, s.token, s.amount, fromStable, s.fromVault, sharesBurned, isPrivate
        );
    }

    /// @notice `from`'s balance of `token`, plus the value of its shares in `vault` when the program
    ///         allows it and it holds `token`. Pass `vault` zero for the stablecoin alone.
    function availableBalance(address from, address token, address vault) external view returns (uint256 total) {
        total = IERC20Like(token).balanceOf(from);
        if (vault == address(0) || !PROGRAM.isAllowedVault(vault)) return total;
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

    /// @dev Pulls only the shares `assets` costs, burns them for `receiver` and returns any the vault left.
    ///      The approval to the vault is a standing maximum: clearing it after each spend would create its
    ///      allowance slot again every time, which Tempo charges as a new storage slot (TIP-1000). The
    ///      spender holds no shares between spends, and the program decides on every spend which vaults
    ///      may be used.
    function _withdrawFromEarn(address vault, address receiver, uint256 assets, uint256 maxShares)
        private
        returns (uint256 burned)
    {
        ITempoEarnVault v = ITempoEarnVault(vault);
        uint256 required = v.previewWithdraw(assets);
        if (maxShares != 0 && required > maxShares) revert ShareCostExceeded(required, maxShares);
        address share = v.earnShare();
        SafeTransferLib.safeTransferFrom(share, msg.sender, address(this), required);
        // `spend` and `spendPrivate` hold the transient lock for this whole call, so neither call below can
        // reenter them.
        if (IERC20Allowance(share).allowance(address(this), vault) < required) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            SafeTransferLib.safeApprove(share, vault, type(uint256).max);
        }
        // forge-lint: disable-next-line(reentrancy-no-eth)
        burned = v.withdrawExact(assets, receiver, required);
        if (burned < required) SafeTransferLib.safeTransfer(share, msg.sender, required - burned);
    }

    /// @dev False unless `target` has code, the call succeeds and returns at least one word.
    function _readWord(address target, bytes memory data) private view returns (bool ok, uint256 word) {
        if (target.code.length == 0) return (false, 0);
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }
}
