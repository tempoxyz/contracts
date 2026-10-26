// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SpenderBase } from "bridge-spender/src/spenders/SpenderBase.sol";
import { Vm } from "forge-std/Vm.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IAccountKeychain } from "tempo-std/interfaces/IAccountKeychain.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";

import { Spend, SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { ZoneSpendReceiver } from "../../src/ZoneSpendReceiver.sol";
import { IBridgeSpenderClone, IBridgeSpenderFactory } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { IZoneOutbox } from "../../src/interfaces/IZoneOutbox.sol";

import { Decline, Funding, PullOutcome, RailCaps } from "../harness/SpendRail.sol";
import { TxCall } from "../harness/lib/TempoTx.sol";
import { RailDefaults } from "./RailDefaults.sol";

/// @notice Shared by every rail on the "TS" handler.
abstract contract TempoRailBase is RailDefaults {
    address internal elsewhere = makeAddr("cardholder.elsewhere");

    function _vaultFor() internal view returns (address) {
        return _funding() == Funding.Earn ? address(earnVault) : address(0);
    }

    /// @notice A spend paying `amount` to the settlement wallet, `fromVault` of it from Earn.
    function _spend(uint256 amount, bytes32 ref, uint256 fromVault, uint256 maxShares)
        internal
        view
        returns (Spend memory)
    {
        return Spend({
            spenderId: SPENDER_ID,
            token: address(usd),
            amount: amount,
            destination: settlement,
            vault: fromVault == 0 ? address(0) : address(earnVault),
            fromVault: fromVault,
            maxShares: maxShares,
            ref: ref
        });
    }

    /// @dev What both "TS" rails fail with once a spend reaches the handler or the keychain.
    function _tempoDeclineError(Decline reason) internal pure returns (bytes4) {
        if (reason == Decline.Revoked) return IAccountKeychain.KeyAlreadyRevoked.selector;
        if (reason == Decline.Paused) return SpenderBase.FactoryPaused.selector;
        if (reason == Decline.SpendLimit) return IAccountKeychain.SpendingLimitExceeded.selector;
        if (reason == Decline.ShareCost) return SpenderTempoSpend.ShareCostExceeded.selector;
        if (reason == Decline.Illiquid) return bytes4(keccak256("Error(string)"));
        return bytes4(0);
    }
}

/// @notice Public spend through the program's Bridge clone, signed by Bridge's access key as the
///         cardholder. Each pull approves the exact amount, submits Bridge's signed intent and
///         clears the approval in one transaction. The protocol enforces the periodic limit.
abstract contract TempoAccessKeyRail is TempoRailBase {
    function _railName() internal pure override returns (string memory) {
        return "tempo.ts-public (access key)";
    }

    function _railCaps() internal view override returns (RailCaps memory caps) {
        caps.earn = _funding() == Funding.Earn;
        caps.boundedShareCost = true;
        caps.periodicSpendLimit = true;
        caps.splitFunding = true;
        caps.noStandingAllowance = true;
    }

    function _limitToken() internal view returns (address) {
        return _funding() == Funding.Earn ? address(earnShare) : address(usd);
    }

    function _railEnroll(address user, uint256 amount) internal override {
        _mintUsd(user, amount);
        if (_funding() == Funding.Earn) _depositEarn(user, amount);

        address[] memory tokens = new address[](2);
        uint256[] memory limits = new uint256[](2);
        tokens[0] = address(usd);
        limits[0] = CARD_BUDGET;
        tokens[1] = address(earnShare);
        limits[1] = earnVault.previewWithdraw(CARD_BUDGET);
        IAccountKeychain.CallScope[] memory scopes = new IAccountKeychain.CallScope[](3);
        scopes[0] = _scope(address(usd), ITIP20.approve.selector, spender);
        scopes[1] = _scope(address(earnShare), ITIP20.approve.selector, spender);
        scopes[2] = _scope(spender, IBridgeSpenderClone.publicCall.selector, address(0));
        _authorizeBridgeKey(user, tokens, limits, scopes);
    }

    function _railPull(address user, uint256 amount, bytes32 actionId) internal override returns (PullOutcome) {
        bool earn = _funding() == Funding.Earn;
        uint256 maxShares = earn ? _quoteShares(amount) : 0;
        Spend memory spend = _spend(amount, actionId, earn ? amount : 0, maxShares);
        return _executeSpend(user, spend, earn ? 0 : amount, maxShares);
    }

    function _executeSpend(address user, Spend memory spend, uint256 stableApproval, uint256 shareApproval)
        internal
        returns (PullOutcome)
    {
        bytes memory call_ = abi.encodeCall(IBridgeSpenderClone.publicCall, (_psCall(spend)));
        TxCall[] memory calls = new TxCall[](5);
        uint256 n;
        if (stableApproval != 0) {
            calls[n++] = TxCall(address(usd), 0, abi.encodeCall(ITIP20.approve, (spender, stableApproval)));
        }
        if (shareApproval != 0) {
            calls[n++] = TxCall(address(earnShare), 0, abi.encodeCall(ITIP20.approve, (spender, shareApproval)));
        }
        calls[n++] = TxCall(spender, 0, call_);
        if (stableApproval != 0) {
            calls[n++] = TxCall(address(usd), 0, abi.encodeCall(ITIP20.approve, (spender, 0)));
        }
        if (shareApproval != 0) {
            calls[n++] = TxCall(address(earnShare), 0, abi.encodeCall(ITIP20.approve, (spender, 0)));
        }
        assembly {
            mstore(calls, n)
        }
        (bool ok, bytes memory reason) = _execAsAccessKeyWithError(user, calls);
        lastPullError = reason;
        return ok ? PullOutcome.Settled : PullOutcome.Rejected;
    }

    function _railDeclineError(Decline reason) internal pure override returns (bytes4) {
        if (reason == Decline.InsufficientFunds) {
            return SafeTransferLib.TransferFromFailed.selector;
        }
        return _tempoDeclineError(reason);
    }

    /// @dev Refunds are stablecoin from the program wallet, as Bridge returns funds today.
    function _railCredit(address user, uint256 amount, bytes32) internal override {
        vm.prank(programWallet);
        usd.transfer(user, amount);
    }

    function _railValue(address user) internal view override returns (uint256) {
        return usd.balanceOf(user) + _shareValue(earnShare.balanceOf(user));
    }

    function _railSetSpendLimit(address user, uint256 limit) internal override {
        uint256 tokenLimit = _funding() == Funding.Earn ? earnVault.previewWithdraw(limit) : limit;
        address limitToken = _limitToken();
        vm.prank(user);
        keychain.updateSpendingLimit(bridgeKey, limitToken, tokenLimit);
    }

    function _railRevoke(address user) internal override {
        vm.prank(user);
        keychain.revokeKey(bridgeKey);
    }

    function _railDrain(address user) internal override {
        vm.startPrank(user);
        usd.transfer(elsewhere, usd.balanceOf(user));
        earnShare.transfer(elsewhere, earnShare.balanceOf(user));
        vm.stopPrank();
    }

    /// @notice One pull that takes `fromStable` stablecoin and the rest from Earn.
    function _railPullSplit(address user, uint256 amount, uint256 fromStable, bytes32 actionId)
        internal
        override
        returns (PullOutcome)
    {
        uint256 fromVault = amount - fromStable;
        uint256 maxShares = _quoteShares(fromVault);
        Spend memory spend = _spend(amount, actionId, fromVault, maxShares);
        return _executeSpend(user, spend, fromStable, maxShares);
    }
}

/// @notice Private spend: balances sit in a Zone. Bridge's Zone access key requests a withdrawal to
///         the program's `ZoneSpendReceiver`, which settles the spend through the clone and returns
///         unused input to the Zone encrypted, so the cardholder never appears on Tempo.
/// @dev The key is scoped to the outbox, which cannot pin the withdrawal recipient.
abstract contract TempoPrivateRail is TempoRailBase {
    uint64 internal constant CALLBACK_GAS = 3_000_000;

    ZoneSpendReceiver internal receiver;

    function _closedLoop() internal pure virtual returns (bool);

    function _railName() internal pure virtual override returns (string memory) {
        return "tempo.ts-private (zone)";
    }

    function _railCaps() internal view override returns (RailCaps memory caps) {
        caps.earn = _funding() == Funding.Earn;
        caps.privateBalances = true;
        caps.boundedShareCost = true;
        caps.periodicSpendLimit = true;
        caps.noStandingAllowance = true;
    }

    function _railSetUp() internal override {
        _deployZone(_closedLoop());
        receiver = new ZoneSpendReceiver(IBridgeSpenderFactory(address(bridgeFactory)), SPENDER_ID, ZONE_ID);
        vm.label(address(receiver), "ZoneSpendReceiver");
        _zoneRegisterGateway(address(receiver));
        _zoneAllowAccount(programRefundRecipient);
    }

    function _inputToken() internal view returns (address) {
        return _funding() == Funding.Earn ? address(earnShare) : address(usd);
    }

    /// @notice Bridge-controlled Tempo account, one per program and admitted on the Zone, that
    ///         receives a Zone return the Zone rejects. The cardholder is the fallbackRecipient.
    address internal programRefundRecipient = makeAddr("bridge.zone-refund-recipient");

    function _railEnroll(address user, uint256 amount) internal override {
        _zoneAllowAccount(user);
        _mintUsd(user, amount);
        uint256 deposit = amount;
        if (_funding() == Funding.Earn) deposit = _depositEarn(user, amount);
        _zoneDeposit(user, _inputToken(), deposit, user);
        _zoneSequence();

        address zoneToken = address(_zoneTokenOf(_inputToken()));
        address[] memory tokens = new address[](1);
        uint256[] memory limits = new uint256[](1);
        tokens[0] = zoneToken;
        limits[0] = _funding() == Funding.Earn ? earnVault.previewWithdraw(CARD_BUDGET) : CARD_BUDGET;
        IAccountKeychain.CallScope[] memory scopes = new IAccountKeychain.CallScope[](2);
        scopes[0] = _scope(zoneToken, ITIP20.approve.selector, address(zoneOutbox));
        scopes[1] = _scope(address(zoneOutbox), IZoneOutbox.requestWithdrawal.selector, address(0));
        _authorizeBridgeKey(user, tokens, limits, scopes);
    }

    function _railPull(address user, uint256 amount, bytes32 actionId) internal override returns (PullOutcome) {
        uint256 change = _returnChange();
        bool earn = _funding() == Funding.Earn;
        uint256 maxShares = earn ? _quoteShares(amount) : 0;
        uint256 input = (earn ? maxShares : amount) + change;
        Spend memory spend = _spend(amount, actionId, earn ? amount : 0, maxShares);
        bytes memory callbackData = abi.encode(spend, _zoneReturnTo(user));
        return _requestPrivateSpend(user, _inputToken(), input, callbackData);
    }

    function _requestPrivateSpend(address user, address inputToken, uint256 input, bytes memory callbackData)
        internal
        returns (PullOutcome)
    {
        TxCall[] memory calls = _outboxCalls(user, inputToken, input, callbackData);
        (bool accepted, bytes memory reason) = _execAsAccessKeyWithError(user, calls);
        lastPullError = reason;
        if (!accepted) return PullOutcome.Rejected;
        // Bridge approves the card once the Zone accepted the request; Tempo settles next batch.
        _zoneSettle();
        lastPullError = lastCallbackErrors[0];
        return lastCallbackResults[0] ? PullOutcome.Settled : PullOutcome.FailedAfterApproval;
    }

    function _railDeclineError(Decline reason) internal pure override returns (bytes4) {
        if (reason == Decline.InsufficientFunds) return ITIP20.InsufficientBalance.selector;
        return _tempoDeclineError(reason);
    }

    function _railZoneKeyWithdrawTo(address user, address outsider, uint256 amount) internal override returns (bool) {
        address token = _inputToken();
        address zoneToken = address(_zoneTokenOf(token));
        TxCall[] memory calls = new TxCall[](2);
        calls[0] = TxCall(zoneToken, 0, abi.encodeCall(ITIP20.approve, (address(zoneOutbox), amount)));
        calls[1] = TxCall(
            address(zoneOutbox),
            0,
            abi.encodeCall(
                IZoneOutbox.requestWithdrawal, (token, outsider, uint128(amount), bytes32(0), 0, user, "", "")
            )
        );
        if (!_execAsAccessKey(user, calls)) return false;
        _zoneSettle();
        return true;
    }

    function _outboxCalls(address user, address inputToken, uint256 input, bytes memory callbackData)
        internal
        view
        returns (TxCall[] memory calls)
    {
        address zoneToken = address(_zoneTokenOf(inputToken));
        uint256 total = input + zoneOutbox.calculateWithdrawalFee(CALLBACK_GAS);
        calls = new TxCall[](2);
        calls[0] = TxCall(zoneToken, 0, abi.encodeCall(ITIP20.approve, (address(zoneOutbox), total)));
        calls[1] = TxCall(
            address(zoneOutbox),
            0,
            abi.encodeCall(
                IZoneOutbox.requestWithdrawal,
                (inputToken, address(receiver), uint128(input), bytes32(0), CALLBACK_GAS, user, callbackData, "")
            )
        );
    }

    /// @notice Change a pull carries whenever something comes back: on a closed-loop Zone, which
    ///         requires every callback to deposit back, and on every Earn spend, which returns its
    ///         unused shares. It covers the portal's deposit and bounce-back fees plus one unit.
    function _returnChange() internal view returns (uint256) {
        if (!zoneClosedLoop && _funding() != Funding.Earn) return 0;
        return uint256(portal.calculateDepositFee()) + portal.calculateBouncebackFee() + 1;
    }

    function _zoneReturnTo(address user) internal returns (ZoneSpendReceiver.ZoneReturn memory) {
        return ZoneSpendReceiver.ZoneReturn({
            keyIndex: 0,
            encrypted: _encryptedTo(user),
            refundRecipient: programRefundRecipient,
            maxDepositFee: portal.calculateDepositFee()
        });
    }

    function _railCredit(address user, uint256 amount, bytes32) internal override {
        vm.startPrank(programWallet);
        usd.approve(address(receiver), amount);
        vm.recordLogs();
        receiver.refundPrivate(address(usd), amount, _zoneReturnTo(user));
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _zoneObserveDeposits(logs);
        _zoneSequence();
    }

    function _railValue(address user) internal view override returns (uint256) {
        return _zoneBalance(address(usd), user) + _shareValue(_zoneBalance(address(earnShare), user));
    }

    function _railShares(address user) internal view override returns (uint256) {
        return _zoneBalance(address(earnShare), user);
    }

    function _railSetSpendLimit(address user, uint256 limit) internal override {
        uint256 tokenLimit = _funding() == Funding.Earn ? earnVault.previewWithdraw(limit) : limit;
        address zoneToken = address(_zoneTokenOf(_inputToken()));
        vm.prank(user);
        keychain.updateSpendingLimit(bridgeKey, zoneToken, tokenLimit);
    }

    function _railRevoke(address user) internal override {
        vm.prank(user);
        keychain.revokeKey(bridgeKey);
    }

    function _railDrain(address user) internal override {
        address zUsd = address(_zoneTokenOf(address(usd)));
        address zShare = address(_zoneTokenOf(address(earnShare)));
        uint256 usdBal = _zoneBalance(address(usd), user);
        uint256 shareBal = _zoneBalance(address(earnShare), user);
        vm.startPrank(user);
        ITIP20(zUsd).transfer(elsewhere, usdBal);
        ITIP20(zShare).transfer(elsewhere, shareBal);
        vm.stopPrank();
    }
}
