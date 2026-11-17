// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import {
    EncryptedDepositPayload,
    IZoneFactory,
    ZONE_FACTORY_ADDRESS,
    ZONE_MESSENGER_ADDRESS,
    ZoneInfo
} from "tempo-earn/interfaces/external/tempo/IZone.sol";
import { SingleZoneEarnRouter } from "tempo-earn/router/SingleZoneEarnRouter.sol";
import { ZoneRouter } from "zone-router/ZoneRouter.sol";
import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";
import { ISpender } from "zone-router/interfaces/ISpender.sol";

import { CardSpend } from "../../src/core/CardSpend.sol";
import { CoreEnv } from "../core/harness/CoreEnv.sol";

contract GasPortal {
    function isTokenEnabled(address) external pure returns (bool) {
        return true;
    }

    function areDepositsActive(address) external pure returns (bool) {
        return true;
    }

    function calculateDepositFee() external pure returns (uint128) {
        return 0;
    }

    function calculateBouncebackFee() external pure returns (uint128) {
        return 0;
    }

    function depositEncrypted(address token, uint128 amount, uint256, EncryptedDepositPayload calldata, address)
        external
        returns (bytes32)
    {
        ITIP20Token(token).transferFrom(msg.sender, address(this), amount);
        return keccak256(abi.encode(token, amount));
    }

    function send(address token, address to, uint256 amount) external {
        ITIP20Token(token).transfer(to, amount);
    }
}

contract GasIdleSpender is ISpender {
    function spendFrom(address, uint256, bytes calldata) external pure {
        revert();
    }
}

/// @notice Zone router callbacks and card program spends on real TIP-20, with and without the one-unit
///         residue the deployment runbook sends, measured with `gasleft` like `EarnTip20Gas`.
contract RouterTip20GasTest is CoreEnv {
    uint32 internal constant ZONE = 7;
    GasPortal internal portal;
    ZoneRouter internal zr;
    bool internal shareResidue;

    function setUp() public {
        _deployCore();
        _deployMockProgram(false);
        portal = new GasPortal();
        vm.etch(ZONE_FACTORY_ADDRESS, hex"00");
        ZoneInfo memory info;
        info.portal = address(portal);
        vm.mockCall(ZONE_FACTORY_ADDRESS, abi.encodeWithSelector(IZoneFactory.zones.selector, ZONE), abi.encode(info));
        vm.mockCall(
            ZONE_FACTORY_ADDRESS,
            abi.encodeWithSelector(IZoneFactory.isZonePortal.selector, address(portal)),
            abi.encode(true)
        );
        usd.mint(address(portal), 1_000_000e6);
        address holder = makeAddr("portal.share-holder");
        usd.mint(holder, 100_000e6);
        usd.mint(alice, 10_000e6);
        uint256 shares = _depositEarn(holder, 100_000e6);
        vm.prank(holder);
        earnShare.transfer(address(portal), shares);
    }

    function _router(bool spends) internal returns (ZoneRouter r) {
        ZoneRouter.Mode memory mode;
        mode.zoneId = ZONE;
        mode.enabledOps = spends ? uint8(7) : uint8(3);
        mode.earnVault = address(earnVault);
        mode.privateAsset = address(usd);
        mode.spenders = new address[](spends ? 1 : 0);
        if (spends) mode.spenders[0] = address(new GasIdleSpender());
        r = ZoneRouter(new ZoneRouterFactory().deploy(mode));
    }

    function _cb(SingleZoneEarnRouter.Flow flow) internal view returns (bytes memory) {
        EncryptedDepositPayload memory e;
        e.ciphertext = hex"01";
        return abi.encode(
            SingleZoneEarnRouter.CallbackData({
                flow: flow,
                minVaultAssets: 1,
                minEarnShares: 1,
                minOutputAmount: 1,
                actionId: bytes32(0),
                zoneReturn: SingleZoneEarnRouter.ZoneReturn({ keyIndex: 0, encrypted: e, refundRecipient: alice })
            })
        );
    }

    /// @dev The Portal's transfer and the messenger's callback run in one withdrawal transaction.
    function _op(ZoneRouter r, address token, uint128 amount, SingleZoneEarnRouter.Flow flow)
        internal
        returns (uint256 used)
    {
        bytes memory data = _cb(flow);
        uint256 before = gasleft();
        portal.send(token, address(r), amount);
        vm.prank(ZONE_MESSENGER_ADDRESS);
        r.onWithdrawalReceived(ZONE, address(portal), bytes32(0), token, amount, data);
        used = before - gasleft();
    }

    function _measureRouter(bool spends, bool residue, bool warm, string memory name) internal {
        zr = _router(spends);
        if (residue) {
            // Base asset only: EarnShare left here could never be redeemed, so supply could never return to zero.
            usd.mint(address(zr), 1);
            if (shareResidue) {
                vm.prank(address(portal));
                earnShare.transfer(address(zr), 1);
            }
        }
        if (warm) {
            zr.warm(address(usd));
            zr.warm(address(earnShare));
        }
        // First op sets the standing EarnVault approvals; measure the second, a steady-state call.
        _op(zr, address(usd), 100e6, SingleZoneEarnRouter.Flow.Deposit);
        _op(zr, address(earnShare), 50e6, SingleZoneEarnRouter.Flow.Redeem);
        uint256 dep = _op(zr, address(usd), 100e6, SingleZoneEarnRouter.Flow.Deposit);
        uint256 red = _op(zr, address(earnShare), 50e6, SingleZoneEarnRouter.Flow.Redeem);
        vm.snapshotValue("router-tip20", string.concat(name, ".deposit"), dep);
        vm.snapshotValue("router-tip20", string.concat(name, ".redeem"), red);
    }

    function test_gasEarnOnlyRouter() public {
        _measureRouter(false, false, false, "earn-only");
    }

    function test_gasEarnOnlyRouterResidue() public {
        _measureRouter(false, true, false, "earn-only.residue");
    }

    function test_gasSpendRouterWarm() public {
        _measureRouter(true, false, true, "spend.warm");
    }

    function test_gasSpendRouterWarmResidue() public {
        _measureRouter(true, true, true, "spend.warm.residue");
    }

    function test_gasEarnOnlyRouterAllResidue() public {
        _seedVault();
        _measureRouter(false, true, false, "earn-only.residue.vault-residue");
    }

    function test_gasSpendRouterWarmAllResidue() public {
        _seedVault();
        _measureRouter(true, true, true, "spend.warm.residue.vault-residue");
    }

    function test_gasCardEarnSpendAllResidue() public {
        _seedVault();
        _measureCard(true, true, "card.earn-spend.residue.vault-residue");
    }

    function test_gasEarnOnlyRouterShareResidue() public {
        _seedVaultShares();
        _measureRouter(false, true, false, "earn-only.share-residue");
    }

    function test_gasSpendRouterWarmShareResidue() public {
        _seedVaultShares();
        _measureRouter(true, true, true, "spend.warm.share-residue");
    }

    function test_gasCardEarnSpendShareResidue() public {
        _seedVaultShares();
        _measureCard(true, true, "card.earn-spend.share-residue");
    }

    /// @dev Base-asset residue plus one EarnShare unit with the vault, router and program.
    function _seedVaultShares() internal {
        _seedVault();
        shareResidue = true;
        vm.prank(address(portal));
        earnShare.transfer(address(earnVault), 1);
    }

    /// @dev The deployment runbook's residue: one base unit with the EarnVault and its ERC-4626 engine.
    function _seedVault() internal {
        usd.mint(address(earnVault), 1);
        usd.mint(earnVault.engine(), 1);
    }

    function _measureCard(bool residue, bool fromVault, string memory name) internal {
        usd.mint(router, 1_000_000e6);
        _depositEarn(alice, 10_000e6);
        if (residue) {
            usd.mint(address(program), 1);
            if (shareResidue) {
                vm.prank(alice);
                earnShare.transfer(address(program), 1);
            }
        }
        CardSpend memory s = fromVault
            ? _earnSpend(pooledWallet, 0, 100e6, 100e6, bytes32(uint256(1)))
            : _stableSpend(pooledWallet, 0, 100e6, bytes32(uint256(1)));
        uint256 before;
        if (fromVault) {
            vm.startPrank(alice);
            earnShare.approve(address(program), type(uint256).max);
            vm.stopPrank();
            before = gasleft();
            vm.prank(alice);
            program.spend(s);
        } else {
            before = gasleft();
            _routerSpend(address(usd), 100e6, s);
        }
        vm.snapshotValue("router-tip20", name, before - gasleft());
    }

    function test_gasCardRouterSpend() public {
        _measureCard(false, false, "card.router-spend");
    }

    function test_gasCardRouterSpendResidue() public {
        _measureCard(true, false, "card.router-spend.residue");
    }

    function test_gasCardEarnSpend() public {
        _measureCard(false, true, "card.earn-spend");
    }

    function test_gasCardEarnSpendResidue() public {
        _measureCard(true, true, "card.earn-spend.residue");
    }
}
