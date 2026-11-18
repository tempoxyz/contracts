// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { ModelEnv } from "./differential/ModelEnv.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

contract ReservationCoreModelTest is ModelEnv {
    function test_smoke() public {
        _deployModel();
        ITIP20Token usd = _token("A");
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _mint(usd, alice, 1000);
        vm.prank(alice);
        core.hold(_request(address(usd), "h", 400, bob, 100, false));
        assertEq(usd.balanceOf(alice), 600);
        assertEq(core.reserved(alice, address(usd)), 400);
        assertEq(usd.balanceOf(address(core)), 400);
        vm.prank(alice);
        core.capture(alice, alice, "h", 300, true);
        assertEq(usd.balanceOf(alice), 700);
        assertEq(usd.balanceOf(bob), 300);
        assertEq(core.getHold(alice, alice, "h").token, address(0));
        assertEq(usd.totalSupply(), 1000);
        _send(usd, alice, bob, 700);
        assertEq(usd.balanceOf(bob), 1000);
    }
}
