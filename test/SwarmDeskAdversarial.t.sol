// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmDeskTestFixture, SwarmDeskIntakeProbe} from "./helpers/SwarmDeskTestFixture.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/oracle/OracleAttestation.sol";
import {Params} from "../src/Params.sol";
import "../src/lib/Errors.sol";

contract SwarmDeskAdversarialTest is SwarmDeskTestFixture {
    /// @dev Each field is changed AFTER signing. This complements the existing external protocol vector.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzzEveryAttestationFieldIsAuthenticated(uint8 rawField) public {
        uint256 field = bound(rawField, 0, 14);
        OracleAttestation.Attestation memory a = answer(0);
        bytes memory sig = sign(a);
        bytes4 error = OracleAttestationConsumer.BadSignature.selector;
        if (field == 0) a.requestId = keccak256("different UUID");
        if (field == 1) {
            a.chainId++;
            error = InvalidValue.selector;
        }
        if (field == 2) {
            a.questionHash = keccak256("different question");
            error = InvalidProof.selector;
        }
        if (field == 3) a.answerType = 4;
        if (field == 4) a.answer[a.answer.length - 1] ^= bytes1(uint8(1));
        if (field == 5) a.figure++;
        if (field == 6) {
            a.fromBlock++;
            error = InvalidValue.selector;
        }
        if (field == 7) {
            a.toBlock++;
            error = InvalidValue.selector;
        }
        if (field == 8) a.blockHash ^= bytes32(uint256(1));
        if (field == 9) a.panelJobId ^= bytes32(uint256(1));
        if (field == 10) a.panelSize++;
        if (field == 11) a.quorum = 5;
        if (field == 12) a.agreed = 4;
        if (field == 13) a.issuedAt++;
        if (field == 14) a.expiresAt++;
        vm.expectRevert(error);
        desk.submit(a, sig);
        assertUnaccepted(a, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzEachPanelConstraintRejectsSignedAnswers(uint8 rawCase, uint16 n) public {
        uint256 which = bound(rawCase, 0, 4);
        OracleAttestation.Attestation memory a = answer(1);
        if (which == 0) a.panelSize = uint16(bound(n, 0, 4));
        if (which == 1) a.quorum = uint16(bound(n, 0, 3));
        if (which == 2) a.agreed = uint16(bound(n, 0, 3));
        if (which == 3) a.agreed = uint16(bound(n, 6, type(uint16).max));
        if (which == 4) a.quorum = uint16(bound(n, 6, type(uint16).max));
        bytes memory sig = sign(a);
        vm.expectRevert(InvalidValue.selector);
        desk.submit(a, sig);
        assertUnaccepted(a, 1);
    }

    function testMinimumPanelAndFutureClockToleranceAreInclusive() public {
        OracleAttestation.Attestation memory a = answer(0);
        a.agreed = 4;
        a.issuedAt = uint64(block.timestamp + 300);
        desk.submit(a, sign(a));
        assertTrue(desk.consumed(a.requestId));
        assertEq(stored(0).requestId, a.requestId);
    }

    function testFutureClockBeyondToleranceDoesNotBurnUUID() public {
        OracleAttestation.Attestation memory a = answer(0);
        a.issuedAt = uint64(block.timestamp + 301);
        bytes memory sig = sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        desk.submit(a, sig);
        assertUnaccepted(a, 0);
        vm.warp(block.timestamp + 1);
        desk.submit(a, sig);
        assertTrue(desk.consumed(a.requestId));
    }

    function testZeroOracleUUIDAndZeroTransportIDAreRejected() public {
        OracleAttestation.Attestation memory a = answer(0);
        bytes memory sig = sign(a);
        address delivery = desk.oracleConfig().delivery;
        vm.expectRevert(InvalidValue.selector);
        vm.prank(delivery);
        desk.onOracleResult(bytes32(0), a, sig);
        a.requestId = bytes32(0);
        sig = sign(a);
        vm.expectRevert(InvalidValue.selector);
        desk.submit(a, sig);
        assertUnaccepted(a, 0);
    }

    function testSignatureForIntakeDomainCannotAuthorizeDesk() public {
        OracleAttestation.Attestation memory a = answer(0);
        address intake = desk.oracleConfig().intake;
        // Place a genuine consumer at the wrong verifying address solely to compute that domain's digest.
        vm.etch(intake, address(desk).code);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x123456, SwarmDesk(intake).attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        desk.submit(a, abi.encodePacked(r, s, v));
        assertUnaccepted(a, 0);
    }

    function testMalformedAndMalleableSignaturesCannotConsumeAnswer() public {
        OracleAttestation.Attestation memory a = answer(0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x123456, desk.attestationDigest(a));
        uint256 curveOrder = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes memory highS = abi.encodePacked(r, bytes32(curveOrder - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        desk.submit(a, highS);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        desk.submit(a, abi.encodePacked(r, s, uint8(0)));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        desk.submit(a, new bytes(64));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        desk.submit(a, new bytes(66));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        desk.submit(a, "");
        assertUnaccepted(a, 0);
        desk.submit(a, abi.encodePacked(r, s, v));
        assertTrue(desk.consumed(a.requestId));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzSignedMalformedArraysNeverStore(uint8 rawStream, uint8 rawFault) public {
        uint8 stream = uint8(bound(rawStream, 0, 1));
        uint256 fault = bound(rawFault, 0, 4);
        OracleAttestation.Attestation memory a = answer(stream);
        uint256 count = stream == 0 ? 7 : 17;
        if (fault == 0) a.answer = abi.encode(new bytes32[](count - 1));
        if (fault == 1) a.answer = abi.encode(new bytes32[](count + 1));
        bytes memory encoded = a.answer;
        // Correct total length but an impossible offset/length must also fail the ABI decoder.
        if (fault == 2) {
            assembly ("memory-safe") { mstore(add(encoded, 32), not(0)) }
        }
        if (fault == 3) {
            assembly ("memory-safe") { mstore(add(encoded, 64), not(0)) }
        }
        if (fault == 4) {
            assembly ("memory-safe") { mstore(add(encoded, 64), sub(count, 1)) }
        }
        bytes memory sig = sign(a);
        vm.expectRevert(); // The compiler's ABI decoder has no custom error for malformed offsets.
        desk.submit(a, sig);
        assertUnaccepted(a, stream);
    }

    function testWeeklyAnswerOlderThanOneDayIsIgnoredWithoutBlockingFreshAnswer() public {
        vm.warp(block.timestamp + 3 days);
        OracleAttestation.Attestation memory a = answer(1);
        a.issuedAt = uint64(block.timestamp - 1 days - 1);
        desk.submit(a, sign(a));
        assertUnaccepted(a, 1);
        a = answer(1);
        a.issuedAt = uint64(block.timestamp - 1 days + 1);
        desk.submit(a, sign(a));
        assertTrue(desk.consumed(a.requestId));
        assertEq(stored(1).validUntil, block.timestamp + 1);
    }

    function testExecutionAtExpiryDiscardsResultWithoutChangingGame() public {
        OracleAttestation.Attestation memory a = answer(0);
        a.expiresAt = uint64(block.timestamp + 1);
        desk.submit(a, sign(a));
        vm.warp(a.expiresAt);
        desk.execute(0, a.answer);
        assertFalse(stored(0).pending);
        assertFalse(d.grid.planAt(d.rewards.epoch() + 1).submitted);
        assertEq(desk.lastLetterHash(), bytes32(0));
        vm.expectRevert(InvalidProof.selector);
        desk.execute(0, a.answer);
    }

    function testOneSecondBeforeExpiryExecutesAndSlotEndCapsValidity() public {
        OracleAttestation.Attestation memory a = answer(0);
        desk.submit(a, sign(a));
        uint256 end = (desk.slot(0) + 1) * 6 hours;
        assertEq(stored(0).validUntil, end);
        vm.warp(end - 1);
        desk.execute(0, a.answer);
        assertTrue(d.grid.planAt(d.rewards.epoch() + 1).submitted);
        assertFalse(stored(0).pending);
    }

    function testBackupFirstHourBoundaryAndStreamsHaveSeparateQuotas() public {
        uint256 start = desk.slot(1) * 7 days;
        vm.warp(start + 1 hours - 1);
        vm.expectRevert(TooEarly.selector);
        desk.askBackup(0, body(0));
        vm.expectRevert(TooEarly.selector);
        desk.askBackup(1, body(1));
        vm.warp(start + 1 hours);
        bytes32 eventId = desk.askBackup(0, body(0));
        bytes32 regulatorId = desk.askBackup(1, body(1));
        assertNotEq(eventId, regulatorId);
        assertEq(probe.requests(), 2);
        assertEq(token.balanceOf(address(desk)), 19 ether);
        assertEq(token.allowance(address(desk), address(probe)), 0);
        assertEq(probe.lastAction(), desk.oracleConfig().action);
        assertEq(probe.lastBody(), body(1));
        assertEq(probe.lastAsset(), address(token));
        assertEq(probe.lastAmount(), 0.5 ether);
        assertEq(probe.lastFailureSelector(), desk.onOracleFailure.selector);
        (address target, bytes4 selector) = probe.callbacks(regulatorId);
        assertEq(target, address(desk));
        assertEq(selector, desk.onOracleResult.selector);
    }

    function testBackupAtSlotEndClipsDeadlineAndRejectsLateDirectAnswer() public {
        uint256 end = (desk.slot(0) + 1) * 6 hours;
        vm.warp(end - 1);
        bytes32 id = desk.askBackup(0, body(0));
        (, uint64 deadline,) = desk.pending(id);
        assertEq(deadline, end);
        OracleAttestation.Attestation memory a = answer(0);
        bytes memory sig = sign(a);
        vm.expectRevert(TooEarly.selector);
        desk.clearExpired(id);
        vm.warp(end);
        assertTrue(probe.result(id, a, sig), "stale callback should return without acting");
        assertFalse(desk.consumed(a.requestId));
        desk.clearExpired(id);
        (,, uint8 active) = desk.pending(id);
        assertEq(active, 0);
        vm.expectRevert(TooEarly.selector);
        desk.clearExpired(id);
    }

    function testDirectAnswerAtDeadlineIsIgnoredAndOneSecondBeforeIsAccepted() public {
        bytes32 id = desk.askBackup(0, body(0));
        (, uint64 deadline,) = desk.pending(id);
        OracleAttestation.Attestation memory a = answer(0);
        bytes memory sig = sign(a);
        uint256 snapshot = vm.snapshotState();
        vm.warp(deadline);
        assertTrue(probe.result(id, a, sig));
        assertFalse(desk.consumed(a.requestId));
        (,, uint8 stillPending) = desk.pending(id);
        assertEq(stillPending, 1);
        assertTrue(vm.revertToState(snapshot));
        vm.warp(deadline - 1);
        assertTrue(probe.result(id, a, sig), "200k direct callback");
        assertTrue(desk.consumed(a.requestId));
        (,, stillPending) = desk.pending(id);
        assertEq(stillPending, 0);
    }

    function testDirectRequestCannotBeAnsweredWithOtherStream() public {
        bytes32 id = desk.askBackup(0, body(0));
        OracleAttestation.Attestation memory a = answer(1);
        assertFalse(probe.result(id, a, sign(a)));
        assertFalse(desk.consumed(a.requestId));
        (,, uint8 active) = desk.pending(id);
        assertEq(active, 1);
        a = answer(0);
        assertTrue(probe.result(id, a, sign(a)));
        assertTrue(desk.consumed(a.requestId));
        assertNotEq(id, a.requestId, "transport IDs and oracle UUIDs are different namespaces");
    }

    function testInvalidFailureStatusCannotClearPaidRequestOrAct() public {
        bytes32 id = desk.askBackup(1, body(1));
        for (uint256 i; i < 3; ++i) {
            uint8 status = i == 0 ? 0 : i == 1 ? 3 : 255;
            vm.expectRevert(InvalidValue.selector);
            vm.prank(address(probe));
            desk.onOracleFailure(id, status, bytes32("forged"), 5, 5, "");
        }
        (,, uint8 active) = desk.pending(id);
        assertEq(active, 2);
        vm.prank(desk.oracleConfig().delivery);
        desk.onOracleFailure(id, 2, bytes32("untrusted remote"), 5, 5, "");
        (,, active) = desk.pending(id);
        assertEq(active, 2, "remote failure must not cancel a local paid request");
        assertEq(desk.lastFailure(), bytes32(0));
        vm.prank(address(probe));
        desk.onOracleFailure(id, 1, bytes32("body_refused"), 0, 0, "");
        assertEq(desk.lastFailure(), bytes32("body_refused"));
        assertEq(stored(1).answerHash, bytes32(0));
        assertEq(token.balanceOf(address(desk)), 19.5 ether, "failure is not a refund");
        vm.expectRevert(TooEarly.selector);
        desk.askBackup(1, body(1));
    }

    function testZeroOverCapAndInsufficientBalanceCannotSpendQuota() public {
        probe.configure(0, 0, 0);
        vm.expectRevert(InvalidValue.selector);
        desk.askBackup(0, body(0));
        probe.configure(0.5 ether + 1, 0, 0);
        vm.expectRevert(InvalidValue.selector);
        desk.askBackup(0, body(0));
        probe.configure(0.5 ether, 0, 0);
        deal(address(token), address(desk), 0.5 ether - 1);
        vm.expectRevert(); // ERC20 insufficient balance bubbles up from the independent token.
        desk.askBackup(0, body(0));
        assertEq(desk.askedSlotPlusOne(0), 0);
        assertEq(token.allowance(address(desk), address(probe)), 0);
        assertEq(probe.requests(), 0);
        token.transfer(address(desk), 1);
        desk.askBackup(0, body(0));
        assertEq(token.balanceOf(address(desk)), 0, "exact full balance may pay the backup");
        assertEq(token.balanceOf(address(probe)), 0.5 ether);
    }

    function testOneWeiPriceAndTokenTransferFailureRollback() public {
        probe.configure(1, 0, 0);
        token.setFail(true);
        vm.expectRevert("test transfer failure");
        desk.askBackup(0, body(0));
        assertEq(desk.askedSlotPlusOne(0), 0);
        assertEq(token.allowance(address(desk), address(probe)), 0);
        token.setFail(false);
        desk.askBackup(0, body(0));
        assertEq(token.balanceOf(address(desk)), 20 ether - 1);
        assertEq(token.balanceOf(address(probe)), 1);
    }

    function testIntakeRevertAndZeroIDRollBackPaymentApprovalAndQuota() public {
        for (uint256 i; i < 2; ++i) {
            probe.configure(0.5 ether, i == 0 ? 3 : 1, 0);
            vm.expectRevert(i == 0 ? SwarmDeskIntakeProbe.RequestFailedAfterPayment.selector : InvalidValue.selector);
            desk.askBackup(0, body(0));
            assertEq(token.balanceOf(address(desk)), 20 ether);
            assertEq(token.balanceOf(address(probe)), 0);
            assertEq(token.allowance(address(desk), address(probe)), 0);
            assertEq(desk.askedSlotPlusOne(0), 0);
            assertEq(probe.requests(), 0);
        }
        probe.configure(0.5 ether, 0, 0);
        desk.askBackup(0, body(0));
        assertEq(probe.requests(), 1, "failed attempts must be retryable");
    }

    function testDuplicateOutstandingIntakeIDRollsBackOtherStreamsPayment() public {
        bytes32 id = desk.askBackup(0, body(0));
        probe.configure(0.5 ether, 2, id);
        vm.expectRevert(InvalidValue.selector);
        desk.askBackup(1, body(1));
        assertEq(token.balanceOf(address(desk)), 19.5 ether);
        assertEq(token.balanceOf(address(probe)), 0.5 ether);
        assertEq(token.allowance(address(desk), address(probe)), 0);
        assertEq(desk.askedSlotPlusOne(1), 0);
        (,, uint8 stream) = desk.pending(id);
        assertEq(stream, 1);
    }

    function testTokenCallbackCannotReenterOtherStreamDuringBackupPayment() public {
        token.setCallback(address(desk), abi.encodeCall(SwarmDesk.askBackup, (uint8(1), body(1))));
        desk.askBackup(0, body(0));
        assertFalse(token.callbackSucceeded());
        assertEq(probe.requests(), 1);
        assertEq(desk.askedSlotPlusOne(1), 0);
        assertEq(token.balanceOf(address(desk)), 19.5 ether);
        assertEq(token.allowance(address(desk), address(probe)), 0);
    }

    function testAcceptedScheduleSuppressesBackupAndCannotOverwriteEarlierPlan() public {
        OracleAttestation.Attestation memory a = answer(0);
        desk.submit(a, sign(a));
        desk.execute(0, a.answer);
        vm.expectRevert(TooEarly.selector);
        desk.askBackup(0, body(0));
        vm.warp(block.timestamp + 6 hours);
        a = answer(0);
        bytes32[] memory v = values(0);
        v[3] = bytes32(uint256(5000));
        a.answer = abi.encode(v);
        desk.submit(a, sign(a));
        desk.execute(0, a.answer);
        assertEq(d.grid.planAt(d.rewards.epoch() + 1).severity, 6000);
        assertEq(d.grid.planAt(d.rewards.epoch() + 2).severity, 6000);
        assertEq(probe.requests(), 0);
    }

    function testRepeatedParamKeyCannotCompoundTenPercentInOneAnswer() public {
        OracleAttestation.Attestation memory a = answer(1);
        bytes32[] memory v = values(1);
        for (uint256 i = 1; i <= 8; ++i) {
            v[i] = bytes32((uint256(1) << 248) | type(uint248).max);
        }
        a.answer = abi.encode(v);
        desk.submit(a, sign(a));
        desk.execute(1, a.answer);
        assertEq(d.params.get(Params.Key.EmissionBps), 385, "eight entries still allow one 10% step");
        assertEq(d.params.lastChanged(Params.Key.EmissionBps), block.timestamp);
    }

    function testLaunchOrderInitializedMarketAllowsCapAnnouncementAfterThirtyDays() public {
        // The accepted b2ccff16 finding concerns an uninitialized market. Rehearse the
        // approved launch order instead: token/market initialized, game bound, age >= 30 days.
        assertGt(market.initializedAt(), 0);
        assertEq(address(desk.registry()), address(d.registry));
        vm.warp(market.initializedAt() + 30 days);
        OracleAttestation.Attestation memory a = answer(1);
        bytes32[] memory v = values(1);
        v[1] = bytes32((uint256(1) << 248) | type(uint248).max);
        v[10] = bytes32(uint256(1));
        a.answer = abi.encode(v);
        desk.submit(a, sign(a));
        desk.execute(1, a.answer);
        assertEq(d.params.get(Params.Key.EmissionBps), 385);
        assertEq(d.enhancement.announcedCap(), 12);
        assertEq(d.enhancement.activationAt(), block.timestamp + 48 hours);
        assertFalse(stored(1).pending);
    }
}
