// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { RevertRecordingHandler } from "../helpers/RevertRecordingHandler.sol";

contract RevertRecordingHarness is RevertRecordingHandler {
    error Expected(uint256 value);
    error AlsoExpected();
    error Unexpected();

    function handle(bytes memory reason) external {
        _expectOnly(reason, Expected.selector, AlsoExpected.selector);
    }
}

contract RevertRecordingHandlerTest is Test {
    RevertRecordingHarness private handler;

    function setUp() public {
        handler = new RevertRecordingHarness();
    }

    function testRethrowsExpectedErrorsWithoutRecording() public {
        bytes memory reason = abi.encodeWithSelector(RevertRecordingHarness.Expected.selector, 7);
        vm.expectRevert(reason);
        handler.handle(reason);
        vm.expectRevert(RevertRecordingHarness.AlsoExpected.selector);
        handler.handle(abi.encodeWithSelector(RevertRecordingHarness.AlsoExpected.selector));
        assertFalse(handler.revertedUnexpectedly());
    }

    function testRecordsTheFirstUnexpectedRevert() public {
        bytes memory first = abi.encodeWithSelector(RevertRecordingHarness.Unexpected.selector);
        handler.handle(first);
        handler.handle(abi.encodeWithSignature("Error(string)", "later"));
        assertTrue(handler.revertedUnexpectedly());
        assertEq(handler.unexpectedRevertReason(), first);
    }

    function testRecordsRevertsWithoutASelector() public {
        handler.handle("");
        assertTrue(handler.revertedUnexpectedly());

        RevertRecordingHarness other = new RevertRecordingHarness();
        // A zero selector stands for an unused slot, never an expected error.
        other.handle(abi.encodePacked(bytes4(0)));
        assertTrue(other.revertedUnexpectedly());
    }
}
