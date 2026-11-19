// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";

import { CardAuth } from "../../src/programs/CardAuth.sol";
import { CardAuthAdmin } from "../../src/programs/CardAuthAdmin.sol";

/// @notice Keeps CardAuth's deployed code inside the size the program works to, well under EIP-170, so later changes
///         have room, and every other program contract under EIP-170. Also checks no program contract creates another:
///         Zones refuse CREATE and CREATE2 from contracts.
contract ContractSizesTest is Test {
    uint256 internal constant CARD_AUTH_BUDGET = 12_288;
    uint256 internal constant EIP170_LIMIT = 24_576;
    /// @dev The compiler's CBOR metadata: a map of an ipfs hash and the compiler version, then its length.
    bytes8 internal constant METADATA_HEAD = hex"a264697066735822";
    uint256 internal constant METADATA_LENGTH = 52;

    function test_cardAuth_runtimeWithinBudget() public {
        CardAuthAdmin admin = new CardAuthAdmin();
        CardAuth cards = new CardAuth(address(1), address(2), address(3), address(admin));
        assertLe(address(cards).code.length, CARD_AUTH_BUDGET, "CardAuth runtime code is over its size budget");
        assertLe(cards.ADMIN().code.length, EIP170_LIMIT, "CardAuthAdmin is over EIP-170");
    }

    function test_programContracts_runtimeWithinEip170() public view {
        string[18] memory names = _names();
        for (uint256 i; i < names.length; ++i) {
            string memory id = string.concat(names[i], ".sol:", names[i]);
            assertLe(vm.getDeployedCode(id).length, EIP170_LIMIT, id);
        }
    }

    /// @dev Scans each program contract's runtime code and constructor code for CREATE and CREATE2.
    function test_programContracts_neverCreate() public view {
        string[18] memory names = _names();
        for (uint256 i; i < names.length; ++i) {
            string memory id = string.concat(names[i], ".sol:", names[i]);
            bytes memory runtime = vm.getDeployedCode(id);
            assertFalse(_creates(runtime, _end(runtime)), string.concat(id, " runtime creates contracts"));
            bytes memory creation = vm.getCode(id);
            assertFalse(
                _creates(creation, _start(creation, runtime)), string.concat(id, " constructor creates contracts")
            );
        }
    }

    /// @dev The scan finds the CREATE a contract does in a function and the one it does in its constructor.
    function test_creationScan_findsCreate() public view {
        bytes memory runtime = type(CreatesInFunction).runtimeCode;
        assertTrue(_creates(runtime, _end(runtime)));
        bytes memory creation = type(CreatesInConstructor).creationCode;
        assertTrue(_creates(creation, _start(creation, type(CreatesInConstructor).runtimeCode)));
    }

    function _names() private pure returns (string[18] memory) {
        return [
            "AccountKeys",
            "AccountLifecycle",
            "CardAuth",
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
    }

    /// @dev Whether the instructions in `code` before `end` include CREATE (0xf0) or CREATE2 (0xf5), skipping push data
    ///      and the CBOR metadata of code a constructor embeds as data (such as the admin code CardAuth checks).
    function _creates(bytes memory code, uint256 end) private pure returns (bool) {
        for (uint256 i; i < end; ++i) {
            if (_metadataAt(code, i)) {
                i += METADATA_LENGTH + 1;
                continue;
            }
            uint8 op = uint8(code[i]);
            if (op == 0xf0 || op == 0xf5) return true;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        return false;
    }

    /// @dev Whether a CBOR metadata map (`{ipfs, solar}`) followed by its two-byte length starts at `i`.
    function _metadataAt(bytes memory code, uint256 i) private pure returns (bool) {
        if (i + METADATA_LENGTH + 2 > code.length) return false;
        bytes8 head;
        assembly ("memory-safe") {
            head := mload(add(add(code, 32), i))
        }
        uint256 length = uint256(uint8(code[i + METADATA_LENGTH])) << 8 | uint8(code[i + METADATA_LENGTH + 1]);
        return head == METADATA_HEAD && length == METADATA_LENGTH;
    }

    /// @dev Where runtime code ends before its CBOR metadata, whose length its last two bytes give.
    function _end(bytes memory code) private pure returns (uint256) {
        uint256 n = code.length;
        uint256 meta = uint256(uint8(code[n - 2])) << 8 | uint8(code[n - 1]);
        return meta + 2 <= n ? n - meta - 2 : n;
    }

    /// @dev Where the runtime code starts inside `creation`, so the constructor code is everything before it.
    function _start(bytes memory creation, bytes memory runtime) private pure returns (uint256) {
        bytes32 head;
        assembly ("memory-safe") {
            head := mload(add(runtime, 32))
        }
        for (uint256 i; i + 32 <= creation.length; ++i) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(creation, 32), i))
            }
            if (word == head) return i;
        }
        revert("runtime code not found in creation code");
    }
}

contract Created { }

contract CreatesInFunction {
    function make() external returns (address) {
        return address(new Created());
    }
}

contract CreatesInConstructor {
    address public made;

    constructor() {
        made = address(new Created());
    }
}
