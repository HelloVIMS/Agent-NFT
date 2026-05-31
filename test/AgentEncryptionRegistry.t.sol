// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/AgentIdentityRegistry.sol";
import "../src/AgentEncryptionRegistry.sol";

contract AgentEncryptionRegistryTest is Test {
    AgentIdentityRegistry    identity;
    AgentEncryptionRegistry  enc;

    address owner   = address(0xA11CE);
    address creator = address(0xC0FFEE);
    address eve     = address(0xBADCAFE);

    uint256 agentId;

    // Two distinct X25519 pubkeys (32 bytes each). Contents are arbitrary —
    // the registry doesn't decode the curve point, it just stores bytes32.
    bytes32 constant PUB_A = bytes32(uint256(0x1111111111111111111111111111111111111111111111111111111111111111));
    bytes32 constant PUB_B = bytes32(uint256(0x2222222222222222222222222222222222222222222222222222222222222222));

    function _wrap(bytes1 tag) internal pure returns (bytes memory) {
        // Synthetic wrapped-privkey blob: version byte + nonce + salt + ct.
        // 1 + 12 + 32 + 32 = 77 bytes, well under the 1 KiB cap.
        bytes memory b = new bytes(77);
        b[0] = tag;
        for (uint256 i = 1; i < b.length; i++) b[i] = bytes1(uint8(i));
        return b;
    }

    function setUp() public {
        vm.startPrank(owner);
        AgentIdentityRegistry idImpl = new AgentIdentityRegistry();
        identity = AgentIdentityRegistry(address(new ERC1967Proxy(
            address(idImpl), abi.encodeCall(AgentIdentityRegistry.initialize, ())
        )));

        AgentEncryptionRegistry encImpl = new AgentEncryptionRegistry();
        enc = AgentEncryptionRegistry(address(new ERC1967Proxy(
            address(encImpl), abi.encodeCall(AgentEncryptionRegistry.initialize, (address(identity)))
        )));
        vm.stopPrank();

        vm.prank(creator);
        agentId = identity.registerAgent("Agent", "ipfs://meta", 1000, address(0));
    }

    // ─── publish ────────────────────────────────────────────────────────

    function test_Publish_HappyPath_BumpsVersionToOne() public {
        bytes memory blob = _wrap(0x01);

        vm.expectEmit(true, true, true, false, address(enc));
        emit AgentEncryptionRegistry.KeyPublished(agentId, PUB_A, 1, creator, 0);

        vm.prank(creator);
        enc.publish(agentId, PUB_A, blob);

        assertEq(enc.getPubkey(agentId), PUB_A);
        assertEq(enc.getVersion(agentId), 1);
        assertTrue(enc.isInitialised(agentId));
        assertEq(enc.getWrappedPrivkey(agentId), blob);
    }

    function test_Publish_RevertsForNonOwner() public {
        vm.prank(eve);
        vm.expectRevert(AgentEncryptionRegistry.NotAgentOwner.selector);
        enc.publish(agentId, PUB_A, _wrap(0x01));
    }

    function test_Publish_RevertsOnSecondCall() public {
        vm.prank(creator);
        enc.publish(agentId, PUB_A, _wrap(0x01));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AgentEncryptionRegistry.AlreadyInitialised.selector, agentId));
        enc.publish(agentId, PUB_B, _wrap(0x02));
    }

    function test_Publish_RejectsZeroPubkey() public {
        vm.prank(creator);
        vm.expectRevert(AgentEncryptionRegistry.ZeroPubkey.selector);
        enc.publish(agentId, bytes32(0), _wrap(0x01));
    }

    function test_Publish_RejectsEmptyWrappedPrivkey() public {
        vm.prank(creator);
        vm.expectRevert(AgentEncryptionRegistry.WrappedPrivkeyEmpty.selector);
        enc.publish(agentId, PUB_A, "");
    }

    function test_Publish_RejectsOversizedWrappedPrivkey() public {
        // 1025 bytes — one over the cap.
        bytes memory tooBig = new bytes(1025);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentEncryptionRegistry.WrappedPrivkeyTooLarge.selector, uint256(1025), uint256(1024)
            )
        );
        enc.publish(agentId, PUB_A, tooBig);
    }

    // ─── rotate ─────────────────────────────────────────────────────────

    function test_Rotate_BumpsVersion_AtomicallySwapsAllFields() public {
        vm.prank(creator);
        enc.publish(agentId, PUB_A, _wrap(0x01));

        bytes memory blobB = _wrap(0x02);

        vm.expectEmit(true, true, true, true, address(enc));
        emit AgentEncryptionRegistry.KeyRotated(agentId, PUB_A, PUB_B, 2, creator, uint64(block.timestamp));

        vm.prank(creator);
        enc.rotate(agentId, PUB_B, blobB);

        (bytes32 p, uint64 v, , bytes memory wrapped) = enc.getRecord(agentId);
        assertEq(p, PUB_B);
        assertEq(v, 2);
        assertEq(wrapped, blobB);
    }

    function test_Rotate_MultipleTimes_VersionMonotone() public {
        vm.prank(creator);
        enc.publish(agentId, PUB_A, _wrap(0x01));

        for (uint256 i = 0; i < 5; ++i) {
            bytes32 p = bytes32(uint256(uint160(uint256(keccak256(abi.encode("p", i))))));
            vm.prank(creator);
            enc.rotate(agentId, p, _wrap(bytes1(uint8(i + 10))));
            assertEq(enc.getVersion(agentId), uint64(i + 2));
        }
    }

    function test_Rotate_RevertsBeforePublish() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AgentEncryptionRegistry.NotYetInitialised.selector, agentId));
        enc.rotate(agentId, PUB_B, _wrap(0x02));
    }

    function test_Rotate_RevertsForNonOwner() public {
        vm.prank(creator);
        enc.publish(agentId, PUB_A, _wrap(0x01));

        vm.prank(eve);
        vm.expectRevert(AgentEncryptionRegistry.NotAgentOwner.selector);
        enc.rotate(agentId, PUB_B, _wrap(0x02));
    }

    function test_Rotate_FollowsNFTOwnership() public {
        vm.prank(creator);
        enc.publish(agentId, PUB_A, _wrap(0x01));

        address newOwner = address(0xFEED);
        vm.prank(creator);
        identity.transferFrom(creator, newOwner, agentId);

        // Old owner can no longer rotate…
        vm.prank(creator);
        vm.expectRevert(AgentEncryptionRegistry.NotAgentOwner.selector);
        enc.rotate(agentId, PUB_B, _wrap(0x02));

        // …new owner can.
        vm.prank(newOwner);
        enc.rotate(agentId, PUB_B, _wrap(0x02));
        assertEq(enc.getPubkey(agentId), PUB_B);
        assertEq(enc.getVersion(agentId), 2);
    }

    // ─── views ──────────────────────────────────────────────────────────

    function test_Views_UninitialisedAgent_ReturnsZeroes() public view {
        assertEq(enc.getPubkey(agentId), bytes32(0));
        assertEq(enc.getVersion(agentId), 0);
        assertFalse(enc.isInitialised(agentId));
        assertEq(enc.getWrappedPrivkey(agentId).length, 0);
    }

    function test_GetRecord_ReturnsAllFieldsAtomically() public {
        bytes memory blob = _wrap(0x07);
        vm.prank(creator);
        enc.publish(agentId, PUB_A, blob);

        (bytes32 p, uint64 v, uint64 t, bytes memory w) = enc.getRecord(agentId);
        assertEq(p, PUB_A);
        assertEq(v, 1);
        assertEq(t, uint64(block.timestamp));
        assertEq(w, blob);
    }
}
