// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentIdentityKeyExtension} from "../src/AgentIdentityKeyExtension.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract KeyTestNFT is ERC721 {
    constructor(string memory n) ERC721(n, n) {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

/// Identity keys for agents of any ERC-721 (collection agents), next to
/// identity-registry agents, in one pubkey namespace.
contract AgentIdentityKeyExtensionNFTTest is Test {
    AgentIdentityKeyExtension ext;
    KeyTestNFT identity;
    KeyTestNFT collection;
    KeyTestNFT otherCollection;
    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");
    bytes32 constant K1 = keccak256("k1");
    bytes32 constant K2 = keccak256("k2");
    bytes32 constant K3 = keccak256("k3");

    function setUp() public {
        identity = new KeyTestNFT("ID");
        collection = new KeyTestNFT("C1");
        otherCollection = new KeyTestNFT("C2");
        AgentIdentityKeyExtension impl = new AgentIdentityKeyExtension();
        ext = AgentIdentityKeyExtension(address(new ERC1967Proxy(address(impl), abi.encodeCall(AgentIdentityKeyExtension.initialize, (address(identity))))));
        identity.mint(owner, 1);
        collection.mint(owner, 1);
        otherCollection.mint(owner, 1);
    }

    function test_collectionAgentKeys() public {
        vm.startPrank(owner);
        ext.registerPrimaryKeyFor(address(collection), 1, K1, "nostr", "primary", 0);
        ext.addKeyFor(address(collection), 1, K2, "nostr", "second", 0);
        vm.stopPrank();
        AgentIdentityKeyExtension.IdentityKey[] memory keys = ext.getKeysFor(address(collection), 1);
        assertEq(keys.length, 2);
        assertEq(keys[0].pubkey, K1);
        (address nft, uint256 tokenId, uint256 index, bool bound,,) = ext.resolveKeyFor(K2);
        assertEq(nft, address(collection));
        assertEq(tokenId, 1);
        assertEq(index, 1);
        assertTrue(bound);
    }

    /// Token #1 of three contracts is three agents with separate keys.
    function test_sameTokenIdInDifferentContractsIsDifferentAgents() public {
        vm.startPrank(owner);
        ext.registerPrimaryKey(1, K1, "nostr", "", 0);
        ext.registerPrimaryKeyFor(address(collection), 1, K2, "nostr", "", 0);
        ext.registerPrimaryKeyFor(address(otherCollection), 1, K3, "nostr", "", 0);
        vm.stopPrank();
        assertEq(ext.getKeys(1)[0].pubkey, K1);
        assertEq(ext.getKeysFor(address(identity), 1)[0].pubkey, K1, "identity agents via the NFT path too");
        assertEq(ext.getKeysFor(address(collection), 1)[0].pubkey, K2);
        assertEq(ext.getKeysFor(address(otherCollection), 1)[0].pubkey, K3);
        (address nft, uint256 tokenId,,,,) = ext.resolveKeyFor(K1);
        assertEq(nft, address(identity));
        assertEq(tokenId, 1);
        assertTrue(ext.subjectOf(address(collection), 1) > type(uint128).max, "tagged subject");
    }

    function test_onePubkeyOneAgentAcrossContracts() public {
        vm.startPrank(owner);
        ext.registerPrimaryKey(1, K1, "nostr", "", 0);
        vm.expectRevert(AgentIdentityKeyExtension.AlreadyBound.selector);
        ext.registerPrimaryKeyFor(address(collection), 1, K1, "nostr", "", 0);
        vm.stopPrank();
    }

    function test_onlyTheCollectionTokensOwner() public {
        vm.prank(stranger);
        vm.expectRevert(AgentIdentityKeyExtension.NotOwner.selector);
        ext.registerPrimaryKeyFor(address(collection), 1, K1, "nostr", "", 0);
        vm.prank(owner);
        vm.expectRevert();
        ext.registerPrimaryKeyFor(address(collection), 99, K1, "nostr", "", 0);
    }

    function test_saleMakesKeysStaleAndTheBuyerRotates() public {
        vm.prank(owner);
        ext.registerPrimaryKeyFor(address(collection), 1, K1, "nostr", "", 0);
        assertFalse(ext.keysStaleFor(address(collection), 1));
        vm.prank(owner);
        collection.transferFrom(owner, buyer, 1);
        assertTrue(ext.keysStaleFor(address(collection), 1));
        vm.prank(owner);
        vm.expectRevert(AgentIdentityKeyExtension.NotOwner.selector);
        ext.addKeyFor(address(collection), 1, K2, "nostr", "", 0);
        vm.prank(buyer);
        ext.rotatePrimaryKeyFor(address(collection), 1, K2, "nostr", "", 0);
        assertFalse(ext.keysStaleFor(address(collection), 1));
        (bool bound) = _bound(K1);
        assertFalse(bound, "old primary freed");
    }

    function test_deactivateAndPermissionsFor() public {
        vm.startPrank(owner);
        ext.registerPrimaryKeyFor(address(collection), 1, K1, "nostr", "", 0);
        ext.addKeyFor(address(collection), 1, K2, "nostr", "", 0);
        ext.updateKeyPermissionsFor(address(collection), 1, K2, 5);
        assertEq(ext.getKeysFor(address(collection), 1)[1].permissions, 5);
        ext.deactivateKeyFor(address(collection), 1, K2);
        vm.stopPrank();
        AgentIdentityKeyExtension.IdentityKey[] memory keys = ext.getKeysFor(address(collection), 1);
        assertFalse(keys[1].active);
        assertEq(keys[1].permissions, 0, "deactivation clears permissions");
        assertFalse(_bound(K2), "deactivated key freed");
    }

    function _bound(bytes32 k) internal view returns (bool bound) {
        (,,, bound,,) = ext.resolveKeyFor(k);
    }
}
