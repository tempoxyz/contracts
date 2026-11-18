// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { ICardAuth } from "../../../src/programs/interfaces/ICardAuth.sol";
import { CAPTURE_FINAL, ISource } from "../../../src/programs/interfaces/ISource.sol";

/// @notice A credit-like funding source for tests: it lends from its own float up to a per-owner limit, holds by
///         booking, pays captures from the float, and takes back at most what each leg captured.
contract StubSource is ISource {
    struct Leg {
        uint128 held;
        uint128 captured;
        uint128 refunded;
    }

    uint8 public constant KIND = 4;
    ICardAuth public immutable PROGRAM;
    address public immutable TOKEN;

    mapping(address owner => uint256) public limitOf;
    mapping(address owner => uint256) public usedOf;
    mapping(address owner => mapping(bytes32 legId => Leg)) public legs;
    mapping(address owner => uint256) public refundedTo;

    error NotProgram();

    modifier onlyProgram() {
        if (msg.sender != address(PROGRAM)) revert NotProgram();
        _;
    }

    constructor(ICardAuth program, address token) {
        (PROGRAM, TOKEN) = (program, token);
    }

    function setLimit(address owner, uint256 limit) external {
        limitOf[owner] = limit;
    }

    function coverable(address owner, bytes32) public view returns (uint256) {
        uint256 used = usedOf[owner];
        return limitOf[owner] > used ? limitOf[owner] - used : 0;
    }

    function held(address owner, bytes32, bytes32 legId) external view returns (uint256) {
        return legs[owner][legId].held;
    }

    function refundable(address owner, bytes32, bytes32 legId) external view returns (uint256) {
        Leg memory l = legs[owner][legId];
        return l.captured - l.refunded;
    }

    function toleranceBps(address, bytes32) external pure returns (uint16) {
        return 0;
    }

    function hold(address owner, bytes32 position, bytes32 legId, uint256 units, uint64, bool)
        external
        onlyProgram
        returns (uint256)
    {
        Leg storage l = legs[owner][legId];
        uint256 most = l.held + coverable(owner, position);
        if (units > most) units = most;
        usedOf[owner] = usedOf[owner] + units - l.held;
        l.held = uint128(units);
        return units;
    }

    function capture(address owner, bytes32, bytes32 legId, uint256 units, uint8 flags)
        external
        onlyProgram
        returns (uint256 taken)
    {
        Leg storage l = legs[owner][legId];
        taken = units < l.held ? units : l.held;
        l.held -= uint128(taken);
        l.captured += uint128(taken);
        if (flags & CAPTURE_FINAL != 0) {
            usedOf[owner] -= l.held;
            l.held = 0;
        }
        if (taken != 0) SafeTransferLib.safeTransfer(TOKEN, PROGRAM.SETTLEMENT_ACCOUNT(), taken);
    }

    function charge(address, bytes32, bytes32, uint256, bool) external view onlyProgram returns (uint256) {
        return 0;
    }

    function release(address owner, bytes32, bytes32 legId) external onlyProgram {
        Leg storage l = legs[owner][legId];
        usedOf[owner] -= l.held;
        l.held = 0;
    }

    function refund(address owner, bytes32, bytes32 legId, uint256 units) external onlyProgram {
        Leg storage l = legs[owner][legId];
        l.refunded += uint128(units);
        usedOf[owner] -= units;
        refundedTo[owner] += units;
    }
}
