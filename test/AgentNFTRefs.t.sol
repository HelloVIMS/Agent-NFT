// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AgentNFTRefs} from "../src/AgentNFTRefs.sol";
import {AgentMemory} from "../src/AgentMemory.sol";
import {AgentAvatarExtension} from "../src/AgentAvatarExtension.sol";

contract RefsNFT is ERC721 {
    constructor(string memory n) ERC721(n, n) {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

contract RefsHarness is AgentNFTRefs {
    address immutable identity;
    constructor(address i) { identity = i; }
    function _identityNFT() internal view override returns (address) { return identity; }
    function slot() external pure returns (bytes32) { return REFS_SLOT; }
    function bind(address nft, uint256 id) external returns (uint256) { return _bindRef(nft, id); }
    function ownerOfRef(uint256 ref) external view returns (address) { return _ownerOfRef(ref); }
}

/// Memory and avatars for agents of any ERC-721, through AgentNFTRefs.
contract AgentNFTRefsTest is Test {
    RefsNFT identity;
    RefsNFT collection;
    AgentMemory mem;
    AgentAvatarExtension avatars;
    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");

    function setUp() public {
        identity = new RefsNFT("ID");
        collection = new RefsNFT("COL");
        identity.mint(owner, 1);
        collection.mint(owner, 1);
        mem = AgentMemory(address(new ERC1967Proxy(address(new AgentMemory()), abi.encodeCall(AgentMemory.initialize, (address(identity))))));
        avatars = AgentAvatarExtension(address(new ERC1967Proxy(address(new AgentAvatarExtension()), abi.encodeCall(AgentAvatarExtension.initialize, (address(identity))))));
    }

    function test_storageSlotIsERC7201() public {
        RefsHarness h = new RefsHarness(address(identity));
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("vims.storage.AgentNFTRefs")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(h.slot(), expected);
    }

    function test_refs() public {
        RefsHarness h = new RefsHarness(address(identity));
        assertEq(h.refOf(address(identity), 7), 7, "identity ids are their own refs");
        uint256 ref = h.refOf(address(collection), 1);
        assertTrue(ref >> 255 == 1, "tagged");
        (address nft,) = h.nftOf(ref);
        assertEq(nft, address(0), "unbound until written");
        vm.expectRevert(AgentNFTRefs.InvalidNFT.selector);
        h.ownerOfRef(ref);
        assertEq(h.bind(address(collection), 1), ref);
        (address bound, uint256 id) = h.nftOf(ref);
        assertEq(bound, address(collection));
        assertEq(id, 1);
        assertEq(h.ownerOfRef(ref), owner);
        vm.expectRevert(AgentNFTRefs.InvalidNFT.selector);
        h.bind(address(0), 1);
    }

    function test_memoryForCollectionAgent() public {
        vm.prank(stranger);
        vm.expectRevert(AgentMemory.NotOwner.selector);
        mem.addVersionFor(address(collection), 1, "ipfs://m", keccak256("m"), 3, 0, 0, 0, "first");
        vm.prank(owner);
        mem.addVersionFor(address(collection), 1, "ipfs://m", keccak256("m"), 3, 0, 0, 0, "first");
        uint256 ref = mem.refOf(address(collection), 1);
        assertEq(mem.versionCount(ref), 1);
        assertEq(mem.versionCount(1), 0, "identity agent #1 is a different agent");
        vm.prank(owner);
        mem.addVersion(1, "ipfs://i", keccak256("i"), 3, 0, 0, 0, "identity");
        assertEq(mem.versionCount(1), 1);
        // A sale moves the right to write with the NFT.
        vm.prank(owner);
        collection.transferFrom(owner, stranger, 1);
        vm.prank(owner);
        vm.expectRevert(AgentMemory.NotOwner.selector);
        mem.addVersion(ref, "ipfs://x", keccak256("x"), 3, 0, 0, 0, "old owner");
        vm.prank(stranger);
        mem.addVersion(ref, "ipfs://y", keccak256("y"), 3, 0, 0, 0, "new owner");
        assertEq(mem.versionCount(ref), 2);
    }

    function test_avatarsForCollectionAgent() public {
        vm.prank(stranger);
        vm.expectRevert(AgentAvatarExtension.NotOwner.selector);
        avatars.setAvatarManifestFor(address(collection), 1, "ipfs://a", keccak256("a"), 2);
        vm.prank(owner);
        avatars.setAvatarManifestFor(address(collection), 1, "ipfs://a", keccak256("a"), 2);
        uint256 ref = avatars.refOf(address(collection), 1);
        assertTrue(avatars.hasAvatarManifest(ref));
        assertFalse(avatars.hasAvatarManifest(1));
        vm.prank(owner);
        avatars.clearAvatarManifestFor(address(collection), 1);
        assertFalse(avatars.hasAvatarManifest(ref));
    }
}
