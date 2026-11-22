// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20, ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

import {
    IReservationCore,
    RESERVATION_CORE_ADDRESS
} from "../../../../src/interfaces/spend/programs/IReservationCore.sol";
import { MockReservationCore } from "../harness/MockReservationCore.sol";

/// @notice The reservation core model etched at its precompile address over real TIP-20 tokens, with helpers that
///         credit accounts. Credits never move funds onward.
abstract contract ModelEnv is Test {
    address internal constant PATH_USD = 0x20C0000000000000000000000000000000000000;
    MockReservationCore internal core = MockReservationCore(RESERVATION_CORE_ADDRESS);
    ITIP403Registry internal registry = StdPrecompiles.TIP403_REGISTRY;

    function _deployModel() internal {
        vm.etch(RESERVATION_CORE_ADDRESS, address(new MockReservationCore()).code);
        vm.allowCheatcodes(RESERVATION_CORE_ADDRESS);
        vm.label(RESERVATION_CORE_ADDRESS, "ReservationCore");
    }

    function _token(string memory symbol) internal returns (ITIP20Token token) {
        token = ITIP20Token(
            StdPrecompiles.TIP20_FACTORY
                .createToken(symbol, symbol, "USD", ITIP20(PATH_USD), address(this), keccak256(bytes(symbol)))
        );
        token.grantRole(token.ISSUER_ROLE(), address(this));
        token.grantRole(token.PAUSE_ROLE(), address(this));
        token.grantRole(token.UNPAUSE_ROLE(), address(this));
        vm.label(address(token), symbol);
    }

    function _mint(ITIP20Token token, address to, uint256 amount) internal {
        token.mint(to, amount);
    }

    function _send(ITIP20Token token, address from, address to, uint256 amount) internal {
        vm.prank(from);
        token.transfer(to, amount);
    }

    /// @dev Gives `token` a blacklist policy this contract administers and returns its id.
    function _blacklistPolicy(ITIP20Token token) internal returns (uint64 policy) {
        policy = registry.createPolicy(address(this), ITIP403Registry.PolicyType.BLACKLIST);
        token.changeTransferPolicyId(policy);
    }

    function _request(address token, bytes32 id, uint128 amount, address payee, uint64 ttl)
        internal
        view
        returns (IReservationCore.HoldRequest memory)
    {
        return IReservationCore.HoldRequest({
            token: token, id: id, amount: amount, payee: payee, expiresAt: uint64(vm.getBlockTimestamp()) + ttl
        });
    }

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
    }
}
