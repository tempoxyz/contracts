// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { AuthEnv } from "./harness/AuthEnv.sol";

contract AuthSmokeTest is AuthEnv {
    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
    }

    function test_smoke() public {
        usd.mint(alice, 1000e6);
        _authorize("p1", 100e6);
        assertEq(_hold(alice, "p1", CASH_LEG).held, 100e6);
        _capture("p1", 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
        _assertSourcesEmpty();
        _assertCoreBalanced();
    }
}
