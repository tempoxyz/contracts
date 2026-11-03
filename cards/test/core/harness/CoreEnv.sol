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

import { CardFactory } from "../../../src/core/CardFactory.sol";
import { CardSpend } from "../../../src/core/CardSpend.sol";
import { CardSpender } from "../../../src/core/CardSpender.sol";
import { ICardProvider } from "../../../src/core/interfaces/ICardProvider.sol";
import { MockPayoutProvider, MockPayoutTarget, MockProvider, MockRouter, MockRouterFactory } from "./Mocks.sol";

/// @notice The world the provider-agnostic contracts run on, with no provider: TIP-20 stablecoins (real
///         precompiles), Tempo Earn over an ERC-4626 venue, a `CardFactory`, a `CardSpender` over a mock
///         provider that pays directly or through a mock payout target, and a router its factory registered
///         that lists the program. Provider harnesses extend it and point `program` at their own.
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

    CardFactory internal factory;
    /// @dev The program the helpers use: the mock provider's here, a provider's in its harness.
    CardSpender internal program;

    MockProvider internal mock;
    MockPayoutTarget internal target;
    address internal publicWallet = makeAddr("mock.public-destination");
    address internal pooledWallet = makeAddr("mock.pooled-destination");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    MockRouterFactory internal routerFactory;
    /// @dev A router `routerFactory` deployed; `_listInRouter` adds a program to its mode.
    address internal router;

    function _deployCore() internal {
        vm.warp(1_790_000_000);
        usd = _createToken("Open USD", "OUSD");
        otherUsd = _createToken("Other USD", "XUSD");
        _deployEarn();
        routerFactory = new MockRouterFactory();
        router = address(new MockRouter());
        routerFactory.register(router, true);
        factory = new CardFactory(address(routerFactory));
        vm.label(address(routerFactory), "ZoneRouterFactory");
        vm.label(router, "ZoneRouter");
        vm.label(address(factory), "CardFactory");
    }

    /// @dev Lists `spender` in `router`'s mode, so it takes the router's `spendFrom` calls.
    function _listInRouter(address spender) internal {
        MockRouter(router).list(spender, true);
    }

    /// @dev The core world with the mock provider: public spends may pay `publicWallet` and `pooledWallet`,
    ///      private spends `pooledWallet` alone. With `payout`, the program pays through `target`.
    function _deployMockProgram(bool payout) internal {
        if (payout) {
            target = new MockPayoutTarget();
            mock = new MockPayoutProvider(address(target));
            target.setProvider(mock);
            vm.label(address(target), "MockPayoutTarget");
        } else {
            mock = new MockProvider();
        }
        mock.setToken(address(usd), true);
        mock.setVault(address(earnVault), true);
        mock.setDestination(publicWallet, true, false);
        mock.setDestination(pooledWallet, true, true);
        program = CardSpender(factory.deploy("mock", ICardProvider(address(mock))));
        _listInRouter(address(program));
        vm.label(address(mock), "MockProvider");
        vm.label(address(program), "CardSpender");
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
        EarnFactory earnFactory =
            new EarnFactory(address(tip20Factory), address(new EarnVault()), address(new EarnFees()));
        FeeConfig memory noFees;
        (address share, EarnVault vault,) = earnFactory.deploy(
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
        s.program = address(program);
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
    ///      (and the share quote), spend, clear the approvals.
    function _publicSpend(address payer, CardSpend memory s) internal {
        vm.startPrank(payer);
        usd.approve(address(program), s.amount - s.fromVault);
        if (s.fromVault != 0) earnShare.approve(address(program), s.maxShares);
        program.spend(s);
        usd.approve(address(program), 0);
        if (s.fromVault != 0) earnShare.approve(address(program), 0);
        vm.stopPrank();
    }

    /// @dev What a ZoneRouter does for a Spend op: transfer `maxInput` of `token` to the program (its
    ///      spender), call `spendFrom` and take back what the program returns.
    function _routerSpend(address token, uint256 maxInput, CardSpend memory s) internal {
        vm.prank(router);
        ITIP20Token(token).transfer(address(program), maxInput);
        vm.prank(router);
        program.spendFrom(token, maxInput, abi.encode(s));
    }

    function _depositEarn(address user, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(user);
        usd.approve(address(earnVault), assets);
        shares = earnVault.deposit(assets, user, 1);
        vm.stopPrank();
    }
}
