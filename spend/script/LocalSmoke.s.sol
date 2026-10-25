// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Script, console } from "forge-std/Script.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20, ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20Factory } from "tempo-std/interfaces/ITIP20Factory.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ISpenderHandler, SpenderStatus } from "bridge-spender/src/ISpenderHandler.sol";
import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import { SpenderErc20 } from "bridge-spender/src/spenders/SpenderErc20.sol";

import { EarnFactory } from "tempo-earn/core/EarnFactory.sol";
import { EarnFees } from "tempo-earn/core/EarnFees.sol";
import { EarnVault } from "tempo-earn/core/EarnVault.sol";
import { Simple4626Vault } from "tempo-earn/demo/Simple4626Vault.sol";
import { ERC4626Engine, IERC4626Vault } from "tempo-earn/engines/ERC4626Engine.sol";
import { FeeConfig } from "tempo-earn/interfaces/core/EarnFeeTypes.sol";
import {
    DistributorConfig,
    EarnVaultControls,
    EngineMigrationMode
} from "tempo-earn/interfaces/core/EarnVaultTypes.sol";

import { Spend, SpenderTempoSpend } from "../src/SpenderTempoSpend.sol";
import { IBridgeSpenderClone } from "../src/interfaces/IBridgeSpenderFactory.sol";

/// @notice Deploys the stack to a real Tempo node and broadcasts public card pulls end to end.
/// @dev script/smoke.sh runs it against a dev node and checks the resulting balances with cast,
///      since forge evaluates a script's own reads in its simulation, not on the node. "TS" is
///      registered gated with the program allowlisted, as Bridge's deployment does it.
///
///      forge script script/LocalSmoke.s.sol --rpc-url http://127.0.0.1:18545 --broadcast --slow
contract LocalSmoke is Script {
    string internal constant MNEMONIC =
        "test test test test test test test test test test test junk";
    address internal constant PATH_USD = 0x20C0000000000000000000000000000000000000;
    bytes32 internal constant SPENDER_ID = keccak256("smoke.card-program");

    uint256 internal deployerPk;
    uint256 internal debitorPk;
    uint256 internal alicePk;
    address internal deployer;
    address internal debitor;
    address internal alice;
    address internal settlement;

    ITIP20Token internal usd;
    EarnVault internal earnVault;
    ITIP20Token internal earnShare;
    SpenderFactory internal factory;
    address internal clone;

    function run() external {
        deployerPk = vm.deriveKey(MNEMONIC, 0);
        debitorPk = vm.deriveKey(MNEMONIC, 1);
        alicePk = vm.deriveKey(MNEMONIC, 2);
        deployer = vm.addr(deployerPk);
        debitor = vm.addr(debitorPk);
        alice = vm.addr(alicePk);
        settlement = vm.addr(vm.deriveKey(MNEMONIC, 4));

        _deploy();
        _bridgeErc20Pull();
        _tempoSpendFromEarn();
        _tempoSplitSpend();
        _writeAddresses();
    }

    function _deploy() internal {
        vm.startBroadcast(deployerPk);
        usd = ITIP20Token(
            ITIP20Factory(StdPrecompiles.TIP20_FACTORY_ADDRESS)
                .createToken(
                    "Smoke USD",
                    "sUSD",
                    "USD",
                    ITIP20(PATH_USD),
                    deployer,
                    keccak256(abi.encode(block.timestamp))
                )
        );
        usd.grantRole(keccak256("ISSUER_ROLE"), deployer);
        usd.mint(alice, 1000e6);
        usd.mint(deployer, 1000e6);

        Simple4626Vault venue = new Simple4626Vault(address(usd), "Smoke Venue", "sVEN", 6);
        ERC4626Engine engine = new ERC4626Engine(IERC4626Vault(address(venue)), deployer, "", "");
        EarnFactory earnFactory = new EarnFactory(
            StdPrecompiles.TIP20_FACTORY_ADDRESS, address(new EarnVault()), address(new EarnFees())
        );
        FeeConfig memory noFees;
        (address share, EarnVault vault,) = earnFactory.deploy(
            EarnFactory.DeployParams({
                deploymentId: keccak256(abi.encode("smoke", block.timestamp)),
                engine: address(engine),
                owner: deployer,
                controls: EarnVaultControls(
                    deployer, deployer, 0, EngineMigrationMode.OperatorEnabled
                ),
                distributorConfig: DistributorConfig(address(0), 0),
                fees: noFees,
                transferPolicyId: 0
            })
        );
        engine.initializeEarnVault(address(vault));
        earnVault = vault;
        earnShare = ITIP20Token(share);
        usd.approve(address(earnVault), 1000e6);
        earnVault.deposit(1000e6, deployer, 1);

        factory = SpenderFactory(
            address(
                new ERC1967Proxy(
                    address(new SpenderFactory()),
                    abi.encodeCall(SpenderFactory.initialize, (deployer, deployer, deployer))
                )
            )
        );
        IFactory f = IFactory(address(factory));
        _register("EA", ISpenderHandler(address(new SpenderErc20(f))), SpenderStatus.Enabled);
        _register("TS", ISpenderHandler(address(new SpenderTempoSpend(f))), SpenderStatus.Gated);
        factory.grantRole(factory.MANAGER_ROLE(), deployer);
        factory.grantRole(factory.DEBITOR_ROLE(), debitor);
        address[] memory destinations = new address[](1);
        destinations[0] = settlement;
        clone = factory.createSpender(SPENDER_ID, destinations);
        factory.updateSpenderHandlerAllowlist("TS", SPENDER_ID, true);
        factory.governorCall(
            SPENDER_ID, abi.encodePacked(bytes2("TS"), bytes2("UV"), uint8(1), address(earnVault))
        );
        vm.stopBroadcast();
        console.log("deployed factory", address(factory), "clone", clone);
    }

    /// @dev Read by script/smoke.sh for the access-key steps it runs with cast.
    function _writeAddresses() internal {
        string memory key = "smoke";
        vm.serializeAddress(key, "usd", address(usd));
        vm.serializeAddress(key, "clone", clone);
        vm.serializeAddress(key, "settlement", settlement);
        vm.serializeAddress(key, "earnVault", address(earnVault));
        vm.serializeAddress(key, "earnShare", address(earnShare));
        string memory json = vm.serializeAddress(key, "factory", address(factory));
        vm.createDir("reports", true);
        vm.writeJson(json, "reports/smoke.json");
    }

    function _register(bytes2 prefix, ISpenderHandler handler, SpenderStatus status) internal {
        factory.setSpenderHandler(prefix, handler);
        factory.updateSpenderHandlerStatus(prefix, status);
    }

    /// Bridge today: a standing allowance and an EA pull.
    function _bridgeErc20Pull() internal {
        vm.broadcast(alicePk);
        usd.approve(clone, 100e6);
        vm.broadcast(debitorPk);
        factory.transferToDestination(
            SPENDER_ID,
            settlement,
            abi.encodePacked(bytes2("EA"), alice, address(usd), uint256(10e6))
        );
    }

    /// TS handler: the cardholder's account spends from Earn shares with a share cap.
    function _tempoSpendFromEarn() internal {
        vm.startBroadcast(alicePk);
        usd.approve(address(earnVault), 200e6);
        earnVault.deposit(200e6, alice, 1);
        vm.stopBroadcast();
        uint256 cap = earnVault.previewWithdraw(25e6) * 1005 / 1000 + 1;
        _spendAsAlice(_spend(25e6, 25e6, cap, keccak256("smoke.auth.1")), 0, cap);
    }

    /// TS handler: one spend from stablecoin and Earn.
    function _tempoSplitSpend() internal {
        uint256 cap = earnVault.previewWithdraw(15e6) * 2;
        _spendAsAlice(_spend(20e6, 15e6, cap, keccak256("smoke.auth.2")), 5e6, cap);
    }

    function _spend(uint256 amount, uint256 fromVault, uint256 maxShares, bytes32 ref)
        internal
        view
        returns (Spend memory)
    {
        return Spend({
            spenderId: SPENDER_ID,
            token: address(usd),
            amount: amount,
            destination: settlement,
            vault: address(earnVault),
            fromVault: fromVault,
            maxShares: maxShares,
            ref: ref
        });
    }

    /// @dev Approve exactly, spend, clear the approvals: what Bridge's access key signs.
    function _spendAsAlice(Spend memory s, uint256 stableApproval, uint256 shareApproval) internal {
        vm.startBroadcast(alicePk);
        if (stableApproval != 0) usd.approve(clone, stableApproval);
        earnShare.approve(clone, shareApproval);
        IBridgeSpenderClone(clone)
            .publicCall(abi.encodePacked(bytes2("TS"), bytes2("PS"), abi.encode(s)));
        if (stableApproval != 0) usd.approve(clone, 0);
        earnShare.approve(clone, 0);
        vm.stopBroadcast();
    }
}
