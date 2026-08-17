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
}
