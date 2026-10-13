// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmDeskTestFixture, SwarmDeskIntakeProbe} from "./helpers/SwarmDeskTestFixture.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/oracle/OracleAttestation.sol";
import {Params} from "../src/Params.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {MockToken} from "./mocks/MockToken.sol";
import "../src/lib/Errors.sol";

/// @dev The ghost ledger is driven by requested operations and their specified outcomes, not
/// reconstructed from Desk balances or its consumed/accepted/pending flags. Expected failures are
/// asserted explicitly; unexpected reverts fail the invariant campaign.
contract SwarmDeskHandler is Test {
    struct Request {
        bytes32 id;
        uint64 slot;
        uint64 deadline;
        uint8 stream;
        bool active;
    }

    struct ExpectedAnswer {
        bytes payload;
        bytes32 uuid;
        uint64 issuedAt;
        uint64 validUntil;
        uint64 slot;
        bool pending;
    }

    SwarmDesk private desk;
    MockToken private token;
    SwarmDeskIntakeProbe private intake;
    Deploy.Deployment private game;
    address[3] private actors;
    uint256[3] private initialActorBalances;
    uint256[3] private actorDonations;
    bytes32 private initialOracleConfig;
    bytes32 private initialBindingConfig;
    Request[] private requests;
    OracleAttestation.Attestation[] private acceptedMessages;
    bytes32[] private acceptedDeliveryKeys;
    ExpectedAnswer[2] private expectedAnswers;
    uint256[2] private askedSlot;
    uint256[2] private acceptedSlot;
    mapping(uint8 => mapping(uint256 => uint256)) private paidPerSlot;
    mapping(uint8 => mapping(uint256 => uint256)) private answersPerSlot;
    uint256 public donated = 20 ether;
    uint256 public spent;
    uint256 public acceptedCount;
    uint256 public executedCount;
    uint256 public clearedCount;
    uint256 public failedCount;
    uint256 private nonce;
    bytes32 private expectedLetter;
    bytes32 private expectedFailure;

    constructor(
        SwarmDesk desk_,
        MockToken token_,
        SwarmDeskIntakeProbe intake_,
        Deploy.Deployment memory game_,
        address[3] memory actors_
    ) {
        desk = desk_;
        token = token_;
        intake = intake_;
        game = game_;
        actors = actors_;
        for (uint256 i; i < 3; ++i) {
            initialActorBalances[i] = token.balanceOf(actors[i]);
        }
        initialOracleConfig = keccak256(abi.encode(desk.oracleConfig()));
        initialBindingConfig = keccak256(abi.encode(desk.bindingConfig()));
    }

    function _stream(uint8 raw) private pure returns (uint8) {
        return raw % 2;
    }

    function _period(uint8 stream) private pure returns (uint256) {
        return stream == 0 ? 6 hours : 7 days;
    }

    function _body(uint8 stream) private pure returns (bytes memory) {
        return stream == 0 ? bytes("event body") : bytes("regulator body");
    }

    function donate(uint256 who, uint256 amount) external {
        uint256 actor = who % 3;
        amount = bound(amount, 0, token.balanceOf(actors[actor]));
        vm.prank(actors[actor]);
        assertTrue(token.transfer(address(desk), amount));
        donated += amount;
        actorDonations[actor] += amount;
    }

    function advance(uint256 seconds_) external {
        seconds_ = bound(seconds_, 0, 8 days);
        vm.warp(vm.getBlockTimestamp() + seconds_);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev Vary the external price, including free, over-cap, one wei, and exact cap, and try
    /// both committed and foreign bodies. The fuzzer cannot call the probe directly.
    function ask(uint8 rawStream, uint256 rawPrice, bool foreignBody, uint256 who) external {
        uint8 stream = _stream(rawStream);
        uint256 price = bound(rawPrice, 0, 0.5 ether + 1);
        intake.configure(price, 0, 0);
        uint256 time = vm.getBlockTimestamp();
        uint256 s = time / _period(stream);
        bytes memory requestBody = foreignBody ? bytes("foreign question") : _body(stream);
        vm.prank(actors[who % 3]);
        if (foreignBody) {
            vm.expectRevert(InvalidProof.selector);
            desk.askBackup(stream, requestBody);
            return;
        }
        if (paidPerSlot[stream][s] != 0 || answersPerSlot[stream][s] != 0 || time % _period(stream) < 1 hours) {
            vm.expectRevert(TooEarly.selector);
            desk.askBackup(stream, requestBody);
            return;
        }
        if (price == 0 || price > 0.5 ether) {
            vm.expectRevert(InvalidValue.selector);
            desk.askBackup(stream, requestBody);
            return;
        }
        if (price > donated - spent) {
            vm.expectRevert(); // Independent ERC20's insufficient-balance error.
            desk.askBackup(stream, requestBody);
            return;
        }
        bytes32 id = desk.askBackup(stream, requestBody);
        spent += price;
        assertEq(++paidPerSlot[stream][s], 1, "multiple paid requests in one stream/slot");
        askedSlot[stream] = s + 1;
        uint256 deadline = time + 1 hours;
        uint256 end = (s + 1) * _period(stream);
        if (deadline > end) deadline = end;
        requests.push(Request(id, uint64(s), uint64(deadline), stream, true));
    }

    function _answer(uint8 stream, uint256 seed) private returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory v = new bytes32[](stream == 0 ? 7 : 17);
        v[0] = bytes32(vm.getBlockTimestamp() / _period(stream));
        if (stream == 0) {
            v[1] = bytes32(game.rewards.epoch());
            v[2] = bytes32(seed);
            v[3] = bytes32(seed >> 8);
            v[4] = bytes32(seed >> 16);
            v[5] = keccak256(abi.encode(seed));
        } else {
            // All eight entries target the same fuzzed key: repeated entries must never
            // compound the per-day step. Reserved keys remain included as numeric keys.
            uint256 key = seed % 45 + 1;
            for (uint256 i = 1; i <= 8; ++i) {
                v[i] = bytes32((key << 248) | uint248(seed >> i));
            }
        }
        v[v.length - 1] = keccak256(abi.encode("public letter", seed));
        SwarmDesk.OracleConfig memory o = desk.oracleConfig();
        a.requestId = keccak256(abi.encode("invariant oracle UUID", ++nonce));
        a.chainId = o.questionChain;
        a.questionHash = o.questions[stream];
        a.answerType = 5;
        a.answer = abi.encode(v);
        a.fromBlock = o.fromBlock;
        a.toBlock = o.toBlock;
        a.blockHash = keccak256("invariant context block");
        a.panelJobId = keccak256("invariant panel");
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 2 days);
    }

    function _sign(OracleAttestation.Attestation memory a, uint256 key) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, desk.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _record(uint8 stream, OracleAttestation.Attestation memory a, bytes32 deliveryKey) private {
        uint256 s = vm.getBlockTimestamp() / _period(stream);
        assertEq(++answersPerSlot[stream][s], 1, "multiple accepted answers in one stream/slot");
        acceptedSlot[stream] = s + 1;
        uint256 until = vm.getBlockTimestamp() + (stream == 0 ? 6 hours : 1 days);
        uint256 end = (s + 1) * _period(stream);
        if (until > end) until = end;
        expectedAnswers[stream] = ExpectedAnswer(a.answer, a.requestId, a.issuedAt, uint64(until), uint64(s), true);
        acceptedMessages.push(a);
        acceptedDeliveryKeys.push(deliveryKey);
        ++acceptedCount;
    }

    function relay(uint8 rawStream, uint256 seed, bool transport, uint256 who) external {
        uint8 stream = _stream(rawStream);
        OracleAttestation.Attestation memory a = _answer(stream, seed);
        bytes memory sig = _sign(a, 0x123456);
        address source = transport ? desk.oracleConfig().delivery : address(0);
        bytes32 id = transport ? keccak256(abi.encode("source request", nonce)) : a.requestId;
        if (transport) {
            vm.prank(source);
            // An EVM call with the real callback stipend, including dynamic ABI decoding.
            (bool ok,) = address(desk).call{gas: 200_000}(abi.encodeCall(SwarmDesk.onOracleResult, (id, a, sig)));
            assertTrue(ok, "200k remote callback failed");
        } else {
            vm.prank(actors[who % 3]);
            desk.submit(a, sig);
        }
        uint256 s = vm.getBlockTimestamp() / _period(stream);
        if (answersPerSlot[stream][s] == 0) _record(stream, a, keccak256(abi.encode(source, id)));
        else assertFalse(desk.consumed(a.requestId), "a second answer displaced the first");
    }

    function answerBackup(uint256 index, uint256 seed) external {
        if (requests.length == 0) return;
        Request storage r = requests[index % requests.length];
        if (!r.active) return;
        OracleAttestation.Attestation memory a = _answer(r.stream, seed);
        bool expected = vm.getBlockTimestamp() < r.deadline
            && answersPerSlot[r.stream][vm.getBlockTimestamp() / _period(r.stream)] == 0;
        assertTrue(intake.result(r.id, a, _sign(a, 0x123456)), "200k direct callback failed");
        if (expected) {
            _record(r.stream, a, keccak256(abi.encode(address(intake), r.id)));
            r.active = false;
        } else {
            assertFalse(desk.consumed(a.requestId));
        }
    }

    function failure(uint256 index, uint8 mode, uint256 who) external {
        if (requests.length == 0) return;
        Request storage r = requests[index % requests.length];
        mode %= 4;
        bytes32 reason = bytes32("disagreed");
        if (mode == 3) {
            vm.expectRevert(Unauthorized.selector);
            vm.prank(actors[who % 3]);
            desk.onOracleFailure(r.id, 2, reason, 0, 0, "");
        } else if (mode == 2) {
            vm.prank(desk.oracleConfig().delivery);
            desk.onOracleFailure(r.id, 2, reason, 0, 0, "");
        } else {
            if (!r.active) vm.expectRevert(InvalidValue.selector);
            vm.prank(address(intake));
            desk.onOracleFailure(r.id, mode + 1, reason, 0, 0, "");
            if (r.active) {
                r.active = false;
                expectedFailure = reason;
                ++failedCount;
            }
        }
    }

    function clear(uint256 index, uint256 who) external {
        if (requests.length == 0) return;
        Request storage r = requests[index % requests.length];
        bool expected = r.active && vm.getBlockTimestamp() >= r.deadline;
        if (!expected) vm.expectRevert(TooEarly.selector);
        vm.prank(actors[who % 3]);
        desk.clearExpired(r.id);
        if (expected) {
            r.active = false;
            ++clearedCount;
        }
    }

    function replay(uint256 index, uint256 who) external {
        if (acceptedMessages.length == 0) return;
        OracleAttestation.Attestation memory a = acceptedMessages[index % acceptedMessages.length];
        vm.prank(actors[who % 3]);
        desk.submit(a, ""); // Consumed UUIDs may return early but must never restore an execution.
    }

    function forgedAnswer(uint8 rawStream, uint256 seed, uint256 who) external {
        OracleAttestation.Attestation memory a = _answer(_stream(rawStream), seed);
        bytes memory sig = _sign(a, 0xBAD);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        vm.prank(actors[who % 3]);
        desk.submit(a, sig);
        assertFalse(desk.consumed(a.requestId));
    }

    function execute(uint8 rawStream, bool tamper, uint256 who) external {
        uint8 stream = _stream(rawStream);
        ExpectedAnswer storage expected = expectedAnswers[stream];
        bytes memory payload = expected.payload;
        if (tamper) payload = bytes.concat(payload, hex"01");
        if (!expected.pending || tamper) {
            vm.expectRevert(InvalidProof.selector);
            vm.prank(actors[who % 3]);
            desk.execute(stream, payload);
            return;
        }
        uint256[45] memory previous;
        uint256[45] memory changedAt;
        for (uint256 i; i < 45; ++i) {
            previous[i] = game.params.get(Params.Key(i));
            changedAt[i] = game.params.lastChanged(Params.Key(i));
        }
        vm.prank(actors[who % 3]);
        desk.execute(stream, payload);
        expected.pending = false;
        bool live = vm.getBlockTimestamp() < expected.validUntil;
        if (live) {
            bytes32[] memory v = abi.decode(payload, (bytes32[]));
            expectedLetter = v[v.length - 1];
            ++executedCount;
        }
        for (uint256 i; i < 45; ++i) {
            uint256 after_ = game.params.get(Params.Key(i));
            if (!live || stream == 0) assertEq(after_, previous[i], "expired/event answer changed Params");
            assertGe(after_, previous[i] - previous[i] / 10, "step exceeded -10%");
            assertLe(after_, previous[i] + previous[i] / 10, "step exceeded +10%");
            if (after_ != previous[i]) {
                assertGe(vm.getBlockTimestamp(), changedAt[i] + 1 days, "cooldown bypass");
                assertEq(game.params.lastChanged(Params.Key(i)), vm.getBlockTimestamp());
            } else {
                assertEq(game.params.lastChanged(Params.Key(i)), changedAt[i], "no-op burned cooldown");
            }
        }
    }

    function tryPrivileges(uint256 who) external {
        address actor = actors[who % 3];
        vm.expectRevert(AlreadyDone.selector);
        vm.prank(actor);
        desk.bind(actor, "", "", 1, 0, 1, 0);
        vm.expectRevert(Unauthorized.selector);
        vm.prank(actor);
        game.params.set(Params.Key.EmissionBps, 360, "unauthorized");
        vm.prank(actor);
        (bool ok,) = address(desk).call(abi.encodeWithSignature("withdraw(address,uint256)", actor, 1));
        assertFalse(ok);
    }

    function checkCustody() external view {
        assertEq(token.balanceOf(address(desk)) + spent, donated, "unaccounted Desk outflow");
        assertEq(token.balanceOf(address(intake)), spent, "payments differ from charged prices");
        assertEq(token.allowance(address(desk), address(intake)), 0, "residual spending permission");
        assertEq(intake.requests(), requests.length, "request/payment count diverged");
        assertLe(spent, requests.length * 0.5 ether, "price ceiling exceeded");
        for (uint256 i; i < 3; ++i) {
            assertEq(token.balanceOf(actors[i]) + actorDonations[i], initialActorBalances[i], "actor extracted funds");
        }
    }

    function checkOracleState() external view {
        for (uint8 stream; stream < 2; ++stream) {
            ExpectedAnswer storage e = expectedAnswers[stream];
            (bytes32 hash, bytes32 id, uint64 issued, uint64 until, uint64 s, bool pending_, uint48 received) =
                desk.lastAnswer(stream);
            assertEq(hash, e.uuid == 0 ? bytes32(0) : keccak256(e.payload));
            assertEq(id, e.uuid);
            assertEq(issued, e.issuedAt);
            assertEq(until, e.validUntil);
            assertEq(s, e.slot);
            assertEq(pending_, e.pending, "replay restored/lost an execution");
            assertEq(received, e.uuid == 0 ? 0 : 1000);
            assertEq(desk.askedSlotPlusOne(stream), askedSlot[stream]);
            assertEq(desk.acceptedSlotPlusOne(stream), acceptedSlot[stream]);
        }
        for (uint256 i; i < requests.length; ++i) {
            Request storage r = requests[i];
            (uint64 s, uint64 deadline, uint8 active) = desk.pending(r.id);
            assertEq(active, r.active ? r.stream + 1 : 0);
            assertEq(s, r.active ? r.slot : 0);
            assertEq(deadline, r.active ? r.deadline : 0);
        }
        for (uint256 i; i < acceptedMessages.length; ++i) {
            assertTrue(desk.consumed(acceptedMessages[i].requestId), "UUID consumption was undone");
            assertTrue(desk.delivered(acceptedDeliveryKeys[i]), "delivery consumption was undone");
        }
        assertEq(desk.lastLetterHash(), expectedLetter);
        assertEq(desk.lastFailure(), expectedFailure);
    }

    function checkAuthorityAndBounds() external view {
        assertEq(address(desk.registry()), address(game.registry));
        assertEq(keccak256(abi.encode(desk.oracleConfig())), initialOracleConfig);
        assertEq(keccak256(abi.encode(desk.bindingConfig())), initialBindingConfig);
        assertEq(desk.oracleSigner(), vm.addr(0x123456));
        assertEq(game.params.swarmWallet(), address(desk));
        assertLe(desk.districtHint(), 7);
        for (uint256 i; i < 45; ++i) {
            (uint256 lo, uint256 hi) = game.params.bounds(Params.Key(i));
            assertGe(game.params.get(Params.Key(i)), lo);
            assertLe(game.params.get(Params.Key(i)), hi);
        }
        for (uint256 e = game.rewards.epoch() + 1; e <= game.rewards.epoch() + 2; ++e) {
            if (game.grid.planAt(e).submitted) {
                assertGe(game.grid.planAt(e).severity, 5000);
                assertLe(game.grid.planAt(e).severity, 7000);
                assertLe(uint256(game.grid.planAt(e).kind), 7, "disabled civic event escaped clamp");
            }
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmDeskInvariantsTest is SwarmDeskTestFixture {
    SwarmDeskHandler private handler;

    function setUp() public override {
        super.setUp();
        address carol = makeAddr("swarm invariant carol");
        token.transfer(carol, 100 ether);
        handler = new SwarmDeskHandler(desk, token, probe, d, [alice, bob, carol]);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.ask.selector;
        selectors[3] = handler.relay.selector;
        selectors[4] = handler.answerBackup.selector;
        selectors[5] = handler.failure.selector;
        selectors[6] = handler.clear.selector;
        selectors[7] = handler.replay.selector;
        selectors[8] = handler.forgedAnswer.selector;
        selectors[9] = handler.execute.selector;
        selectors[10] = handler.tryPrivileges.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetSender(alice);
        targetSender(bob);
        targetSender(carol);
    }

    function invariantDonationsCanOnlyPayBoundedBackupRequests() public view {
        handler.checkCustody();
    }

    function invariantOracleStateMatchesIndependentLifecycle() public view {
        handler.checkOracleState();
    }

    function invariantBindingAuthorityAndGameBoundsNeverChange() public view {
        handler.checkAuthorityAndBounds();
    }

    /// @dev A deterministic reachability check prevents an all-reverting/vacuous handler from
    /// appearing to test custody or execution. The invariant campaign starts with fresh state.
    function testHandlerReachesPaidDirectRelayExecutionFailureAndTimeout() public {
        handler.donate(0, 1 ether);
        handler.ask(0, 0.5 ether, false, 0);
        handler.answerBackup(0, 0);
        handler.execute(0, false, 1);
        handler.replay(0, 2);
        handler.ask(1, 0.5 ether, false, 2);
        handler.failure(1, 1, 0);
        handler.relay(1, type(uint256).max, true, 2);
        handler.execute(1, false, 0);
        handler.advance(6 hours);
        handler.ask(0, 1, false, 1);
        handler.advance(1 hours);
        handler.clear(2, 2);
        handler.forgedAnswer(0, 0, 1);
        handler.tryPrivileges(2);
        assertEq(handler.acceptedCount(), 2);
        assertEq(handler.executedCount(), 2);
        assertEq(handler.failedCount(), 1);
        assertEq(handler.clearedCount(), 1);
        assertEq(handler.spent(), 1 ether + 1);
        handler.checkCustody();
        handler.checkOracleState();
        handler.checkAuthorityAndBounds();
    }
}
