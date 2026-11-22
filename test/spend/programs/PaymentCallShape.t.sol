// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardAuth } from "../../../src/spend/programs/CardAuth.sol";
import { CardAuthAdmin } from "../../../src/spend/programs/CardAuthAdmin.sol";
import { CardLegs } from "../../../src/spend/programs/CardLegs.sol";
import { Conversion } from "../../../src/spend/programs/Conversion.sol";
import { ICardAuth } from "../../../src/interfaces/spend/programs/ICardAuth.sol";
import { ISource } from "../../../src/interfaces/spend/programs/ISource.sol";
import { FixedPricePool } from "./venues/FixedPricePool.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";
import { Rates } from "./harness/Rates.sol";

/// @notice What a node-side registry of payment calls reads from CardAuth's code: the byte ranges its immutables take
///         (zeroed, every deployment shares one code hash), the libraries it links (kept, so that hash also names
///         them), code that never changes and runs no foreign code in its context but the CardAuthAdmin it pins by code
///         hash and those libraries, and the selectors and static-only calldata of its payment calls.
contract PaymentCallCodeTest is Test {
    /// @dev One entry of a compiler artifact's immutableReferences, its fields in the order JSON decoding sorts them.
    struct Range {
        uint256 length;
        uint256 start;
    }

    /// @dev The compiler's CBOR metadata: a map of an ipfs hash and the compiler version, then its length.
    bytes8 internal constant METADATA_HEAD = hex"a264697066735822";
    uint256 internal constant METADATA_LENGTH = 52;
    uint8 internal constant CALLCODE = 0xf2;
    uint8 internal constant DELEGATECALL = 0xf4;
    uint8 internal constant SELFDESTRUCT = 0xff;

    bytes4 internal constant AUTHORIZE = 0xca89e414;
    bytes4 internal constant CAPTURE = 0x0971ede5;
    bytes4 internal constant CHARGE = 0xbf97396e;
    bytes4 internal constant RELEASE = 0x67d42a8b;
    bytes4 internal constant ADJUST = 0xf5f66924;
    bytes4 internal constant REFUND = 0x1bc85bf3;

    /// @notice Two programs with different issuers, settlement accounts and settlement tokens over one admin, and a
    ///         third over another admin, differ only inside the ranges the artifact lists for ADMIN and
    ///         SETTLEMENT_ACCOUNT, and hash alike once those ranges are zeroed.
    function test_immutableRanges_maskEveryDeploymentToOneHash() public {
        CardAuthAdmin admin = new CardAuthAdmin();
        CardAuth a = new CardAuth(makeAddr("issuer.a"), makeAddr("settlement.a"), makeAddr("token.a"), address(admin));
        CardAuth b = new CardAuth(makeAddr("issuer.b"), makeAddr("settlement.b"), makeAddr("token.b"), address(admin));
        CardAuth c = new CardAuth(
            makeAddr("issuer.b"), makeAddr("settlement.b"), makeAddr("token.b"), address(new CardAuthAdmin())
        );
        string memory json = _artifact("CardAuth");
        (Range[] memory ranges, uint256 immutables) = _ranges(json, ".deployedBytecode.immutableReferences");
        assertEq(immutables, 2, "CardAuth has two immutables");
        assertEq(ranges.length, 4, "each immutable is read in two places");
        _assertRangesHold(address(a), ranges);
        _assertRangesHold(address(c), ranges);

        bytes memory codeA = address(a).code;
        assertEq(address(b).code.length, codeA.length);
        assertEq(address(c).code.length, codeA.length);
        assertTrue(keccak256(codeA) != keccak256(address(b).code), "settlement accounts differ");
        assertTrue(keccak256(address(b).code) != keccak256(address(c).code), "admins differ");
        _assertDiffersOnlyWithin(codeA, address(b).code, ranges);
        _assertDiffersOnlyWithin(codeA, address(c).code, ranges);

        bytes32 masked = keccak256(_mask(codeA, ranges));
        assertEq(keccak256(_mask(address(b).code, ranges)), masked);
        assertEq(keccak256(_mask(address(c).code, ranges)), masked);
        // The artifact's runtime code carries zeros where the immutables go, so masking an instance gives it back.
        assertEq(keccak256(vm.getDeployedCode("CardAuth.sol:CardAuth")), masked, "artifact code is the masked code");
    }

    /// @notice CardAuth and CardAuthAdmin link the same CardLegs and CardLimits deployments, at ranges outside the
    ///         immutables, so the masked code hash names those libraries: an instance linked against other library code
    ///         hashes differently.
    function test_linkedLibraries_sharedAndOutsideTheMask() public {
        CardAuthAdmin admin = new CardAuthAdmin();
        CardAuth program = new CardAuth(address(1), address(2), address(3), address(admin));
        string memory json = _artifact("CardAuth");
        (Range[] memory immutables,) = _ranges(json, ".deployedBytecode.immutableReferences");
        (address legs, address limits) = _libraries(address(program).code, json);
        (address adminLegs, address adminLimits) = _libraries(address(admin).code, _artifact("CardAuthAdmin"));
        assertEq(adminLegs, legs, "admin links CardAuth's CardLegs");
        assertEq(adminLimits, limits, "admin links CardAuth's CardLimits");
        (Range[] memory links,) = _ranges(json, ".deployedBytecode.linkReferences['src/spend/programs/CardLegs.sol']");
        _assertDisjoint(links, immutables);
        (links,) = _ranges(json, ".deployedBytecode.linkReferences['src/spend/programs/CardLimits.sol']");
        _assertDisjoint(links, immutables);
    }

    /// @notice Neither CardAuth, the CardAuthAdmin it runs by delegatecall, nor the libraries both link hold
    ///         SELFDESTRUCT or CALLCODE, and the libraries hold no DELEGATECALL: CardAuth's code never changes, and
    ///         what runs in its context is the admin, whose code hash its constructor checks, and the libraries its
    ///         masked code names (the admin's own DELEGATECALLs are its calls into those same libraries).
    function test_runtime_neverChangesOrBorrowsCode() public {
        CardAuthAdmin admin = new CardAuthAdmin();
        bytes memory auth = address(new CardAuth(address(1), address(2), address(3), address(admin))).code;
        assertFalse(_holds(auth, SELFDESTRUCT), "CardAuth holds SELFDESTRUCT");
        assertFalse(_holds(auth, CALLCODE), "CardAuth holds CALLCODE");
        assertTrue(_holds(auth, DELEGATECALL), "CardAuth runs its admin and libraries by DELEGATECALL");
        assertFalse(_holds(address(admin).code, SELFDESTRUCT), "CardAuthAdmin holds SELFDESTRUCT");
        assertFalse(_holds(address(admin).code, CALLCODE), "CardAuthAdmin holds CALLCODE");
        (address legs, address limits) = _libraries(auth, _artifact("CardAuth"));
        address[2] memory libraries = [legs, limits];
        for (uint256 i; i < libraries.length; ++i) {
            bytes memory code = libraries[i].code;
            assertGt(code.length, 0, "library deployed");
            assertFalse(_holds(code, SELFDESTRUCT), "library holds SELFDESTRUCT");
            assertFalse(_holds(code, CALLCODE), "library holds CALLCODE");
            assertFalse(_holds(code, DELEGATECALL), "library holds DELEGATECALL");
        }
    }

    /// @notice CardAuth passes the registry's template checks over its whole deployed code, metadata tail included:
    ///         it does not start with 0xEF, holds no SELFDESTRUCT anywhere in the instruction stream outside push data,
    ///         and every immutable range lies inside one push's data, so zeroed bytes never run as instructions.
    function test_template_wholeCodeChecks() public {
        bytes memory code = address(new CardAuth(address(1), address(2), address(3), address(new CardAuthAdmin()))).code;
        assertTrue(code[0] != 0xef, "code starts with 0xEF");
        (Range[] memory ranges,) = _ranges(_artifact("CardAuth"), ".deployedBytecode.immutableReferences");
        bool[] memory inside = new bool[](ranges.length);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            assertTrue(op != SELFDESTRUCT, "SELFDESTRUCT in the instruction stream");
            if (op < 0x60 || op > 0x7f) continue;
            uint256 dataEnd = i + 1 + (op - 0x5f);
            for (uint256 j; j < ranges.length; ++j) {
                if (ranges[j].start > i && ranges[j].start + ranges[j].length <= dataEnd) inside[j] = true;
            }
            i = dataEnd - 1;
        }
        for (uint256 j; j < ranges.length; ++j) {
            assertTrue(inside[j], "immutable range outside push data");
        }
    }

    /// @notice The scan finds an opcode, and skips push data and embedded CBOR metadata that carry its byte.
    function test_opcodeScan_skipsPushDataAndMetadata() public pure {
        assertTrue(_holds(hex"6000ff", SELFDESTRUCT));
        assertFalse(_holds(bytes.concat(hex"7f", bytes32(type(uint256).max), hex"00"), SELFDESTRUCT));
        bytes memory metadata = bytes.concat(METADATA_HEAD, bytes32(type(uint256).max), bytes12(type(uint96).max));
        bytes memory code = bytes.concat(hex"00", metadata, hex"0034", hex"00", metadata, hex"0034");
        assertFalse(_holds(code, SELFDESTRUCT));
        assertTrue(_holds(bytes.concat(hex"ff", code), SELFDESTRUCT));
    }

    /// @notice The payment calls keep their selectors and take only static arguments: calldata is the selector and one
    ///         word per argument, whatever the values.
    function test_paymentSelectors_staticCalldata() public pure {
        bytes32 id = bytes32(type(uint256).max);
        uint128 amount = type(uint128).max;
        address who = address(type(uint160).max);
        _assertCall(abi.encodeCall(CardAuth.authorize, (id, id, amount, who, type(uint64).max, 3)), AUTHORIZE, 6);
        _assertCall(abi.encodeCall(CardAuth.capture, (id, amount, true)), CAPTURE, 3);
        _assertCall(abi.encodeCall(CardAuth.charge, (id, id, amount, who)), CHARGE, 4);
        _assertCall(abi.encodeCall(CardAuth.release, (id)), RELEASE, 1);
        _assertCall(abi.encodeCall(CardAuth.adjust, (id, amount)), ADJUST, 2);
        _assertCall(abi.encodeCall(CardAuth.refund, (id, amount)), REFUND, 2);
        _assertCall(abi.encodeCall(CardAuth.authorize, (0, 0, 0, address(0), 0, 0)), AUTHORIZE, 6);
        assertEq(CardAuth.authorize.selector, AUTHORIZE);
        assertEq(CardAuth.capture.selector, CAPTURE);
        assertEq(CardAuth.charge.selector, CHARGE);
        assertEq(CardAuth.release.selector, RELEASE);
        assertEq(CardAuth.adjust.selector, ADJUST);
        assertEq(CardAuth.refund.selector, REFUND);
    }

    function _assertCall(bytes memory data, bytes4 selector, uint256 words) private pure {
        assertEq(bytes4(data), selector, "selector");
        assertEq(data.length, 4 + 32 * words, "calldata length");
    }

    function _artifact(string memory name) private view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/out/", name, ".sol/", name, ".json"));
    }

    /// @dev The ranges under `key` of an artifact, one list per child key, flattened, and how many child keys there are.
    function _ranges(string memory json, string memory key)
        private
        pure
        returns (Range[] memory ranges, uint256 count)
    {
        string[] memory ids = vm.parseJsonKeys(json, key);
        Range[][] memory each = new Range[][](ids.length);
        uint256 n;
        for (uint256 i; i < ids.length; ++i) {
            each[i] = abi.decode(vm.parseJson(json, string.concat(key, "['", ids[i], "']")), (Range[]));
            n += each[i].length;
        }
        ranges = new Range[](n);
        n = 0;
        for (uint256 i; i < each.length; ++i) {
            for (uint256 j; j < each[i].length; ++j) {
                ranges[n++] = each[i][j];
            }
        }
        return (ranges, ids.length);
    }

    /// @dev The CardLegs and CardLimits addresses `code` links, checking it links only those two and the same address
    ///      at every one of a library's ranges.
    function _libraries(bytes memory code, string memory json) private pure returns (address legs, address limits) {
        string[] memory files = vm.parseJsonKeys(json, ".deployedBytecode.linkReferences");
        assertEq(files.length, 2, "links two libraries");
        legs = _linked(code, json, "src/spend/programs/CardLegs.sol");
        limits = _linked(code, json, "src/spend/programs/CardLimits.sol");
        assertTrue(legs != limits);
    }

    function _linked(bytes memory code, string memory json, string memory file) private pure returns (address at) {
        (Range[] memory ranges,) = _ranges(json, string.concat(".deployedBytecode.linkReferences['", file, "']"));
        assertGt(ranges.length, 0, file);
        for (uint256 i; i < ranges.length; ++i) {
            assertEq(ranges[i].length, 20, file);
            address here;
            uint256 start = ranges[i].start;
            assembly ("memory-safe") {
                here := shr(96, mload(add(add(code, 32), start)))
            }
            if (i == 0) at = here;
            assertEq(here, at, file);
        }
        assertTrue(at != address(0), file);
    }

    function _assertDisjoint(Range[] memory x, Range[] memory y) private pure {
        for (uint256 i; i < x.length; ++i) {
            for (uint256 j; j < y.length; ++j) {
                bool apart = x[i].start + x[i].length <= y[j].start || y[j].start + y[j].length <= x[i].start;
                assertTrue(apart, "link and immutable ranges overlap");
            }
        }
    }

    /// @dev Every range holds, right-aligned, either the program's ADMIN or its SETTLEMENT_ACCOUNT, and each is held
    ///      by some range.
    function _assertRangesHold(address program, Range[] memory ranges) private view {
        bytes memory code = program.code;
        uint256 admin = uint160(CardAuth(program).ADMIN());
        uint256 settlement = uint160(CardAuth(program).SETTLEMENT_ACCOUNT());
        uint256 seen;
        for (uint256 i; i < ranges.length; ++i) {
            Range memory r = ranges[i];
            assertTrue(r.length != 0 && r.length <= 32 && r.start + r.length <= code.length, "range in bounds");
            uint256 value;
            for (uint256 k; k < r.length; ++k) {
                value = value << 8 | uint8(code[r.start + k]);
            }
            if (value == admin) seen |= 1;
            else if (value == settlement) seen |= 2;
            else revert("range holds neither immutable");
        }
        assertEq(seen, 3, "both immutables are in the ranges");
    }

    function _assertDiffersOnlyWithin(bytes memory x, bytes memory y, Range[] memory ranges) private pure {
        for (uint256 i; i < x.length; ++i) {
            if (x[i] == y[i]) continue;
            bool inside;
            for (uint256 j; j < ranges.length && !inside; ++j) {
                inside = i >= ranges[j].start && i < ranges[j].start + ranges[j].length;
            }
            assertTrue(inside, "code differs outside the immutable ranges");
        }
    }

    function _mask(bytes memory code, Range[] memory ranges) private pure returns (bytes memory masked) {
        masked = bytes.concat(code);
        for (uint256 i; i < ranges.length; ++i) {
            for (uint256 k; k < ranges[i].length; ++k) {
                masked[ranges[i].start + k] = 0;
            }
        }
    }

    /// @dev Whether the instructions of runtime `code`, before its trailing CBOR metadata, include `op`, skipping push
    ///      data and any CBOR metadata embedded as data.
    function _holds(bytes memory code, uint8 op) private pure returns (bool) {
        uint256 end = _end(code);
        for (uint256 i; i < end; ++i) {
            if (_metadataAt(code, i)) {
                i += METADATA_LENGTH + 1;
                continue;
            }
            uint8 at = uint8(code[i]);
            if (at == op) return true;
            if (at >= 0x60 && at <= 0x7f) i += at - 0x5f;
        }
        return false;
    }

    /// @dev Whether a CBOR metadata map followed by its two-byte length starts at `i`.
    function _metadataAt(bytes memory code, uint256 i) private pure returns (bool) {
        if (i + METADATA_LENGTH + 2 > code.length) return false;
        bytes8 head;
        assembly ("memory-safe") {
            head := mload(add(add(code, 32), i))
        }
        uint256 length = uint256(uint8(code[i + METADATA_LENGTH])) << 8 | uint8(code[i + METADATA_LENGTH + 1]);
        return head == METADATA_HEAD && length == METADATA_LENGTH;
    }

    /// @dev Where code ends before trailing CBOR metadata, whose length its last two bytes give when it has some.
    function _end(bytes memory code) private pure returns (uint256) {
        uint256 n = code.length;
        if (n < METADATA_LENGTH + 2 || !_metadataAt(code, n - METADATA_LENGTH - 2)) return n;
        return n - METADATA_LENGTH - 2;
    }
}

/// @notice Gas of each payment call in the heaviest purchase shape CardAuth allows, against a cap per call, and of a
///         one-leg purchase against the payment-lane caps the registry design proposes.
/// @dev Measured over MockReservationCore, the Solidity model of the reservation core, as call gas before any refund
///      (what a transaction's gas limit must cover), without the transaction's intrinsic and fee costs. The model is
///      not the precompile: test_model_pricesAtOrAboveTheNode checks that it prices the one-leg paths at or above
///      what node 0703315 measured, which bounds the node for those paths only. No node figure exists yet for the
///      multi-leg and converted paths, so their caps bound the model, not the node.
contract PaymentCallGasTest is AuthEnv {
    /// @dev Caps for the heaviest shape, four legs (a converted EURX cash leg, USD cash, savings and a credit line), at
    ///      about 15% over what the model measures at this commit. Far above the design's lane caps: a purchase this
    ///      shape needs a gas limit past them, so the lane rule would leave it in the general lane.
    uint256 internal constant AUTHORIZE_CAP = 6_500_000;
    uint256 internal constant ADJUST_CAP = 3_700_000;
    uint256 internal constant CAPTURE_CAP = 4_500_000;
    uint256 internal constant CHARGE_CAP = 3_800_000;
    uint256 internal constant RELEASE_CAP = 300_000;
    uint256 internal constant REFUND_CAP = 2_800_000;
    /// @dev The design's payment-lane caps: authorize 1.5M and capture 500k as proposed; the rest assumed alike.
    uint256 internal constant LANE_AUTHORIZE = 1_500_000;
    uint256 internal constant LANE_CAPTURE = 500_000;
    uint256 internal constant LANE_CHARGE = 1_500_000;
    uint256 internal constant LANE_ADJUST = 1_500_000;
    uint256 internal constant LANE_RELEASE = 500_000;
    uint256 internal constant LANE_REFUND = 500_000;
    /// @dev Node 0703315 at contracts 5fd9af5, whole-transaction gas: a first one-leg swipe's gas used, and a steady
    ///      swipe's gas limit (estimate plus 3%; storage credits charge new slots before refunding them). Measure the
    ///      node again when a change to the programs moves the model below these.
    uint256 internal constant NODE_SWIPE_FIRST = 1_391_024;
    uint256 internal constant NODE_SWIPE_STEADY_LIMIT = 1_193_565;
    /// @dev Node gas used net of refunds, so the model must at least reach it.
    uint256 internal constant NODE_CAPTURE_FIRST = 381_005;
    uint256 internal constant NODE_CAPTURE_STEADY = 133_717;
    uint256 internal constant NODE_REFUND_STEADY = 132_616;
    uint256 internal constant NODE_RELEASE = 124_716;

    uint256 internal constant BID = 1.0967e18;
    uint256 internal constant ASK = 1_103_310_000_000_000_000;
    uint256 internal constant FOUR_LEGS = 15;

    ITIP20Token internal eur;
    Conversion internal conv;
    address internal op = makeAddr("operator");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(5000e6, 10_000e6, 50_000e6));
        eur = _createToken("Euro", "EURX");
        conv = new Conversion(address(usd), address(this));
        FixedPricePool bid = new FixedPricePool(address(eur), address(usd), BID);
        FixedPricePool ask = new FixedPricePool(address(eur), address(usd), ASK);
        usd.mint(address(bid), 1_000_000e6);
        eur.mint(address(ask), 1_000_000e6);
        conv.setVenue(address(eur), address(usd), address(bid), true);
        conv.setVenue(address(usd), address(eur), address(ask), false);
        Rates.set(conv, address(eur), 1.1e18);
        conv.setTrusted(address(cash), true);
        conv.setTrusted(address(savings), true);
        usd.mint(address(conv), 100_000e6);
        eur.mint(address(conv), 100_000e6);
        _setting(abi.encodeCall(cards.setCompanions, (address(0), address(0), address(0), address(conv))));
        vm.prank(alice);
        core.approveHolder(address(cash), address(eur), type(uint128).max, 0);
        line.setLimit(alice, 10_000e6);
        // Purchases come from an operator key, as a processor's would, with the authorize and settle roles.
        vm.prank(issuer);
        cards.setOperator(op, 7, 1e15);
        usd.mint(op, 100_000e6);
        vm.prank(op);
        usd.approve(address(cards), type(uint256).max);
    }

    function test_gas_authorize_fourLegs() public {
        _fourLegs();
        uint256 first = _call(abi.encodeCall(cards.authorize, (CARD, "p1", 200e6, merchant, _expiry(), 0)));
        assertEq(_legs("p1"), FOUR_LEGS);
        _call(abi.encodeCall(cards.capture, ("p1", 200e6, true)));
        _fund();
        uint256 steady = _call(abi.encodeCall(cards.authorize, (CARD, "p2", 200e6, merchant, _expiry(), 0)));
        assertEq(_legs("p2"), FOUR_LEGS);
        assertLe(first, AUTHORIZE_CAP, "authorize, first purchase");
        assertLe(steady, AUTHORIZE_CAP, "authorize, steady");
    }

    function test_gas_adjust_upFromOneLegToFour() public {
        _fourLegs();
        _call(abi.encodeCall(cards.authorize, (CARD, "p1", 20e6, merchant, _expiry(), 0)));
        assertEq(_legs("p1"), 1);
        uint256 gas = _call(abi.encodeCall(cards.adjust, ("p1", 200e6)));
        assertEq(_legs("p1"), FOUR_LEGS);
        assertLe(gas, ADJUST_CAP, "adjust");
    }

    function test_gas_capture_fourLegs() public {
        _fourLegs();
        _call(abi.encodeCall(cards.authorize, (CARD, "p1", 200e6, merchant, _expiry(), 0)));
        uint256 part = _call(abi.encodeCall(cards.capture, ("p1", 100e6, false)));
        uint256 last = _call(abi.encodeCall(cards.capture, ("p1", 100e6, true)));
        assertLe(part, CAPTURE_CAP, "capture partial");
        assertLe(last, CAPTURE_CAP, "capture final");
    }

    /// @dev A tip within tolerance past the hold, the excess taken from cash that arrived after the authorization.
    function test_gas_capture_tipFromFreeCash() public {
        _fourLegs();
        // USD cash first, so the tip lands on a cash leg past its hold.
        CardLegs.Funding[] memory order = new CardLegs.Funding[](4);
        order[0] = _cashEntry(address(usd), 100);
        order[1] = _cashEntry(address(eur), 100);
        order[2] = CardLegs.Funding(ISource(address(savings)), bytes32(0));
        order[3] = CardLegs.Funding(ISource(address(line)), bytes32(0));
        vm.prank(alice);
        cards.setFunding(order);
        _setTolerance(alice, address(cash), address(eur), 5000);
        _setTolerance(alice, address(cash), address(usd), 5000);
        _call(abi.encodeCall(cards.authorize, (CARD, "p1", 200e6, merchant, _expiry(), 0)));
        usd.mint(alice, 80e6);
        uint256 gas = _call(abi.encodeCall(cards.capture, ("p1", 280e6, true)));
        // A unit of conversion rounding may fall to the issuer.
        assertLe(cards.purchaseOf("p1").refunded, 1, "sources covered all of it");
        assertLe(gas, CAPTURE_CAP, "capture past the hold");
    }

    /// @dev A force post the cash legs cover from free funds, in EURX and then USD.
    function test_gas_charge_converted() public {
        _fourLegs();
        usd.mint(alice, 100e6);
        uint256 gas = _call(abi.encodeCall(cards.charge, (CARD, "p1", 150e6, merchant)));
        assertEq(cards.purchaseOf("p1").refunded, 0, "sources covered all of it");
        assertLe(gas, CHARGE_CAP, "charge");
    }

    function test_gas_release_fourLegs() public {
        _fourLegs();
        _call(abi.encodeCall(cards.authorize, (CARD, "p1", 200e6, merchant, _expiry(), 0)));
        uint256 gas = _call(abi.encodeCall(cards.release, ("p1")));
        assertLe(gas, RELEASE_CAP, "release");
    }

    function test_gas_refund_fourLegs() public {
        _fourLegs();
        _call(abi.encodeCall(cards.authorize, (CARD, "p1", 200e6, merchant, _expiry(), 0)));
        _call(abi.encodeCall(cards.capture, ("p1", 200e6, true)));
        // Everything the sources covered: the converted leg's rounding leaves a unit absorbed.
        ICardAuth.PurchaseView memory p = cards.purchaseOf("p1");
        uint256 gas = _call(abi.encodeCall(cards.refund, ("p1", uint128(p.captured - p.refunded))));
        assertLe(gas, REFUND_CAP, "refund");
    }

    /// @notice A one-leg USD purchase, the shape the node measured, stays under the design's lane caps in the model,
    ///         once the owner has bought from the merchant before.
    function test_gas_oneLeg_underLaneCaps() public {
        _oneLeg();
        // A first purchase pays for the owner's and merchant's new slots too: above LANE_AUTHORIZE in the model,
        // 1,391,024 on the node.
        _call(abi.encodeCall(cards.authorize, (CARD, "p0", 10e6, merchant, _expiry(), 0)));
        uint256 captureFirst = _call(abi.encodeCall(cards.capture, ("p0", 10e6, true)));
        uint256 auth = _call(abi.encodeCall(cards.authorize, (CARD, "p1", 10e6, merchant, _expiry(), 0)));
        uint256 part = _call(abi.encodeCall(cards.capture, ("p1", 4e6, false)));
        uint256 last = _call(abi.encodeCall(cards.capture, ("p1", 6e6, true)));
        uint256 refund = _call(abi.encodeCall(cards.refund, ("p1", 5e6)));
        _call(abi.encodeCall(cards.authorize, (CARD, "p2", 10e6, merchant, _expiry(), 0)));
        uint256 adjust = _call(abi.encodeCall(cards.adjust, ("p2", 15e6)));
        uint256 release = _call(abi.encodeCall(cards.release, ("p2")));
        uint256 charge = _call(abi.encodeCall(cards.charge, (CARD, "p3", 10e6, merchant)));
        assertLe(auth, LANE_AUTHORIZE, "authorize");
        assertLe(captureFirst, LANE_CAPTURE, "capture, first");
        assertLe(part, LANE_CAPTURE, "capture partial");
        assertLe(last, LANE_CAPTURE, "capture final");
        assertLe(refund, LANE_REFUND, "refund");
        assertLe(adjust, LANE_ADJUST, "adjust");
        assertLe(release, LANE_RELEASE, "release");
        assertLe(charge, LANE_CHARGE, "charge");
    }

    /// @notice The model prices the one-leg paths at or above the node's measurements, so for those paths a cap the
    ///         model meets the node meets too. The node's figures are whole transactions; the model's are the call
    ///         alone, which makes the comparison stricter.
    function test_model_pricesAtOrAboveTheNode() public {
        _oneLeg();
        assertGe(_call(abi.encodeCall(cards.authorize, (CARD, "p0", 10e6, merchant, _expiry(), 0))), NODE_SWIPE_FIRST);
        assertGe(_call(abi.encodeCall(cards.capture, ("p0", 10e6, true))), NODE_CAPTURE_FIRST);
        assertGe(
            _call(abi.encodeCall(cards.authorize, (CARD, "p1", 10e6, merchant, _expiry(), 0))), NODE_SWIPE_STEADY_LIMIT
        );
        assertGe(_call(abi.encodeCall(cards.capture, ("p1", 10e6, true))), NODE_CAPTURE_STEADY);
        assertGe(_call(abi.encodeCall(cards.refund, ("p1", 5e6))), NODE_REFUND_STEADY);
        _call(abi.encodeCall(cards.authorize, (CARD, "p2", 10e6, merchant, _expiry(), 0)));
        assertGe(_call(abi.encodeCall(cards.release, ("p2"))), NODE_RELEASE);
    }

    function _call(bytes memory data) internal returns (uint256 gas) {
        vm.prank(op);
        uint256 before = gasleft();
        (bool ok, bytes memory result) = address(cards).call(data);
        gas = before - gasleft();
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /// @dev Alice's order: EURX cash converting at up to 1%, USD cash, savings, then the credit line, with about 30 in
    ///      each of the first three so a 200 purchase draws on all four.
    function _fourLegs() internal {
        CardLegs.Funding[] memory order = new CardLegs.Funding[](4);
        order[0] = _cashEntry(address(eur), 100);
        order[1] = _cashEntry(address(usd), 100);
        order[2] = CardLegs.Funding(ISource(address(savings)), bytes32(0));
        order[3] = CardLegs.Funding(ISource(address(line)), bytes32(0));
        vm.prank(alice);
        cards.setFunding(order);
        _fund();
    }

    /// @dev Alice's order: USD cash alone, holding enough for every purchase.
    function _oneLeg() internal {
        CardLegs.Funding[] memory order = new CardLegs.Funding[](1);
        order[0] = _cashEntry(address(usd), 0);
        vm.prank(alice);
        cards.setFunding(order);
        usd.mint(alice, 1000e6);
    }

    function _fund() internal {
        usd.mint(alice, 60e6);
        _depositEarn(alice, 30e6);
        eur.mint(alice, 33e6);
    }

    function _expiry() internal view returns (uint64) {
        return uint64(block.timestamp + 7 days);
    }
}
