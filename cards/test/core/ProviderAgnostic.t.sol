// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { CardSpend } from "../../src/core/CardSpend.sol";
import { CardSpender } from "../../src/core/CardSpender.sol";
import { ICardProvider } from "../../src/core/interfaces/ICardProvider.sol";
import { CoreEnv } from "./harness/CoreEnv.sol";

/// @notice A provider whose program pays a settlement-wallet allowlist directly, with a pause, read from the
///         provider's own registry.
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
contract SettlementWalletProvider is ICardProvider {
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

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(ICardProvider).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @notice A second provider runs on the same `CardSpender` with only its own provider contract, and one
///         program's spend never pays through another's.
contract ProviderAgnosticTest is CoreEnv {
    SettlementWalletRegistry internal registry;
    CardSpender internal walletProgram;
    address internal settlementWallet = makeAddr("provider.settlement");

    function setUp() public {
        _deployCore();
        _deployMockProgram(false);
        registry = new SettlementWalletRegistry();
        registry.set("program", settlementWallet, true);
        walletProgram =
            CardSpender(factory.deploy("wallet", new SettlementWalletProvider(registry, "program", address(usd))));
        usd.mint(alice, 100e6);
        usd.mint(router, 100e6);
    }

    function _walletSpend(uint256 amount) internal view returns (CardSpend memory s) {
        s.program = address(walletProgram);
        s.token = address(usd);
        s.amount = amount;
        s.destination = settlementWallet;
    }

    function test_publicAndPrivate_withASecondProvider() public {
        program = walletProgram;
        _publicSpend(alice, _walletSpend(10e6));
        _routerSettle(address(usd), 12e6, _walletSpend(12e6));
        assertEq(usd.balanceOf(settlementWallet), 22e6);
    }

    function test_revert_pausedProvider() public {
        registry.setPaused(true);
        CardSpend memory s = _walletSpend(10e6);
        vm.startPrank(alice);
        usd.approve(address(walletProgram), 10e6);
        vm.expectRevert(CardSpender.ProgramPaused.selector);
        walletProgram.spend(s);
        vm.stopPrank();
    }

    function test_revert_crossProgram() public {
        CardSpend memory s = _walletSpend(1e6);
        vm.prank(router);
        usd.transfer(address(program), 1e6);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.WrongProgram.selector, s.program));
        program.settle(address(usd), 1e6, abi.encode(s));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.WrongProgram.selector, s.program));
        program.spend(s);
    }
}
