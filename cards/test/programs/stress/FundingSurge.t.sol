// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FundingBase } from "./FundingBase.sol";

/// @notice Refund and dispute surge: a week of ordinary card spend, then on Monday one merchant shuts down and every
///         purchase at it is disputed, while the other merchants refund a tenth of theirs, about a quarter of the
///         week's volume at once. The issuer credits cardholders provisionally, pledges the shut merchant's dispute
///         reserve, and resolves the disputes over the following days (most for the cardholder, some against, and
///         some of those cardholders have moved their money out). The network settles the net each business day in
///         both directions. Every step checks conservation, custody, each holder's bound, that the merchant never
///         loses more than the reserve it consented to and that the desk and reserves keep no tokens.
contract FundingSurgeStressTest is FundingBase {
    address internal network = makeAddr("network");
    address internal elsewhere = makeAddr("elsewhere");
    address internal bank = makeAddr("issuer.bank");
    uint256 internal buffer;

    struct Buy {
        bytes32 ref;
        uint32 holder;
        uint32 dueHour;
        uint32 resolveHour;
        uint8 state;
        uint128 amount;
        uint128 reserved;
    }

    struct Stats {
        uint256 weekVolume;
        uint256 disputes;
        uint256 disputeVolume;
        uint256 refunds;
        uint256 refundVolume;
        uint256 provisional;
        uint256 reservePledged;
        uint256 reserveCollected;
        uint256 chargeback;
        uint256 won;
        uint256 lost;
        uint256 lostVolume;
        uint256 recoveredFromHolders;
        uint256 receivablesRecorded;
        uint256 movedOut;
        uint256 networkPaidIn;
        uint256 networkPaidBack;
        uint256 maxOutlay;
        uint256 maxIssuerDebt;
        uint256 advanced;
        uint256 receivablesCollected;
        uint256 negativeNetDays;
        uint256 maxNegativeNet;
        uint256 declined;
        uint256 creditFailures;
        uint256 shortfalls;
        uint256 maxShortfall;
        uint256 refundFailures;
        uint256 waitingMax;
        uint256 waitingMaxUsd;
        uint256 waitMaxHours;
    }

    Buy[] internal buys;
    uint256[] internal pending;
    Stats internal s;
    mapping(address holder => uint256) internal moved;

    uint256 internal n;
    uint256 internal fundsTarget;
    uint128 internal reserveCap;
    uint128 internal reserveLeft;
    int256 internal outlay;
    /// @dev What refunds and charged-back disputes have the network owe the issuer since the last settlement.
    uint256 internal networkOwes;

    uint256 internal constant SURGE_HOUR = 7 * 24 + 9;
    /// @dev Purchase states: 1 captured, 2 disputed and credited, 3 refunded, 4 resolved, 5 disputed and waiting for
    ///      its provisional credit, 6 waiting for its refund, 9 released.
    uint8 internal constant WAIT_CREDIT = 5;
    uint8 internal constant WAIT_REFUND = 6;
    uint256 internal constant DAYS = 14;

    function _setUp(uint256 bufferPerHolder) internal {
        vm.pauseGasMetering();
        n = 60 * _scale();
        rng = 0x5e9e;
        tolBps = 2000;
        _world(uint128(n * 5000e6));
        fundsTarget = n * 50e6;
        parties.push(network);
        parties.push(elsewhere);
        vm.startPrank(settlement);
        core.approveHolder(address(treasury), address(usd), type(uint128).max, 0);
        core.approveHolder(address(reserves), address(usd), type(uint128).max, 0);
        vm.stopPrank();
        _setDebtCap(settlement, address(treasury), address(usd), type(uint64).max);
        vm.prank(issuer);
        usd.approve(address(treasury), type(uint256).max);
        for (uint256 i; i < n; ++i) {
            address h = _holder(i, 300e6 + _rand(2700e6), _cashOnly());
            _setDebtCap(h, address(cash), address(usd), 100e6);
            _setTolerance(h, address(cash), address(usd), uint16(tolBps));
            vm.prank(h);
            core.approveHolder(address(desk), address(usd), type(uint128).max, 0);
        }
        // The merchant that shuts down keeps a dispute reserve of about 5% of a week's sales there.
        reserveCap = uint128(n * 12e6);
        reserveLeft = reserveCap;
        address shop = merchants[0];
        _mint(shop, reserveCap);
        vm.startPrank(shop);
        core.approveHolder(address(reserves), address(usd), reserveCap, 0);
        reserves.allowReserves(address(usd), reserveCap, bytes32("disputes"));
        reserves.setDisputeReserves(true);
        vm.stopPrank();
        _mint(network, n * 1000e6);
        buffer = n * bufferPerHolder;
        _mint(settlement, buffer);
        _mint(bank, n * 10_000e6);
        parties.push(bank);
        _topUp();
        _seal();
    }

    /// @dev The settlement account holds $200 per holder, more than the surge pays out.
    function test_stress_refundAndDisputeSurge() public {
        _setUp(200e6);
        tag = "surge";
        _run();
    }

    /// @dev The settlement account holds $20 per holder: the provisional credits and refunds run on treasury advances.
    function test_stress_refundAndDisputeSurge_thinSettlementAccount() public {
        _setUp(20e6);
        tag = "surge_thin_account";
        _run();
    }

    function _run() internal {
        vm.pauseGasMetering();
        for (uint256 hr; hr < DAYS * 24; ++hr) {
            this.step(hr);
        }
        _drain(DAYS * 24);
        _report();
    }

    /// @dev One simulated hour, as its own call so memory does not grow across the run.
    function step(uint256 hr) external {
        require(msg.sender == address(this));
        _hour(hr);
    }

    function _hour(uint256 hr) internal {
        uint256 t = START + hr * HOUR;
        vm.warp(t);
        uint256 hour = hr % 24;
        uint256 wd = _weekday(t);
        bool weekend = wd == 0 || wd == 6;
        if (hour == 9 && !weekend) {
            _topUp();
            _refill();
        }
        if (hr == SURGE_HOUR) _surge(hr);
        if (hr > SURGE_HOUR) _retryWaiting();
        if (hour == 10 && !weekend) _settleNetwork();
        _captureDue(hr);
        _resolveDue(hr);
        // Spend continues at other merchants after the shutdown.
        uint256 rate = _curve(hour, weekend) * n;
        uint256 count = rate / 100 + (_rand(100) < rate % 100 ? 1 : 0);
        for (uint256 k; k < count; ++k) {
            vm.warp(t + (k + 1) * HOUR / (count + 1));
            _swipe(hr);
        }
        _observe();
    }

    function _swipe(uint256 hr) internal {
        uint256 i = _rand(n);
        bytes32 ref = keccak256(abi.encode("buy", buys.length));
        // After the shutdown nobody can buy from the closed merchant.
        if (hr >= SURGE_HOUR && uint256(ref) % merchants.length == 0) return;
        uint128 amount = _ticket();
        (uint256 approved,,) = _try(holders[i], cardIds[i], ref, amount, 0);
        if (approved == 0) {
            ++s.declined;
            return;
        }
        buys.push(Buy(ref, uint32(i), uint32(hr + 1 + _rand(30)), 0, 0, uint128(approved), 0));
        pending.push(buys.length - 1);
        _checkAll();
    }

    /// @dev 60% $5-40, 30% $40-150, 10% $150-600.
    function _ticket() internal returns (uint128) {
        uint256 r = _rand(100);
        if (r < 60) return uint128(5e6 + _rand(35e6));
        if (r < 90) return uint128(40e6 + _rand(110e6));
        return uint128(150e6 + _rand(450e6));
    }

    function _captureDue(uint256 hr) internal {
        for (uint256 j; j < pending.length;) {
            Buy storage b = buys[pending[j]];
            if (b.dueHour > hr) {
                ++j;
                continue;
            }
            address h = holders[b.holder];
            (bool ok, uint256 covered,) = _book(h, b.ref, b.amount);
            if (!ok) _releaseBuy(h, b.ref);
            else if (hr < SURGE_HOUR) s.weekVolume += covered;
            b.state = ok ? 1 : 9;
            pending[j] = pending[pending.length - 1];
            pending.pop();
            _checkAll();
        }
    }

    /// @dev Every captured purchase at the closed merchant is disputed in full with provisional credit and covered
    ///      by its reserve while the reserve lasts; a tenth of the other captured purchases are refunded.
    function _surge(uint256 hr) internal {
        uint64 expiry = uint64(block.timestamp + 60 days);
        for (uint256 j; j < buys.length; ++j) {
            Buy storage b = buys[j];
            if (b.state != 1) continue;
            uint128 open = uint128(_paid(b.ref));
            if (open == 0) continue;
            address h = holders[b.holder];
            uint256 before = _worth(b.ref);
            int256 net0 = _net();
            if (uint256(b.ref) % merchants.length == 0) {
                vm.prank(issuer);
                desk.openDispute(b.ref, open, "merchant closed");
                ++s.disputes;
                s.disputeVolume += open;
                b.dueHour = uint32(hr);
                uint128 cover = open < reserveLeft ? open : reserveLeft;
                if (cover != 0) {
                    vm.prank(issuer);
                    reserves.reserveDispute(
                        merchants[0], address(usd), b.ref, [cover, uint128(0)], [cover, uint128(0)], expiry
                    );
                    reserveLeft -= cover;
                    s.reservePledged += cover;
                }
                b.reserved = cover;
                b.state = WAIT_CREDIT;
                // Three to twelve days to resolve.
                b.resolveHour = uint32(hr + 72 + _rand(216));
                // One in eight disputing holders will move their money out right after the credit.
                if (_rand(8) == 0) b.amount |= uint128(1) << 127;
                _credit(b);
            } else if (_rand(10) == 0) {
                ++s.refunds;
                s.refundVolume += open;
                b.dueHour = uint32(hr);
                b.state = WAIT_REFUND;
                _refundBuy(b);
                // _refundBuy books its own changes.
                (before, net0) = (_worth(b.ref), _net());
            }
            _owesSince(net0);
            costCap[h] = costCap[h] + _worth(b.ref) - before;
            _checkAll();
        }
    }

    /// @dev Gives a waiting dispute its provisional credit; false while the issuer cannot fund it.
    function _credit(Buy storage b) internal returns (bool) {
        uint128 open = uint128(_paid(b.ref));
        uint8 step_ = desk.PROVISIONAL_CREDIT();
        vm.prank(issuer);
        try desk.disputeStep(b.ref, step_, open, "", false) { }
        catch {
            ++s.creditFailures;
            return false;
        }
        s.provisional += open;
        outlay += int256(uint256(open));
        b.state = 2;
        _waited(b);
        if (b.amount >> 127 != 0) _moveOut(holders[b.holder]);
        return true;
    }

    /// @dev Refunds a waiting purchase in full; false while the issuer cannot fund it.
    function _refundBuy(Buy storage b) internal returns (bool) {
        address h = holders[b.holder];
        uint256 before = _worth(b.ref);
        int256 net0 = _net();
        uint128 open = uint128(_paid(b.ref));
        vm.prank(issuer);
        try desk.refund(b.ref, open) { }
        catch {
            ++s.refundFailures;
            return false;
        }
        outlay += int256(uint256(open));
        _owesSince(net0);
        costCap[h] = costCap[h] + _worth(b.ref) - before;
        b.state = 3;
        _waited(b);
        return true;
    }

    function _waited(Buy storage b) internal {
        uint256 waited = (block.timestamp - START) / HOUR - b.dueHour;
        if (waited > s.waitMaxHours) s.waitMaxHours = waited;
    }

    /// @dev Retries every credit and refund still waiting, and tracks the backlog.
    function _retryWaiting() internal {
        uint256 count;
        uint256 usd_;
        for (uint256 j; j < buys.length; ++j) {
            Buy storage b = buys[j];
            if (b.state != WAIT_CREDIT && b.state != WAIT_REFUND) continue;
            bool done = b.state == WAIT_CREDIT ? _credit(b) : _refundBuy(b);
            if (!done) {
                ++count;
                usd_ += _paid(b.ref);
            }
            _checkAll();
        }
        if (count > s.waitingMax) (s.waitingMax, s.waitingMaxUsd) = (count, usd_);
    }

    function _net() internal view returns (int256 net) {
        (,, net,) = cards.ledger();
    }

    /// @dev Books the drop in the ledger's net since "before" as owed by the network.
    function _owesSince(int256 before) internal {
        int256 now_ = _net();
        if (now_ < before) networkOwes += uint256(before - now_);
    }

    function _moveOut(address h) internal {
        uint256 free = core.available(h, address(usd));
        if (free == 0) return;
        vm.prank(h);
        usd.transfer(elsewhere, free);
        moved[h] += free;
        s.movedOut += free;
    }

    /// @dev 85% of disputes go the cardholder's way: the reserve is collected first and the network charges the
    ///      rest back. The others go against the cardholder: the reserve is released and the credit recovered.
    function _resolveDue(uint256 hr) internal {
        for (uint256 j; j < buys.length; ++j) {
            Buy storage b = buys[j];
            if (b.state != 2 || b.resolveHour > hr) continue;
            address h = holders[b.holder];
            uint256 before = _worth(b.ref);
            int256 net0 = _net();
            bool wins = uint256(keccak256(abi.encode(b.ref, "outcome"))) % 100 < 85;
            bytes32 id = reserves.reserveId(b.ref, merchants[0]);
            uint128 open = uint128(_paid(b.ref));
            if (wins) {
                if (b.reserved != 0) {
                    vm.startPrank(issuer);
                    reserves.collectReserve(id, b.reserved);
                    desk.collectedReserve(b.ref, b.reserved);
                    vm.stopPrank();
                    s.reserveCollected += b.reserved;
                    outlay -= int256(uint256(b.reserved));
                }
                vm.prank(issuer);
                desk.resolveDispute(b.ref, true);
                ++s.won;
                s.chargeback += open - b.reserved;
            } else {
                if (b.reserved != 0) {
                    vm.prank(issuer);
                    reserves.releaseReserve(id);
                }
                uint256 owedBefore = desk.receivables(h, address(usd));
                uint256 costBefore = _lossOf(h);
                vm.prank(issuer);
                desk.resolveDispute(b.ref, false);
                ++s.lost;
                s.lostVolume += open;
                uint256 recorded = desk.receivables(h, address(usd)) - owedBefore;
                s.receivablesRecorded += recorded;
                uint256 recovered = _lossOf(h) - costBefore - recorded;
                s.recoveredFromHolders += recovered;
                outlay -= int256(recovered);
            }
            _owesSince(net0);
            costCap[h] = costCap[h] + _worth(b.ref) - before;
            b.state = 4;
            _checkAll();
        }
    }

    /// @dev The issuer refills its treasury funds each business morning.
    function _topUp() internal {
        uint256 have = treasury.issuerFunds(address(usd));
        if (have >= fundsTarget) return;
        uint256 need = fundsTarget - have;
        _mint(issuer, need);
        vm.prank(issuer);
        treasury.fundIssuerDebt(address(usd), need);
    }

    /// @dev Each business morning the bank sends what the network will be owed today, plus the buffer.
    function _refill() internal {
        uint256 want = _unsettled() + buffer;
        uint256 free = core.available(settlement, address(usd));
        if (free >= want) return;
        vm.prank(bank);
        usd.transfer(settlement, want - free);
        core.notifyCredit(address(usd), settlement, want - free);
        _checkAll();
    }

    /// @dev The network settles the net since the last settlement in whichever direction it runs, and the sponsor
    ///      acknowledges the live sequence.
    function _settleNetwork() internal {
        (uint64 seq, uint64 through, int128 net, int128 settledNet) = cards.ledger();
        if (seq == through) return;
        int256 delta = int256(net) - int256(settledNet);
        if (delta > 0) {
            uint256 can = core.available(settlement, address(usd)) + treasury.issuerFunds(address(usd));
            if (uint256(delta) > can) {
                // The surge spent the money meant for the network: settle on the next business day.
                ++s.shortfalls;
                if (uint256(delta) - can > s.maxShortfall) s.maxShortfall = uint256(delta) - can;
                return;
            }
            vm.prank(issuer);
            s.advanced += treasury.payOut(network, uint256(delta), bytes32("network"));
            s.networkPaidIn += uint256(delta);
        } else if (delta < 0) {
            uint256 back = uint256(-delta);
            vm.prank(network);
            usd.transfer(settlement, back);
            core.notifyCredit(address(usd), settlement, back);
            s.networkPaidBack += back;
            ++s.negativeNetDays;
            if (back > s.maxNegativeNet) s.maxNegativeNet = back;
        }
        vm.prank(sponsor);
        treasury.acknowledgeSettlement(seq, 0);
        // Whether paid back or netted against new captures, the network has now settled what it owed.
        outlay -= int256(networkOwes);
        networkOwes = 0;
        _checkAll();
    }

    function _observe() internal {
        if (outlay > 0 && uint256(outlay) > s.maxOutlay) s.maxOutlay = uint256(outlay);
        uint256 d = _issuerDebt();
        if (d > s.maxIssuerDebt) s.maxIssuerDebt = d;
    }

    function _drain(uint256 hr) internal {
        vm.warp(START + hr * HOUR);
        for (uint256 j; j < pending.length; ++j) {
            Buy storage b = buys[pending[j]];
            address h = holders[b.holder];
            (bool ok,,) = _book(h, b.ref, b.amount);
            if (!ok) _releaseBuy(h, b.ref);
        }
        delete pending;
        // Fund whatever still waits, then resolve whatever is still open as of today.
        _topUp();
        _refill();
        _retryWaiting();
        _resolveDue(type(uint32).max);
        vm.warp(START + hr * HOUR + 1 days);
        _refill();
        _settleNetwork();
        assertEq(desk.openDisputes(), 0, "disputes left open");
        (uint256 held,,) = cards.exposure();
        assertEq(held, 0, "holds left open");
        assertEq(_unsettled(), 0, "unsettled left");
        for (uint256 j; j < buys.length; ++j) {
            assertFalse(cards.purchaseOf(buys[j].ref).open, "purchase left open");
        }
        // Every won dispute is paid by the reserve or charged back, and the merchant lost exactly what was collected.
        assertEq(s.reserveCollected + s.chargeback + s.lostVolume, s.disputeVolume, "dispute volume unaccounted");
        assertEq(mintedTo[merchants[0]] - usd.balanceOf(merchants[0]), s.reserveCollected, "merchant loss");
        // What the issuer is still out is exactly the receivables it has not collected.
        assertApproxEqAbs(uint256(outlay), s.receivablesRecorded, n, "outlay is not the receivables");
        _checkAll();
        _logUsd("issuer_outlay_before_collection", outlay > 0 ? uint256(outlay) : 0);
        // Next payday, the issuer collects receivables from whoever has funds again.
        for (uint256 i; i < n; ++i) {
            address h = holders[i];
            uint256 owed = desk.receivables(h, address(usd));
            if (owed == 0) continue;
            _payday(h, 500e6);
            uint256 free = core.available(h, address(usd));
            uint128 take = uint128(owed < free ? owed : free);
            if (take == 0) continue;
            vm.prank(issuer);
            desk.collectReceivable(h, address(usd), take);
            s.receivablesCollected += take;
            outlay -= int256(uint256(take));
            _checkAll();
        }
    }

    // Checks.

    function _lossOf(address h) internal view returns (uint256) {
        return mintedTo[h] - usd.balanceOf(h) - moved[h] + _owed(h, address(usd), address(cash))
            + desk.receivables(h, address(usd));
    }

    function _checkAll() internal view {
        _checkLedger();
        assertEq(usd.balanceOf(address(desk)), 0, "desk kept tokens");
        assertEq(usd.balanceOf(address(reserves)), 0, "reserves kept tokens");
        // The closed merchant never loses more than the reserve it consented to.
        assertLe(mintedTo[merchants[0]] - usd.balanceOf(merchants[0]), reserveCap, "merchant past its reserve");
        for (uint256 i; i < n; ++i) {
            address h = holders[i];
            uint256 cost = _lossOf(h);
            assertLe(cost, costCap[h], "holder paid past captured plus held");
            assertLe(cost, authorized[h] * (10_000 + tolBps) / 10_000, "holder paid past authorized");
        }
        assertGe(usd.balanceOf(address(treasury)), treasury.issuerFunds(address(usd)), "treasury short");
    }

    function _report() internal view {
        _log("holders", n);
        _logUsd("week_volume", s.weekVolume);
        _log("disputes", s.disputes);
        _logUsd("dispute_volume", s.disputeVolume);
        _log("refunds", s.refunds);
        _logUsd("refund_volume", s.refundVolume);
        _log(
            "surge_share_of_week_bps",
            s.weekVolume == 0 ? 0 : (s.disputeVolume + s.refundVolume) * 10_000 / s.weekVolume
        );
        _logUsd("provisional_credit", s.provisional);
        _logUsd("merchant_reserve", reserveCap);
        _logUsd("reserve_pledged", s.reservePledged);
        _logUsd("reserve_collected_merchant_loss", s.reserveCollected);
        _logUsd("charged_back_to_acquirer", s.chargeback);
        _log("disputes_won_by_holder", s.won);
        _log("disputes_lost_by_holder", s.lost);
        _logUsd("lost_volume", s.lostVolume);
        _logUsd("recovered_from_holders", s.recoveredFromHolders);
        _logUsd("receivables_recorded", s.receivablesRecorded);
        _logUsd("receivables_collected_next_payday", s.receivablesCollected);
        _logUsd("moved_out_by_holders", s.movedOut);
        _logUsd("issuer_peak_outlay", s.maxOutlay);
        _logUsd("issuer_end_outlay", outlay > 0 ? uint256(outlay) : 0);
        _logUsd("max_issuer_debt", s.maxIssuerDebt);
        _logUsd("treasury_advanced", s.advanced);
        _log("negative_net_settlements", s.negativeNetDays);
        _logUsd("max_network_paid_back", s.maxNegativeNet);
        _logUsd("network_paid_in", s.networkPaidIn);
        _logUsd("network_paid_back", s.networkPaidBack);
        _log("declined", s.declined);
        _log("network_settlement_shortfalls", s.shortfalls);
        _logUsd("network_max_shortfall", s.maxShortfall);
        _log("credit_attempts_refused", s.creditFailures);
        _log("refund_attempts_refused", s.refundFailures);
        _log("waiting_max", s.waitingMax);
        _logUsd("waiting_max", s.waitingMaxUsd);
        _log("wait_max_h", s.waitMaxHours);
    }
}
