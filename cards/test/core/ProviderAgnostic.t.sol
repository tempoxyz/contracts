// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardSettler } from "../../src/core/CardSettler.sol";
import { CardSpend } from "../../src/core/CardSpend.sol";
import { CardSpender } from "../../src/core/CardSpender.sol";
import { ICardProgram } from "../../src/core/interfaces/ICardProgram.sol";
import { CardsEnv } from "../rain/harness/CardsEnv.sol";

/// @notice A provider modeled on Bridge's: a program with a settlement-wallet allowlist and a pause,
///         read from the provider's own registry (here a stand-in for Bridge's spender factory).
contract SettlementWalletRegistry {
    mapping(bytes32 programId => mapping(address destination => bool)) public isAuthorizedDestination;
    bool public paused;

    function set(bytes32 id, address destination, bool allowed) external {
        isAuthorizedDestination[id][destination] = allowed;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }
}

contract SettlementWalletProgram is ICardProgram {
    SettlementWalletRegistry public immutable REGISTRY;
    bytes32 public immutable PROGRAM_ID;
    address public immutable TOKEN;

    constructor(SettlementWalletRegistry registry, bytes32 id, address token) {
        REGISTRY = registry;
        PROGRAM_ID = id;
        TOKEN = token;
    }

    function isAuthorizedDestination(address, address destination, address token, uint256)
        external
        view
        returns (bool)
    {
        return token == TOKEN && !REGISTRY.paused() && REGISTRY.isAuthorizedDestination(PROGRAM_ID, destination);
    }

    function isAllowedVault(address) external pure returns (bool) {
        return false;
    }
}

/// @notice The same `CardSpender` and `CardSettler` run a second provider whose destinations work like
///         Bridge's settlement wallets, with no change: only the `ICardProgram` adapter differs.
contract ProviderAgnosticTest is CardsEnv {
    SettlementWalletRegistry internal registry;
    CardSpender internal walletSpender;
    CardSettler internal walletSettler;
    address internal settlementWallet = makeAddr("provider.settlement");
    address internal router = makeAddr("zone-router");

    function setUp() public {
        _deployWorld();
        registry = new SettlementWalletRegistry();
        registry.set("program", settlementWallet, true);
        walletSpender = new CardSpender(new SettlementWalletProgram(registry, "program", address(usd)));
        walletSettler = new CardSettler(walletSpender);
        usd.mint(alice, 100e6);
        usd.mint(router, 100e6);
    }

    function _spend(uint256 amount) internal view returns (CardSpend memory s) {
        s.program = address(walletSpender.PROGRAM());
        s.token = address(usd);
        s.amount = amount;
        s.destination = settlementWallet;
    }

    function test_publicAndPrivate_withASecondProvider() public {
        vm.startPrank(alice);
        usd.approve(address(walletSpender), 10e6);
        walletSpender.spend(_spend(10e6));
        vm.stopPrank();
        vm.prank(router);
        usd.transfer(address(walletSettler), 12e6);
        vm.prank(router);
        walletSettler.settle(address(usd), 12e6, abi.encode(_spend(12e6)));
        assertEq(usd.balanceOf(settlementWallet), 22e6);
    }

    function test_revert_pausedProvider() public {
        registry.setPaused(true);
        CardSpend memory s = _spend(10e6);
        vm.startPrank(alice);
        usd.approve(address(walletSpender), 10e6);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, settlementWallet));
        walletSpender.spend(s);
        vm.stopPrank();
    }

    /// @dev One program's spend never pays through another program's spender or settler.
    function test_revert_crossProgram() public {
        CardSpend memory s = _spend(1e6);
        vm.prank(router);
        usd.transfer(address(settler), 1e6);
        vm.expectRevert(abi.encodeWithSelector(CardSettler.WrongProgram.selector, s.program));
        settler.settle(address(usd), 1e6, abi.encode(s));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.WrongProgram.selector, s.program));
        spender.spend(s);
    }
}
