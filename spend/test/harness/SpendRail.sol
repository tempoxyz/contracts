// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { AccessKeys } from "./AccessKeys.sol";

/// @notice Where a cardholder keeps the money their card spends.
enum Funding {
    Stablecoin,
    Earn
}

/// @notice Result of one Bridge pull.
enum PullOutcome {
    /// Funds reached the settlement wallet.
    Settled,
    /// Nothing moved and Bridge knew before approving the card (a revert or a rejected request).
    Rejected,
    /// Bridge approved the card but settlement then failed (a bounced Zone callback).
    FailedAfterApproval
}

/// @notice Why a scenario expects a pull to fail.
enum Decline {
    InsufficientFunds,
    Revoked,
    Paused,
    SpendLimit,
    ShareCost,
    Illiquid
}

/// @notice What a contract setup can do. Scenarios assert the product behavior where a capability
///         exists and pin the setup's actual behavior where it does not, so the same suite runs
///         against every setup and records its gaps.
struct RailCaps {
    /// Pulls can be funded from Tempo Earn shares.
    bool earn;
    /// Balances live in a Zone and Tempo never sees the cardholder.
    bool privateBalances;
    /// A pull reverts instead of burning more shares than the quote allowed.
    bool boundedShareCost;
    /// A cardholder-set periodic limit is enforced on chain.
    bool periodicSpendLimit;
    /// One pull can combine stablecoin and Earn.
    bool splitFunding;
    /// Refunds re-enter Earn instead of landing as stablecoin.
    bool refundsEarn;
    /// The same action ID cannot settle twice.
    bool idempotentActions;
    /// No allowance is left standing between pulls.
    bool noStandingAllowance;
}

/// @notice One way of moving card spend on Tempo. A rail implements these hooks for one contract
///         setup; the card program and the scenarios only ever talk to a rail through them.
abstract contract SpendRail is AccessKeys {
    /// @dev Budget a cardholder grants when linking a card, mirroring Tempo Cash's $10k cap.
    uint256 internal constant CARD_BUDGET = 10_000e6;
    /// @dev Share-cost tolerance Bridge adds to a live Earn quote.
    uint256 internal constant SHARE_TOLERANCE_BPS = 50;

    function _railName() internal pure virtual returns (string memory);

    function _railCaps() internal view virtual returns (RailCaps memory);

    function _funding() internal view virtual returns (Funding);

    /// @notice Deploys anything the rail needs beyond the shared world.
    function _railSetUp() internal virtual;

    /// @notice Gives `user` `amount` of value in its funding source and links the card: the
    ///         user grants the program whatever authority this rail needs to pull.
    function _railEnroll(address user, uint256 amount) internal virtual;

    /// @notice Why the last pull did not settle: the revert data of the rejected request or of the
    ///         failed callback. Empty after a pull that settled.
    bytes internal lastPullError;

    /// @notice Selector of the error a pull fails with for `reason` on this rail. Zero where the
    ///         rail does not pin one, and the scenario then checks only the outcome.
    function _railDeclineError(Decline reason) internal view virtual returns (bytes4);

    /// @notice Bridge pulls `amount` for a card authorization.
    function _railPull(address user, uint256 amount, bytes32 actionId)
        internal
        virtual
        returns (PullOutcome);

    /// @notice Bridge returns `amount` to `user` from program liquidity.
    function _railCredit(address user, uint256 amount, bytes32 actionId) internal virtual;

    /// @notice Total value the cardholder holds in the rail's funding source, in stablecoin units.
    function _railValue(address user) internal view virtual returns (uint256);

    /// @notice Gives the cardholder extra stablecoin outside the card's main funding source.
    function _giveStablecoin(address user, uint256 amount) internal virtual;

    /// @notice Shares a pull of `assets` costs at the current price.
    function _previewShares(uint256 assets) internal view virtual returns (uint256);

    /// @notice Earn shares (or vault shares) the cardholder holds in the rail's funding source.
    function _railShares(address user) internal view virtual returns (uint256);

    /// @notice One pull that takes `fromStable` stablecoin and the rest from Earn. Only rails with
    ///         `splitFunding` implement it.
    function _railPullSplit(address user, uint256 amount, uint256 fromStable, bytes32 actionId)
        internal
        virtual
        returns (PullOutcome);

    /// @notice The cardholder caps spend at `limit` per `LIMIT_PERIOD` where the rail supports
    ///         it, or with the closest control the rail offers.
    function _railSetSpendLimit(address user, uint256 limit) internal virtual;

    /// @notice The cardholder withdraws the card's authority to pull.
    function _railRevoke(address user) internal virtual;

    /// @notice Moves all of the cardholder's spendable funds out of reach of the card, as a user
    ///         front-running a pull would.
    function _railDrain(address user) internal virtual;

    /// @notice Uses Bridge's Zone access key, as if it leaked, to withdraw `amount` of the
    ///         cardholder's Zone balance to `outsider` on Tempo. Returns whether the Zone accepted
    ///         the request. Private rails only.
    function _railZoneKeyWithdrawTo(address user, address outsider, uint256 amount)
        internal
        virtual
        returns (bool);

    // ------------------------------------------------------------------
    // Shared helpers for rails
    // ------------------------------------------------------------------

    /// @dev Basis points of venue value lost right after Bridge quotes an Earn pull, modelling a
    ///      price move between quote and execution. Cleared once applied.
    uint256 internal lossAfterQuoteBps;

    /// @notice Bridge's Earn quote: the live share cost plus `SHARE_TOLERANCE_BPS`.
    function _quoteShares(uint256 assets) internal returns (uint256 quote) {
        uint256 live = earnVault.previewWithdraw(assets);
        quote = live + live * SHARE_TOLERANCE_BPS / 10_000 + 1;
        if (lossAfterQuoteBps != 0) {
            _venueLoss(lossAfterQuoteBps);
            lossAfterQuoteBps = 0;
        }
    }

    /// @notice The Earn venue loses `bps` of its assets, lowering the share price.
    function _venueLoss(uint256 bps) internal {
        uint256 loss = usd.balanceOf(address(venue)) * bps / 10_000;
        vm.prank(address(venue));
        usd.transfer(makeAddr("venue.loss"), loss);
    }
}
