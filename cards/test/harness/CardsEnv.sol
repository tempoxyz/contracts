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

import { CardSettler } from "../../src/CardSettler.sol";
import { CardSpend } from "../../src/CardSpend.sol";
import { CardSpender } from "../../src/CardSpender.sol";
import { ICardProgram } from "../../src/interfaces/ICardProgram.sol";
import { RainCardProgram } from "../../src/providers/rain/RainCardProgram.sol";

import { IRainController, IRainFactoryAdmin, RainStack } from "../../script/RainStack.sol";

/// @notice The world a Tempo card program runs on: TIP-20 stablecoins (real precompiles), Tempo Earn over
///         an ERC-4626 venue, Rain's own collateral contracts from the vendored sources, and a Rain card
///         program on the provider-agnostic `CardSpender` and `CardSettler`.
abstract contract CardsEnv is Test, RainStack {
    address internal constant PATH_USD = 0x20C0000000000000000000000000000000000000;
    bytes32 internal constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    ITIP20Factory internal tip20Factory = ITIP20Factory(StdPrecompiles.TIP20_FACTORY_ADDRESS);

    ITIP20Token internal usd;
    /// @dev A stablecoin the program does not accept.
    ITIP20Token internal otherUsd;

    Simple4626Vault internal venue;
    EarnVault internal earnVault;
    ITIP20Token internal earnShare;

    // Rain.
    Rain internal rain;
    uint256 internal rainAdminPk = uint256(keccak256("rain.controller-admin"));
    address internal rainAdmin = vm.addr(uint256(keccak256("rain.controller-admin")));
    address internal rainTreasury = makeAddr("rain.treasury");
    /// @dev The partner's account that owns the program's pooled collateral (partner-managed, private spend).
    address internal partner = makeAddr("rain.partner");
    address internal programCollateral;
    uint256 internal programCollateralNonce;

    // The card program on the provider-agnostic contracts.
    RainCardProgram internal program;
    CardSpender internal spender;
    CardSettler internal settler;

    // Cardholders, each with their own Rain collateral contract (Rain-managed, public spend).
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal aliceCollateral;
    uint256 internal aliceNonce;
    address internal bobCollateral;
    uint256 internal bobNonce;

    /// @dev The factory's next CREATE nonce. The beacon took nonce 1 in `initialize`.
    uint256 private _factoryNonce = 2;

    function _deployWorld() internal {
        vm.warp(1_790_000_000);
        usd = _createToken("Open USD", "OUSD");
        otherUsd = _createToken("Other USD", "XUSD");
        _deployEarn();
        rain = _deployRain(rainAdmin, rainTreasury);
        vm.label(address(rain.factory), "Rain.Factory");
        vm.label(address(rain.controller), "Rain.Controller");
        (aliceCollateral, aliceNonce) = _createCollateral("alice", alice);
        (bobCollateral, bobNonce) = _createCollateral("bob", bob);
        (programCollateral, programCollateralNonce) = _createCollateral("program", partner);
        program = _deployProgram(address(earnVault));
        spender = new CardSpender(program);
        settler = new CardSettler(spender);
        vm.label(address(program), "RainCardProgram");
        vm.label(address(spender), "CardSpender");
        vm.label(address(settler), "CardSettler");
    }

    function _deployProgram(address vault) internal returns (RainCardProgram) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usd);
        address[] memory vaults = new address[](vault == address(0) ? 0 : 1);
        if (vault != address(0)) vaults[0] = vault;
        address[] memory pooled = new address[](1);
        pooled[0] = programCollateral;
        return new RainCardProgram(address(rain.factory), tokens, vaults, pooled);
    }

    /// @dev Rain's factory owner (this contract) creates `user`'s collateral contract.
    function _createCollateral(string memory name, address user) internal returns (address collateral, uint256 n) {
        n = _factoryNonce++;
        collateral = rain.factory.createCollateralContract(name, user);
        assertEq(collateral, vm.computeCreateAddress(address(rain.factory), n), "factory CREATE nonce");
        vm.label(collateral, string.concat("Rain.Collateral.", name));
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
    function _routerSettle(address router, address token, uint256 maxInput, CardSpend memory s) internal {
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
