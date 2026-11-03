// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC165 } from "openzeppelin-contracts/utils/introspection/IERC165.sol";

import { CardProgram } from "../../../src/core/CardProgram.sol";
import { CardSpend } from "../../../src/core/CardSpend.sol";
import { ICardIssuer, ICardIssuerPayout } from "../../../src/core/interfaces/ICardIssuer.sol";
import { BridgeIssuer } from "../../../src/providers/bridge/BridgeIssuer.sol";
import { Spend } from "../../../src/providers/bridge/interfaces/IBridgeSpender.sol";
import { IBridgeSpenderFactory } from "../../../src/providers/bridge/interfaces/IBridgeSpenderFactory.sol";

/// @dev A plain ERC-20 whose transfers out of one address can be made to report success without moving
///      anything, to leave a residual balance behind.
contract SettlerMockToken {
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;
    address public stuck;
    bool public refuseApprovals;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
///      input from the caller and pays the destination `pay` of the spend's token from its own balance;
///      `publicGetCall` answers "GV" with `vaultAnswer`, raw.
contract MockClone {
    uint256 public consume;
    uint256 public pay;
    bytes public lastCall;
    bytes public vaultAnswer;
    bool public getReverts;

    function configure(uint256 consume_, uint256 pay_) external {
        consume = consume_;
        pay = pay_;
    }

    function setVaultAnswer(bytes calldata answer, bool reverts) external {
        vaultAnswer = answer;
        getReverts = reverts;
    }

    function publicCall(bytes calldata data) external {
        lastCall = data;
        Spend memory spend = abi.decode(data[4:], (Spend));
        address input = spend.fromVault == 0 ? spend.token : MockVault(spend.vault).earnShare();
        if (consume != 0) SettlerMockToken(input).transferFrom(msg.sender, address(this), consume);
        if (pay != 0) SettlerMockToken(spend.token).transfer(spend.destination, pay);
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

    function setClone(bytes32 spenderId, address clone) external {
        clones[spenderId] = clone;
    }

    function setDestination(bytes32 spenderId, address destination, bool allowed) external {
        authorized[spenderId][destination] = allowed;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
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

/// @notice `BridgeIssuer` and the `CardProgram` it pays through, against a mock factory and clone: the
///         issuer answers from the factory and the clone, and the program pays through the clone with the
///         `Spend` the "TS" handler settles, keeping its own checks whatever the clone does. test/bridge runs
///         both against Bridge's real factory and the "TS" handler (`BridgeProgram.t.sol`).
contract BridgeIssuerMockTest is Test {
    bytes32 internal constant SPENDER_ID = keccak256("program");
    uint256 internal constant AMOUNT = 25e6;

    SettlerMockToken internal usd;
    SettlerMockToken internal share;
    MockVault internal vault;
    MockClone internal clone;
    MockFactory internal factory;
    BridgeIssuer internal issuer;
    CardProgram internal program;
    address internal router = makeAddr("router");
    address internal destination = makeAddr("destination");

    function setUp() public {
        usd = new SettlerMockToken();
        share = new SettlerMockToken();
        vault = new MockVault(address(share), address(usd));
        clone = new MockClone();
        clone.setVaultAnswer(abi.encode(abi.encode(true)), false);
        factory = new MockFactory();
        factory.setClone(SPENDER_ID, address(clone));
        factory.setDestination(SPENDER_ID, destination, true);
        issuer = new BridgeIssuer(factory, SPENDER_ID);
        program = new CardProgram(issuer, address(0));
        usd.mint(address(clone), 1000e6);
    }

    // ------------------------------------------------------------------
    // The issuer
    // ------------------------------------------------------------------

    function testConstructorRefusesZeroFactory() public {
        vm.expectRevert(BridgeIssuer.ZeroAddress.selector);
        new BridgeIssuer(IBridgeSpenderFactory(address(0)), SPENDER_ID);
    }

    /// @notice An issuer is bound to the program's clone when it is created, so one must exist.
    function testConstructorRefusesAProgramWithoutAClone() public {
        bytes32 empty = keccak256("no code");
        factory.setClone(empty, makeAddr("no code"));
        vm.expectRevert(BridgeIssuer.NoClone.selector);
        new BridgeIssuer(factory, empty);
        vm.expectRevert("unknown spender");
        new BridgeIssuer(factory, keccak256("unknown"));
    }

    function testIdentity() public view {
        assertEq(address(issuer.FACTORY()), address(factory));
        assertEq(issuer.SPENDER_ID(), SPENDER_ID);
        assertEq(issuer.CLONE(), address(clone));
        assertEq(issuer.payoutTarget(), address(clone));
        assertEq(program.PAYOUT_TARGET(), address(clone), "the program pays through the clone");
        assertTrue(issuer.supportsInterface(type(ICardIssuer).interfaceId));
        assertTrue(issuer.supportsInterface(type(ICardIssuerPayout).interfaceId));
        assertTrue(issuer.supportsInterface(type(IERC165).interfaceId));
        assertFalse(issuer.supportsInterface(0xffffffff));
    }

    /// @notice Destinations and the pause are the factory's, for public and private spends alike, and
    ///         whoever pays.
    function testDestinationsAndPauseAreTheFactorys() public {
        address other = makeAddr("other");
        assertTrue(issuer.isAuthorizedDestination(address(0), destination, address(usd), 0, false));
        assertTrue(issuer.isAuthorizedDestination(router, destination, address(share), 7, true));
        assertFalse(issuer.isAuthorizedDestination(router, other, address(usd), 0, false));
        factory.setDestination(SPENDER_ID, other, true);
        assertTrue(issuer.isAuthorizedDestination(router, other, address(usd), 0, true));

        assertFalse(issuer.paused());
        factory.setPaused(true);
        assertTrue(issuer.paused());
        assertTrue(program.paused(), "the program stops with the factory");
    }

    /// @notice The vault allowlist is the clone's "GV", and anything but a well-formed `true` is no vault.
    function testVaultAllowlistIsTheClones() public {
        assertTrue(issuer.isAllowedVault(address(vault)));
        clone.setVaultAnswer(abi.encode(abi.encode(false)), false);
        assertFalse(issuer.isAllowedVault(address(vault)));
        clone.setVaultAnswer(abi.encode(abi.encode(true)), true);
        assertFalse(issuer.isAllowedVault(address(vault)), "reverting clone");
        clone.setVaultAnswer(hex"01", false);
        assertFalse(issuer.isAllowedVault(address(vault)), "short answer");
        clone.setVaultAnswer(abi.encode(bytes("")), false);
        assertFalse(issuer.isAllowedVault(address(vault)), "empty inner answer");
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
        assertEq(issuer.payoutData(s), expected);
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
        program.settle(address(usd), AMOUNT, abi.encode(_spend(address(usd))));
        assertEq(usd.allowance(address(program), address(clone)), type(uint256).max - AMOUNT);
    }

    function testSettlesAndHandsBackUnusedInput() public {
        uint256 maxInput = AMOUNT + 7e6;
        clone.configure(AMOUNT, AMOUNT);
        CardSpend memory spend = _spend(address(usd));

        usd.mint(address(program), maxInput);
        vm.expectEmit(address(program));
        emit CardProgram.SpendSettled(spend.ref, address(usd), AMOUNT, 7e6);
        vm.prank(router);
        program.settle(address(usd), maxInput, abi.encode(spend));

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

        _settle(address(share), maxInput, maxInput, spend);

        assertEq(usd.balanceOf(destination), AMOUNT);
        assertEq(share.balanceOf(router), 6e6);
        assertEq(share.balanceOf(address(program)), 0);
    }

    /// @notice A public spend pulls only the stablecoin part and the live share quote (not the `maxShares` cap)
    ///         from the payer, pays through the clone and returns what the clone did not use.
    function testPublicSpendReturnsWhatTheCloneDidNotUse() public {
        address payer = makeAddr("payer");
        CardSpend memory spend = _spend(address(usd));
        spend.vault = address(vault);
        spend.fromVault = 20e6;
        spend.maxShares = 45e6;
        // Exactly the live quote (2 x 20e6), below the 45e6 cap: pulling the cap would fail.
        share.mint(payer, 40e6);
        usd.mint(payer, 100e6);
        vm.startPrank(payer);
        usd.approve(address(program), type(uint256).max);
        share.approve(address(program), type(uint256).max);
        vm.stopPrank();
        // The clone takes only the stablecoin it is shown (the mock pulls one input) and pays in full.
        clone.configure(0, AMOUNT);
        vm.prank(payer);
        program.spend(spend);
        assertEq(usd.balanceOf(destination), AMOUNT);
        assertEq(usd.balanceOf(payer), 100e6, "the unused stablecoin came back");
        assertEq(share.balanceOf(payer), 40e6, "the unused shares came back");
        assertEq(usd.balanceOf(address(program)), 0);
        assertEq(share.balanceOf(address(program)), 0);
    }

    function testRefusesAnotherProgram() public {
        CardSpend memory spend = _spend(address(usd));
        spend.program = makeAddr("other program");
        _expectSettleRevert(
            address(usd), AMOUNT, spend, abi.encodeWithSelector(CardProgram.WrongProgram.selector, spend.program)
        );
    }

    function testRefusesADestinationTheFactoryDoesNotAuthorize() public {
        CardSpend memory spend = _spend(address(usd));
        spend.destination = makeAddr("elsewhere");
        _expectSettleRevert(
            address(usd),
            AMOUNT,
            spend,
            abi.encodeWithSelector(CardProgram.DestinationNotAuthorized.selector, spend.destination)
        );
    }

    function testRefusesAVaultTheCloneDoesNotAllow() public {
        clone.setVaultAnswer(abi.encode(abi.encode(false)), false);
        CardSpend memory spend = _spend(address(usd));
        spend.vault = address(vault);
        spend.fromVault = AMOUNT;
        _expectSettleRevert(
            address(share), AMOUNT, spend, abi.encodeWithSelector(CardProgram.VaultNotAllowed.selector, address(vault))
        );
    }

    function testRefusesAWrongInputToken() public {
        // A stablecoin spend must be funded in its token.
        _expectSettleRevert(
            address(share),
            AMOUNT,
            _spend(address(usd)),
            abi.encodeWithSelector(CardProgram.WrongInputToken.selector, address(share))
        );

        // An Earn spend must be funded in its vault's EarnShare.
        CardSpend memory spend = _spend(address(usd));
        spend.vault = address(vault);
        spend.fromVault = AMOUNT;
        _expectSettleRevert(
            address(usd), AMOUNT, spend, abi.encodeWithSelector(CardProgram.WrongInputToken.selector, address(usd))
        );

        // A spend split between stablecoin and shares cannot come from one withdrawal.
        spend.fromVault = AMOUNT / 2;
        _expectSettleRevert(
            address(share), AMOUNT, spend, abi.encodeWithSelector(CardProgram.WrongInputToken.selector, address(share))
        );
    }

    function testRefusesAnInvalidAmount() public {
        _expectSettleRevert(
            address(usd), 0, _spend(address(usd)), abi.encodeWithSelector(CardProgram.InvalidAmount.selector)
        );
        _expectSettleRevert(
            address(usd),
            uint256(type(uint128).max) + 1,
            _spend(address(usd)),
            abi.encodeWithSelector(CardProgram.InvalidAmount.selector)
        );
    }

    function testRefusesInsufficientInput() public {
        clone.configure(AMOUNT, AMOUNT);
        usd.mint(address(program), AMOUNT - 1);
        vm.prank(router);
        vm.expectRevert(CardProgram.InsufficientInput.selector);
        program.settle(address(usd), AMOUNT, abi.encode(_spend(address(usd))));
    }

    function testRefusesASpendThatDidNotPayTheDestination() public {
        clone.configure(AMOUNT, AMOUNT - 1);
        _expectSettleRevert(
            address(usd),
            AMOUNT,
            _spend(address(usd)),
            abi.encodeWithSelector(CardProgram.DestinationNotCredited.selector)
        );
    }

    function testRefusesASpendThatConsumedNothing() public {
        clone.configure(0, AMOUNT);
        _expectSettleRevert(
            address(usd), AMOUNT, _spend(address(usd)), abi.encodeWithSelector(CardProgram.NothingSettled.selector)
        );
    }

    function testRefusesToKeepAResidualBalance() public {
        // The hand-back reports success without moving the unused input.
        clone.configure(AMOUNT, AMOUNT);
        usd.setStuck(address(program));
        _expectSettleRevert(
            address(usd),
            AMOUNT + 1,
            _spend(address(usd)),
            abi.encodeWithSelector(CardProgram.ResidualBalance.selector, address(usd))
        );
    }

    /// @dev A token that refuses an approval fails with Solady's `ApproveFailed()`.
    function testRefusesATokenCallThatDoesNotSucceed() public {
        clone.configure(AMOUNT, AMOUNT);
        usd.setRefuseApprovals(true);
        _expectSettleRevert(address(usd), AMOUNT, _spend(address(usd)), abi.encodeWithSelector(bytes4(0x3e3f8f73)));
    }

    function testKeepsTokensHeldBeforeTheCallOutOfTheSettlement() public {
        usd.mint(address(program), 3e6);
        clone.configure(AMOUNT, AMOUNT);
        _settle(address(usd), AMOUNT + 1e6, AMOUNT + 1e6, _spend(address(usd)));
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
    function _settle(address token, uint256 sent, uint256 maxInput, CardSpend memory spend) internal {
        SettlerMockToken(token).mint(router, sent);
        vm.startPrank(router);
        SettlerMockToken(token).transfer(address(program), sent);
        program.settle(token, maxInput, abi.encode(spend));
        vm.stopPrank();
    }

    function _expectSettleRevert(address token, uint256 maxInput, CardSpend memory spend, bytes memory reason)
        internal
    {
        SettlerMockToken(token).mint(address(program), maxInput);
        vm.prank(router);
        vm.expectRevert(reason);
        program.settle(token, maxInput, abi.encode(spend));
    }
}
