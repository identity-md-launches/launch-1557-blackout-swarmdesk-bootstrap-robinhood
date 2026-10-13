// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmDeskTestFixture} from "./helpers/SwarmDeskTestFixture.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {SwarmArgs} from "../script/SwarmArgs.sol";
import {LocalApplicationFactory} from "../script/Deploy.s.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {Params} from "../src/Params.sol";
import "../src/lib/Errors.sol";

/// @dev Honest and invalid local factory proofs. The production game commitment remains
/// opaque; this fixture derives its own commitment from the existing test game's explicit inputs.
contract SwarmDeskBindingTest is SwarmDeskTestFixture {
    SwarmDesk private subject;
    LocalApplicationFactory private factory;
    Params private params;
    GameRegistry private candidate;
    bytes private registryCode;
    bytes private paramsCode;
    bytes32 private initialBinding;
    event Bound(address indexed registry);

    function setUp() public override {
        super.setUp();
        factory = new LocalApplicationFactory();
        SwarmDesk.BindingConfig memory b = desk.bindingConfig();
        b.factory = address(factory);
        b.registryLaunch = 0;
        b.registryIndex = 0;
        b.paramsLaunch = 0;
        b.paramsIndex = 0;
        subject = SwarmDesk(deployCode("SwarmDesk.sol:SwarmDesk", SwarmArgs.encode(desk.oracleConfig(), b)));
        initialBinding = keccak256(abi.encode(subject.bindingConfig()));
        paramsCode = vm.getCode("Params.sol:Params");
        registryCode = vm.getCode("GameRegistry.sol:GameRegistry");
        params = Params(
            factory.deploy(2, 7, bytes.concat(paramsCode, abi.encode(address(subject), uint256(200), uint256(1 ether))))
        );
        candidate = GameRegistry(factory.deploy(3, 7, bytes.concat(registryCode, registryArgs(address(params)))));
    }

    function registryArgs(address p) private view returns (bytes memory) {
        return abi.encode(
            address(token),
            p,
            address(market),
            d.registry.starterRoot(),
            d.registry.freeRoot(),
            d.registry.snapshotBlock(),
            d.registry.endowment(),
            address(factory)
        );
    }

    function bind() private {
        subject.bind(address(candidate), registryCode, paramsCode, 3, 7, 2, 7);
    }

    function assertStillUnbound() private view {
        assertEq(address(subject.registry()), address(0));
        assertEq(keccak256(abi.encode(subject.bindingConfig())), initialBinding, "failed proof changed binding");
    }

    function testPermissionlessBindAtIndexSevenAcrossSeparateLaunchesIsFinal() public {
        vm.expectEmit(true, false, false, true, address(subject));
        emit Bound(address(candidate));
        vm.prank(alice);
        bind();
        assertEq(address(subject.registry()), address(candidate));
        SwarmDesk.BindingConfig memory b = subject.bindingConfig();
        assertEq(b.registryLaunch, 3);
        assertEq(b.registryIndex, 7);
        assertEq(b.paramsLaunch, 2);
        assertEq(b.paramsIndex, 7);
        assertEq(params.swarmWallet(), address(subject));
        vm.expectRevert(AlreadyDone.selector);
        vm.prank(bob);
        bind();
        assertEq(address(subject.registry()), address(candidate));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzEachFrozenGameFieldMustMatchCommitment(uint8 rawField) public {
        uint256 word = bound(rawField, 0, 3) + 3;
        bytes memory args = registryArgs(address(params));
        // Toggle one bit of starterRoot, freeRoot, snapshotBlock, or endowment. The candidate
        // is genuinely factory-created with the right code, so only the commitment is wrong.
        assembly ("memory-safe") {
            let at := add(add(args, 32), mul(word, 32))
            mstore(at, xor(mload(at), 1))
        }
        address wrong = factory.deploy(4, 0, bytes.concat(registryCode, args));
        vm.expectRevert(InvalidProof.selector);
        subject.bind(wrong, registryCode, paramsCode, 4, 0, 2, 7);
        assertStillUnbound();
        bind();
        assertEq(address(subject.registry()), address(candidate));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzOneByteChangedCreationProofCannotBind(bool changeRegistry, uint256 rawOffset) public {
        bytes memory changed = changeRegistry ? registryCode : paramsCode;
        uint256 offset = bound(rawOffset, 0, changed.length - 1);
        changed[offset] ^= bytes1(uint8(1));
        bytes memory rCode = changeRegistry ? changed : registryCode;
        bytes memory pCode = changeRegistry ? paramsCode : changed;
        vm.expectRevert(InvalidProof.selector);
        subject.bind(address(candidate), rCode, pCode, 3, 7, 2, 7);
        assertStillUnbound();
    }

    function testCorrectProofAtWrongCoordinatesCannotPartiallyBind() public {
        vm.expectRevert(InvalidProof.selector);
        subject.bind(address(candidate), registryCode, paramsCode, 4, 7, 2, 7);
        assertStillUnbound();
        vm.expectRevert(InvalidProof.selector);
        subject.bind(address(candidate), registryCode, paramsCode, 3, 6, 2, 7);
        assertStillUnbound();
        vm.expectRevert(InvalidProof.selector);
        subject.bind(address(candidate), registryCode, paramsCode, 3, 7, 4, 7);
        assertStillUnbound();
        vm.expectRevert(InvalidProof.selector);
        subject.bind(address(candidate), registryCode, paramsCode, 3, 7, 2, 6);
        assertStillUnbound();
        bind();
        assertEq(address(subject.registry()), address(candidate));
    }

    function testMissingParamsCodeRejectsUntilDependencyExists() public {
        bytes memory runtime = address(params).code;
        vm.etch(address(params), "");
        vm.expectRevert(InvalidProof.selector);
        bind();
        assertStillUnbound();
        vm.etch(address(params), runtime);
        bind();
        assertEq(address(subject.registry()), address(candidate));
    }

    function testWrongParamsHeartbeatAndWalletCannotSubstituteForCommittedInitCode() public {
        for (uint256 i; i < 2; ++i) {
            address wallet = i == 0 ? address(subject) : bob;
            uint256 bps = i == 0 ? 201 : 200;
            address other = factory.deploy(4, i, bytes.concat(paramsCode, abi.encode(wallet, bps, uint256(1 ether))));
            address wrong = factory.deploy(5, i, bytes.concat(registryCode, registryArgs(other)));
            vm.expectRevert(InvalidProof.selector);
            subject.bind(wrong, registryCode, paramsCode, 5, uint8(i), 4, uint8(i));
            assertStillUnbound();
        }
    }

    function testRegistryCannotPointToOtherParamsEvenWithBothContractsFactoryCreated() public {
        address other = factory.deploy(
            4, 0, bytes.concat(paramsCode, abi.encode(address(subject), uint256(200), uint256(1 ether)))
        );
        address wrong = factory.deploy(5, 0, bytes.concat(registryCode, registryArgs(other)));
        vm.expectRevert(InvalidProof.selector);
        subject.bind(wrong, registryCode, paramsCode, 5, 0, 2, 7);
        assertStillUnbound();
        // The proof becomes valid only when it proves the actual Params constructor/address.
        subject.bind(wrong, registryCode, paramsCode, 5, 0, 4, 0);
        assertEq(address(subject.registry()), wrong);
    }

    function testRegistryDeployedOutsideFactoryIsNotAuthenticatedByMatchingRuntime() public {
        address lookalike = deployCode("GameRegistry.sol:GameRegistry", registryArgs(address(params)));
        assertEq(lookalike.codehash, address(candidate).codehash, "identical immutable configuration");
        vm.expectRevert(InvalidProof.selector);
        subject.bind(lookalike, registryCode, paramsCode, 3, 7, 2, 7);
        assertStillUnbound();
    }

    function testWrongFactoryAndCodelessRegistryCannotBind() public {
        bytes memory args = registryArgs(address(params));
        address wrongFactory = makeAddr("test foreign factory");
        assembly ("memory-safe") { mstore(add(args, 256), wrongFactory) }
        address wrong = factory.deploy(4, 0, bytes.concat(registryCode, args));
        vm.expectRevert(InvalidProof.selector);
        subject.bind(wrong, registryCode, paramsCode, 4, 0, 2, 7);
        assertStillUnbound();
        vm.expectRevert(); // No ABI return data from a nonexistent registry.
        subject.bind(alice, registryCode, paramsCode, 3, 7, 2, 7);
        assertStillUnbound();
    }
}
