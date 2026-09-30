// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentIdentityKeyExtension} from "../src/AgentIdentityKeyExtension.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Bip340} from "../src/libraries/Bip340.sol";
import {Bip340Signer} from "./helpers/Bip340Signer.sol";

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
    bytes32 K1;
    bytes32 K2;
    bytes32 K3;

    mapping(bytes32 => uint256) secretOf;

    function _key(bytes32 seed) internal returns (bytes32 pk) {
        uint256 sk = uint256(seed) % (Bip340.N - 1) + 1;
        pk = Bip340Signer.pubkey(sk);
        secretOf[pk] = sk;
    }

    /// The key's binding proof for token `id` of `nft`, signed for `who`.
    /// Called outside vm.prank (inside startPrank is fine: views only).
    function _p(address nft, uint256 id, bytes32 pk, address who) internal view returns (bytes memory) {
        return Bip340Signer.sign(secretOf[pk], ext.bindingDigest(nft, id, pk, who));
    }

    function setUp() public {
        K1 = _key("k1");
        K2 = _key("k2");
        K3 = _key("k3");
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
        ext.registerPrimaryKeyFor(address(collection), 1, K1, "nostr", "primary", 0, _p(address(collection), 1, K1, owner));
        ext.addKeyFor(address(collection), 1, K2, "nostr", "second", 0, _p(address(collection), 1, K2, owner));
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
        ext.registerPrimaryKey(1, K1, "nostr", "", 0, _p(address(identity), 1, K1, owner));
        ext.registerPrimaryKeyFor(address(collection), 1, K2, "nostr", "", 0, _p(address(collection), 1, K2, owner));
        ext.registerPrimaryKeyFor(address(otherCollection), 1, K3, "nostr", "", 0, _p(address(otherCollection), 1, K3, owner));
        vm.stopPrank();
        assertEq(ext.getKeys(1)[0].pubkey, K1);
        assertEq(ext.getKeysFor(address(identity), 1)[0].pubkey, K1, "identity agents via the NFT path too");
        assertEq(ext.getKeysFor(address(collection), 1)[0].pubkey, K2);
        assertEq(ext.getKeysFor(address(otherCollection), 1)[0].pubkey, K3);
        (address nft, uint256 tokenId,,,,) = ext.resolveKeyFor(K1);
        assertEq(nft, address(identity));
        assertEq(tokenId, 1);
        assertTrue(ext.refOf(address(collection), 1) > type(uint128).max, "tagged subject");
    }

    function test_onePubkeyOneAgentAcrossContracts() public {
        bytes memory proof = _p(address(collection), 1, K1, owner);
        vm.startPrank(owner);
        ext.registerPrimaryKey(1, K1, "nostr", "", 0, _p(address(identity), 1, K1, owner));
        vm.expectRevert(AgentIdentityKeyExtension.AlreadyBound.selector);
        ext.registerPrimaryKeyFor(address(collection), 1, K1, "nostr", "", 0, proof);
        vm.stopPrank();
    }

    function test_onlyTheCollectionTokensOwner() public {
        bytes memory proof = _p(address(collection), 1, K1, stranger);
        vm.prank(stranger);
        vm.expectRevert(AgentIdentityKeyExtension.NotOwner.selector);
        ext.registerPrimaryKeyFor(address(collection), 1, K1, "nostr", "", 0, proof);
        proof = _p(address(collection), 99, K1, owner);
        vm.prank(owner);
        vm.expectRevert();
        ext.registerPrimaryKeyFor(address(collection), 99, K1, "nostr", "", 0, proof);
    }

    function test_saleMakesKeysStaleAndTheBuyerRotates() public {
        bytes memory proof = _p(address(collection), 1, K1, owner);
        vm.prank(owner);
        ext.registerPrimaryKeyFor(address(collection), 1, K1, "nostr", "", 0, proof);
        assertFalse(ext.keysStaleFor(address(collection), 1));
        vm.prank(owner);
        collection.transferFrom(owner, buyer, 1);
        assertTrue(ext.keysStaleFor(address(collection), 1));
        proof = _p(address(collection), 1, K2, owner);
        vm.prank(owner);
        vm.expectRevert(AgentIdentityKeyExtension.NotOwner.selector);
        ext.addKeyFor(address(collection), 1, K2, "nostr", "", 0, proof);
        proof = _p(address(collection), 1, K2, buyer);
        vm.prank(buyer);
        ext.rotatePrimaryKeyFor(address(collection), 1, K2, "nostr", "", 0, proof);
        assertFalse(ext.keysStaleFor(address(collection), 1));
        (bool bound) = _bound(K1);
        assertFalse(bound, "old primary freed");
    }

    function test_deactivateAndPermissionsFor() public {
        vm.startPrank(owner);
        ext.registerPrimaryKeyFor(address(collection), 1, K1, "nostr", "", 0, _p(address(collection), 1, K1, owner));
        ext.addKeyFor(address(collection), 1, K2, "nostr", "", 0, _p(address(collection), 1, K2, owner));
        ext.updateKeyPermissionsFor(address(collection), 1, K2, 5);
        assertEq(ext.getKeysFor(address(collection), 1)[1].permissions, 5);
        ext.deactivateKeyFor(address(collection), 1, K2);
        vm.stopPrank();
        AgentIdentityKeyExtension.IdentityKey[] memory keys = ext.getKeysFor(address(collection), 1);
        assertFalse(keys[1].active);
        assertEq(keys[1].permissions, 0, "deactivation clears permissions");
        assertFalse(_bound(K2), "deactivated key freed");
    }

    // ── proof of control ──────────────────────────────────────────

    /// Anyone can deploy an NFT they own, but can't bind a key they don't
    /// hold to it — so a known npub can't be squatted to lock its owner out.
    function test_squattingAKnownKeyWithoutItsSecretFails() public {
        KeyTestNFT fake = new KeyTestNFT("FAKE");
        fake.mint(stranger, 1);
        bytes memory forged = _p(address(fake), 1, K2, stranger); // signed by K2's holder… for K2
        vm.prank(stranger);
        vm.expectRevert(AgentIdentityKeyExtension.InvalidProof.selector);
        ext.registerPrimaryKeyFor(address(fake), 1, K1, "nostr", "", 0, forged);
        vm.prank(stranger);
        vm.expectRevert(AgentIdentityKeyExtension.InvalidProof.selector);
        ext.registerPrimaryKeyFor(address(fake), 1, K1, "nostr", "", 0, "");
    }

    /// A proof names the agent, owner, contract and chain: replaying it
    /// for any other fails.
    function test_proofsCantBeReplayed() public {
        collection.mint(owner, 2);
        bytes memory forToken1 = _p(address(collection), 1, K1, owner);
        vm.prank(owner);
        vm.expectRevert(AgentIdentityKeyExtension.InvalidProof.selector);
        ext.registerPrimaryKeyFor(address(collection), 2, K1, "nostr", "", 0, forToken1);

        vm.prank(owner);
        collection.transferFrom(owner, buyer, 1);
        vm.prank(buyer);
        vm.expectRevert(AgentIdentityKeyExtension.InvalidProof.selector);
        ext.registerPrimaryKeyFor(address(collection), 1, K1, "nostr", "", 0, forToken1);

        bytes memory forBuyer = _p(address(collection), 1, K1, buyer);
        vm.chainId(8453);
        vm.prank(buyer);
        vm.expectRevert(AgentIdentityKeyExtension.InvalidProof.selector);
        ext.registerPrimaryKeyFor(address(collection), 1, K1, "nostr", "", 0, forBuyer);
        vm.chainId(31337);
        vm.prank(buyer);
        ext.registerPrimaryKeyFor(address(collection), 1, K1, "nostr", "", 0, forBuyer);
        assertEq(ext.getKeysFor(address(collection), 1)[0].pubkey, K1);
    }

    function _bound(bytes32 k) internal view returns (bool bound) {
        (,,, bound,,) = ext.resolveKeyFor(k);
    }
}
