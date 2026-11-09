// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EarnFactory } from "tempo-earn/core/EarnFactory.sol";
import { EarnFees } from "tempo-earn/core/EarnFees.sol";
import { EarnVault } from "tempo-earn/core/EarnVault.sol";
import { ERC4626Engine, IERC4626Vault } from "tempo-earn/engines/ERC4626Engine.sol";
import { FeeConfig } from "tempo-earn/interfaces/core/EarnFeeTypes.sol";
import {
    DistributorConfig,
    EarnVaultControls,
    EngineMigrationMode
} from "tempo-earn/interfaces/core/EarnVaultTypes.sol";
import { IReceivePolicyGuard } from "tempo-std/interfaces/IReceivePolicyGuard.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

import { CardSpend } from "../../src/core/CardSpend.sol";
import { CardSpender } from "../../src/core/CardSpender.sol";
import { TempoEnv } from "../bridge/harness/TempoEnv.sol";
import { MockProvider } from "./harness/Mocks.sol";

/// @dev ERC-4626 permits withdraw to burn fewer shares than previewWithdraw quotes. Native EarnShare
///      refunds therefore remain necessary even when the payer approves exactly the live quote.
contract RefundConservativeQuoteVenue is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Conservative venue", "CV") { }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return super.previewWithdraw(assets) + 1e6;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        require(assets <= maxWithdraw(owner), "capacity");
        shares = _convertToShares(assets, Math.Rounding.Ceil);
        _withdraw(msg.sender, receiver, owner, assets, shares);
    }
}

/// @notice Public Earn refunds must credit the payer, not TIP-1028's receive-policy guard, on both paths.
/// @dev Uses native TIP precompiles, real Earn and Bridge payout; only the venue and direct provider are fixtures.
contract RefundReceivePolicyTest is TempoEnv {
    ITIP403Registry internal constant POLICIES = ITIP403Registry(0x403c000000000000000000000000000000000000);
    IReceivePolicyGuard internal constant GUARD = IReceivePolicyGuard(0xB10C000000000000000000000000000000000000);
    uint256 internal constant SPEND_AMOUNT = 10e6;
    address internal payer = makeAddr("refund.payer");
    CardSpender internal directProgram;
    uint64 internal senderPolicy;
    uint64 internal allTokens;

    struct Balances {
        uint256 payerShares;
        uint256 supply;
        uint256 guardShares;
        uint256 guardStable;
        uint256 destination;
        uint256 programShares;
        uint256 programStable;
        uint256 cloneShares;
        uint256 cloneStable;
    }

    function setUp() public {
        _deployTempo();
        RefundConservativeQuoteVenue quoteVenue = new RefundConservativeQuoteVenue(IERC20(address(usd)));
        ERC4626Engine quoteEngine = new ERC4626Engine(IERC4626Vault(address(quoteVenue)), address(this), "", "");
        EarnFactory earnFactory =
            new EarnFactory(address(tip20Factory), address(new EarnVault()), address(new EarnFees()));
        FeeConfig memory noFees;
        (address share, EarnVault vault,) = earnFactory.deploy(
            EarnFactory.DeployParams({
                deploymentId: bytes32("refund.receive-policy"),
                engine: address(quoteEngine),
                owner: address(this),
                controls: EarnVaultControls({
                    emergencyGuardian: address(this),
                    asyncJanitor: address(this),
                    maxManagedAssets: 0,
                    migrationMode: EngineMigrationMode.OperatorEnabled
                }),
                distributorConfig: DistributorConfig(address(0), 0),
                fees: noFees,
                transferPolicyId: 0
            })
        );
        quoteEngine.initializeEarnVault(address(vault));
        earnVault = vault;
        earnShare = ITIP20Token(share);
        _bridgeGovernorCall(abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(1), address(earnVault)));
        MockProvider directProvider = new MockProvider();
        directProvider.setToken(address(usd), true);
        directProvider.setVault(address(earnVault), true);
        directProvider.setDestination(settlement, true, false);
        directProgram = CardSpender(cardFactory.deploy(bytes32("refund.direct"), directProvider));
        _mintUsd(payer, 100e6);
        _depositEarn(payer, 100e6);
        senderPolicy = POLICIES.createPolicy(payer, ITIP403Registry.PolicyType.WHITELIST);
        allTokens = POLICIES.createPolicy(payer, ITIP403Registry.PolicyType.BLACKLIST);
        vm.prank(payer);
        POLICIES.modifyPolicyWhitelist(senderPolicy, address(earnVault), true);
    }

    function test_directBlockedRefundDefaultAuthorityRevertsAtomically() public {
        _blocked(directProgram, address(0));
    }

    function test_directBlockedRefundPayerAuthorityRevertsAtomically() public {
        _blocked(directProgram, payer);
    }

    function test_payoutBlockedRefundDefaultAuthorityRevertsAtomically() public {
        _blocked(program, address(0));
    }

    function test_payoutBlockedRefundPayerAuthorityRevertsAtomically() public {
        _blocked(program, payer);
    }

    function test_directAllowedRefundCreditsPayer() public {
        _allowRefund(directProgram);
        _successful(directProgram);
    }

    function test_payoutAllowedRefundCreditsPayer() public {
        _allowRefund(program);
        _successful(program);
    }

    function test_directNoReceivePolicyRefundCreditsPayer() public {
        _successful(directProgram);
    }

    function test_payoutNoReceivePolicyRefundCreditsPayer() public {
        _successful(program);
    }

    function _allowRefund(CardSpender selected) internal {
        vm.startPrank(payer);
        POLICIES.modifyPolicyWhitelist(senderPolicy, address(selected), true);
        POLICIES.setReceivePolicy(senderPolicy, allTokens, payer);
        vm.stopPrank();
    }

    function _blocked(CardSpender selected, address authority) internal {
        vm.prank(payer);
        POLICIES.setReceivePolicy(senderPolicy, allTokens, authority);
        CardSpend memory s = _spend(selected);
        vm.prank(payer);
        earnShare.approve(address(selected), s.maxShares);
        Balances memory before = _balances(selected);
        // Even a recoverable guard receipt is not an immediate credit to the cardholder.
        vm.prank(payer);
        vm.expectRevert(CardSpender.RefundNotCredited.selector);
        selected.spend(s);
        assertEq(abi.encode(_balances(selected)), abi.encode(before), "refund failure must roll back every balance");
        assertEq(earnShare.allowance(payer, address(selected)), s.maxShares, "payer approval must roll back");
    }

    function _successful(CardSpender selected) internal {
        CardSpend memory s = _spend(selected);
        Balances memory before = _balances(selected);
        vm.prank(payer);
        earnShare.approve(address(selected), s.maxShares);
        vm.expectEmit(true, true, true, true, address(selected));
        emit CardSpender.CardSpent(s.ref, payer, settlement, address(usd), SPEND_AMOUNT, SPEND_AMOUNT, 10e6, false);
        vm.prank(payer);
        selected.spend(s);
        assertEq(before.payerShares - earnShare.balanceOf(payer), 10e6, "refund must reach payer");
        assertEq(before.supply - earnShare.totalSupply(), 10e6, "actual burn is below quote");
        assertEq(usd.balanceOf(settlement) - before.destination, SPEND_AMOUNT);
        assertEq(earnShare.balanceOf(address(GUARD)), before.guardShares);
        assertEq(usd.balanceOf(address(GUARD)), before.guardStable);
        assertEq(earnShare.balanceOf(address(selected)), before.programShares);
        assertEq(usd.balanceOf(address(selected)), before.programStable);
        assertEq(earnShare.balanceOf(spender), before.cloneShares);
        assertEq(usd.balanceOf(spender), before.cloneStable);
    }

    function _spend(CardSpender selected) internal view returns (CardSpend memory) {
        uint256 quote = earnVault.previewWithdraw(SPEND_AMOUNT);
        assertEq(quote, 11e6);
        return CardSpend({
            program: address(selected),
            token: address(usd),
            amount: SPEND_AMOUNT,
            destination: settlement,
            vault: address(earnVault),
            fromVault: SPEND_AMOUNT,
            maxShares: quote,
            destinationHint: 0,
            ref: bytes32("refund")
        });
    }

    function _balances(CardSpender selected) internal view returns (Balances memory) {
        return Balances({
            payerShares: earnShare.balanceOf(payer),
            supply: earnShare.totalSupply(),
            guardShares: earnShare.balanceOf(address(GUARD)),
            guardStable: usd.balanceOf(address(GUARD)),
            destination: usd.balanceOf(settlement),
            programShares: earnShare.balanceOf(address(selected)),
            programStable: usd.balanceOf(address(selected)),
            cloneShares: earnShare.balanceOf(spender),
            cloneStable: usd.balanceOf(spender)
        });
    }
}
