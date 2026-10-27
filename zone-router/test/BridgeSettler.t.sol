// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";

import { BridgeSettler } from "../src/settlers/BridgeSettler.sol";
import { IBridgeSpenderFactory, Spend } from "../src/settlers/bridge/IBridgeSpender.sol";

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

/// @dev Stands in for a Bridge spender clone running the "TS" handler: it pulls `consume` of the input
///      from the caller and pays the destination `pay` of the spend's token from its own balance.
contract MockClone {
    uint256 public consume;
    uint256 public pay;
    bytes public lastCall;

    function configure(uint256 consume_, uint256 pay_) external {
        consume = consume_;
        pay = pay_;
    }

    function publicCall(bytes calldata data) external {
        lastCall = data;
        Spend memory spend = abi.decode(data[4:], (Spend));
        address input = spend.fromVault == 0 ? spend.token : MockVault(spend.vault).earnShare();
        if (consume != 0) SettlerMockToken(input).transferFrom(msg.sender, address(this), consume);
        if (pay != 0) SettlerMockToken(spend.token).transfer(spend.destination, pay);
    }
}

contract MockFactory is IBridgeSpenderFactory {
    mapping(bytes32 spenderId => address) internal clones;

    function setClone(bytes32 spenderId, address clone) external {
        clones[spenderId] = clone;
    }

    function getSpenderAddress(bytes32 spenderId) external view returns (address clone) {
        clone = clones[spenderId];
        require(clone != address(0), "unknown spender");
    }
}

contract MockVault {
    address public earnShare;

    constructor(address earnShare_) {
        earnShare = earnShare_;
    }
}

/// @notice BridgeSettler's own checks against a mock factory and clone; bridge/test runs it against
///         Bridge's real factory and the "TS" handler.
contract BridgeSettlerTest is Test {
    bytes32 internal constant SPENDER_ID = keccak256("program");
    uint256 internal constant AMOUNT = 25e6;

    SettlerMockToken internal usd;
    SettlerMockToken internal share;
    MockVault internal vault;
    MockClone internal clone;
    MockFactory internal factory;
    BridgeSettler internal settler;
    address internal router = makeAddr("router");
    address internal destination = makeAddr("destination");

    function setUp() public {
        usd = new SettlerMockToken();
        share = new SettlerMockToken();
        vault = new MockVault(address(share));
        clone = new MockClone();
        factory = new MockFactory();
        factory.setClone(SPENDER_ID, address(clone));
        settler = new BridgeSettler(factory, SPENDER_ID);
        usd.mint(address(clone), 1000e6);
    }

    function testConstructorRefusesZeroFactory() public {
        vm.expectRevert(BridgeSettler.ZeroAddress.selector);
        new BridgeSettler(IBridgeSpenderFactory(address(0)), SPENDER_ID);
    }

    function testSettlesAndHandsBackUnusedInput() public {
        uint256 maxInput = AMOUNT + 7e6;
        clone.configure(AMOUNT, AMOUNT);
        Spend memory spend = _spend(address(usd));

        usd.mint(address(settler), maxInput);
        vm.expectEmit(address(settler));
        emit BridgeSettler.SpendSettled(spend.ref, address(usd), AMOUNT, 7e6);
        vm.prank(router);
        settler.settle(address(usd), maxInput, abi.encode(spend));

        assertEq(usd.balanceOf(destination), AMOUNT);
        assertEq(usd.balanceOf(router), 7e6);
        assertEq(usd.balanceOf(address(settler)), 0);
        assertEq(usd.allowance(address(settler), address(clone)), 0);
        assertEq(clone.lastCall(), abi.encodePacked(bytes2("TS"), bytes2("PS"), abi.encode(spend)));
    }

    function testSettlesFromTheVaultsEarnShares() public {
        uint256 maxInput = 30e6;
        clone.configure(24e6, AMOUNT);
        Spend memory spend = _spend(address(usd));
        spend.vault = address(vault);
        spend.fromVault = AMOUNT;

        _settle(address(share), maxInput, maxInput, spend);

        assertEq(usd.balanceOf(destination), AMOUNT);
        assertEq(share.balanceOf(router), 6e6);
        assertEq(share.balanceOf(address(settler)), 0);
    }

    function testRefusesAnotherProgram() public {
        Spend memory spend = _spend(address(usd));
        spend.spenderId = keccak256("other");
        _expectSettleRevert(
            address(usd), AMOUNT, spend, abi.encodeWithSelector(BridgeSettler.WrongProgram.selector, spend.spenderId)
        );
    }

    function testRefusesAWrongInputToken() public {
        // A stablecoin spend must be funded in its token.
        _expectSettleRevert(
            address(share),
            AMOUNT,
            _spend(address(usd)),
            abi.encodeWithSelector(BridgeSettler.WrongInputToken.selector, address(share))
        );

        // An Earn spend must be funded in its vault's EarnShare.
        Spend memory spend = _spend(address(usd));
        spend.vault = address(vault);
        spend.fromVault = AMOUNT;
        _expectSettleRevert(
            address(usd), AMOUNT, spend, abi.encodeWithSelector(BridgeSettler.WrongInputToken.selector, address(usd))
        );

        // A spend split between stablecoin and shares cannot come from one withdrawal.
        spend.fromVault = AMOUNT / 2;
        _expectSettleRevert(
            address(share),
            AMOUNT,
            spend,
            abi.encodeWithSelector(BridgeSettler.WrongInputToken.selector, address(share))
        );
    }

    function testRefusesAnInvalidAmount() public {
        _expectSettleRevert(
            address(usd), 0, _spend(address(usd)), abi.encodeWithSelector(BridgeSettler.InvalidAmount.selector)
        );
        _expectSettleRevert(
            address(usd),
            uint256(type(uint128).max) + 1,
            _spend(address(usd)),
            abi.encodeWithSelector(BridgeSettler.InvalidAmount.selector)
        );
    }

    function testRefusesInsufficientInput() public {
        clone.configure(AMOUNT, AMOUNT);
        usd.mint(address(settler), AMOUNT - 1);
        vm.prank(router);
        vm.expectRevert(BridgeSettler.InsufficientInput.selector);
        settler.settle(address(usd), AMOUNT, abi.encode(_spend(address(usd))));
    }

    function testRefusesASpendThatDidNotPayTheDestination() public {
        clone.configure(AMOUNT, AMOUNT - 1);
        _expectSettleRevert(
            address(usd),
            AMOUNT,
            _spend(address(usd)),
            abi.encodeWithSelector(BridgeSettler.DestinationNotPaid.selector)
        );
    }

    function testRefusesASpendThatConsumedNothing() public {
        clone.configure(0, AMOUNT);
        _expectSettleRevert(
            address(usd), AMOUNT, _spend(address(usd)), abi.encodeWithSelector(BridgeSettler.NothingSettled.selector)
        );
    }

    function testRefusesToKeepAResidualBalance() public {
        // The hand-back reports success without moving the unused input.
        clone.configure(AMOUNT, AMOUNT);
        usd.setStuck(address(settler));
        _expectSettleRevert(
            address(usd),
            AMOUNT + 1,
            _spend(address(usd)),
            abi.encodeWithSelector(BridgeSettler.ResidualBalance.selector, address(usd))
        );
    }

    /// @dev A token that refuses an approval fails with Solady's
    ///      `ApproveFailed()`.
    function testRefusesATokenCallThatDoesNotSucceed() public {
        clone.configure(AMOUNT, AMOUNT);
        usd.setRefuseApprovals(true);
        _expectSettleRevert(address(usd), AMOUNT, _spend(address(usd)), abi.encodeWithSelector(bytes4(0x3e3f8f73)));
    }

    function testKeepsTokensHeldBeforeTheCallOutOfTheSettlement() public {
        usd.mint(address(settler), 3e6);
        clone.configure(AMOUNT, AMOUNT);
        _settle(address(usd), AMOUNT + 1e6, AMOUNT + 1e6, _spend(address(usd)));
        assertEq(usd.balanceOf(router), 1e6);
        assertEq(usd.balanceOf(address(settler)), 3e6);
    }

    function _spend(address token) internal view returns (Spend memory spend) {
        spend.spenderId = SPENDER_ID;
        spend.token = token;
        spend.amount = AMOUNT;
        spend.destination = destination;
        spend.ref = keccak256("ref");
    }

    /// @dev Sends `sent` to the settler as the router does, then settles with `maxInput`.
    function _settle(address token, uint256 sent, uint256 maxInput, Spend memory spend) internal {
        SettlerMockToken(token).mint(router, sent);
        vm.startPrank(router);
        SettlerMockToken(token).transfer(address(settler), sent);
        settler.settle(token, maxInput, abi.encode(spend));
        vm.stopPrank();
    }

    function _expectSettleRevert(address token, uint256 maxInput, Spend memory spend, bytes memory reason) internal {
        SettlerMockToken(token).mint(address(settler), maxInput);
        vm.prank(router);
        vm.expectRevert(reason);
        settler.settle(token, maxInput, abi.encode(spend));
    }
}
