// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IdentityRules } from "../../../src/spend/programs/IdentityRules.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

contract IdentityRulesTest is AuthEnv {
    IdentityRules internal rules;
    address internal governor = makeAddr("governor");
    address internal sponsor = makeAddr("sponsor");
    address internal attester = makeAddr("kyc");
    address internal attesterKey = makeAddr("kyc.key");
    address internal other = makeAddr("other-kyc");
    bytes32 internal constant US = "US";
    bytes32 internal constant EU = "EU";
    bytes32 internal constant KYC = "kyc";
    bytes32 internal constant P1 = "p1";

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 1000e6);
        rules = new IdentityRules(governor);
        address[] memory sponsors = new address[](1);
        sponsors[0] = sponsor;
        vm.prank(governor);
        rules.setJurisdiction(US, 10_000e6, sponsors);
        vm.prank(attester);
        rules.setKey(attesterKey, true);
        _setting(abi.encodeCall(cards.setCompanions, (address(0), address(rules), address(0), address(0))));
        vm.startPrank(issuer);
        rules.setPolicy(address(cards), _attesters(), KYC, US, sponsor);
        vm.stopPrank();
    }

    function _attesters() internal view returns (address[] memory list) {
        list = new address[](1);
        list[0] = attester;
    }

    function _attest(bytes32 jurisdiction, uint64 expiresAt) internal {
        vm.prank(attesterKey);
        rules.attest(attester, alice, KYC, jurisdiction, expiresAt, keccak256("record"));
    }

    function test_authorize_withoutAttestation_identityRequired() public {
        vm.prank(issuer);
        vm.expectRevert(IdentityRules.IdentityRequired.selector);
        cards.authorize(CARD, P1, 10e6, merchant, uint64(block.timestamp + 7 days), 0);
    }

    function test_authorize_withAttestation_approves() public {
        _attest(US, uint64(block.timestamp + 365 days));
        _authorize(P1, 10e6);
        assertEq(cards.purchaseOf(P1).owner, alice);
        assertEq(rules.attestationsOf(alice).length, 1);
    }

    function test_attestation_wrongJurisdictionOrExpired_doesNotCount() public {
        _attest(EU, uint64(block.timestamp + 365 days));
        _attest(US, uint64(block.timestamp + 1 days));
        assertTrue(rules.admits(address(cards), alice));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertFalse(rules.admits(address(cards), alice));
    }

    function test_attest_onlyRegisteredKeys() public {
        // A key the attester never registered can't vouch in its name.
        vm.prank(alice);
        vm.expectRevert(IdentityRules.Unauthorized.selector);
        rules.attest(attester, alice, KYC, US, uint64(block.timestamp + 1 days), bytes32(0));
        // A revoked key stops attesting.
        vm.prank(attester);
        rules.setKey(attesterKey, false);
        vm.prank(attesterKey);
        vm.expectRevert(IdentityRules.Unauthorized.selector);
        rules.attest(attester, alice, KYC, US, uint64(block.timestamp + 1 days), bytes32(0));
    }

    function test_attestation_fromUnacceptedAttester_doesNotCount() public {
        vm.prank(other);
        rules.setKey(other, true);
        vm.prank(other);
        rules.attest(other, alice, KYC, US, uint64(block.timestamp + 1 days), bytes32(0));
        assertFalse(rules.admits(address(cards), alice));
    }

    function test_attest_refusesPastExpiryOrEmptyClaim() public {
        vm.startPrank(attesterKey);
        vm.expectRevert(IdentityRules.InvalidAttestation.selector);
        rules.attest(attester, alice, KYC, US, uint64(block.timestamp), bytes32(0));
        vm.expectRevert(IdentityRules.InvalidAttestation.selector);
        rules.attest(attester, alice, bytes32(0), US, uint64(block.timestamp + 1), bytes32(0));
        vm.stopPrank();
    }

    function test_setPolicy_sponsorMustBeLicensed() public {
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IdentityRules.SponsorNotLicensed.selector, sponsor, EU));
        rules.setPolicy(address(cards), _attesters(), KYC, EU, sponsor);
    }

    function test_setPolicy_onlyProgramIssuer() public {
        vm.prank(alice);
        vm.expectRevert(IdentityRules.Unauthorized.selector);
        rules.setPolicy(address(cards), _attesters(), KYC, US, sponsor);
    }

    function test_setJurisdiction_onlyGovernor() public {
        vm.prank(issuer);
        vm.expectRevert(IdentityRules.Unauthorized.selector);
        rules.setJurisdiction(EU, 1, new address[](0));
        (uint128 threshold, address[] memory sponsors) = rules.jurisdictionOf(US);
        assertEq(threshold, 10_000e6);
        assertEq(sponsors.length, 1);
    }

    function test_lapsedAttestation_blocksNewPurchases_openOneStillCaptures() public {
        _attest(US, uint64(block.timestamp + 1 days));
        _authorize(P1, 10e6);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(issuer);
        vm.expectRevert(IdentityRules.IdentityRequired.selector);
        cards.authorize(CARD, "p2", 10e6, merchant, uint64(block.timestamp + 7 days), 0);
        _capture(P1, 10e6, true);
        assertEq(usd.balanceOf(settlement), 10e6);
    }

    function test_admits_strangersAttestationsDoNotChangeCostOrResult() public {
        address carol = makeAddr("carol");
        address dave = makeAddr("dave");
        // One stranger attests over and over, and many strangers attest once each, in the policy's claim and
        // jurisdiction, before the accepted attester does.
        vm.prank(other);
        rules.setKey(other, true);
        for (uint256 i; i < 30; ++i) {
            vm.prank(other);
            rules.attest(other, carol, KYC, US, uint64(block.timestamp + 1 days + i), bytes32(i));
        }
        for (uint160 i = 1; i <= 20; ++i) {
            address stranger = address(0x5000 + i);
            vm.startPrank(stranger);
            rules.setKey(stranger, true);
            rules.attest(stranger, carol, KYC, US, uint64(block.timestamp + 1 days), bytes32(0));
            vm.stopPrank();
        }
        // None of theirs admits.
        assertFalse(rules.admits(address(cards), carol));
        vm.startPrank(attesterKey);
        rules.attest(attester, carol, KYC, US, uint64(block.timestamp + 365 days), keccak256("record"));
        rules.attest(attester, dave, KYC, US, uint64(block.timestamp + 365 days), keccak256("record"));
        vm.stopPrank();
        // Admitting the account strangers piled onto costs what admitting one nobody else attested does (the first
        // read warms the policy for both).
        assertFalse(rules.admits(address(cards), alice));
        uint256 gas = gasleft();
        assertTrue(rules.admits(address(cards), dave));
        uint256 plain = gas - gasleft();
        gas = gasleft();
        assertTrue(rules.admits(address(cards), carol));
        assertEq(gas - gasleft(), plain);
    }

    function test_attest_sameAttesterOverwritesInPlace() public {
        _attest(US, uint64(block.timestamp + 1 days));
        _attest(US, uint64(block.timestamp + 30 days));
        IdentityRules.Attestation[] memory list = rules.attestationsOf(alice);
        assertEq(list.length, 1);
        assertEq(list[0].expiresAt, uint64(block.timestamp + 30 days));
        assertEq(rules.attestationOf(alice, attester).expiresAt, uint64(block.timestamp + 30 days));
    }

    function test_noPolicy_admitsEveryone() public view {
        assertTrue(rules.admits(address(0xBEEF), alice));
    }
}
