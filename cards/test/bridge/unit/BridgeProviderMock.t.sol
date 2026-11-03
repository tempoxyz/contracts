// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC165 } from "openzeppelin-contracts/utils/introspection/IERC165.sol";

import { CardSpend } from "../../../src/core/CardSpend.sol";
import { CardSpender } from "../../../src/core/CardSpender.sol";
import { ICardProvider, ICardProviderPayout } from "../../../src/core/interfaces/ICardProvider.sol";
import { BridgeProvider } from "../../../src/providers/bridge/BridgeProvider.sol";
import { Spend } from "../../../src/providers/bridge/interfaces/IBridgeSpender.sol";
import { IBridgeSpenderFactory } from "../../../src/providers/bridge/interfaces/IBridgeSpenderFactory.sol";
import { MockRouter, MockRouterFactory } from "../../core/harness/Mocks.sol";

/// @dev A plain ERC-20 whose transfers out of one address can be made to report success without moving
///      anything, to leave a residual balance behind.
contract SpenderMockToken {
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;
    uint256 public totalSupply;
    address public stuck;
    bool public refuseApprovals;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }

    function setStuck(address account) external {
        stuck = account;
    }

    function setRefuseApprovals(bool refuse) external {
        refuseApprovals = refuse;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (refuseApprovals) return false;
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (msg.sender == stuck) return true;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Stands in for a Bridge spender clone running the "TS" handler: `publicCall` pulls `consume` of the
///      input from the caller, burns the shares it took for an Earn spend (as the vault does) but `keep`, and pays
///      the destination `pay` of the spend's token from its own balance;
///      `publicGetCall` answers "GV" with `vaultAnswer`, raw.
contract MockClone {
    uint256 public consume;
    uint256 public pay;
    uint256 public keep;
    bytes public lastCall;
    bytes public vaultAnswer;
    bool public getReverts;

    function configure(uint256 consume_, uint256 pay_) external {
        consume = consume_;
        pay = pay_;
    }

    function setKeep(uint256 keep_) external {
        keep = keep_;
    }

    function setVaultAnswer(bytes calldata answer, bool reverts) external {
        vaultAnswer = answer;
        getReverts = reverts;
    }

    function publicCall(bytes calldata data) external {
        lastCall = data;
        Spend memory spend = abi.decode(data[4:], (Spend));
        address input = spend.fromVault == 0 ? spend.token : MockVault(spend.vault).earnShare();
        if (consume != 0) SpenderMockToken(input).transferFrom(msg.sender, address(this), consume);
        if (spend.fromVault != 0 && consume > keep) SpenderMockToken(input).burn(consume - keep);
        if (pay != 0) SpenderMockToken(spend.token).transfer(spend.destination, pay);
    }

    function publicGetCall(bytes calldata data) external view returns (bytes memory) {
        require(!getReverts, "no handler");
        require(bytes4(data[0:4]) == bytes4(abi.encodePacked(bytes2("TS"), bytes2("GV"))) && data.length == 24);
        bytes memory answer = vaultAnswer;
        // Returned as is, so a test can hand back malformed data.
        assembly {
            return(add(answer, 0x20), mload(answer))
        }
    }
}

contract MockFactory is IBridgeSpenderFactory {
    mapping(bytes32 spenderId => address) internal clones;
    mapping(bytes32 spenderId => mapping(address destination => bool)) public authorized;
    bool public paused;
    /// @dev Whether the factory refuses to route "TS" for the clone (disabled, or gated without it).
    bool public handlerRefused;

    function setClone(bytes32 spenderId, address clone) external {
        clones[spenderId] = clone;
    }

    function setDestination(bytes32 spenderId, address destination, bool allowed) external {
        authorized[spenderId][destination] = allowed;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setHandlerRefused(bool refused) external {
        handlerRefused = refused;
    }

    function getSpenderHandlerWithCheckedPermissions(bytes2, address) external view returns (address) {
        require(!handlerRefused, "handler refused");
        return address(0x7);
    }

    function getSpenderAddress(bytes32 spenderId) external view returns (address clone) {
        clone = clones[spenderId];
        require(clone != address(0), "unknown spender");
    }

    function isAuthorizedDestination(bytes32 spenderId, address destination) external view returns (bool) {
        return authorized[spenderId][destination];
    }

    function hasRole(bytes32, address) external pure returns (bool) {
        return false;
    }
}

contract MockVault {
    address public earnShare;
    address public asset;

    constructor(address earnShare_, address asset_) {
        earnShare = earnShare_;
        asset = asset_;
    }

    /// @dev A fixed quote: two shares per unit of the asset.
    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets * 2;
    }
}

/// @notice `BridgeProvider` and the `CardSpender` it pays through, against a mock factory and clone: the
///         provider answers from the factory and the clone, and the program pays through the clone with the
///         `Spend` the "TS" handler settles, keeping its own checks whatever the clone does. test/bridge runs
///         both against Bridge's real factory and the "TS" handler (`BridgeProgram.t.sol`).
contract BridgeProviderMockTest is Test {
    bytes32 internal constant SPENDER_ID = keccak256("program");
    uint256 internal constant AMOUNT = 25e6;

    SpenderMockToken internal usd;
    SpenderMockToken internal share;
    MockVault internal vault;
    MockClone internal clone;
    MockFactory internal factory;
    BridgeProvider internal provider;
    CardSpender internal program;
    /// @dev A router its factory registered, listing the program.
    address internal router;
    address internal destination = makeAddr("destination");

    function setUp() public {
        usd = new SpenderMockToken();
        share = new SpenderMockToken();
        vault = new MockVault(address(share), address(usd));
        clone = new MockClone();
        clone.setVaultAnswer(abi.encode(abi.encode(true)), false);
        factory = new MockFactory();
        factory.setClone(SPENDER_ID, address(clone));
        factory.setDestination(SPENDER_ID, destination, true);
        provider = new BridgeProvider(factory, SPENDER_ID);
        MockRouterFactory routerFactory = new MockRouterFactory();
        router = address(new MockRouter());
        routerFactory.register(router, true);
        program = new CardSpender(provider, address(routerFactory));
        MockRouter(router).list(address(program), true);
        usd.mint(address(clone), 1000e6);
    }

    // ------------------------------------------------------------------
    // The provider
    // ------------------------------------------------------------------

    function testConstructorRefusesZeroFactory() public {
        vm.expectRevert(BridgeProvider.ZeroAddress.selector);
        new BridgeProvider(IBridgeSpenderFactory(address(0)), SPENDER_ID);
    }

    /// @notice A `BridgeProvider` is bound to the program's clone when it is created, so one must exist.
    function testConstructorRefusesAProgramWithoutAClone() public {
        bytes32 empty = keccak256("no code");
        factory.setClone(empty, makeAddr("no code"));
        vm.expectRevert(BridgeProvider.NoClone.selector);
        new BridgeProvider(factory, empty);
        vm.expectRevert("unknown spender");
        new BridgeProvider(factory, keccak256("unknown"));
    }

    function testIdentity() public view {
        assertEq(address(provider.FACTORY()), address(factory));
        assertEq(provider.SPENDER_ID(), SPENDER_ID);
        assertEq(provider.CLONE(), address(clone));
        assertEq(provider.payoutTarget(), address(clone));
        assertEq(program.PAYOUT_TARGET(), address(clone), "the program pays through the clone");
        assertTrue(provider.supportsInterface(type(ICardProvider).interfaceId));
        assertTrue(provider.supportsInterface(type(ICardProviderPayout).interfaceId));
        assertTrue(provider.supportsInterface(type(IERC165).interfaceId));
        assertFalse(provider.supportsInterface(0xffffffff));
    }

    /// @notice Destinations and the pause are the factory's, for public and private spends alike, and
    ///         whoever pays.
    function testDestinationsAndPauseAreTheFactorys() public {
        address other = makeAddr("other");
        assertTrue(provider.isAuthorizedDestination(address(0), destination, address(usd), 0, false));
        assertTrue(provider.isAuthorizedDestination(router, destination, address(share), 7, true));
        assertFalse(provider.isAuthorizedDestination(router, other, address(usd), 0, false));
        factory.setDestination(SPENDER_ID, other, true);
        assertTrue(provider.isAuthorizedDestination(router, other, address(usd), 0, true));

        assertFalse(provider.paused());
        factory.setPaused(true);
        assertTrue(provider.paused());
        assertTrue(program.paused(), "the program stops with the factory");
    }

    /// @notice A "TS" handler the factory would not route for the clone (disabled, or gated without it) stops
    ///         spends as the pause does, so the program reports itself paused. The clone itself refuses the
    ///         spend (BridgeProgram.t.sol runs that against Bridge's factory).
    function testPausedWhileTheFactoryRefusesTheHandler() public {
        factory.setHandlerRefused(true);
        assertTrue(provider.paused());
        assertTrue(program.paused());
        factory.setHandlerRefused(false);
        assertFalse(program.paused());
    }

    /// @notice The vault allowlist is the clone's "GV", and anything but a well-formed `true` is no vault.
    function testVaultAllowlistIsTheClones() public {
        assertTrue(provider.isAllowedVault(address(vault)));
        clone.setVaultAnswer(abi.encode(abi.encode(false)), false);
        assertFalse(provider.isAllowedVault(address(vault)));
        clone.setVaultAnswer(abi.encode(abi.encode(true)), true);
        assertFalse(provider.isAllowedVault(address(vault)), "reverting clone");
        clone.setVaultAnswer(hex"01", false);
        assertFalse(provider.isAllowedVault(address(vault)), "short answer");
        clone.setVaultAnswer(abi.encode(bytes("")), false);
        assertFalse(provider.isAllowedVault(address(vault)), "empty inner answer");
    }

    /// @notice The payout is the clone's `publicCall "TS" "PS"` with the program's spender ID.
    function testPayoutDataIsTheTempoSpend() public view {
        CardSpend memory s = _spend(address(usd));
        s.vault = address(vault);
        s.fromVault = 5e6;
        s.maxShares = 11e6;
        s.destinationHint = 42;
        bytes memory expected = abi.encodeWithSignature(
            "publicCall(bytes)", abi.encodePacked(bytes2("TS"), bytes2("PS"), abi.encode(_tsSpend(s)))
        );
        assertEq(provider.payoutData(s), expected);
    }

    // ------------------------------------------------------------------
    // The program, paying through the clone
    // ------------------------------------------------------------------

    /// @notice Anyone may set the program's standing approval to the clone ahead of the first spend, after
    ///         which a spend approves nothing.
    function testWarmApprovesTheProgramClone() public {
        vm.prank(makeAddr("anyone"));
        program.warm(address(usd));
        assertEq(usd.allowance(address(program), address(clone)), type(uint256).max);

        clone.configure(AMOUNT, AMOUNT);
        usd.mint(address(program), AMOUNT);
        vm.prank(router);
        program.spendFrom(address(usd), AMOUNT, abi.encode(_spend(address(usd))));
        assertEq(usd.allowance(address(program), address(clone)), type(uint256).max - AMOUNT);
    }

    function testSettlesAndHandsBackUnusedInput() public {
        uint256 maxInput = AMOUNT + 7e6;
        clone.configure(AMOUNT, AMOUNT);
        CardSpend memory spend = _spend(address(usd));

        usd.mint(address(program), maxInput);
        vm.expectEmit(address(program));
        emit CardSpender.InputSpent(spend.ref, address(usd), AMOUNT, 7e6);
        vm.prank(router);
        program.spendFrom(address(usd), maxInput, abi.encode(spend));

        assertEq(usd.balanceOf(destination), AMOUNT);
        assertEq(usd.balanceOf(router), 7e6);
        assertEq(usd.balanceOf(address(program)), 0);
        // The standing approval to the clone stays, less what the spend used.
        assertEq(usd.allowance(address(program), address(clone)), type(uint256).max - AMOUNT);
        assertEq(clone.lastCall(), abi.encodePacked(bytes2("TS"), bytes2("PS"), abi.encode(_tsSpend(spend))));
    }

    function testSettlesFromTheVaultsEarnShares() public {
        uint256 maxInput = 30e6;
        clone.configure(24e6, AMOUNT);
        CardSpend memory spend = _spend(address(usd));
        spend.vault = address(vault);
        spend.fromVault = AMOUNT;

        _spendFrom(address(share), maxInput, maxInput, spend);

        assertEq(usd.balanceOf(destination), AMOUNT);
        assertEq(share.balanceOf(router), 6e6);
        assertEq(share.balanceOf(address(program)), 0);
    }

    /// @notice A public spend pulls only the live share quote (not the `maxShares` cap) from the payer, pays
    ///         through the clone and returns the shares the clone did not use.
    function testPublicSpendReturnsSharesTheCloneDidNotUse() public {
        address payer = makeAddr("payer");
        CardSpend memory spend = _spend(address(usd));
        spend.vault = address(vault);
        spend.fromVault = AMOUNT;
        spend.maxShares = 55e6;
        // Exactly the live quote (2 x 25e6), below the 55e6 cap: pulling the cap would fail.
        share.mint(payer, 50e6);
        vm.prank(payer);
        share.approve(address(program), type(uint256).max);
        clone.configure(40e6, AMOUNT);
        vm.prank(payer);
        program.spend(spend);
        assertEq(usd.balanceOf(destination), AMOUNT);
        assertEq(share.balanceOf(payer), 10e6, "the unused shares came back");
        assertEq(share.balanceOf(address(program)), 0);
    }

    /// @notice A public spend's stablecoin part is used in full: a clone that pays the destination some other
    ///         way and leaves it with the program is refused.
    function testPublicSpendRefusesUnusedStablecoin() public {
        address payer = makeAddr("payer");
        usd.mint(payer, 100e6);
        vm.prank(payer);
        usd.approve(address(program), type(uint256).max);
        clone.configure(0, AMOUNT);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.InputNotConsumed.selector, 0, AMOUNT));
        program.spend(_spend(address(usd)));
    }

    function testRefusesAnotherProgram() public {
        CardSpend memory spend = _spend(address(usd));
        spend.program = makeAddr("other program");
        _expectSpendRevert(
            address(usd), AMOUNT, spend, abi.encodeWithSelector(CardSpender.WrongProgram.selector, spend.program)
        );
    }

    /// @notice Through a payout target the program leaves the pause, destination and vault rules to the clone,
    ///         which enforces them in the same call (BridgeProgram.t.sol), and asks the provider nothing.
    function testLeavesTheProviderRulesToTheClone() public {
        clone.configure(AMOUNT, 0);
        CardSpend memory spend = _spend(address(usd));
        vm.expectCall(address(provider), abi.encodeWithSelector(BridgeProvider.isAuthorizedDestination.selector), 0);
        vm.expectCall(address(provider), abi.encodeWithSelector(BridgeProvider.paused.selector), 0);
        usd.mint(router, AMOUNT);
        vm.prank(router);
        usd.transfer(address(program), AMOUNT);
        vm.prank(router);
        vm.expectRevert(CardSpender.DestinationNotCredited.selector);
        program.spendFrom(address(usd), AMOUNT, abi.encode(spend));
    }

    function testRefusesAWrongInputToken() public {
        // A stablecoin spend must be funded in its token.
        _expectSpendRevert(
            address(share),
            AMOUNT,
            _spend(address(usd)),
            abi.encodeWithSelector(CardSpender.WrongInputToken.selector, address(share))
        );

        // An Earn spend must be funded in its vault's EarnShare.
        CardSpend memory spend = _spend(address(usd));
        spend.vault = address(vault);
        spend.fromVault = AMOUNT;
        _expectSpendRevert(
            address(usd), AMOUNT, spend, abi.encodeWithSelector(CardSpender.WrongInputToken.selector, address(usd))
        );

        // A spend split between stablecoin and shares cannot come from one withdrawal.
        spend.fromVault = AMOUNT / 2;
        _expectSpendRevert(
            address(share), AMOUNT, spend, abi.encodeWithSelector(CardSpender.WrongInputToken.selector, address(share))
        );
    }

    function testRefusesAnInvalidAmount() public {
        _expectSpendRevert(
            address(usd), 0, _spend(address(usd)), abi.encodeWithSelector(CardSpender.InvalidAmount.selector)
        );
        _expectSpendRevert(
            address(usd),
            uint256(type(uint128).max) + 1,
            _spend(address(usd)),
            abi.encodeWithSelector(CardSpender.InvalidAmount.selector)
        );
    }

    function testRefusesInsufficientInput() public {
        clone.configure(AMOUNT, AMOUNT);
        usd.mint(address(program), AMOUNT - 1);
        vm.prank(router);
        vm.expectRevert(CardSpender.InsufficientInput.selector);
        program.spendFrom(address(usd), AMOUNT, abi.encode(_spend(address(usd))));
    }

    function testRefusesASpendThatDidNotPayTheDestination() public {
        clone.configure(AMOUNT, AMOUNT - 1);
        _expectSpendRevert(
            address(usd),
            AMOUNT,
            _spend(address(usd)),
            abi.encodeWithSelector(CardSpender.DestinationNotCredited.selector)
        );
    }

    /// @notice A private Earn spend whose clone pays from elsewhere and takes no shares is refused.
    function testRefusesASpendThatConsumedNothing() public {
        clone.configure(0, AMOUNT);
        CardSpend memory spend = _spend(address(usd));
        spend.vault = address(vault);
        spend.fromVault = AMOUNT;
        _expectSpendRevert(address(share), 60e6, spend, abi.encodeWithSelector(CardSpender.NothingSpent.selector));
    }

    /// @notice A private stablecoin spend uses exactly its amount: a clone (or a replaced "TS" handler) that
    ///         keeps more of the withdrawal, or takes less, is refused.
    function testRefusesAPayoutThatDoesNotUseExactlyTheAmount() public {
        clone.configure(AMOUNT + 7e6, AMOUNT);
        _expectSpendRevert(
            address(usd),
            AMOUNT + 7e6,
            _spend(address(usd)),
            abi.encodeWithSelector(CardSpender.InputNotConsumed.selector, AMOUNT + 7e6, AMOUNT)
        );
        clone.configure(AMOUNT - 1, AMOUNT);
        usd.mint(address(clone), AMOUNT);
        _expectSpendRevert(
            address(usd),
            AMOUNT,
            _spend(address(usd)),
            abi.encodeWithSelector(CardSpender.InputNotConsumed.selector, AMOUNT - 1, AMOUNT)
        );
    }

    /// @notice A private Earn spend uses exactly the shares the vault burned, so a clone cannot keep any of
    ///         `maxInput`: here it burns all but one of the shares it took.
    function testRefusesAPayoutThatKeepsShares() public {
        clone.configure(50e6, AMOUNT);
        clone.setKeep(1);
        CardSpend memory spend = _spend(address(usd));
        spend.vault = address(vault);
        spend.fromVault = AMOUNT;
        _expectSpendRevert(
            address(share), 60e6, spend, abi.encodeWithSelector(CardSpender.InputNotConsumed.selector, 50e6, 50e6 - 1)
        );
    }

    function testRefusesToKeepAResidualBalance() public {
        // The hand-back reports success without moving the unused input.
        clone.configure(AMOUNT, AMOUNT);
        usd.setStuck(address(program));
        _expectSpendRevert(
            address(usd),
            AMOUNT + 1,
            _spend(address(usd)),
            abi.encodeWithSelector(CardSpender.ResidualBalance.selector, address(usd))
        );
    }

    /// @dev A token that refuses an approval fails with Solady's `ApproveFailed()`.
    function testRefusesATokenCallThatDoesNotSucceed() public {
        clone.configure(AMOUNT, AMOUNT);
        usd.setRefuseApprovals(true);
        _expectSpendRevert(address(usd), AMOUNT, _spend(address(usd)), abi.encodeWithSelector(bytes4(0x3e3f8f73)));
    }

    function testKeepsTokensHeldBeforeTheCallOutOfTheSettlement() public {
        usd.mint(address(program), 3e6);
        clone.configure(AMOUNT, AMOUNT);
        _spendFrom(address(usd), AMOUNT + 1e6, AMOUNT + 1e6, _spend(address(usd)));
        assertEq(usd.balanceOf(router), 1e6);
        assertEq(usd.balanceOf(address(program)), 3e6);
    }

    function _spend(address token) internal view returns (CardSpend memory spend) {
        spend.program = address(program);
        spend.token = token;
        spend.amount = AMOUNT;
        spend.destination = destination;
        spend.ref = keccak256("ref");
    }

    function _tsSpend(CardSpend memory s) internal pure returns (Spend memory) {
        return Spend({
            spenderId: SPENDER_ID,
            token: s.token,
            amount: s.amount,
            destination: s.destination,
            vault: s.vault,
            fromVault: s.fromVault,
            maxShares: s.maxShares,
            ref: s.ref
        });
    }

    /// @dev Sends `sent` to the program as the router does, then settles with `maxInput`.
    function _spendFrom(address token, uint256 sent, uint256 maxInput, CardSpend memory spend) internal {
        SpenderMockToken(token).mint(router, sent);
        vm.startPrank(router);
        SpenderMockToken(token).transfer(address(program), sent);
        program.spendFrom(token, maxInput, abi.encode(spend));
        vm.stopPrank();
    }

    function _expectSpendRevert(address token, uint256 maxInput, CardSpend memory spend, bytes memory reason) internal {
        SpenderMockToken(token).mint(address(program), maxInput);
        vm.prank(router);
        vm.expectRevert(reason);
        program.spendFrom(token, maxInput, abi.encode(spend));
    }
}
