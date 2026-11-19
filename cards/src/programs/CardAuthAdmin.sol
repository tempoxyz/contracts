// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuthBase } from "./CardAuthBase.sol";
import { CardLegs } from "./CardLegs.sol";
import { CardLimits } from "./CardLimits.sol";
import { ISource } from "./interfaces/ISource.sol";

/// @title CardAuthAdmin
/// @notice CardAuth's settings, card management and cardholder calls. CardAuth deploys it once and runs it by
///         delegatecall over CardAuth's own storage, so the code is CardAuth's and nothing here changes after
///         deployment. Called directly it only touches its own storage, which nothing reads.
// Library calls are linked code, not outside contracts; sources it calls are ones the issuer approved.
// forge-lint: disable-start(reentrancy-no-eth, calls-loop, unsafe-typecast)
contract CardAuthAdmin is CardAuthBase {
    constructor(address settlementAccount) CardAuthBase(settlementAccount) { }

    // Issuer.

    function issueCard(bytes32 card, address owner, uint40 expiry, CardLimits.Limits calldata limits, uint8 kinds)
        external
    {
        _onlyIssuer();
        CardLimits.issue(_cards[card], card, owner, expiry, limits, kinds, _newIndex(card), _scale());
    }

    /// @notice Replaces `oldCard` with `newCard`; open purchases follow the replacement.
    function replaceCard(bytes32 oldCard, bytes32 newCard, uint40 expiry) external {
        _onlyIssuer();
        CardLimits.replace(_cards[oldCard], _cards[newCard], oldCard, newCard, expiry, _newIndex(newCard));
        replacedBy[oldCard] = newCard;
    }

    /// @notice Sets a card's spending cap in units, expiry, or status (as CardLimits.set reads `what`).
    function setCard(bytes32 card, uint8 what, uint256 value) external {
        _onlyIssuer();
        CardLimits.set(_cards[card], card, what, value, _scale());
    }

    /// @notice Carries an owner's usage counted on another instance of the program: `data` is the ABI encoding of
    ///         (Usage usage, bytes32[] cards, Window[] windows, address[] merchants, Mandate[] spent), as CardLimits.carry
    ///         reads it.
    function carryUsage(address owner, bytes calldata data) external {
        _onlyIssuer();
        CardLimits.carry(_cards, mandates[owner], usageOf[owner], owner, data);
    }

    /// @notice Gives `key` the role bits `roles` and a cumulative cap of `cap` units; zero roles removes it.
    function setOperator(address key, uint8 roles, uint256 cap) external {
        _onlyIssuer();
        uint256 base;
        if (roles != 0) {
            base = _base(cap);
            if (roles > 7 || base == 0 || base > type(uint120).max) revert InvalidAmount();
        }
        _operators[key] = Operator(roles, uint120(base), 0);
        emit OperatorSet(key, roles, cap);
    }

    /// @notice Approves `source` as a funding source after the settings delay, or stops it at once. A stopped
    ///         source still settles the purchases it holds.
    function setSource(address source, bool approved) external {
        _onlyIssuer();
        if (!_settle(!approved)) return;
        uint8 kind = approved ? ISource(source).KIND() : 0;
        if (approved && kind != CASH && kind != SAVINGS && kind != CREDIT) revert InvalidOrder();
        sourceKind[source] = kind;
        emit SourceSet(source, kind);
    }

    /// @notice Registers a companion contract (treasury, desk, reserves) after the settings delay, or removes one at
    ///         once.
    function setCompanion(address account, bool active) external {
        _onlyIssuer();
        if (!_settle(!active)) return;
        // The event follows on the next line.
        // forge-lint: disable-next-line(missing-events-access-control)
        isCompanion[account] = active;
        emit CompanionSet(account, active);
    }

    /// @notice Sets the account key registry, identity rules, account lifecycle and conversion the program follows.
    // Zero is meaningful for each: owners sign as themselves, no identity check, no lifecycle, no conversion.
    // forge-lint: disable-next-item(missing-zero-check)
    function setCompanions(address accountKeys_, address identityRules_, address lifecycle_, address conversion_)
        external
    {
        _onlyIssuer();
        if (!_settle(false)) return;
        (accountKeys, identityRules, lifecycle, conversion) = (accountKeys_, identityRules_, lifecycle_, conversion_);
        emit CompanionsSet(accountKeys_, identityRules_, lifecycle_, conversion_);
    }

    /// @notice Sets the guard asked after every step that raises the program's exposure (zero for none), after the
    ///         settings delay.
    // Zero turns the check off.
    // forge-lint: disable-next-item(missing-zero-check)
    function setExposureGuard(address guard) external {
        _onlyIssuer();
        if (!_settle(false)) return;
        exposureGuard = guard;
        emit ExposureGuardSet(guard);
    }

    function cancelSetting(bytes32 id) external {
        _onlyIssuer();
        delete pendingSetting[id];
        emit SettingCancelled(id);
    }

    // Zero is how the issuer withdraws an offer.
    // forge-lint: disable-next-item(missing-zero-check)
    function transferIssuer(address next) external {
        _onlyIssuer();
        // The event follows on the next line.
        // forge-lint: disable-next-line(missing-events-access-control)
        pendingIssuer = next;
        emit IssuerOffered(msg.sender, next);
    }

    function acceptIssuer() external {
        if (msg.sender != pendingIssuer) revert NotIssuer();
        emit IssuerTransferred(_issuer, msg.sender);
        // IssuerTransferred, just above, records both changes.
        // forge-lint: disable-start(missing-events-access-control)
        _issuer = msg.sender;
        delete pendingIssuer;
        // forge-lint: disable-end(missing-events-access-control)
    }

    /// @notice Acknowledges purchase steps through `throughSeq` as settled off chain. Once the issuer sets an exposure
    ///         guard, only the guard acknowledges, for the party the exposure is owed to; without one, the issuer.
    function acknowledgeSettlement(uint64 throughSeq) external {
        address guard = exposureGuard;
        if (guard == address(0)) _onlyIssuer();
        else if (msg.sender != guard) revert Unauthorized();
        CardLegs.acknowledge(_ledger, throughSeq);
    }

    // Companions.

    function useOperatorCap(address operator, uint256 value) external {
        if (!isCompanion[msg.sender]) revert NotCompanion();
        _useCap(operator, value);
    }

    function setSettlementToken(address token, uint256 scale) external {
        if (!isCompanion[msg.sender]) revert NotCompanion();
        CardLegs.switchToken(eras, _state, _ledger, token, scale);
    }

    // Cardholder.

    /// @notice Freezes (1), unfreezes (2) or closes (3) the caller's card.
    function setOwnStatus(bytes32 card, uint8 how) external {
        CardLimits.setOwnStatus(_ownedCard(card), card, how);
    }

    /// @notice Sets a card's limits: `how` 0 the issuer raises them within the ceiling the owner allows, 1 the owner
    ///         lowers them (and the ceiling with them), 2 the owner sets the ceiling.
    function setLimits(bytes32 card, CardLimits.Limits calldata limits, uint8 how) external {
        CardLimits.Card storage c = _cards[card];
        if (how == 0) _onlyIssuer();
        else _ownedCard(card);
        CardLimits.setLimits(c, card, limits, how, _scale());
    }

    function setMandate(address merchant, bool revoked, uint96 monthlyLimit) external {
        CardLimits.setMandate(mandates[msg.sender][merchant], merchant, revoked, monthlyLimit, _scale());
    }

    /// @notice Lists the approved sources the caller's purchases draw on, in order. Open purchases keep the order
    ///         they were placed under. Versions count modulo 256.
    function setFunding(CardLegs.Funding[] calldata order) external {
        uint8 version;
        unchecked {
            version = fundingVersion[msg.sender] + 1;
        }
        CardLegs.setOrder(_funding[msg.sender][version], sourceKind, order, version);
        fundingVersion[msg.sender] = version;
    }

    /// @notice Grants the program `given` terms across the caller's cards, starting their usage afresh.
    function grant(CardLimits.Terms calldata given) external {
        if (CardLimits.grant(grants[msg.sender], usageOf[msg.sender], given, eras[_state.era].scale)) {
            ++_state.grantedOwners;
        }
    }

    function revoke() external {
        grants[msg.sender].active = false;
        emit Revoked(msg.sender);
    }
}
// forge-lint: disable-end(reentrancy-no-eth, calls-loop, unsafe-typecast)
