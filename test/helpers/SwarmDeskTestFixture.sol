// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../Base.t.sol";
import {SwarmDesk, ISwarmIntake} from "../../src/SwarmDesk.sol";
import {OracleAttestation} from "../../src/oracle/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Offline dependency probe. Faults model an external call failing after the token pull,
/// and invalid request IDs; no mock bypasses the Desk's signature or binding checks.
contract SwarmDeskIntakeProbe is ISwarmIntake {
    error RequestFailedAfterPayment();

    uint256 public price;
    uint256 public requests;
    uint8 public fault;
    bytes32 public fixedId;
    bytes32 public lastAction;
    bytes public lastBody;
    address public lastAsset;
    uint256 public lastAmount;
    bytes4 public lastFailureSelector;
    mapping(bytes32 => Callback) public callbacks;

    function configure(uint256 price_, uint8 fault_, bytes32 id_) external {
        price = price_;
        fault = fault_;
        fixedId = id_;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata cb,
        bytes4 failure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        require(msg.value == 0 && amount == price, "incorrect payment");
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "pull failed");
        ++requests;
        lastAction = action;
        lastBody = body;
        lastAsset = asset;
        lastAmount = amount;
        lastFailureSelector = failure;
        if (fault == 3) revert RequestFailedAfterPayment();
        id = fault == 1 ? bytes32(0) : fault == 2 ? fixedId : keccak256(abi.encode(address(this), requests));
        callbacks[id] = cb;
    }

    function result(bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata sig)
        external
        returns (bool ok)
    {
        Callback memory cb = callbacks[id];
        (ok,) = cb.target.call{gas: 200_000}(abi.encodeWithSelector(cb.selector, id, a, sig));
    }
}

/// @dev Reuses the accepted full-game fixture and its explicitly test-only signing key.
/// Exact production constructor words remain covered separately by SwarmDeskBootstrapTest.
abstract contract SwarmDeskTestFixture is BaseTest {
    SwarmDeskIntakeProbe internal probe;
    uint256 internal answerNonce;

    function launchFeatures() internal pure override returns (bool) {
        return false;
    }

    function setUp() public virtual override {
        super.setUp();
        vm.chainId(4663);
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(uint256(1000)));
        vm.warp((block.timestamp / 7 days + 1) * 7 days + 2 hours);
        address intake = desk.oracleConfig().intake;
        vm.etch(intake, vm.getDeployedCode("SwarmDeskTestFixture.sol:SwarmDeskIntakeProbe"));
        probe = SwarmDeskIntakeProbe(intake);
        probe.configure(0.5 ether, 0, bytes32(0));
        token.transfer(address(desk), 20 ether);
    }

    function body(uint8 stream) internal pure returns (bytes memory) {
        return stream == 0 ? bytes("event body") : bytes("regulator body");
    }

    function values(uint8 stream) internal view returns (bytes32[] memory v) {
        v = new bytes32[](stream == 0 ? 7 : 17);
        v[0] = bytes32(desk.slot(stream));
        if (stream == 0) {
            v[1] = bytes32(d.rewards.epoch());
            v[2] = bytes32(uint256(1));
            v[3] = bytes32(uint256(6000));
            v[4] = bytes32(uint256(2));
            v[5] = keccak256("adversarial fixture entropy");
        }
        v[v.length - 1] = keccak256("adversarial fixture public letter");
    }

    function answer(uint8 stream) internal returns (OracleAttestation.Attestation memory a) {
        SwarmDesk.OracleConfig memory o = desk.oracleConfig();
        a.requestId = keccak256(abi.encode("test oracle UUID", ++answerNonce));
        a.chainId = o.questionChain;
        a.questionHash = o.questions[stream];
        a.answerType = 5;
        a.answer = abi.encode(values(stream));
        a.fromBlock = o.fromBlock;
        a.toBlock = o.toBlock;
        a.blockHash = keccak256("test context block");
        a.panelJobId = keccak256("test panel job");
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x123456, desk.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function stored(uint8 stream) internal view returns (SwarmDesk.Result memory r) {
        (r.answerHash, r.requestId, r.issuedAt, r.validUntil, r.slot, r.pending, r.receivedBlock) =
            desk.lastAnswer(stream);
    }

    function assertUnaccepted(OracleAttestation.Attestation memory a, uint8 stream) internal view {
        assertFalse(desk.consumed(a.requestId), "invalid UUID consumed");
        assertEq(desk.acceptedSlotPlusOne(stream), 0, "invalid answer occupied slot");
        assertEq(stored(stream).answerHash, bytes32(0), "invalid answer stored");
        assertEq(token.balanceOf(address(desk)), 20 ether, "invalid answer moved funds");
    }
}
