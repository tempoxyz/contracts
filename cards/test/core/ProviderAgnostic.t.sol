// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardSettler } from "../../src/core/CardSettler.sol";
import { CardSpend } from "../../src/core/CardSpend.sol";
import { CardSpender } from "../../src/core/CardSpender.sol";
import { ICardProgram } from "../../src/core/interfaces/ICardProgram.sol";
import { CoreEnv } from "./harness/CoreEnv.sol";

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

/// @dev A settlement wallet is shared by every cardholder, so it serves public and private spends alike.
contract SettlementWalletProgram is ICardProgram {
    SettlementWalletRegistry public immutable REGISTRY;
    bytes32 public immutable PROGRAM_ID;
    address public immutable TOKEN;

    constructor(SettlementWalletRegistry registry, bytes32 id, address token) {
        REGISTRY = registry;
        PROGRAM_ID = id;
        TOKEN = token;
    }

    function isAuthorizedDestination(address, address destination, address token, uint256, bool)
        external
        view
        returns (bool)
    {
        return token == TOKEN && REGISTRY.isAuthorizedDestination(PROGRAM_ID, destination);
    }

    function isAllowedVault(address) external pure returns (bool) {
        return false;
    }

    function paused() external view returns (bool) {
        return REGISTRY.paused();
    }
}

/// @notice The same `CardSpender` and `CardSettler` run a second provider whose destinations work like
///         Bridge's settlement wallets, with no change: only the `ICardProgram` adapter differs.
contract ProviderAgnosticTest is CoreEnv {
    SettlementWalletRegistry internal registry;
    address internal settlementWallet = makeAddr("provider.settlement");

    function setUp() public {
        _deployCore();
        _deployMockProgram();
        registry = new SettlementWalletRegistry();
        registry.set("program", settlementWallet, true);
        spender = new CardSpender(new SettlementWalletProgram(registry, "program", address(usd)));
        settler = CardSettler(spender.SETTLER());
        usd.mint(alice, 100e6);
        usd.mint(router, 100e6);
    }

    function test_publicAndPrivate_withASecondProvider() public {
        _publicSpend(alice, _stableSpend(settlementWallet, 0, 10e6, "public"));
        _routerSettle(address(usd), 12e6, _stableSpend(settlementWallet, 0, 12e6, "private"));
        assertEq(usd.balanceOf(settlementWallet), 22e6);
    }

    function test_revert_pausedProvider() public {
        registry.setPaused(true);
        CardSpend memory s = _stableSpend(settlementWallet, 0, 10e6, "paused");
        vm.startPrank(alice);
        usd.approve(address(spender), 10e6);
        vm.expectRevert(CardSpender.ProgramPaused.selector);
        spender.spend(s);
        vm.stopPrank();
    }

    /// @dev One program's spend never pays through another program's spender or settler.
    function test_revert_crossProgram() public {
        CardSpender mockSpender = new CardSpender(mock);
        CardSettler mockSettler = CardSettler(mockSpender.SETTLER());
        CardSpend memory s = _stableSpend(settlementWallet, 0, 1e6, "cross");
        vm.prank(router);
        usd.transfer(address(mockSettler), 1e6);
        vm.expectRevert(abi.encodeWithSelector(CardSettler.WrongProgram.selector, s.program));
        mockSettler.settle(address(usd), 1e6, abi.encode(s));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.WrongProgram.selector, s.program));
        mockSpender.spend(s);
    }
}
