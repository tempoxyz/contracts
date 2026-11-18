// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CreditSource } from "../../../src/programs/CreditSource.sol";
import { IssuerDesk } from "../../../src/programs/IssuerDesk.sol";
import { ICardAuthCompanion, IssuerTreasury } from "../../../src/programs/IssuerTreasury.sol";
import { MerchantReserves } from "../../../src/programs/MerchantReserves.sol";
import { ICardAuth } from "../../../src/programs/interfaces/ICardAuth.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "../../../src/programs/interfaces/IReservationCore.sol";
import { ISource } from "../../../src/programs/interfaces/ISource.sol";
import { CoreEnv } from "../../core/harness/CoreEnv.sol";
import { MockReservationCore } from "./MockReservationCore.sol";

interface ICompToken {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

/// @notice A stand-in for the card authorization contract that the companions read and call: its settings, roles
///         and operator caps, the exposure and purchases tests set, and a driver that runs one source's legs as the
///         program does. It holds settlement tokens of its own to refund with.
contract CompCardAuth is ICardAuthCompanion {
    address public immutable ISSUER;
    address public immutable SETTLEMENT_ACCOUNT;
    address public settlementToken;
    address public conversion;
    address public treasury;
    uint256 public grantedOwners;
    uint256 internal _total;
    uint256 internal _committed;
    uint256 public lastStep;

    struct Purchase {
        uint64 captured;
        uint64 refunded;
        bool open;
    }

    mapping(address operator => uint8) public rolesOf;
    mapping(address operator => uint256) public capOf;
    mapping(address operator => uint256) public usedOf;
    mapping(address owner => mapping(bytes32 ref => Purchase)) internal _purchases;
    /// @notice What creditBack counted per purchase: usage freed and net refunded.
    mapping(address owner => mapping(bytes32 ref => uint256)) public creditedBack;

    error CapExceeded();
    error NotTreasury();

    constructor(address issuer, address settlement, address token) {
        (ISSUER, SETTLEMENT_ACCOUNT, settlementToken) = (issuer, settlement, token);
    }

    function setRoles(address operator, uint8 roles, uint256 cap) external {
        (rolesOf[operator], capOf[operator], usedOf[operator]) = (roles, cap, 0);
    }

    function setExposure(uint256 total, uint256 committed) external {
        (_total, _committed) = (total, committed);
    }

    function setGranted(uint256 n) external {
        grantedOwners = n;
    }

    function setConversion(address venue) external {
        conversion = venue;
    }

    function setToken(address token) external {
        settlementToken = token;
    }

    function setTreasury(address t) external {
        treasury = t;
    }

    function setPurchase(address owner, bytes32 ref, uint64 captured, uint64 refunded) external {
        _purchases[owner][ref] = Purchase(captured, refunded, false);
    }

    function hasRoles(address operator, uint8 roles) external view returns (bool) {
        return rolesOf[operator] & roles == roles && roles != 0;
    }

    function useOperatorCap(address operator, uint256 value) external {
        uint256 used = usedOf[operator] + value;
        if (used > capOf[operator]) revert CapExceeded();
        usedOf[operator] = used;
    }

    function exposure() external view returns (uint256, uint256) {
        return (_total, _committed);
    }

    function setSettlementToken(address token, uint256 step) external {
        if (msg.sender != treasury) revert NotTreasury();
        (settlementToken, lastStep) = (token, step);
    }

    function purchaseOf(address owner, bytes32 ref) external view returns (uint64, uint64, bool) {
        Purchase memory p = _purchases[owner][ref];
        return (p.captured, p.refunded, p.open);
    }

    /// @dev Refunds units of a purchase to its owner from this contract's own tokens.
    function refund(address owner, bytes32 ref, uint256 units) external {
        // forge-lint: disable-next-line(unsafe-typecast)
        _purchases[owner][ref].refunded += uint64(units);
        SafeTransferLib.safeTransfer(settlementToken, owner, units);
    }

    function creditBack(address owner, bytes32 ref, uint256, uint256 net) external {
        // forge-lint: disable-next-line(unsafe-typecast)
        _purchases[owner][ref].refunded += uint64(net);
        creditedBack[owner][ref] += net;
    }

    // Driver: runs a source's legs as the program.

    function hold(ISource source, address owner, bytes32 position, bytes32 legId, uint256 units, bool standIn)
        external
        returns (uint256)
    {
        // forge-lint: disable-next-line(block-timestamp,unsafe-typecast)
        return source.hold(owner, position, legId, units, uint64(block.timestamp + 7 days), standIn);
    }

    function capture(ISource source, address owner, bytes32 legId, uint256 units, bool isFinal, bytes32 ref)
        external
        returns (uint256 paid)
    {
        (paid,) = source.capture(owner, bytes32(0), legId, units, isFinal);
        // forge-lint: disable-next-line(unsafe-typecast)
        _purchases[owner][ref].captured += uint64(units);
    }

    function release(ISource source, address owner, bytes32 legId) external {
        source.release(owner, bytes32(0), legId);
    }

    /// @dev Sends units of its own tokens to the source and refunds them onto the leg.
    function refundLeg(ISource source, address owner, bytes32 legId, uint256 units) external returns (uint256 taken) {
        SafeTransferLib.safeTransfer(settlementToken, address(source), units);
        taken = source.refund(owner, bytes32(0), legId, units);
    }
}

/// @notice The companions' world: the core model at its address, real tokens and Earn vault, the stand-in program,
///         and its credit lines, treasury, merchant reserves and dispute desk.
abstract contract CompEnv is CoreEnv {
    uint8 internal constant SETTLE = 2;
    uint8 internal constant TREASURY = 4;

    MockReservationCore internal core = MockReservationCore(RESERVATION_CORE_ADDRESS);
    CompCardAuth internal auth;
    CreditSource internal credit;
    IssuerTreasury internal treasury;
    MerchantReserves internal reserves;
    IssuerDesk internal desk;

    address internal issuer = makeAddr("issuer");
    address internal settlement = makeAddr("issuer.settlement");
    address internal lender = makeAddr("lender");
    address internal merchant = makeAddr("merchant");
    address internal operator = makeAddr("operator");

    function _deployComp() internal {
        _deployCore();
        vm.etch(RESERVATION_CORE_ADDRESS, address(new MockReservationCore()).code);
        vm.allowCheatcodes(RESERVATION_CORE_ADDRESS);
        auth = new CompCardAuth(issuer, settlement, address(usd));
        credit = new CreditSource(auth);
        treasury = new IssuerTreasury(auth);
        reserves = new MerchantReserves(auth);
        desk = new IssuerDesk(auth, credit, treasury, IEarnVault(address(earnVault)));
        auth.setTreasury(address(treasury));
        // The desk repays and redraws lines and pays out as a treasury and settle operator.
        auth.setRoles(address(desk), SETTLE | TREASURY, type(uint256).max);
        usd.mint(address(auth), 1_000_000e6);
        vm.prank(settlement);
        usd.approve(address(desk), type(uint256).max);
        vm.prank(settlement);
        usd.approve(address(treasury), type(uint256).max);
        vm.label(address(auth), "CardAuth");
        vm.label(address(credit), "CreditSource");
        vm.label(address(treasury), "IssuerTreasury");
        vm.label(address(reserves), "MerchantReserves");
        vm.label(address(desk), "IssuerDesk");
    }

    /// @dev Opens and accepts a line from lender to borrower, funding and approving the lender.
    function _openLine(address borrower, uint128 limit, IEarnVault vault, uint16 ltvBps, uint16 aprBps)
        internal
        returns (uint64 lineId)
    {
        usd.mint(lender, 100_000e6);
        vm.startPrank(lender);
        core.approveHolder(address(credit), address(usd), type(uint128).max, 0);
        lineId = credit.openLine(borrower, limit, uint64(block.timestamp + 60 days), vault, ltvBps, aprBps, 0);
        vm.stopPrank();
        _accept(borrower, lineId);
    }

    function _accept(address borrower, uint64 lineId) internal {
        (uint16 aprBps, uint128 maxDebt) = credit.offerOf(lineId);
        vm.prank(borrower);
        credit.acceptLine(lineId, aprBps, maxDebt);
    }

    function _pos(uint64 lineId) internal pure returns (bytes32) {
        return bytes32(uint256(lineId));
    }

    /// @dev Holds then captures units on lineId for borrower as purchase ref, leg legId.
    function _draw(address borrower, uint64 lineId, bytes32 legId, uint256 units, bytes32 ref) internal {
        auth.hold(credit, borrower, _pos(lineId), legId, units, false);
        auth.capture(credit, borrower, legId, units, true, ref);
    }

    function _owed(address owner, address token, address creditor) internal view returns (uint128) {
        IReservationCore.Debt[] memory debts = core.debtOf(owner, token);
        for (uint256 i; i < debts.length; ++i) {
            if (debts[i].creditor == creditor) return debts[i].amount;
        }
        return 0;
    }

    function _setDebtCap(address owner, address payee, address token, uint128 debtCap) internal {
        IReservationCore.PayeeTerms memory t = core.payeeTerms(owner, payee, token);
        t.debtCap = debtCap;
        vm.prank(owner);
        core.setPayeeTerms(payee, token, t);
    }

    function _repayDebt(address owner, address token) internal {
        core.notifyCredit(token, owner, ICompToken(token).balanceOf(owner));
    }

    function _assertCoreBalanced() internal view {
        assertEq(usd.balanceOf(address(core)), core.totalReserved(address(usd)), "usd reserved");
        assertEq(earnShare.balanceOf(address(core)), core.totalReserved(address(earnShare)), "share reserved");
    }

    /// @dev Calls a treasury setting as the issuer and applies it once its delay passes.
    function _setting(bytes memory data) internal {
        _issuerCall(data);
        uint64 eta = treasury.pendingSetting(keccak256(data));
        if (eta == 0) return;
        uint256 at = vm.getBlockTimestamp();
        vm.warp(eta);
        _issuerCall(data);
        vm.warp(at);
    }

    function _issuerCall(bytes memory data) internal {
        vm.prank(issuer);
        (bool ok, bytes memory result) = address(treasury).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    // Silences unused-import lints for types tests import through this file.
    function _types() internal pure returns (ICardAuth, ICompToken) {
        return (ICardAuth(address(0)), ICompToken(address(0)));
    }
}
