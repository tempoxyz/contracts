// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";

import { CardAuth } from "../../src/programs/CardAuth.sol";

/// @notice Keeps CardAuth's deployed code inside the size the program works to, well under EIP-170, so later changes
///         have room, and every other program contract under EIP-170.
contract ContractSizesTest is Test {
    uint256 internal constant CARD_AUTH_BUDGET = 12_288;
    uint256 internal constant EIP170_LIMIT = 24_576;

    function test_cardAuth_runtimeWithinBudget() public {
        CardAuth cards = new CardAuth(address(1), address(2), address(3));
        assertLe(address(cards).code.length, CARD_AUTH_BUDGET, "CardAuth runtime code is over its size budget");
        assertLe(cards.ADMIN().code.length, EIP170_LIMIT, "CardAuthAdmin is over EIP-170");
    }

    function test_programContracts_runtimeWithinEip170() public view {
        string[17] memory names = [
            "AccountKeys",
            "AccountLifecycle",
            "CardAuthAdmin",
            "CardLegs",
            "CardLimits",
            "CardRegistry",
            "CashSource",
            "Conversion",
            "CoverageRegistry",
            "CreditSource",
            "IdentityRules",
            "IssuerDesk",
            "IssuerTreasury",
            "MerchantReserves",
            "ProgramVenue",
            "ReceiveSweep",
            "Rewards"
        ];
        for (uint256 i; i < names.length; ++i) {
            string memory id = string.concat(names[i], ".sol:", names[i]);
            assertLe(vm.getDeployedCode(id).length, EIP170_LIMIT, id);
        }
        assertLe(vm.getDeployedCode("SavingsSource.sol:SavingsSource").length, EIP170_LIMIT, "SavingsSource");
    }
}
