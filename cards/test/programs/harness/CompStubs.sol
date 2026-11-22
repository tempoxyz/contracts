// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CreditSource } from "../../../src/programs/CreditSource.sol";
import { IssuerDesk } from "../../../src/programs/IssuerDesk.sol";
import { IssuerTreasury } from "../../../src/programs/IssuerTreasury.sol";
import { MerchantReserves } from "../../../src/programs/MerchantReserves.sol";
import { ICardAuth } from "../../../src/programs/interfaces/ICardAuth.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "../../../src/programs/interfaces/IReservationCore.sol";
import { CAPTURE_FINAL, CAPTURE_FREE, ISource } from "../../../src/programs/interfaces/ISource.sol";
import { CoreEnv } from "../../core/harness/CoreEnv.sol";
import { MockReservationCore } from "./MockReservationCore.sol";

interface ICompToken {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

/// @notice A stand-in for the card authorization contract that the companions read and call: its settings, roles,
///         companions and operator caps, the exposure and purchases tests set, and a driver that runs one source's
///         legs as the program does. Refunds take today's token from the caller, as the program does, and pay the
///         purchase's owner.
contract CompCardAuth is ICardAuth {
    uint8 public constant ROLE_AUTHORIZE = 1;
    uint8 public constant ROLE_SETTLE = 2;
    uint8 public constant ROLE_TREASURY = 4;
    uint64 public constant SETTINGS_DELAY = 2 days;
    uint64 public constant SETTINGS_WINDOW = 7 days;
    address public immutable ISSUER;
    address public immutable SETTLEMENT_ACCOUNT;
    address public settlementToken;
    address public conversion;
    uint64 public grantedOwners;
    uint256 internal _held;
    uint256 internal _unsettled;
    uint256 public lastScale;

    mapping(address operator => uint8) public rolesOf;
    mapping(address operator => uint256) public capOf;
    mapping(address operator => uint256) public usedOf;
    mapping(address account => bool) public isCompanion;
    mapping(bytes32 ref => PurchaseView) internal _purchases;
    mapping(bytes32 ref => address[]) internal _sources;
    mapping(bytes32 ref => bytes32[]) internal _legIds;
    /// @notice What creditBack counted per purchase.
    mapping(bytes32 ref => uint256) public creditedBack;
    /// @notice What creditBack counted against settlement per purchase.
    mapping(bytes32 ref => int256) public settledBack;
    /// @notice What refunds per purchase paid out.
    mapping(bytes32 ref => uint256) public refundedOut;

    error CapExceeded();
    error NotCompanion();
    error NotSettle();

    constructor(address issuer, address settlement, address token) {
        (ISSUER, SETTLEMENT_ACCOUNT, settlementToken) = (issuer, settlement, token);
    }

    function setRoles(address operator, uint8 roles, uint256 cap) external {
        (rolesOf[operator], capOf[operator], usedOf[operator]) = (roles, cap, 0);
    }

    function setCompanion(address account, bool on) external {
        isCompanion[account] = on;
    }

    function setExposure(uint256 held_, uint256 unsettled) external {
        (_held, _unsettled) = (held_, unsettled);
    }

    function setGranted(uint64 n) external {
        grantedOwners = n;
    }

    function setConversion(address venue) external {
        conversion = venue;
    }

    function setToken(address token) external {
        settlementToken = token;
    }

    /// @dev Records a purchase of owner booked in today's token, with one leg on source.
    function setPurchase(bytes32 ref, address owner, uint64 captured, uint64 refunded) external {
        PurchaseView storage p = _purchases[ref];
        (p.owner, p.token, p.captured, p.refunded) = (owner, settlementToken, captured, refunded);
    }

    function setLeg(bytes32 ref, address source, bytes32 legId) external {
        _sources[ref].push(source);
        _legIds[ref].push(legId);
    }

    function hasRoles(address operator, uint8 roles) external view returns (bool) {
        if (operator == ISSUER) return true;
        return roles != 0 && rolesOf[operator] & roles == roles;
    }

    function useOperatorCap(address operator, uint256 value) external {
        if (!isCompanion[msg.sender]) revert NotCompanion();
        if (operator == ISSUER) return;
        uint256 used = usedOf[operator] + value;
        if (used > capOf[operator]) revert CapExceeded();
        usedOf[operator] = used;
    }

    function exposure() external view returns (uint256, uint256) {
        return (_held, _unsettled);
    }

    /// @dev The program approves no cash source here, so the issuer treasury counts no converted holds.
    function cashSources() external pure returns (address[] memory) { }

    function sourceKind(address) external pure returns (uint8) { }

    /// @dev Settles every unsettled step.
    function acknowledgeSettlement(uint64) external {
        _unsettled = 0;
    }

    function checkpointSettlement() external pure returns (uint64) {
        return 0;
    }

    function settlementCheckpoint(uint256) external pure returns (uint64, int128) {
        return (0, 0);
    }

    function ledger() external view returns (uint64, uint64, int128, int128) {
        // Unsettled exposure reads as one step the issuer has not acknowledged.
        return (_unsettled == 0 ? 0 : 1, 0, int128(int256(_unsettled)), 0);
    }

    function setSettlementToken(address token, uint256 scale) external {
        if (!isCompanion[msg.sender]) revert NotCompanion();
        (settlementToken, lastScale) = (token, scale);
    }

    function purchaseOf(bytes32 ref) external view returns (PurchaseView memory) {
        return _purchases[ref];
    }

    function legsOf(bytes32 ref) external view returns (address[] memory, bytes32[] memory, bytes32[] memory) {
        address[] memory sources = _sources[ref];
        return (sources, new bytes32[](sources.length), _legIds[ref]);
    }

    function capture(bytes32, uint128, bool) external pure { }

    function charge(bytes32, bytes32, uint128, address) external pure { }

    function reserveSettled(bytes32, uint128) external pure { }

    /// @dev Takes amount of today's token from the caller and pays the purchase's owner.
    function refund(bytes32 ref, uint128 amount) external {
        if (!this.hasRoles(msg.sender, ROLE_SETTLE)) revert NotSettle();
        PurchaseView storage p = _purchases[ref];
        p.refunded += uint64(amount);
        refundedOut[ref] += amount;
        SafeTransferLib.safeTransferFrom(settlementToken, msg.sender, p.owner, amount);
    }

    function creditBack(bytes32 ref, uint128 amount, int128 settles) external {
        if (!isCompanion[msg.sender]) revert NotCompanion();
        _purchases[ref].refunded += uint64(amount);
        creditedBack[ref] += amount;
        settledBack[ref] += settles;
    }

    // Driver: runs a source's legs as the program.

    function hold(ISource source, address owner, bytes32 position, bytes32 legId, uint256 units)
        external
        returns (uint256)
    {
        // forge-lint: disable-next-line(block-timestamp,unsafe-typecast)
        return source.hold(owner, position, legId, units, uint64(block.timestamp + 7 days));
    }

    function capture(ISource source, address owner, bytes32 legId, uint256 units, bool isFinal, bytes32 ref)
        external
        returns (uint256 taken)
    {
        (taken,) = source.capture(owner, bytes32(0), legId, units, isFinal ? CAPTURE_FINAL : 0);
        PurchaseView storage p = _purchases[ref];
        if (p.owner == address(0)) {
            (p.owner, p.token) = (owner, settlementToken);
            _sources[ref].push(address(source));
            _legIds[ref].push(legId);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        p.captured += uint64(taken);
    }

    function captureFree(ISource source, address owner, bytes32 legId, uint256 units) external returns (uint256 taken) {
        (taken,) = source.capture(owner, bytes32(0), legId, units, CAPTURE_FINAL | CAPTURE_FREE);
    }

    function release(ISource source, address owner, bytes32 legId) external {
        source.release(owner, bytes32(0), legId);
    }

    /// @dev Sends units of its own tokens to the source and refunds them onto the leg.
    function refundLeg(ISource source, address owner, bytes32 legId, uint256 units) external {
        SafeTransferLib.safeTransfer(settlementToken, address(source), units);
        source.refund(owner, bytes32(0), legId, units);
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
        vm.prank(issuer);
        credit.setLender(lender, true);
        treasury = new IssuerTreasury(auth);
        reserves = new MerchantReserves(auth);
        desk = new IssuerDesk(auth, credit, treasury, IEarnVault(address(earnVault)));
        auth.setCompanion(address(treasury), true);
        auth.setCompanion(address(reserves), true);
        auth.setCompanion(address(desk), true);
        auth.setCompanion(address(credit), true);
        // The desk refunds and credits back as a settle operator and pays out through the treasury.
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
        auth.hold(credit, borrower, _pos(lineId), legId, units);
        auth.capture(credit, borrower, legId, units, true, ref);
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
