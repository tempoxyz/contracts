// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SpenderStatus } from "bridge-spender/src/ISpenderHandler.sol";
import { SpenderFactoryErrorsAndEvents } from "bridge-spender/src/SpenderFactoryErrorsAndEvents.sol";
import { SpenderBase } from "bridge-spender/src/spenders/SpenderBase.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IAccountKeychain } from "tempo-std/interfaces/IAccountKeychain.sol";
import { ITIP20 } from "tempo-std/interfaces/ITIP20.sol";

import { Spend, SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { IBridgeSpenderClone } from "../../src/interfaces/IBridgeSpenderFactory.sol";
import { AccessKeys } from "../harness/AccessKeys.sol";
import { TxCall } from "../harness/lib/TempoTx.sol";

/// @notice What a leaked Bridge access key can and cannot do, with the scopes the rails use.
contract AccessKeySecurityTest is AccessKeys {
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        _deployTempo();
        _deployZone(false);
        _mintUsd(alice, 1000e6);
    }

    // ------------------------------------------------------------------
    // Public key: scoped to approve(clone) and the clone's publicCall
    // ------------------------------------------------------------------

    function _scopePublicKey(uint256 limit) internal {
        _scopePublicKey(alice, limit);
    }

    function _scopePublicKey(address account, uint256 limit) internal {
        address[] memory tokens = new address[](1);
        uint256[] memory limits = new uint256[](1);
        tokens[0] = address(usd);
        limits[0] = limit;
        IAccountKeychain.CallScope[] memory scopes = new IAccountKeychain.CallScope[](2);
        scopes[0] = _scope(address(usd), ITIP20.approve.selector, spender);
        scopes[1] = _scope(spender, IBridgeSpenderClone.publicCall.selector, address(0));
        _authorizeBridgeKey(account, tokens, limits, scopes);
    }

    function test_publicKey_cannotTransferOut() public {
        _scopePublicKey(1000e6);
        _assertRejected(
            _call(address(usd), abi.encodeCall(ITIP20.transfer, (attacker, 1e6))),
            abi.encodeWithSelector(IAccountKeychain.CallNotAllowed.selector)
        );
        assertEq(usd.balanceOf(attacker), 0);
    }

    function test_publicKey_cannotApproveAnyoneButTheClone() public {
        _scopePublicKey(1000e6);
        _assertRejected(
            _call(address(usd), abi.encodeCall(ITIP20.approve, (attacker, 1e6))),
            abi.encodeWithSelector(IAccountKeychain.CallNotAllowed.selector)
        );
        assertEq(usd.allowance(alice, attacker), 0);
    }

    /// @notice Spend only reaches program destinations.
    function test_publicKey_cannotPayOutsideProgram() public {
        _scopePublicKey(1000e6);
        Spend memory s = _spend(10e6);
        s.destination = attacker;
        _assertRejected(
            _approveAndSpend(10e6, s),
            abi.encodeWithSelector(SpenderTempoSpend.DestinationNotAuthorized.selector, attacker)
        );
        assertEq(usd.balanceOf(attacker), 0);
    }

    /// @notice "PS" is the only "TS" action behind the clone's `publicCall`.
    function test_publicKey_reachesNoOtherTempoSpendAction() public {
        _scopePublicKey(1000e6);
        TxCall[] memory calls = _call(
            spender,
            abi.encodeCall(
                IBridgeSpenderClone.publicCall,
                (abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("RF"), attacker, uint256(10e6)))
            )
        );
        _assertRejected(calls, abi.encodeWithSelector(SpenderBase.PrefixUnknown.selector, bytes2("RF")));
    }

    /// @notice The scope names the clone's `publicCall`, not a prefix, so the key also reaches the
    ///         public actions of every other handler the program can use. Here it sets the
    ///         cardholder's "TF" vault preference.
    function test_publicKey_reachesOtherHandlersPublicActions() public {
        _scopePublicKey(1000e6);
        assertTrue(_exec(_setTewfPreference(address(earnVault))), "TF accepted the key");
        bytes memory preference =
            IBridgeSpenderClone(spender).publicGetCall(abi.encodePacked(PREFIX_TEWF, bytes2("GP"), alice));
        assertEq(abi.decode(preference, (address)), address(earnVault));
    }

    /// @notice Gating a handler without allowlisting the program closes that path.
    function test_publicKey_cannotReachAGatedHandler() public {
        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderHandlerStatus(PREFIX_TEWF, SpenderStatus.Gated);
        _scopePublicKey(1000e6);
        _assertRejected(
            _setTewfPreference(address(earnVault)),
            abi.encodeWithSelector(SpenderFactoryErrorsAndEvents.SpenderHandlerNotAllowed.selector)
        );
    }

    function test_publicKey_boundedByPeriodicLimit() public {
        _scopePublicKey(100e6);
        assertTrue(_exec(_approveAndSpend(80e6, _spend(80e6))), "within limit");
        _assertRejected(
            _approveAndSpend(30e6, _spend(30e6)),
            abi.encodeWithSelector(IAccountKeychain.SpendingLimitExceeded.selector)
        );
        vm.warp(block.timestamp + LIMIT_PERIOD);
        assertTrue(_exec(_approveAndSpend(30e6, _spend(30e6))), "next period");
    }

    /// @notice The key names the clone, not a destination, so governance can move the program to a
    ///         new destination without the cardholder authorizing anything again.
    function test_publicKey_followsDestinationChange() public {
        _scopePublicKey(1000e6);
        address next = makeAddr("bridge.settlement.next");
        vm.startPrank(bridgeGovernor);
        bridgeFactory.updateSpenderDestination(SPENDER_ID, next, true);
        bridgeFactory.updateSpenderDestination(SPENDER_ID, settlement, false);
        vm.stopPrank();

        _assertRejected(
            _approveAndSpend(10e6, _spend(10e6)),
            abi.encodeWithSelector(SpenderTempoSpend.DestinationNotAuthorized.selector, settlement)
        );
        Spend memory s = _spend(10e6);
        s.destination = next;
        assertTrue(_exec(_approveAndSpend(10e6, s)), "same key, new destination");
        assertEq(usd.balanceOf(next), 10e6);
    }

    function test_publicKey_revokedKeyCannotSign() public {
        _scopePublicKey(1000e6);
        vm.prank(alice);
        keychain.revokeKey(bridgeKey);
        _assertRejected(
            _approveAndSpend(10e6, _spend(10e6)), abi.encodeWithSelector(IAccountKeychain.KeyAlreadyRevoked.selector)
        );
    }

    /// @notice Decision 9: one Bridge key serves every cardholder of a program, and a transaction
    ///         it signs for one cardholder only ever pays from that cardholder, even while another
    ///         cardholder has an approval standing to the clone.
    function test_sharedKey_paysEachCardholderOnlyFromTheirOwnFunds() public {
        address bob = makeAddr("bob");
        _mintUsd(bob, 1000e6);
        _scopePublicKey(alice, 1000e6);
        _scopePublicKey(bob, 1000e6);
        uint256 before = usd.balanceOf(settlement);
        assertTrue(_execAsAccessKey(alice, _approveAndSpend(10e6, _spend(10e6))), "alice spends");
        assertTrue(_execAsAccessKey(bob, _approveAndSpend(10e6, _spend(10e6))), "bob spends");
        assertEq(usd.balanceOf(settlement) - before, 20e6);

        vm.prank(bob);
        usd.approve(spender, 50e6);
        vm.startPrank(alice);
        usd.transfer(makeAddr("alice.elsewhere"), usd.balanceOf(alice));
        vm.stopPrank();
        uint256 bobBefore = usd.balanceOf(bob);

        TxCall[] memory spendOnly =
            _call(spender, abi.encodeCall(IBridgeSpenderClone.publicCall, (_psCall(_spend(10e6)))));
        _assertRejected(spendOnly, abi.encodeWithSelector(SafeTransferLib.TransferFromFailed.selector));
        _assertRejected(
            _call(address(usd), abi.encodeCall(ITIP20.transferFrom, (bob, settlement, uint256(10e6)))),
            abi.encodeWithSelector(IAccountKeychain.CallNotAllowed.selector)
        );
        assertEq(usd.balanceOf(bob), bobBefore, "bob's funds untouched");
        assertEq(usd.allowance(bob, spender), 50e6, "bob's approval untouched");
    }

    // ------------------------------------------------------------------
    // Zone key
    // ------------------------------------------------------------------

    /// @notice Accepted risk (decision 7): keychain recipient rules only apply to TIP-20 transfer and
    ///         approve, so a Zone key scoped to the outbox's `requestWithdrawal` can withdraw the
    ///         cardholder's private balance, up to its limit, to any address in an open Zone.
    function test_zoneKey_scopedToOutbox_canRedirectWithdrawal() public {
        _fundZone(500e6);
        address zUsd = address(_zoneTokenOf(address(usd)));
        _authorizeZoneKey(zUsd, address(zoneOutbox), address(zoneOutbox), zoneOutbox.requestWithdrawal.selector);

        TxCall[] memory calls = new TxCall[](2);
        calls[0] = TxCall(zUsd, 0, abi.encodeCall(ITIP20.approve, (address(zoneOutbox), 200e6)));
        calls[1] = TxCall(
            address(zoneOutbox),
            0,
            abi.encodeCall(
                zoneOutbox.requestWithdrawal, (address(usd), attacker, uint128(200e6), bytes32(0), 0, alice, "", "")
            )
        );
        assertTrue(_execAsAccessKey(alice, calls), "keychain allowed the redirect");
        _zoneSettle();
        assertEq(usd.balanceOf(attacker), 200e6, "attacker received the private balance");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _fundZone(uint256 amount) internal {
        _zoneDeposit(alice, address(usd), amount, alice);
        _zoneSequence();
    }

    function _authorizeZoneKey(address zoneToken, address approveTo, address target, bytes4 selector) internal {
        address[] memory tokens = new address[](1);
        uint256[] memory limits = new uint256[](1);
        tokens[0] = zoneToken;
        limits[0] = 1000e6;
        IAccountKeychain.CallScope[] memory scopes = new IAccountKeychain.CallScope[](2);
        scopes[0] = _scope(zoneToken, ITIP20.approve.selector, approveTo);
        scopes[1] = _scope(target, selector, address(0));
        _authorizeBridgeKey(alice, tokens, limits, scopes);
    }

    function _spend(uint256 amount) internal view returns (Spend memory) {
        return Spend({
            spenderId: SPENDER_ID,
            token: address(usd),
            amount: amount,
            destination: settlement,
            vault: address(0),
            fromVault: 0,
            maxShares: 0,
            ref: bytes32(0)
        });
    }

    function _approveAndSpend(uint256 approval, Spend memory s) internal view returns (TxCall[] memory calls) {
        calls = new TxCall[](3);
        calls[0] = TxCall(address(usd), 0, abi.encodeCall(ITIP20.approve, (spender, approval)));
        calls[1] = TxCall(spender, 0, abi.encodeCall(IBridgeSpenderClone.publicCall, (_psCall(s))));
        calls[2] = TxCall(address(usd), 0, abi.encodeCall(ITIP20.approve, (spender, 0)));
    }

    function _setTewfPreference(address vault) internal view returns (TxCall[] memory) {
        return _call(
            spender,
            abi.encodeCall(IBridgeSpenderClone.publicCall, (abi.encodePacked(PREFIX_TEWF, bytes2("UP"), vault)))
        );
    }

    function _call(address to, bytes memory data) internal pure returns (TxCall[] memory calls) {
        calls = new TxCall[](1);
        calls[0] = TxCall(to, 0, data);
    }

    function _exec(TxCall[] memory calls) internal returns (bool) {
        return _execAsAccessKey(alice, calls);
    }

    /// @dev Alice's transaction signed by Bridge's key fails with exactly `err`.
    function _assertRejected(TxCall[] memory calls, bytes memory err) internal {
        (bool ok, bytes memory reason) = _execAsAccessKeyWithError(alice, calls);
        assertFalse(ok, "rejected");
        assertEq(reason, err, "rejection reason");
    }
}
