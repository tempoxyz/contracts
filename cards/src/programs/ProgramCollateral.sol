// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuardTransient } from "solady/utils/ReentrancyGuardTransient.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CardProgram } from "./CardProgram.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";

/// @title ProgramCollateral
/// @notice Collateral a card program's settlement account pledges to its sponsor, in cash or in savings shares that
///         keep earning. Each deposit is a core pledge whose authority is this contract, so the sponsor releases or
///         seizes it only through here, and never below or beyond the program's live exposure.
/// @dev The settlement account pledges first (`IReservationCore.pledge` with `pledgeId` and this contract as authority), then
///      calls `post`. Value is read from the core's liens and the vault's price, never recorded.
contract ProgramCollateral is ReentrancyGuardTransient {
    using FixedPointMathLib for uint256;

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    uint256 private constant RATE_ONE = 1e18;
    /// @dev Pledges a program keeps at once; each deposit adds one.
    uint256 public constant MAX_PLEDGES = 16;

    /// @notice One program's collateral: who may release it, what it is held in and how many pledges back it.
    struct Position {
        address sponsor;
        address token;
        IEarnVault vault;
        uint32 count;
    }

    mapping(address program => Position) public positionOf;

    event CollateralPosted(address indexed program, address indexed sponsor, bytes32 pledgeId, uint128 units);
    event CollateralReleased(address indexed program, uint256 value, uint256 units);
    event CollateralSeized(address indexed program, address indexed to, uint256 value, uint256 units);

    error NotSettlementAccount();
    error NotSponsor();
    error WrongAsset();
    error WrongSponsor();
    error PledgeMissing(bytes32 pledgeId);
    error TooManyPledges();
    error BelowExposure(uint256 remaining, uint256 exposure);
    error AboveExposure(uint256 value, uint256 exposure);

    /// @notice The id the settlement account pledges its next deposit for `program` under.
    function pledgeId(address program, uint256 n) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), program, n));
    }

    /// @notice Records the settlement account's latest pledge for `program` as collateral held for `sponsor`, in the
    ///         program's settlement token or, with a vault, that vault's shares. A program keeps one sponsor and asset.
    function post(address program, address sponsor, IEarnVault vault) external nonReentrant {
        address account = CardProgram(program).SETTLEMENT_ACCOUNT();
        if (msg.sender != account) revert NotSettlementAccount();
        Position storage pos = positionOf[program];
        address token = address(vault) == address(0) ? CardProgram(program).SETTLEMENT_TOKEN() : vault.earnShare();
        if (pos.count == 0) {
            if (sponsor == address(0)) revert WrongSponsor();
            (pos.sponsor, pos.token, pos.vault) = (sponsor, token, vault);
        } else {
            if (pos.token != token || address(pos.vault) != address(vault)) revert WrongAsset();
            if (pos.sponsor != sponsor) revert WrongSponsor();
        }
        if (pos.count >= MAX_PLEDGES) revert TooManyPledges();
        bytes32 id = pledgeId(program, pos.count + 1);
        (address owner, address liened, uint128 units, uint64 expiresAt, bool pledged) = CORE.lienOf(address(this), id);
        // forge-lint: disable-next-line(block-timestamp)
        if (owner != account || liened != token || !pledged || units == 0 || expiresAt <= block.timestamp) {
            revert PledgeMissing(id);
        }
        ++pos.count;
        emit CollateralPosted(program, sponsor, id, units);
    }

    /// @notice Releases `value` settlement units of `program`'s collateral back to its settlement account, as its
    ///         sponsor, while what stays covers the program's live exposure.
    function release(address program, uint256 value) external nonReentrant {
        Position storage pos = _sponsored(program);
        uint256 current = valueOf(program);
        uint256 remaining = current > value ? current - value : 0;
        uint256 exposure = _exposure(program);
        if (remaining < exposure) revert BelowExposure(remaining, exposure);
        // Released units round down, so what stays is never worth less than the collateral minus the release.
        uint256 units = _unitsDown(pos, program, value);
        _take(pos, program, units, false);
        emit CollateralReleased(program, value, units);
    }

    /// @notice Seizes `value` settlement units of `program`'s collateral to `to`, as its sponsor, up to the
    ///         program's live exposure: the sponsor takes what the program owes, never more.
    function seize(address program, uint256 value, address to) external nonReentrant {
        Position storage pos = _sponsored(program);
        uint256 exposure = _exposure(program);
        if (value > exposure) revert AboveExposure(value, exposure);
        uint256 units = _unitsDown(pos, program, value);
        uint256 seized = _take(pos, program, units, true);
        SafeTransferLib.safeTransfer(pos.token, to, seized);
        emit CollateralSeized(program, to, value, seized);
    }

    /// @notice The live units `program`'s pledges hold, and what they are worth in its settlement units.
    function unitsOf(address program) public view returns (uint256 units) {
        Position storage pos = positionOf[program];
        for (uint256 n = 1; n <= pos.count; ++n) {
            (,, uint128 amount, uint64 expiresAt,) = CORE.lienOf(address(this), pledgeId(program, n));
            // forge-lint: disable-next-line(block-timestamp)
            if (expiresAt > block.timestamp) units += amount;
        }
    }

    /// @notice What `program`'s collateral is worth in settlement units, at the vault's current price for shares.
    function valueOf(address program) public view returns (uint256) {
        Position storage pos = positionOf[program];
        uint256 units = unitsOf(program);
        if (units == 0) return 0;
        if (address(pos.vault) == address(0)) return units;
        uint256 assets = pos.vault.previewRedeem(units);
        address asset = pos.vault.asset();
        CardProgram p = CardProgram(program);
        if (asset == p.SETTLEMENT_TOKEN()) return assets;
        return assets.mulDiv(p.rateOf(asset), RATE_ONE);
    }

    function _sponsored(address program) private view returns (Position storage pos) {
        pos = positionOf[program];
        if (pos.count == 0 || msg.sender != pos.sponsor) revert NotSponsor();
    }

    function _exposure(address program) private view returns (uint256 total) {
        (,,,, total) = CardProgram(program).exposure();
    }

    function _unitsDown(Position storage pos, address program, uint256 value) private view returns (uint256) {
        if (address(pos.vault) == address(0)) return value;
        address asset = pos.vault.asset();
        CardProgram p = CardProgram(program);
        uint256 assets = asset == p.SETTLEMENT_TOKEN() ? value : value.mulDiv(RATE_ONE, p.rateOf(asset));
        uint256 shares = pos.vault.previewWithdraw(assets);
        // previewWithdraw rounds up; step down when that share would redeem for more than the value asked.
        if (shares != 0 && pos.vault.previewRedeem(shares) > assets) --shares;
        return shares;
    }

    /// @dev Frees `units` from the latest pledges first, seizing them to this contract or releasing them to the
    ///      owner, and returns the units moved.
    function _take(Position storage pos, address program, uint256 units, bool seizing) private returns (uint256 moved) {
        for (uint256 n = pos.count; n > 0 && units != 0; --n) {
            bytes32 id = pledgeId(program, n);
            (,, uint128 amount, uint64 expiresAt,) = CORE.lienOf(address(this), id);
            // forge-lint: disable-next-line(block-timestamp)
            if (amount == 0 || expiresAt <= block.timestamp) continue;
            uint128 part = units < amount ? uint128(units) : amount;
            if (seizing) CORE.seizeLien(id, part);
            else if (part == amount) CORE.releaseLien(id);
            else CORE.reduceLien(id, part);
            units -= part;
            moved += part;
        }
    }
}
