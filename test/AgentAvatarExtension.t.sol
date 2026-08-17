// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentAvatarExtension} from "../src/AgentAvatarExtension.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Minimal stub honouring only `ownerOf`, the sole method
///      AgentAvatarExtension calls on the identity registry.
contract MockIdentityRegistry {
    mapping(uint256 => address) public owners;
    function setOwner(uint256 id, address who) external { owners[id] = who; }
    function ownerOf(uint256 id) external view returns (address) { return owners[id]; }
}

contract AgentAvatarExtensionTest is Test {
    AgentAvatarExtension internal ext;
    MockIdentityRegistry internal idReg;

    address internal admin    = makeAddr("admin");
    address internal agentEoa = makeAddr("agent-owner");
    address internal buyer    = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant TOKEN_A = 1;
    uint256 internal constant TOKEN_B = 2;

    bytes32 internal constant HASH_A = keccak256("manifest-a");
    bytes32 internal constant HASH_B = keccak256("manifest-b");

    string constant URI_A = "ipfs://bafybeigemmaavatar/manifest.json";
    string constant URI_B = "ipfs://bafybeigemmaavatarv2/manifest.json";

    event AvatarManifestUpdated(
        uint256 indexed tokenId,
        address indexed setter,
        string manifestURI,
        bytes32 contentHash,
        uint16 version,
        uint16 fileCount
    );
    event AvatarManifestCleared(uint256 indexed tokenId, address indexed setter);

    function setUp() public {
        idReg = new MockIdentityRegistry();
        idReg.setOwner(TOKEN_A, agentEoa);
        idReg.setOwner(TOKEN_B, buyer);

        AgentAvatarExtension impl = new AgentAvatarExtension();
        bytes memory init = abi.encodeCall(AgentAvatarExtension.initialize, (address(idReg)));
        vm.prank(admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        ext = AgentAvatarExtension(address(proxy));
    }

    // ── init ──────────────────────────────────────────────────────

    function test_initialize_setsOwnerAndRegistry() public view {
        assertEq(ext.owner(), admin);
        assertEq(address(ext.identityRegistry()), address(idReg));
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        ext.initialize(address(idReg));
    }

    // ── setAvatarManifest ─────────────────────────────────────────

    function test_setAvatarManifest_ownerCanSet() public {
        vm.expectEmit(true, true, false, true, address(ext));
        emit AvatarManifestUpdated(TOKEN_A, agentEoa, URI_A, HASH_A, 1, 3);

        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 3);

        AgentAvatarExtension.AvatarManifest memory m = ext.getAvatarManifest(TOKEN_A);
        assertEq(m.manifestURI, URI_A);
        assertEq(m.contentHash, HASH_A);
        assertEq(m.fileCount, 3);
        assertEq(m.version, 1);
        assertTrue(m.updatedAt > 0);
        assertEq(ext.latestVersion(TOKEN_A), 1);
        assertTrue(ext.hasAvatarManifest(TOKEN_A));
    }

    function test_setAvatarManifest_strangerReverts() public {
        vm.expectRevert(AgentAvatarExtension.NotOwner.selector);
        vm.prank(stranger);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 1);
    }

    function test_setAvatarManifest_emptyURIReverts() public {
        vm.expectRevert(AgentAvatarExtension.EmptyInput.selector);
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, "", HASH_A, 1);
    }

    function test_setAvatarManifest_emptyHashReverts() public {
        vm.expectRevert(AgentAvatarExtension.EmptyInput.selector);
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, bytes32(0), 1);
    }

    function test_setAvatarManifest_uriTooLongReverts() public {
        // 513-char string, one past MAX_URI_LENGTH.
        bytes memory big = new bytes(513);
        for (uint256 i; i < big.length; i++) big[i] = "a";
        vm.expectRevert(AgentAvatarExtension.URITooLong.selector);
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, string(big), HASH_A, 1);
    }

    function test_setAvatarManifest_replaceBumpsVersion() public {
        vm.startPrank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 3);
        ext.setAvatarManifest(TOKEN_A, URI_B, HASH_B, 5);
        vm.stopPrank();

        AgentAvatarExtension.AvatarManifest memory m = ext.getAvatarManifest(TOKEN_A);
        assertEq(m.manifestURI, URI_B);
        assertEq(m.contentHash, HASH_B);
        assertEq(m.fileCount, 5);
        assertEq(m.version, 2);
        assertEq(ext.latestVersion(TOKEN_A), 2);
    }

    function test_setAvatarManifest_perTokenIsolation() public {
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 1);
        vm.prank(buyer);
        ext.setAvatarManifest(TOKEN_B, URI_B, HASH_B, 2);

        AgentAvatarExtension.AvatarManifest memory a = ext.getAvatarManifest(TOKEN_A);
        AgentAvatarExtension.AvatarManifest memory b = ext.getAvatarManifest(TOKEN_B);
        assertEq(a.manifestURI, URI_A);
        assertEq(b.manifestURI, URI_B);
        assertEq(a.version, 1);
        assertEq(b.version, 1);
    }

    // ── clearAvatarManifest ───────────────────────────────────────

    function test_clearAvatarManifest_ownerCanClear() public {
        vm.startPrank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 1);

        vm.expectEmit(true, true, false, false, address(ext));
        emit AvatarManifestCleared(TOKEN_A, agentEoa);
        ext.clearAvatarManifest(TOKEN_A);
        vm.stopPrank();

        assertFalse(ext.hasAvatarManifest(TOKEN_A));
        AgentAvatarExtension.AvatarManifest memory m = ext.getAvatarManifest(TOKEN_A);
        assertEq(bytes(m.manifestURI).length, 0);
        // latestVersion should be retained so a re-set continues the sequence.
        assertEq(ext.latestVersion(TOKEN_A), 1);
    }

    function test_clearAvatarManifest_versionContinuesAfterClear() public {
        vm.startPrank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 1);
        ext.clearAvatarManifest(TOKEN_A);
        ext.setAvatarManifest(TOKEN_A, URI_B, HASH_B, 2);
        vm.stopPrank();

        assertEq(ext.getAvatarManifest(TOKEN_A).version, 2);
    }

    function test_clearAvatarManifest_strangerReverts() public {
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 1);
        vm.expectRevert(AgentAvatarExtension.NotOwner.selector);
        vm.prank(stranger);
        ext.clearAvatarManifest(TOKEN_A);
    }

    function test_clearAvatarManifest_notSetReverts() public {
        vm.expectRevert(AgentAvatarExtension.NotExists.selector);
        vm.prank(agentEoa);
        ext.clearAvatarManifest(TOKEN_A);
    }

    // ── ownership transfer semantics ──────────────────────────────

    function test_secondarySale_newOwnerCanReplaceManifest() public {
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 1);

        // Simulate a secondary sale: token A now owned by buyer.
        idReg.setOwner(TOKEN_A, buyer);

        // Previous owner can no longer touch it.
        vm.expectRevert(AgentAvatarExtension.NotOwner.selector);
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_B, HASH_B, 2);

        // New owner can update.
        vm.prank(buyer);
        ext.setAvatarManifest(TOKEN_A, URI_B, HASH_B, 2);

        AgentAvatarExtension.AvatarManifest memory m = ext.getAvatarManifest(TOKEN_A);
        assertEq(m.manifestURI, URI_B);
        assertEq(m.version, 2);
    }

    // ── views ─────────────────────────────────────────────────────

    function test_getAvatarPointer_returnsURIAndHash() public {
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 4);

        (string memory uri, bytes32 hashOut) = ext.getAvatarPointer(TOKEN_A);
        assertEq(uri, URI_A);
        assertEq(hashOut, HASH_A);
    }

    function test_getAvatarPointer_unsetReturnsEmpty() public view {
        (string memory uri, bytes32 hashOut) = ext.getAvatarPointer(TOKEN_A);
        assertEq(bytes(uri).length, 0);
        assertEq(hashOut, bytes32(0));
    }

    // ── fuzz ──────────────────────────────────────────────────────

    function testFuzz_setAvatarManifest_arbitraryValidInput(
        string calldata uri,
        bytes32 hash_,
        uint16 count
    ) public {
        vm.assume(bytes(uri).length > 0 && bytes(uri).length <= 512);
        vm.assume(hash_ != bytes32(0));

        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, uri, hash_, count);

        AgentAvatarExtension.AvatarManifest memory m = ext.getAvatarManifest(TOKEN_A);
        assertEq(m.manifestURI, uri);
        assertEq(m.contentHash, hash_);
        assertEq(m.fileCount, count);
        assertEq(m.version, 1);
    }

    // ── upgrade ───────────────────────────────────────────────────

    function test_authorizeUpgrade_onlyOwner() public {
        AgentAvatarExtension impl2 = new AgentAvatarExtension();
        vm.expectRevert();
        vm.prank(stranger);
        ext.upgradeToAndCall(address(impl2), "");
    }

    function test_authorizeUpgrade_ownerCanUpgrade() public {
        AgentAvatarExtension impl2 = new AgentAvatarExtension();
        vm.prank(admin);
        ext.upgradeToAndCall(address(impl2), "");
    }

    /// An upgrade that loses the manifests is worse than no upgrade: the
    /// tokens keep pointing at avatars the contract can no longer name,
    /// and nothing reverts to say so. Upgrading and asserting the call
    /// succeeded — which is all the test above did — cannot see that.
    /// This writes state, upgrades, and reads it back through the proxy.
    function test_upgrade_preservesManifestsAndVersions() public {
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 3);
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_B, HASH_B, 4);
        vm.prank(buyer);
        ext.setAvatarManifest(TOKEN_B, URI_A, HASH_A, 1);

        uint16 versionBefore = ext.latestVersion(TOKEN_A);
        assertEq(versionBefore, 2, "two sets should be version 2");

        AgentAvatarExtension impl2 = new AgentAvatarExtension();
        vm.prank(admin);
        ext.upgradeToAndCall(address(impl2), "");

        AgentAvatarExtension.AvatarManifest memory m = ext.getAvatarManifest(TOKEN_A);
        assertEq(m.manifestURI, URI_B, "manifest URI lost across upgrade");
        assertEq(m.contentHash, HASH_B, "content hash lost across upgrade");
        assertEq(m.fileCount, 4, "file count lost across upgrade");
        assertEq(m.version, versionBefore, "version lost across upgrade");
        assertEq(ext.latestVersion(TOKEN_A), versionBefore, "latestVersion lost across upgrade");

        // The neighbouring token must survive too: a storage-layout
        // change is as likely to shift a mapping as to clear one slot.
        assertEq(ext.getAvatarManifest(TOKEN_B).manifestURI, URI_A, "second token lost across upgrade");
        assertEq(ext.owner(), admin, "ownership lost across upgrade");
        assertEq(address(ext.identityRegistry()), address(idReg), "registry lost across upgrade");

        // And the contract stays writable, with versions continuing from
        // where they were rather than restarting.
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 1);
        assertEq(ext.latestVersion(TOKEN_A), versionBefore + 1, "version did not continue after upgrade");
    }

    /// An unowned token must be writable by nobody — including address(0).
    ///
    /// This caught a real hole. The guard was `ownerOf(tokenId) !=
    /// msg.sender`, and for an unminted token both sides are zero, so a
    /// call from address(0) satisfied it and wrote a manifest to a token
    /// that does not exist. The canonical registry reverts on an unminted
    /// id, which hid it — but authorisation here must not rest on what a
    /// collaborator happens to do, and the contract already declared
    /// NotExists for precisely this case without ever raising it.
    function test_setAvatarManifest_unmintedTokenIsWritableByNobody() public {
        uint256 unminted = 999;
        assertEq(idReg.ownerOf(unminted), address(0), "fixture expects an unowned token");

        vm.prank(agentEoa);
        vm.expectRevert(AgentAvatarExtension.NotExists.selector);
        ext.setAvatarManifest(unminted, URI_A, HASH_A, 1);

        vm.prank(address(0));
        vm.expectRevert(AgentAvatarExtension.NotExists.selector);
        ext.setAvatarManifest(unminted, URI_A, HASH_A, 1);

        vm.prank(address(0));
        vm.expectRevert(AgentAvatarExtension.NotExists.selector);
        ext.clearAvatarManifest(unminted);

        assertFalse(ext.hasAvatarManifest(unminted), "an unminted token must hold no manifest");
    }

    /// Burning is the same shape as never minting: once ownerOf goes back
    /// to zero the manifest must stop being writable, rather than becoming
    /// writable by address(0).
    function test_setAvatarManifest_burnedTokenIsWritableByNobody() public {
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 1);

        idReg.setOwner(TOKEN_A, address(0));

        vm.prank(agentEoa);
        vm.expectRevert(AgentAvatarExtension.NotExists.selector);
        ext.setAvatarManifest(TOKEN_A, URI_B, HASH_B, 1);

        vm.prank(address(0));
        vm.expectRevert(AgentAvatarExtension.NotExists.selector);
        ext.setAvatarManifest(TOKEN_A, URI_B, HASH_B, 1);

        // The record itself survives, so an indexer can still resolve what
        // the token pointed at before it was burned.
        assertEq(ext.getAvatarManifest(TOKEN_A).manifestURI, URI_A);
    }

    /// The existing suite only tests the far side of MAX_URI_LENGTH. A
    /// bound is where off-by-ones live, so pin both sides of it: 512
    /// accepted, 513 rejected.
    function test_setAvatarManifest_uriAtExactlyMaxLengthIsAccepted() public {
        uint256 max = ext.MAX_URI_LENGTH();
        string memory atLimit = _repeat("a", max);
        assertEq(bytes(atLimit).length, max, "fixture must sit exactly on the bound");

        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, atLimit, HASH_A, 1);
        assertEq(ext.getAvatarManifest(TOKEN_A).manifestURI, atLimit);

        string memory overLimit = _repeat("a", max + 1);
        vm.prank(agentEoa);
        vm.expectRevert(AgentAvatarExtension.URITooLong.selector);
        ext.setAvatarManifest(TOKEN_A, overLimit, HASH_A, 1);
    }

    /// hasAvatarManifest is what clients branch on to decide between the
    /// 3D avatar and the fallback SVG, so it has to track set and clear.
    function test_hasAvatarManifest_tracksSetAndClear() public {
        assertFalse(ext.hasAvatarManifest(TOKEN_A), "unset token must report no manifest");

        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 2);
        assertTrue(ext.hasAvatarManifest(TOKEN_A), "set token must report a manifest");
        assertFalse(ext.hasAvatarManifest(TOKEN_B), "manifest must not leak across tokens");

        vm.prank(agentEoa);
        ext.clearAvatarManifest(TOKEN_A);
        assertFalse(ext.hasAvatarManifest(TOKEN_A), "cleared token must report no manifest");
    }

    /// The contract's stated reason for these events is that an indexer
    /// can rebuild "current avatar for token N" from logs alone. That
    /// only holds if every field it needs is in the log, so assert the
    /// full payload rather than just that something was emitted.
    function test_events_carryEverythingAnIndexerNeeds() public {
        vm.expectEmit(true, true, false, true, address(ext));
        emit AvatarManifestUpdated(TOKEN_A, agentEoa, URI_A, HASH_A, 1, 7);
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_A, HASH_A, 7);

        // Replacement must report the bumped version, or an indexer
        // cannot order two updates mined in the same block.
        vm.expectEmit(true, true, false, true, address(ext));
        emit AvatarManifestUpdated(TOKEN_A, agentEoa, URI_B, HASH_B, 2, 9);
        vm.prank(agentEoa);
        ext.setAvatarManifest(TOKEN_A, URI_B, HASH_B, 9);

        vm.expectEmit(true, true, false, true, address(ext));
        emit AvatarManifestCleared(TOKEN_A, agentEoa);
        vm.prank(agentEoa);
        ext.clearAvatarManifest(TOKEN_A);
    }

    function _repeat(string memory unit, uint256 times) internal pure returns (string memory out) {
        bytes memory u = bytes(unit);
        bytes memory buf = new bytes(u.length * times);
        for (uint256 i; i < times; ++i) {
            for (uint256 j; j < u.length; ++j) {
                buf[i * u.length + j] = u[j];
            }
        }
        return string(buf);
    }
}
