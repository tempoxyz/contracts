// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Vm } from "forge-std/Vm.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ISignatureVerifier } from "tempo-std/interfaces/ISignatureVerifier.sol";
import { ITIP20, ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

import {
    BlockTransition,
    DepositPayload,
    DepositQueueTransition,
    IWithdrawalReceiver,
    IZoneFactory,
    IZonePortal,
    PORTAL_ENCRYPTION_KEYS_SLOT,
    Role,
    TokenEnablementTransition,
    Withdrawal,
    ZONE_FACTORY_ADDRESS,
    ZONE_MESSENGER_ADDRESS,
    ZONE_PORTAL_IMPL_ADDRESS,
    ZONE_VERIFIER_ADDRESS,
    ZoneInfo
} from "tempo-zones/interfaces/IZone.sol";
import { Verifier } from "tempo-zones/tempo/Verifier.sol";
import { ZoneMessenger } from "tempo-zones/tempo/ZoneMessenger.sol";
import { ZonePortal } from "tempo-zones/tempo/ZonePortal.sol";

import { TempoEnv } from "./TempoEnv.sol";

/// @notice Zone-side withdrawal entrypoint. Mirrors the shape of the Zone's outbox
///         `requestWithdrawal` so a Zone access key can be scoped to it exactly as in production.
contract ZoneOutboxSim {
    uint64 internal constant WITHDRAWAL_BASE_GAS = 50_000;

    ZoneEnv private immutable SEQUENCER;
    /// @notice Zone token units per Tempo gas unit, set by the sequencer.
    uint128 public tempoGasRate;

    constructor(ZoneEnv sequencer_) {
        SEQUENCER = sequencer_;
    }

    function setTempoGasRate(uint128 rate) external {
        require(msg.sender == address(SEQUENCER), "only sequencer");
        tempoGasRate = rate;
    }

    function calculateWithdrawalFee(uint64 gasLimit) public view returns (uint128) {
        return (WITHDRAWAL_BASE_GAS + gasLimit) * tempoGasRate;
    }

    function requestWithdrawal(
        address token,
        address to,
        uint128 amount,
        bytes32 memo,
        uint64 gasLimit,
        address fallbackRecipient,
        bytes calldata callbackData,
        bytes calldata
    ) external {
        _validateRecipient(to, gasLimit);
        address zoneToken = SEQUENCER.zoneTokenFor(token);
        uint256 total = uint256(amount) + calculateWithdrawalFee(gasLimit);
        require(ITIP20(zoneToken).transferFrom(msg.sender, address(this), total), "zone debit");
        SEQUENCER.enqueueWithdrawal(msg.sender, token, to, amount, memo, gasLimit, fallbackRecipient, callbackData);
    }

    /// @dev The Zone outbox's recipient policy: closed-loop Zones only withdraw to admitted
    ///      accounts, and only call back into registered gateways.
    function _validateRecipient(address to, uint64 gasLimit) internal view {
        ZonePortal portal = SEQUENCER.zonePortal();
        bool gatewayEnforced = !portal.isGatewayOpen();
        bool isGateway = portal.hasRole(to, Role.CallbackGateway);
        if (gasLimit == 0) {
            require(!(gatewayEnforced && isGateway), "invalid callback target");
            require(!portal.isAccessEnforced() || portal.hasRole(to, Role.Account), "account not allowed");
        } else {
            require(!gatewayEnforced || isGateway, "invalid callback target");
        }
    }
}

/// @notice Runs a Tempo Zone against the real L1 contracts.
/// @dev The Tempo side is production code: `ZonePortal`, `ZoneMessenger` and the shared verifier
///      at their canonical addresses, the TIP-20 precompile, and the AccountKeychain. The Zone side
///      is a model: each Zone balance is a shadow TIP-20 in the same EVM (so the real keychain
///      enforces Zone access-key limits and call scopes), and this contract plays sequencer,
///      decrypting deposits, batching withdrawals, and crediting bounce-backs and returns.
abstract contract ZoneEnv is TempoEnv {
    uint32 internal constant ZONE_ID = 7;

    /// @dev Stand-in for the sequencer's encryption key: the secp256k1 generator x-coordinate.
    bytes32 private constant SEQUENCER_KEY_X = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;

    bytes32 private constant WITHDRAWAL_PROCESSED_SIG =
        keccak256("WithdrawalProcessed(address,bytes32,address,uint128,bool)");
    bytes32 private constant DEPOSIT_MADE_SIG = keccak256(
        "DepositMade(bytes32,address,address,uint128,uint128,uint256,bytes32,uint8,bytes,bytes12,bytes16,address,uint64)"
    );

    ZonePortal internal portal;
    ZoneOutboxSim internal zoneOutbox;
    address internal zoneAdmin = makeAddr("zone.admin");
    address internal zoneSequencer = makeAddr("zone.sequencer");
    bool internal zoneClosedLoop;

    mapping(address l1Token => address zoneToken) private _zoneToken;

    struct Credit {
        address token;
        address to;
        uint256 amount;
    }

    Withdrawal[] private _pendingWithdrawals;
    Credit[] private _queuedCredits;
    mapping(bytes32 senderTag => address fallbackRecipient) private _fallbackOf;
    uint64 private _fallbackNonce;
    bytes32 private _processedDepositHash;
    uint64 private _processedDepositNumber;
    uint64 private _processedTokenCount;
    uint64 private _enabledTokenCount;
    uint256 private _zoneHeight;
    uint256 private _encryptionNonce;

    /// @notice Every Tempo log emitted while the last batch's withdrawals were processed.
    bytes internal lastSettlementLogBlob;
    /// @notice Callback outcomes of the last processed batch, in order.
    bool[] internal lastCallbackResults;
    /// @notice Why each callback of the last processed batch failed, in order: the receiver's
    ///         revert data, or the portal's error for a closed-loop callback that returned nothing.
    ///         Empty for a callback that settled and for a plain withdrawal.
    bytes[] internal lastCallbackErrors;

    // ------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------

    /// @param closedLoop Enforce both the account allowlist and callback gateway registration.
    ///        Open mode admits any account and callback target.
    function _deployZone(bool closedLoop) internal {
        zoneClosedLoop = closedLoop;
        if (ZONE_FACTORY_ADDRESS.code.length == 0) vm.etch(ZONE_FACTORY_ADDRESS, hex"00");
        vm.etch(ZONE_VERIFIER_ADDRESS, type(Verifier).runtimeCode);
        vm.etch(ZONE_MESSENGER_ADDRESS, type(ZoneMessenger).runtimeCode);
        vm.etch(ZONE_PORTAL_IMPL_ADDRESS, address(new ZonePortal()).code);

        address proxy = address(uint160(0x5ad0) << 144 | uint160(ZONE_ID));
        vm.etch(
            proxy,
            abi.encodePacked(hex"363d3d373d3d3d363d73", ZONE_PORTAL_IMPL_ADDRESS, hex"5af43d82803e903d91602b57fd5bf3")
        );
        portal = ZonePortal(proxy);
        vm.label(proxy, "ZonePortal");

        _mockPolicyBinding(address(usd));
        _mockPolicyBinding(address(earnShare));

        address[] memory sequencers = new address[](1);
        sequencers[0] = zoneSequencer;
        address[] memory none = new address[](0);
        vm.prank(ZONE_FACTORY_ADDRESS);
        portal.initialize(
            ZONE_ID,
            address(usd),
            closedLoop,
            closedLoop,
            none,
            none,
            ZONE_MESSENGER_ADDRESS,
            zoneAdmin,
            sequencers,
            1,
            ZONE_VERIFIER_ADDRESS,
            "http://zone.local"
        );
        _enabledTokenCount = 1;

        vm.mockCall(
            ZONE_FACTORY_ADDRESS,
            abi.encodeCall(IZoneFactory.zones, (ZONE_ID)),
            abi.encode(
                ZoneInfo({
                    zoneId: ZONE_ID,
                    portal: proxy,
                    accessMode: closedLoop,
                    gatewayMode: closedLoop,
                    admin: zoneAdmin,
                    sequencers: sequencers,
                    threshold: 1,
                    verifier: ZONE_VERIFIER_ADDRESS,
                    rpcUrl: "http://zone.local"
                })
            )
        );
        vm.mockCall(ZONE_FACTORY_ADDRESS, abi.encodeCall(IZoneFactory.isZonePortal, (proxy)), abi.encode(true));
        vm.mockCall(
            address(StdPrecompiles.SIGNATURE_VERIFIER),
            abi.encodeWithSelector(ISignatureVerifier.recover.selector),
            abi.encode(zoneSequencer)
        );
        _installEncryptionKey();

        zoneOutbox = new ZoneOutboxSim(this);
        vm.label(address(zoneOutbox), "ZoneOutbox");
        _createZoneToken(address(usd), "Zone OUSD");

        // The first batch initializes the token cursor; then EarnShare can be enabled.
        _zoneSequence();
        vm.prank(zoneAdmin);
        portal.enableToken(address(earnShare));
        _enabledTokenCount += 1;
        _createZoneToken(address(earnShare), "Zone EarnShare");
        _zoneSequence();
    }

    /// @dev The portal requires a TIP-403 policy binding (a later hardfork than the local EVM's
    ///      T8), so report the token's own policy as bound, as the zones test suite does.
    function _mockPolicyBinding(address token) private {
        vm.mockCall(
            address(StdPrecompiles.TIP403_REGISTRY),
            abi.encodeCall(ITIP403Registry.tokenTransferPolicyId, (token)),
            abi.encode(true, ITIP20(token).transferPolicyId())
        );
    }

    function _installEncryptionKey() private {
        bytes32 entriesBase = keccak256(abi.encode(uint256(PORTAL_ENCRYPTION_KEYS_SLOT)));
        vm.store(address(portal), PORTAL_ENCRYPTION_KEYS_SLOT, bytes32(uint256(1)));
        vm.store(address(portal), entriesBase, SEQUENCER_KEY_X);
        vm.store(
            address(portal),
            bytes32(uint256(entriesBase) + 1),
            bytes32((uint256(uint64(block.number)) << 8) | uint256(0x02))
        );
    }

    function _createZoneToken(address l1Token, string memory name) private {
        ITIP20Token zt = ITIP20Token(
            tip20Factory.createToken(name, "ZT", "USD", ITIP20(PATH_USD), address(this), keccak256(bytes(name)))
        );
        zt.grantRole(ISSUER_ROLE, address(this));
        _zoneToken[l1Token] = address(zt);
        vm.label(address(zt), name);
    }

    /// @notice Admits an account (closed loop) so it can deposit and receive bounce-backs.
    function _zoneAllowAccount(address account) internal {
        if (!zoneClosedLoop) return;
        vm.prank(zoneAdmin);
        portal.setAllowedAccount(account, true);
    }

    /// @notice Registers a callback receiver (closed loop requires it for callback withdrawals).
    function _zoneRegisterGateway(address gateway) internal {
        if (!zoneClosedLoop) return;
        vm.prank(zoneAdmin);
        portal.setGateway(gateway, true);
    }

    // ------------------------------------------------------------------
    // Zone state
    // ------------------------------------------------------------------

    function zonePortal() external view returns (ZonePortal) {
        return portal;
    }

    function zoneTokenFor(address l1Token) external view returns (address) {
        address zt = _zoneToken[l1Token];
        require(zt != address(0), "token not enabled in zone");
        return zt;
    }

    function _zoneTokenOf(address l1Token) internal view returns (ITIP20Token) {
        return ITIP20Token(this.zoneTokenFor(l1Token));
    }

    function _zoneBalance(address l1Token, address account) internal view returns (uint256) {
        return _zoneTokenOf(l1Token).balanceOf(account);
    }

    /// @notice Encrypted recipient payload the sequencer will decrypt to `recipient`.
    /// @dev Real deposits use ECIES to the sequencer key and the portal only checks their shape.
    ///      The model XORs the plaintext with a keystream derived from a fresh nonce, so Tempo
    ///      data never contains the recipient and equal recipients never repeat a ciphertext.
    function _encryptedTo(address recipient) internal returns (DepositPayload memory) {
        bytes12 nonce = bytes12(keccak256(abi.encode("zone.nonce", ++_encryptionNonce)));
        return DepositPayload({
            ephemeralPubkeyX: SEQUENCER_KEY_X,
            ephemeralPubkeyYParity: 0x02,
            ciphertext: _xorKeystream(abi.encodePacked(recipient, bytes32(0), bytes12(0)), nonce),
            nonce: nonce,
            tag: bytes16(0)
        });
    }

    function _decryptRecipient(bytes memory ciphertext, bytes12 nonce) private pure returns (address) {
        return address(bytes20(_xorKeystream(ciphertext, nonce)));
    }

    function _xorKeystream(bytes memory data, bytes12 nonce) private pure returns (bytes memory out) {
        out = new bytes(data.length);
        for (uint256 i; i < data.length; ++i) {
            bytes32 block_ = keccak256(abi.encode(SEQUENCER_KEY_X, nonce, i / 32));
            out[i] = data[i] ^ block_[i % 32];
        }
    }

    /// @notice `from` deposits L1 tokens into the Zone for `recipient`, credited at the next batch.
    function _zoneDeposit(address from, address token, uint256 amount, address recipient) internal {
        vm.startPrank(from);
        ITIP20(token).approve(address(portal), amount);
        portal.deposit(token, uint128(amount), 0, _encryptedTo(recipient), from);
        vm.stopPrank();
        _queuedCredits.push(Credit(token, recipient, amount));
    }

    /// @notice Called by the outbox once a Zone account authorized a withdrawal.
    function enqueueWithdrawal(
        address sender,
        address token,
        address to,
        uint128 amount,
        bytes32 memo,
        uint64 gasLimit,
        address fallbackRecipient,
        bytes calldata callbackData
    ) external {
        require(msg.sender == address(zoneOutbox), "only outbox");
        _fallbackNonce += 1;
        bytes32 senderTag = keccak256(abi.encodePacked(sender, _fallbackNonce));
        _fallbackOf[senderTag] = fallbackRecipient;
        _pendingWithdrawals.push(
            Withdrawal({
                token: token,
                senderTag: senderTag,
                to: to,
                amount: amount,
                memo: memo,
                gasLimit: gasLimit,
                fallbackNonce: _fallbackNonce,
                callbackData: callbackData,
                encryptedSender: ""
            })
        );
    }

    function _zonePendingWithdrawals() internal view returns (uint256) {
        return _pendingWithdrawals.length;
    }

    // ------------------------------------------------------------------
    // Sequencing
    // ------------------------------------------------------------------

    /// @notice Settles everything outstanding: processes queued withdrawals on Tempo, then runs a
    ///         second batch so callback returns and bounce-backs are credited in the Zone.
    function _zoneSettle() internal {
        _zoneSequence();
        _zoneSequence();
    }

    /// @notice One Zone batch: credits deposits the Zone has observed, submits the batch to the
    ///         real portal, then processes its withdrawals (running Tempo callbacks).
    function _zoneSequence() internal {
        Withdrawal[] memory withdrawals = _pendingWithdrawals;
        delete _pendingWithdrawals;

        bytes32 queueHash;
        for (uint256 i = withdrawals.length; i > 0; --i) {
            queueHash = keccak256(abi.encode(withdrawals[i - 1], queueHash));
        }

        // Deposits already in the portal queue are processed by this batch.
        Credit[] memory credits = _queuedCredits;
        delete _queuedCredits;
        bytes32 depositHead = portal.currentDepositQueueHash();
        uint64 depositCount = portal.depositCount();

        vm.roll(block.number + 1);
        _zoneHeight += 1;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = hex"01";
        bytes32 prevBlockHash = portal.blockHash();
        vm.prank(zoneSequencer);
        portal.submitBatch(
            uint64(block.number - 1),
            0,
            BlockTransition({
                prevBlockHash: prevBlockHash, nextBlockHash: keccak256(abi.encode("zone", _zoneHeight))
            }),
            DepositQueueTransition({
                    prevProcessedHash: _processedDepositHash,
                    nextProcessedHash: depositHead,
                    prevDepositNumber: _processedDepositNumber,
                    nextDepositNumber: depositCount
                }),
            TokenEnablementTransition({
                prevProcessedTokenCount: _processedTokenCount, nextProcessedTokenCount: _enabledTokenCount
            }),
            queueHash,
            "",
            "",
            _zoneHeight,
            signatures
        );
        _processedDepositHash = depositHead;
        _processedDepositNumber = depositCount;
        _processedTokenCount = _enabledTokenCount;

        for (uint256 i; i < credits.length; ++i) {
            ITIP20Token(_zoneToken[credits[i].token]).mint(credits[i].to, credits[i].amount);
        }

        if (withdrawals.length == 0) return;
        bytes[] memory errors = new bytes[](withdrawals.length);
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < withdrawals.length; ++i) {
            if (withdrawals[i].gasLimit == 0) continue;
            try this.dryRunCallback(withdrawals[i]) { }
            catch (bytes memory err) {
                errors[i] = err;
            }
        }
        vm.revertToState(snapshot);
        delete lastCallbackErrors;
        for (uint256 i; i < errors.length; ++i) {
            lastCallbackErrors.push(errors[i]);
        }
        vm.recordLogs();
        vm.prank(zoneSequencer);
        portal.processWithdrawals(withdrawals, bytes32(0));
        _observe(withdrawals, vm.getRecordedLogs());
    }

    /// @notice Runs one callback as the portal and messenger deliver it, reverting with the
    ///         reason it fails. The messenger reports every receiver revert as
    ///         `CallbackRejected()`, so `_zoneSequence` reads the reason here inside a snapshot.
    function dryRunCallback(Withdrawal calldata w) external {
        require(msg.sender == address(this), "only self");
        bytes32 depositsBefore = portal.currentDepositQueueHash();
        vm.prank(address(portal));
        ITIP20(w.token).transfer(w.to, w.amount);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        (bool ok, bytes memory err) = w.to.call{ gas: w.gasLimit }(
            abi.encodeCall(
                IWithdrawalReceiver.onWithdrawalReceived,
                (ZONE_ID, address(portal), w.senderTag, w.token, w.amount, w.callbackData)
            )
        );
        if (!ok) {
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }
        if (portal.isAccessEnforced() && portal.currentDepositQueueHash() == depositsBefore) {
            revert IZonePortal.CallbackDidNotReturnToZone();
        }
    }

    /// @notice Whether any Tempo log of the last processed batch carries `word` as a topic or
    ///         data word, such as an event signature.
    function _lastSettlementLogged(bytes32 word) internal view returns (bool) {
        bytes memory blob = lastSettlementLogBlob;
        if (blob.length < 32) return false;
        for (uint256 i; i <= blob.length - 32; ++i) {
            bytes32 window;
            assembly {
                window := mload(add(add(blob, 0x20), i))
            }
            if (window == word) return true;
        }
        return false;
    }

    /// @notice Queues Zone credits for deposits made outside a batch (e.g. a private refund).
    ///         Call with the logs recorded around the depositing transaction.
    function _zoneObserveDeposits(Vm.Log[] memory logs) internal {
        Withdrawal[] memory none = new Withdrawal[](0);
        _observe(none, logs);
    }

    /// @dev Reads what the Zone would learn from Tempo: callback results (failures bounce back to
    ///      the fallback recipient) and deposits appended during callbacks (encrypted returns).
    function _observe(Withdrawal[] memory withdrawals, Vm.Log[] memory logs) private {
        delete lastCallbackResults;
        bytes memory blob;
        uint256 next;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            blob = abi.encodePacked(blob, log.emitter, log.data);
            for (uint256 t; t < log.topics.length; ++t) {
                blob = abi.encodePacked(blob, log.topics[t]);
            }
            if (log.emitter != address(portal) || log.topics.length == 0) continue;
            if (log.topics[0] == WITHDRAWAL_PROCESSED_SIG) {
                (, uint128 amount, bool ok) = abi.decode(log.data, (address, uint128, bool));
                Withdrawal memory w = withdrawals[next++];
                lastCallbackResults.push(ok);
                if (!ok) _queuedCredits.push(Credit(w.token, _fallbackOf[w.senderTag], amount));
            } else if (log.topics[0] == DEPOSIT_MADE_SIG) {
                (address token, uint128 netAmount,,,,, bytes memory ciphertext, bytes12 nonce,,,) = abi.decode(
                    log.data,
                    (address, uint128, uint128, uint256, bytes32, uint8, bytes, bytes12, bytes16, address, uint64)
                );
                _queuedCredits.push(Credit(token, _decryptRecipient(ciphertext, nonce), netAmount));
            }
        }
        lastSettlementLogBlob = blob;
    }
}
