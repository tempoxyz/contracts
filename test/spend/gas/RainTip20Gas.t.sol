// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardSpend } from "../../../src/spend/CardSpend.sol";
import { RainEnv } from "../rain/harness/RainEnv.sol";

/// @notice Steady-state Rain card spends (the program pays Rain collateral directly) on real TIP-20: a
///         repeat spend after the first created the destination's slots, measured with `gasleft` like
///         `RouterTip20Gas`. The program holds a one-unit seed of each token, as the deployment runbook leaves it.
contract RainTip20GasTest is RainEnv {
    uint256 internal constant AMOUNT = 40e6;

    function setUp() public {
        _deployWorld();
        usd.mint(address(earnVault), 1);
        usd.mint(earnVault.engine(), 1);
        usd.mint(address(program), 1);
        usd.mint(alice, 1_000_000e6);
        usd.mint(router, 1_000_000e6);
        _depositEarn(alice, 500_000e6);
        _depositEarn(router, 500_000e6);
        vm.prank(alice);
        earnShare.transfer(address(program), 1);
        program.warmVault(address(earnVault));
        program.warmRouter(router);
        vm.startPrank(alice);
        usd.approve(address(program), type(uint256).max);
        earnShare.approve(address(program), type(uint256).max);
        vm.stopPrank();
    }

    function _public(CardSpend memory s) internal returns (uint256 used) {
        uint256 before = gasleft();
        vm.prank(alice);
        program.spend(s);
        used = before - gasleft();
    }

    function _private(address token, uint256 maxInput, CardSpend memory s) internal returns (uint256 used) {
        bytes memory data = abi.encode(s);
        uint256 before = gasleft();
        vm.prank(router);
        _transfer(token, maxInput);
        vm.prank(router);
        program.spendFrom(token, maxInput, data);
        used = before - gasleft();
    }

    function _transfer(address token, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", address(program), amount));
        require(ok);
    }

    function test_gasRainPublicStableSpend() public {
        _public(_stableSpend(aliceCollateral, aliceIndex, AMOUNT, "s.1"));
        uint256 used = _public(_stableSpend(aliceCollateral, aliceIndex, AMOUNT, "s.2"));
        vm.snapshotValue("rain-tip20", "public.stable.repeat", used);
    }

    function test_gasRainPublicEarnSpend() public {
        _public(_earnSpend(aliceCollateral, aliceIndex, AMOUNT, AMOUNT, "e.1"));
        uint256 used = _public(_earnSpend(aliceCollateral, aliceIndex, AMOUNT, AMOUNT, "e.2"));
        vm.snapshotValue("rain-tip20", "public.earn.repeat", used);
    }

    function test_gasRainPrivateStableSpend() public {
        _private(address(usd), AMOUNT, _stableSpend(programCollateral, programCollateralIndex, AMOUNT, "p.1"));
        uint256 used =
            _private(address(usd), AMOUNT, _stableSpend(programCollateral, programCollateralIndex, AMOUNT, "p.2"));
        vm.snapshotValue("rain-tip20", "private.stable.repeat", used);
    }

    function test_gasRainPrivateEarnSpend() public {
        CardSpend memory s = _earnSpend(programCollateral, programCollateralIndex, AMOUNT, AMOUNT, "pe.1");
        _private(address(earnShare), s.maxShares, s);
        s = _earnSpend(programCollateral, programCollateralIndex, AMOUNT, AMOUNT, "pe.2");
        uint256 used = _private(address(earnShare), s.maxShares, s);
        vm.snapshotValue("rain-tip20", "private.earn.repeat", used);
    }
}
