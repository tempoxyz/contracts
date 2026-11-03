// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20, ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20Factory } from "tempo-std/interfaces/ITIP20Factory.sol";

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

import { CardSettler } from "../../../src/core/CardSettler.sol";
import { CardSpend } from "../../../src/core/CardSpend.sol";
import { CardSpender } from "../../../src/core/CardSpender.sol";
import { ICardProgram } from "../../../src/core/interfaces/ICardProgram.sol";

/// @notice A provider-neutral `ICardProgram`: destinations, tokens and vaults set by the test, with
///         public and private destinations kept apart, and a pause.
contract MockCardProgram is ICardProgram {
    mapping(address => bool) public isAcceptedToken;
    mapping(address => bool) public isPublicDestination;
    mapping(address => bool) public isPrivateDestination;
    mapping(address => bool) public isAllowedVault;
    bool public paused;

    function setToken(address token, bool accepted) external {
        isAcceptedToken[token] = accepted;
    }

    function setDestination(address destination, bool publicSpend, bool privateSpend) external {
        isPublicDestination[destination] = publicSpend;
        isPrivateDestination[destination] = privateSpend;
    }

    function setVault(address vault, bool allowed) external {
        isAllowedVault[vault] = allowed;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function isAuthorizedDestination(address, address destination, address token, uint256, bool isPrivate)
        external
        view
        returns (bool)
    {
        if (!isAcceptedToken[token]) return false;
        return isPrivate ? isPrivateDestination[destination] : isPublicDestination[destination];
    }
}

/// @notice The world the provider-agnostic contracts run on, with no provider: TIP-20 stablecoins (real
///         precompiles), Tempo Earn over an ERC-4626 venue, and a `CardSpender` (with the `CardSettler` it
///         deploys) over a `MockCardProgram`. Provider harnesses extend it and point `spender` and `settler`
///         at their own program.
abstract contract CoreEnv is Test {
    address internal constant PATH_USD = 0x20C0000000000000000000000000000000000000;
    bytes32 internal constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    ITIP20Factory internal tip20Factory = ITIP20Factory(StdPrecompiles.TIP20_FACTORY_ADDRESS);

    ITIP20Token internal usd;
    /// @dev A stablecoin the program does not accept.
    ITIP20Token internal otherUsd;

    Simple4626Vault internal venue;
    EarnVault internal earnVault;
    ITIP20Token internal earnShare;

    /// @dev The spender and settler the helpers use: the mock program's here, a provider's in its harness.
    CardSpender internal spender;
    CardSettler internal settler;

    MockCardProgram internal mock;
    address internal publicWallet = makeAddr("mock.public-destination");
    address internal pooledWallet = makeAddr("mock.pooled-destination");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal router = makeAddr("zone-router");

    function _deployCore() internal {
        vm.warp(1_790_000_000);
        usd = _createToken("Open USD", "OUSD");
        otherUsd = _createToken("Other USD", "XUSD");
        _deployEarn();
    }

    /// @dev The core world with the mock program: public spends may pay `publicWallet` and `pooledWallet`,
    ///      private spends `pooledWallet` alone.
    function _deployMockProgram() internal {
        mock = new MockCardProgram();
        mock.setToken(address(usd), true);
        mock.setVault(address(earnVault), true);
        mock.setDestination(publicWallet, true, false);
        mock.setDestination(pooledWallet, true, true);
        spender = new CardSpender(mock);
        settler = CardSettler(spender.SETTLER());
        vm.label(address(mock), "MockCardProgram");
        vm.label(address(spender), "CardSpender");
        vm.label(address(settler), "CardSettler");
    }

    function _createToken(string memory name, string memory symbol) internal returns (ITIP20Token token) {
        token = ITIP20Token(
            tip20Factory.createToken(name, symbol, "USD", ITIP20(PATH_USD), address(this), keccak256(bytes(symbol)))
        );
        token.grantRole(ISSUER_ROLE, address(this));
        vm.label(address(token), symbol);
    }

    function _deployEarn() private {
        venue = new Simple4626Vault(address(usd), "Vault OUSD", "vOUSD", 6);
        ERC4626Engine engine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        EarnFactory factory = new EarnFactory(address(tip20Factory), address(new EarnVault()), address(new EarnFees()));
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
        // Seed and accrue so the share price is not 1:1, which catches unit mixups.
        address seeder = makeAddr("earn.seeder");
        usd.mint(seeder, 1_000_000e6);
        vm.startPrank(seeder);
        usd.approve(address(earnVault), type(uint256).max);
        earnVault.deposit(1_000_000e6, seeder, 1);
        vm.stopPrank();
        usd.mint(address(venue), usd.balanceOf(address(venue)) * 370 / 10_000);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _stableSpend(address destination, uint256 hint, uint256 amount, bytes32 ref)
        internal
        view
        returns (CardSpend memory s)
    {
        s.program = address(spender.PROGRAM());
        s.token = address(usd);
        s.amount = amount;
        s.destination = destination;
        s.destinationHint = hint;
        s.ref = ref;
    }

    function _earnSpend(address destination, uint256 hint, uint256 amount, uint256 fromVault, bytes32 ref)
        internal
        view
        returns (CardSpend memory s)
    {
        s = _stableSpend(destination, hint, amount, ref);
        s.vault = address(earnVault);
        s.fromVault = fromVault;
        s.maxShares = fromVault == 0 ? 0 : earnVault.previewWithdraw(fromVault) * 1005 / 1000;
    }

    /// @dev A public spend as the provider's access key sends it from `payer`: approve the exact amount
    ///      (and the shares), spend, clear the approvals.
    function _publicSpend(address payer, CardSpend memory s) internal {
        vm.startPrank(payer);
        usd.approve(address(spender), s.amount - s.fromVault);
        if (s.fromVault != 0) earnShare.approve(address(spender), s.maxShares);
        spender.spend(s);
        usd.approve(address(spender), 0);
        if (s.fromVault != 0) earnShare.approve(address(spender), 0);
        vm.stopPrank();
    }

    /// @dev What a ZoneRouter does for a Spend op: transfer `maxInput` of `token` to the settler, call
    ///      `settle` and take back what the settler returns.
    function _routerSettle(address token, uint256 maxInput, CardSpend memory s) internal {
        vm.prank(router);
        ITIP20Token(token).transfer(address(settler), maxInput);
        vm.prank(router);
        settler.settle(token, maxInput, abi.encode(s));
    }

    function _depositEarn(address user, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(user);
        usd.approve(address(earnVault), assets);
        shares = earnVault.deposit(assets, user, 1);
        vm.stopPrank();
    }
}
