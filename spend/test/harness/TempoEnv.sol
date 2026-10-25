// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20, ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20Factory } from "tempo-std/interfaces/ITIP20Factory.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SpenderErc4626 } from "bridge-spender/pending/spenders/SpenderErc4626.sol";
import { ISpenderHandler, SpenderStatus } from "bridge-spender/src/ISpenderHandler.sol";
import { SpenderFactory } from "bridge-spender/src/SpenderFactory.sol";
import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import { SpenderErc20 } from "bridge-spender/src/spenders/SpenderErc20.sol";
import { SpenderPermit2 } from "bridge-spender/src/spenders/SpenderPermit2.sol";
import { SpenderTEWF } from "bridge-spender/src/spenders/SpenderTempoEarnWithFallback.sol";

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

import { Spend, SpenderTempoSpend } from "../../src/SpenderTempoSpend.sol";
import { IBridgeSpenderClone } from "../../src/interfaces/IBridgeSpenderFactory.sol";

/// @notice Deploys the on-chain world a Tempo card program runs on: TIP-20 stablecoins (real
///         precompiles), a Tempo Earn stack over an ERC-4626 venue, and Bridge's SpenderFactory with
///         every handler registered against one card program.
abstract contract TempoEnv is Test {
    address internal constant PATH_USD = 0x20C0000000000000000000000000000000000000;
    bytes32 internal constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    bytes2 internal constant PREFIX_ERC20 = "EA";
    bytes2 internal constant PREFIX_PERMIT2 = "P2";
    bytes2 internal constant PREFIX_TEWF = "TF";
    bytes2 internal constant PREFIX_ERC4626 = "EV";
    bytes2 internal constant PREFIX_TEMPO_SPEND = "TS";

    bytes32 internal constant SPENDER_ID = keccak256("bridge.card-program.tempo");

    ITIP20Factory internal tip20Factory = ITIP20Factory(StdPrecompiles.TIP20_FACTORY_ADDRESS);

    /// @dev The card token and the Earn vault's asset: an OUSD-like TIP-20 quoted in pathUSD.
    ITIP20Token internal usd;

    // Tempo Earn: EarnVault over an ERC-4626 venue, issuing a native TIP-20 EarnShare.
    Simple4626Vault internal venue;
    ERC4626Engine internal engine;
    EarnVault internal earnVault;
    ITIP20Token internal earnShare;

    /// @dev Uniswap Permit2, deployed from `test/harness/fixtures/Permit2.json`.
    address internal permit2;

    // Bridge card program.
    SpenderFactory internal bridgeFactory;
    address internal spender; // the program's spender clone
    address internal bridgeAdmin = makeAddr("bridge.admin");
    address internal bridgeGovernor = makeAddr("bridge.governor");
    address internal bridgeManager = makeAddr("bridge.manager");
    address internal bridgePauser = makeAddr("bridge.pauser");
    uint256 internal bridgeDebitorPk = uint256(keccak256("bridge.debitor"));
    address internal bridgeDebitor = vm.addr(uint256(keccak256("bridge.debitor")));
    /// @dev Stripe settlement wallet: the only destination pulls may land in.
    address internal settlement = makeAddr("bridge.settlement");
    /// @dev Bridge program liquidity used to return excess holds, refunds and dispute credits.
    address internal programWallet = makeAddr("bridge.program-wallet");
    /// @dev Platform reserve that covers settlement when a pull fails after approval.
    address internal reserveWallet = makeAddr("bridge.reserve");

    function _deployTempo() internal {
        vm.warp(1_790_000_000);
        _deployStablecoin();
        _deployEarn();
        _deployBridge();
        _mintUsd(programWallet, 1_000_000e6);
        _mintUsd(reserveWallet, 1_000_000e6);
    }

    function _deployStablecoin() private {
        usd = _createToken("Open USD", "OUSD");
    }

    function _createToken(string memory name, string memory symbol)
        internal
        returns (ITIP20Token token)
    {
        token = ITIP20Token(
            tip20Factory.createToken(
                name, symbol, "USD", ITIP20(PATH_USD), address(this), keccak256(bytes(symbol))
            )
        );
        token.grantRole(ISSUER_ROLE, address(this));
        vm.label(address(token), symbol);
    }

    function _deployEarn() private {
        venue = new Simple4626Vault(address(usd), "Sentora OUSD", "sOUSD", 6);
        engine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        EarnFactory factory = new EarnFactory(
            address(tip20Factory), address(new EarnVault()), address(new EarnFees())
        );
        FeeConfig memory noFees;
        (address share, EarnVault vault,) = factory.deploy(
            EarnFactory.DeployParams({
                deploymentId: bytes32("tempo-earn.ousd"),
                engine: address(engine),
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
        engine.initializeEarnVault(address(vault));
        earnVault = vault;
        earnShare = ITIP20Token(share);
        vm.label(address(earnVault), "EarnVault");
        vm.label(share, "EarnShare");
        vm.label(address(venue), "Venue");

        // Seed so the share price is not 1:1, which catches unit mixups between assets and shares.
        address seeder = makeAddr("earn.seeder");
        usd.mint(seeder, 1_000_000e6);
        vm.startPrank(seeder);
        usd.approve(address(earnVault), type(uint256).max);
        earnVault.deposit(1_000_000e6, seeder, 1);
        vm.stopPrank();
        _accrueYield(370); // 3.7%
    }

    function _deployBridge() private {
        SpenderFactory impl = new SpenderFactory();
        bridgeFactory = SpenderFactory(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        SpenderFactory.initialize, (bridgeAdmin, bridgeGovernor, bridgePauser)
                    )
                )
            )
        );
        vm.label(address(bridgeFactory), "Bridge.SpenderFactory");

        IFactory f = IFactory(address(bridgeFactory));
        _registerHandler(PREFIX_ERC20, ISpenderHandler(address(new SpenderErc20(f))));
        permit2 = _deployPermit2();
        _registerHandler(PREFIX_PERMIT2, ISpenderHandler(address(new SpenderPermit2(f, permit2))));
        _registerHandler(PREFIX_TEWF, ISpenderHandler(address(new SpenderTEWF(f))));
        _registerHandler(PREFIX_ERC4626, ISpenderHandler(address(new SpenderErc4626(f))));
        _registerHandler(PREFIX_TEMPO_SPEND, ISpenderHandler(address(new SpenderTempoSpend(f))));

        bytes32 managerRole = bridgeFactory.MANAGER_ROLE();
        bytes32 debitorRole = bridgeFactory.DEBITOR_ROLE();
        vm.prank(bridgeGovernor);
        bridgeFactory.grantRole(managerRole, bridgeManager);
        vm.prank(bridgeManager);
        bridgeFactory.grantRole(debitorRole, bridgeDebitor);

        // The program wallet is a destination so it can pay private refunds.
        address[] memory destinations = new address[](2);
        destinations[0] = settlement;
        destinations[1] = programWallet;
        vm.prank(bridgeManager);
        spender = bridgeFactory.createSpender(SPENDER_ID, destinations);
        vm.label(spender, "Bridge.SpenderClone");

        // Both vault-aware handlers keep their own allowlist in the clone's storage.
        _bridgeManagerCall(
            abi.encodePacked(PREFIX_TEWF, bytes2("UV"), uint8(1), address(earnVault))
        );
        _bridgeGovernorCall(
            abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("UV"), uint8(1), address(earnVault))
        );
    }

    /// @dev Permit2 pins solc 0.8.17, so its creation code is built once with its own toolchain and
    ///      committed as a fixture (provenance in the file).
    function _deployPermit2() private returns (address deployed) {
        bytes memory code =
            vm.parseJsonBytes(vm.readFile("test/harness/fixtures/Permit2.json"), ".creationCode");
        assembly {
            deployed := create(0, add(code, 0x20), mload(code))
        }
        require(deployed != address(0), "Permit2 deploy");
        vm.label(deployed, "Permit2");
    }

    function _registerHandler(bytes2 prefix, ISpenderHandler handler) private {
        vm.prank(bridgeAdmin);
        bridgeFactory.setSpenderHandler(prefix, handler);
        vm.prank(bridgeGovernor);
        bridgeFactory.updateSpenderHandlerStatus(prefix, SpenderStatus.Enabled);
    }

    function _bridgeManagerCall(bytes memory data) internal {
        vm.prank(bridgeManager);
        bridgeFactory.managerCall(SPENDER_ID, data);
    }

    function _bridgeGovernorCall(bytes memory data) internal {
        vm.prank(bridgeGovernor);
        bridgeFactory.governorCall(SPENDER_ID, data);
    }

    // ------------------------------------------------------------------
    // "TS" handler through the program's clone
    // ------------------------------------------------------------------

    /// @dev A pending `vm.prank` applies to this call.
    function _cloneCall(bytes memory data) internal {
        (bool ok, bytes memory err) =
            spender.call(abi.encodeCall(IBridgeSpenderClone.publicCall, (data)));
        if (!ok) {
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }
    }

    function _cloneGet(bytes memory data) internal returns (bytes memory) {
        return IBridgeSpenderClone(spender).publicGetCall(data);
    }

    function _psCall(Spend memory spend) internal pure returns (bytes memory) {
        return abi.encodePacked(PREFIX_TEMPO_SPEND, bytes2("PS"), abi.encode(spend));
    }

    // ------------------------------------------------------------------
    // World helpers
    // ------------------------------------------------------------------

    function _mintUsd(address to, uint256 amount) internal {
        usd.mint(to, amount);
    }

    /// @notice Deposits `assets` of the user's stablecoin into Tempo Earn.
    function _depositEarn(address user, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(user);
        usd.approve(address(earnVault), assets);
        shares = earnVault.deposit(assets, user, 1);
        vm.stopPrank();
    }

    /// @notice Grows the Earn share price by `bps` by donating yield to the venue.
    function _accrueYield(uint256 bps) internal {
        uint256 venueAssets = usd.balanceOf(address(venue));
        usd.mint(address(venue), venueAssets * bps / 10_000);
    }

    /// @notice Value in stablecoin units of `shares` EarnShare at the current price.
    function _shareValue(uint256 shares) internal view returns (uint256) {
        return shares == 0 ? 0 : earnVault.previewRedeem(shares);
    }
}
