// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardSettler } from "../../../src/core/CardSettler.sol";
import { CardSpender } from "../../../src/core/CardSpender.sol";
import { RainCardProgram } from "../../../src/providers/rain/RainCardProgram.sol";

import { IRainController, IRainFactoryAdmin, RainStack } from "../../../script/rain/RainStack.sol";
import { CoreEnv } from "../../core/harness/CoreEnv.sol";

/// @notice The core world (`CoreEnv`) with Rain as the provider: Rain's own collateral contracts from the
///         vendored sources, cardholders' and the program's collateral, and a `RainCardProgram` on the
///         provider-agnostic `CardSpender` and the `CardSettler` it deploys.
abstract contract RainEnv is CoreEnv, RainStack {
    Rain internal rain;
    uint256 internal rainAdminPk = uint256(keccak256("rain.controller-admin"));
    address internal rainAdmin = vm.addr(uint256(keccak256("rain.controller-admin")));
    address internal rainTreasury = makeAddr("rain.treasury");
    /// @dev Rain's key that can pause this program's spends.
    address internal rainPauser = makeAddr("rain.pauser");
    /// @dev The partner's account that owns the program's pooled collateral (partner-managed, private spend).
    address internal partner = makeAddr("rain.partner");
    address internal programCollateral;
    uint256 internal programCollateralIndex;

    RainCardProgram internal program;

    // Cardholders, each with their own Rain collateral contract (Rain-managed, public spend).
    address internal aliceCollateral;
    uint256 internal aliceIndex;
    address internal bobCollateral;
    uint256 internal bobIndex;

    /// @dev The index the factory's next collateral contract gets in `collateralProxies`.
    uint256 private _nextIndex;

    function _deployWorld() internal {
        _deployCore();
        rain = _deployRain(rainAdmin, rainTreasury);
        vm.label(address(rain.factory), "Rain.Factory");
        vm.label(address(rain.controller), "Rain.Controller");
        (aliceCollateral, aliceIndex) = _createCollateral("alice", alice);
        (bobCollateral, bobIndex) = _createCollateral("bob", bob);
        (programCollateral, programCollateralIndex) = _createCollateral("program", partner);
        program = _deployProgram(address(earnVault), rainPauser);
        spender = new CardSpender(program);
        settler = CardSettler(spender.SETTLER());
        vm.label(address(program), "RainCardProgram");
        vm.label(address(spender), "CardSpender");
        vm.label(address(settler), "CardSettler");
    }

    function _deployProgram(address vault, address pauser) internal returns (RainCardProgram) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usd);
        address[] memory vaults = new address[](vault == address(0) ? 0 : 1);
        if (vault != address(0)) vaults[0] = vault;
        address[] memory pooled = new address[](1);
        pooled[0] = programCollateral;
        return new RainCardProgram(address(rain.factory), tokens, vaults, pooled, pauser);
    }

    /// @dev Rain's factory owner (this contract) creates `user`'s collateral contract.
    function _createCollateral(string memory name, address user) internal returns (address collateral, uint256 n) {
        n = _nextIndex++;
        collateral = rain.factory.createCollateralContract(name, user);
        vm.label(collateral, string.concat("Rain.Collateral.", name));
    }

    // ------------------------------------------------------------------
    // Rain's own settlement: EIP-712 signatures from Rain's controller admin
    // ------------------------------------------------------------------

    function _rainDomain(bytes32 salt) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                rain.controller.EIP712_DOMAIN_TYPE_HASH(),
                keccak256("Rain Collateral"),
                keccak256("1"),
                block.chainid,
                address(rain.controller),
                salt
            )
        );
    }

    function _signPay(
        address caller,
        address collateral,
        address asset,
        uint256 amount,
        uint256 expiresAt,
        bytes32 salt
    ) internal view returns (bytes memory) {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    rain.controller.PAY_TYPE_HASH(),
                    caller,
                    collateral,
                    keccak256(abi.encodePacked(assets)),
                    keccak256(abi.encodePacked(amounts))
                ),
                abi.encode(rain.controller.nonce(collateral), expiresAt)
            )
        );
        return _sign(salt, structHash);
    }

    function _signWithdraw(
        address caller,
        address collateral,
        address asset,
        uint256 amount,
        address recipient,
        uint256 expiresAt,
        bytes32 salt
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(rain.controller.WITHDRAW_TYPE_HASH(), caller, collateral, asset, amount),
                abi.encode(recipient, rain.controller.nonce(collateral), expiresAt)
            )
        );
        return _sign(salt, structHash);
    }

    function _sign(bytes32 salt, bytes32 structHash) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(rainAdminPk, keccak256(abi.encodePacked("\x19\x01", _rainDomain(salt), structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _one(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }
}
