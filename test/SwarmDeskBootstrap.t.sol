// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {LocalApplicationFactory} from "../script/Deploy.s.sol";
import "../src/lib/Errors.sol";

/// @dev Offline launch rehearsal only. No live RPC, signing, broadcasting or reserved launch number.
contract SwarmDeskBootstrapTest is Test {
    address constant FACTORY = address(bytes20(hex"9c9d2fcb75c2c132c0ac0c42df3819a42347265e"));
    bytes32 constant CREATION_HASH = 0x65968358bcf87aa8839b8bce6b2d339493deac3f77d75a3ff0b3ad4f35955745;
    bytes32 constant GAME_CONFIG_HASH = 0x11ed7438974e96ecc962201e9c46422c7bf239d725876863fa25a56c734b20d3;

    function setUp() public {
        vm.chainId(4663);
        vm.etch(FACTORY, vm.getDeployedCode("Deploy.s.sol:LocalApplicationFactory"));
    }

    function constructorArgs() internal pure returns (bytes memory) {
        // The approved words, independently encoded in two static halves to fit non-via-IR compilation.
        return bytes.concat(
            abi.encode(
                address(bytes20(hex"a43e6f75ee006411f79ac1c84120606c2330de82")),
                address(bytes20(hex"ce0e6a670aa75e161d02aca3c7f00b94ca428ccb")),
                address(bytes20(hex"5598aa9146215bc13eb26f2c692ad1461fd32982")),
                address(bytes20(hex"5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127")),
                bytes32(0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000),
                uint256(5391989333430298100116863486635657822062725418115979424500284366258177)
            ),
            abi.encode(
                bytes32(0x2fc5a57f2c5f7bc083ea8ac5016234f1a0b1c68a514e5d921956cc57948534ef),
                bytes32(0xc13efed8438aab53ea052a4507def2dc4ce9856765520dfa28c66daa59cfc11d),
                bytes32(0x00e69e4445c7ca7256338293f9f9cea439fd2beb1959d1d43ebec7b14493e2f6),
                bytes32(0xc0ae7511b06744cf7ccadc6b60ff9ff96cb7234cf32988850df33324861cc8df),
                FACTORY,
                GAME_CONFIG_HASH
            )
        );
    }

    function initCode() internal view returns (bytes memory) {
        bytes memory code = vm.getCode("SwarmDesk.sol:SwarmDesk");
        assertEq(keccak256(code), CREATION_HASH, "launch creation-code pin");
        bytes memory args = constructorArgs();
        assertEq(args.length, 12 * 32, "exactly twelve static constructor words");
        return bytes.concat(code, args);
    }

    function deployDesk() internal returns (SwarmDesk) {
        // Coordinates (1,0) exist only inside this local fixture and are never launch inputs.
        return SwarmDesk(LocalApplicationFactory(FACTORY).deploy(1, 0, initCode()));
    }

    function testFactoryDeploysExactlyOneUnboundDeskWithoutExternalCalls() public {
        bytes memory code = initCode();
        assertLe(code.length, 49_152, "EIP-3860 init-code limit");
        address predicted = LocalApplicationFactory(FACTORY).predictContract(1, 0, code);
        vm.startStateDiffRecording();
        address deployed = LocalApplicationFactory(FACTORY).deploy(1, 0, code);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(deployed, predicted);
        emit log_named_address("Offline SwarmDesk bootstrap (not a live deployment)", deployed);
        uint256 creations;
        for (uint256 i; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory a = accesses[i];
            if (a.kind == VmSafe.AccountAccessKind.Create) {
                ++creations;
                assertEq(a.account, deployed);
                assertEq(a.accessor, FACTORY);
                assertEq(a.value, 0);
                assertFalse(a.reverted);
            }
            if (a.accessor == deployed) {
                assertTrue(
                    a.kind != VmSafe.AccountAccessKind.Call && a.kind != VmSafe.AccountAccessKind.StaticCall
                        && a.kind != VmSafe.AccountAccessKind.DelegateCall
                        && a.kind != VmSafe.AccountAccessKind.CallCode,
                    "constructor made an external call"
                );
            }
        }
        assertEq(creations, 1, "bootstrap creates only SwarmDesk");
        SwarmDesk desk = SwarmDesk(deployed);
        assertEq(address(desk.registry()), address(0));
        SwarmDesk.BindingConfig memory b = desk.bindingConfig();
        assertEq(b.factory, FACTORY);
        assertEq(b.gameConfigHash, GAME_CONFIG_HASH);
        assertEq(b.registryLaunch, 0);
        assertEq(b.registryIndex, 0);
        assertEq(b.paramsLaunch, 0);
        assertEq(b.paramsIndex, 0);
        assertEq(b.heartbeatBps, 200);
        assertEq(b.heartbeatCap, 1 ether);
        SwarmDesk.OracleConfig memory o = desk.oracleConfig();
        assertEq(o.intake, address(bytes20(hex"a43e6f75ee006411f79ac1c84120606c2330de82")));
        assertEq(o.delivery, address(bytes20(hex"ce0e6a670aa75e161d02aca3c7f00b94ca428ccb")));
        assertEq(o.signer, address(bytes20(hex"5598aa9146215bc13eb26f2c692ad1461fd32982")));
        assertEq(o.asset, address(bytes20(hex"5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127")));
        assertEq(o.action, bytes32("oracle.request@oracle-1"));
        assertEq(o.maxPrice, 500000000000000000);
        assertEq(o.questionChain, 1);
        assertEq(o.fromBlock, 26122900);
        assertEq(o.toBlock, 26122901);
        assertEq(desk.oracleSigner(), o.signer);
        assertEq(o.questions[0], 0x2fc5a57f2c5f7bc083ea8ac5016234f1a0b1c68a514e5d921956cc57948534ef);
        assertEq(o.questions[1], 0xc13efed8438aab53ea052a4507def2dc4ce9856765520dfa28c66daa59cfc11d);
        assertEq(o.bodies[0], 0x00e69e4445c7ca7256338293f9f9cea439fd2beb1959d1d43ebec7b14493e2f6);
        assertEq(o.bodies[1], 0xc0ae7511b06744cf7ccadc6b60ff9ff96cb7234cf32988850df33324861cc8df);
    }

    function testRuntimeSizeAndForbiddenOpcodes() public {
        bytes memory code = address(deployDesk()).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }

    function testUnboundDeskRejectsOracleAndBackupActions() public {
        SwarmDesk desk = deployDesk();
        OracleAttestation.Attestation memory a;
        vm.expectRevert(NotConfigured.selector);
        desk.submit(a, "");
        vm.expectRevert(NotConfigured.selector);
        desk.askBackup(0, "");
        vm.expectRevert(InvalidProof.selector);
        desk.execute(0, "");
        assertEq(address(desk.registry()), address(0));
        assertEq(desk.bindingConfig().gameConfigHash, GAME_CONFIG_HASH);
    }

    function testEip712DomainUsesRobinhoodAndDeployedDesk() public {
        SwarmDesk desk = deployDesk();
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            desk.eip712Domain();
        assertEq(name, "IdentityMD Oracle");
        assertEq(version, "2");
        assertEq(chainId, 4663);
        assertEq(verifyingContract, address(desk));
    }

    function replaceWord(bytes memory args, uint256 index, uint256 value) internal pure {
        assembly ("memory-safe") { mstore(add(add(args, 32), mul(index, 32)), value) }
    }

    /// @dev All twelve words are mandatory, including every commitment and packed policy.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzzConstructorRejectsEachZeroWord(uint8 rawWord) public {
        bytes memory args = constructorArgs();
        replaceWord(args, bound(rawWord, 0, 11), 0);
        bytes memory code = vm.getCode("SwarmDesk.sol:SwarmDesk");
        vm.expectRevert(InvalidValue.selector); // Local factory reports a failed CREATE2.
        LocalApplicationFactory(FACTORY).deploy(1, 0, bytes.concat(code, args));
        assertFalse(LocalApplicationFactory(FACTORY).used(1, 0), "failed deployment occupied the coordinate");
    }

    function testConstructorRejectsDuplicateTransportsAndQuestions() public {
        bytes memory args = constructorArgs();
        replaceWord(args, 1, uint160(address(bytes20(hex"a43e6f75ee006411f79ac1c84120606c2330de82"))));
        bytes memory code = vm.getCode("SwarmDesk.sol:SwarmDesk");
        vm.expectRevert(InvalidValue.selector);
        LocalApplicationFactory(FACTORY).deploy(1, 0, bytes.concat(code, args));
        args = constructorArgs();
        replaceWord(args, 7, uint256(0x2fc5a57f2c5f7bc083ea8ac5016234f1a0b1c68a514e5d921956cc57948534ef));
        vm.expectRevert(InvalidValue.selector);
        LocalApplicationFactory(FACTORY).deploy(1, 0, bytes.concat(code, args));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzConstructorRejectsReservedBitsAndPolicyBoundaries(uint8 rawCase, uint16 raw) public {
        uint256 policy = 5391989333430298100116863486635657822062725418115979424500284366258177;
        uint256 which = bound(rawCase, 0, 5);
        if (which == 0) policy |= bound(raw, 1, type(uint16).max) << 240;
        if (which == 1) policy = (policy & ~(uint256(type(uint16).max) << 224)) | (bound(raw, 0, 199) << 224);
        if (which == 2) policy = (policy & ~(uint256(type(uint16).max) << 224)) | (bound(raw, 5001, 65535) << 224);
        if (which == 3) policy &= ~(uint256(type(uint96).max) << 128);
        if (which == 4) policy &= ~uint256(type(uint32).max);
        if (which == 5) {
            policy &= ~(uint256(type(uint48).max) << 80);
            policy |= uint256(26122899) << 80; // toBlock immediately before the pinned fromBlock.
        }
        bytes memory args = constructorArgs();
        replaceWord(args, 5, policy);
        bytes memory code = vm.getCode("SwarmDesk.sol:SwarmDesk");
        vm.expectRevert(InvalidValue.selector);
        LocalApplicationFactory(FACTORY).deploy(1, 0, bytes.concat(code, args));
        assertFalse(LocalApplicationFactory(FACTORY).used(1, 0));
    }

    /// @dev Exercise packed field isolation at the full supported integer widths. These are
    /// alternate local constructor inputs, never replacements for the launch's approved words.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzzPackedFieldsRoundTripWithoutCrossFieldContamination(
        uint32 chain,
        uint48 from,
        uint48 rawTo,
        uint96 price,
        uint16 heartbeat
    ) public {
        chain = uint32(bound(chain, 1, type(uint32).max));
        uint48 to = uint48(bound(rawTo, from, type(uint48).max));
        price = uint96(bound(price, 1, type(uint96).max));
        heartbeat = uint16(bound(heartbeat, 200, 5000));
        uint256 policy = uint256(chain) | (uint256(from) << 32) | (uint256(to) << 80) | (uint256(price) << 128)
            | (uint256(heartbeat) << 224);
        bytes memory args = constructorArgs();
        replaceWord(args, 5, policy);
        SwarmDesk desk = SwarmDesk(
            LocalApplicationFactory(FACTORY).deploy(1, 0, bytes.concat(vm.getCode("SwarmDesk.sol:SwarmDesk"), args))
        );
        SwarmDesk.OracleConfig memory o = desk.oracleConfig();
        assertEq(o.questionChain, chain);
        assertEq(o.fromBlock, from);
        assertEq(o.toBlock, to);
        assertEq(o.maxPrice, price);
        assertEq(desk.bindingConfig().heartbeatBps, heartbeat);
        assertEq(desk.bindingConfig().heartbeatCap, 1 ether);
        assertEq(desk.bindingConfig().gameConfigHash, GAME_CONFIG_HASH);
        assertEq(address(desk.registry()), address(0));
    }

    function testConstructorCannotReceiveNativeValue() public {
        bytes memory code = initCode();
        vm.deal(address(this), 1);
        address result;
        assembly ("memory-safe") { result := create(1, add(code, 32), mload(code)) }
        assertEq(result, address(0));
        assertEq(address(this).balance, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzUnboundDeskRejectsInvalidBindingCoordinates(uint8 rawCase, uint8 rawIndex) public {
        SwarmDesk desk = deployDesk();
        uint256 which = bound(rawCase, 0, 3);
        uint64 registryLaunch = which == 0 ? 0 : 1;
        uint64 paramsLaunch = which == 1 ? 0 : 1;
        uint8 registryIndex = which == 2 ? uint8(bound(rawIndex, 8, 255)) : 0;
        uint8 paramsIndex = which == 3 ? uint8(bound(rawIndex, 8, 255)) : 0;
        vm.expectRevert(InvalidValue.selector);
        desk.bind(FACTORY, "", "", registryLaunch, registryIndex, paramsLaunch, paramsIndex);
        assertEq(address(desk.registry()), address(0));
        assertEq(desk.bindingConfig().registryLaunch, 0);
        assertEq(desk.bindingConfig().paramsLaunch, 0);
    }

    function testUnboundDeskRejectsEveryActionAndUnknownPrivilegeSelector() public {
        SwarmDesk desk = deployDesk();
        OracleAttestation.Attestation memory a;
        SwarmDesk.OracleConfig memory o = desk.oracleConfig();
        vm.expectRevert(Unauthorized.selector);
        desk.onOracleResult(bytes32(uint256(1)), a, "");
        vm.expectRevert(NotConfigured.selector);
        vm.prank(o.intake);
        desk.onOracleResult(bytes32(uint256(1)), a, "");
        vm.expectRevert(NotConfigured.selector);
        vm.prank(o.delivery);
        desk.onOracleResult(bytes32(uint256(1)), a, "");
        vm.expectRevert(NotConfigured.selector);
        desk.askBackup(1, "");
        vm.expectRevert(InvalidValue.selector);
        desk.askBackup(2, "");
        vm.expectRevert(InvalidValue.selector);
        desk.execute(2, "");
        vm.expectRevert(TooEarly.selector);
        desk.clearExpired(bytes32(uint256(1)));
        vm.expectRevert(Unauthorized.selector);
        desk.onOracleFailure(bytes32(uint256(1)), 1, 0, 0, 0, "");
        (bool ok,) = address(desk).call(abi.encodeWithSignature("withdraw(address,uint256)", address(this), 1));
        assertFalse(ok);
        (ok,) = address(desk).call(abi.encodeWithSignature("setOracleSigner(address)", address(this)));
        assertFalse(ok);
        (ok,) = address(desk).call(abi.encodeWithSignature("upgradeTo(address)", address(this)));
        assertFalse(ok);
        assertEq(address(desk.registry()), address(0));
        assertEq(desk.bindingConfig().gameConfigHash, GAME_CONFIG_HASH);
    }
}
