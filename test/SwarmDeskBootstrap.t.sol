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
}
