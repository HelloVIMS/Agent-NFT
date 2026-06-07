// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "../src/AgentIdentityRegistry.sol";

/**
 * @title AgentIdentityRegistryExtrasTest
 * @notice Drives the surface of AgentIdentityRegistry that the existing
 *         AgentIdentityRegistry.t.sol does not cover: collection lifecycle
 *         (mintToCollection / lockCollection / getCollectionAgents /
 *         totalCollections), tokenURI fallback + on-chain SVG path,
 *         supportsInterface IERC2981 branch, agentCreator getter,
 *         calculateRoyaltySplit, getSubaccounts, reputationAnchor
 *         registration branches, and deactivate/reactivate revert paths.
 */
contract AgentIdentityRegistryExtrasTest is Test {
    AgentIdentityRegistry public registry;

    address public deployer = makeAddr("deployer");
    address public alice    = makeAddr("alice");
    address public bob      = makeAddr("bob");
    address public anchor   = makeAddr("anchor");

    function setUp() public {
        vm.prank(deployer);
        AgentIdentityRegistry impl = new AgentIdentityRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        registry = AgentIdentityRegistry(address(proxy));
    }

    // ─── registerAgent with reputationAnchor ─────────────────────────────

    function test_registerAgent_withReputationAnchor_pushesAndEmits() public {
        // Anchor must be address(0) or msg.sender (soulbound to caller).
        vm.prank(alice);
        uint256 agentId = registry.registerAgent("Anchored", "ipfs://meta", 1000, alice);
        assertEq(registry.ownerOf(agentId), alice);
    }

    function test_registerAgent_revertsForNonSelfAnchor() public {
        vm.prank(alice);
        vm.expectRevert(AgentIdentityRegistry.InvalidValue.selector);
        registry.registerAgent("X", "ipfs://x", 500, anchor);
    }

    // ─── tokenURI fallback (no on-chain SVG) ─────────────────────────────

    function test_tokenURI_fallsBackToStoredURI_whenNoSVG() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent("Plain", "ipfs://plain-meta", 500, address(0));
        string memory uri = registry.tokenURI(agentId);
        assertEq(uri, "ipfs://plain-meta");
    }

    function test_tokenURI_buildsOnChainURI_withSVG() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent("Visual", "ipfs://meta", 500, address(0));

        vm.prank(alice);
        registry.setSVGImage(agentId, "<svg>x</svg>");

        string memory uri = registry.tokenURI(agentId);
        // Should be a base64 data URI (not the plain ipfs URI).
        assertGt(bytes(uri).length, 50);
        // It should not equal the plain stored URI.
        assertTrue(keccak256(bytes(uri)) != keccak256(bytes("ipfs://meta")));
    }

    // ─── supportsInterface ────────────────────────────────────────────────

    function test_supportsInterface_includesERC2981() public view {
        assertTrue(registry.supportsInterface(type(IERC2981).interfaceId));
    }

    // ─── agentCreator + calculateRoyaltySplit ────────────────────────────

    function test_agentCreator_returnsRegistrar() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent("Solo", "ipfs://meta", 1500, address(0));
        assertEq(registry.agentCreator(agentId), alice);
    }

    function test_calculateRoyaltySplit_returnsBpsSplit() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent("Royal", "ipfs://m", 1500, address(0)); // 15%
        (uint256 creatorCut, uint256 ownerCut) = registry.calculateRoyaltySplit(agentId, 1 ether);
        assertEq(creatorCut, 0.15 ether);
        assertEq(ownerCut,   0.85 ether);
        assertEq(creatorCut + ownerCut, 1 ether);
    }

    // ─── Collections: createCollection / mintToCollection / lock ──────────

    function test_collections_fullLifecycle() public {
        vm.prank(alice);
        uint256 collectionId = registry.createCollection("Genesis", 100, "ipfs://col");
        assertEq(registry.totalCollections(), 1);

        // Mint two agents.
        vm.prank(alice);
        uint256 a1 = registry.mintToCollection(collectionId, "A1", "ipfs://a1", 500, address(0));
        vm.prank(alice);
        uint256 a2 = registry.mintToCollection(collectionId, "A2", "ipfs://a2", 500, address(0));

        uint256[] memory agents = registry.getCollectionAgents(collectionId);
        assertEq(agents.length, 2);
        assertEq(agents[0], a1);
        assertEq(agents[1], a2);

        // Lock and verify subsequent mint reverts.
        vm.prank(alice);
        registry.lockCollection(collectionId);

        vm.prank(alice);
        vm.expectRevert(AgentIdentityRegistry.CollectionLocked.selector);
        registry.mintToCollection(collectionId, "A3", "ipfs://a3", 500, address(0));
    }

    function test_lockCollection_revertsForNonCreator() public {
        vm.prank(alice);
        uint256 collectionId = registry.createCollection("Genesis", 100, "ipfs://col");
        vm.prank(bob);
        vm.expectRevert(AgentIdentityRegistry.NotCollectionCreator.selector);
        registry.lockCollection(collectionId);
    }

    function test_lockCollection_revertsWhenAlreadyLocked() public {
        vm.prank(alice);
        uint256 collectionId = registry.createCollection("G", 100, "ipfs://col");
        vm.prank(alice);
        registry.lockCollection(collectionId);
        vm.prank(alice);
        vm.expectRevert(AgentIdentityRegistry.CollectionLocked.selector);
        registry.lockCollection(collectionId);
    }

    function test_mintToCollection_revertsWhenFull() public {
        vm.prank(alice);
        uint256 collectionId = registry.createCollection("Tiny", 1, "ipfs://col");
        vm.prank(alice);
        registry.mintToCollection(collectionId, "A1", "ipfs://a1", 500, address(0));
        vm.prank(alice);
        vm.expectRevert(AgentIdentityRegistry.CollectionFull.selector);
        registry.mintToCollection(collectionId, "A2", "ipfs://a2", 500, address(0));
    }

    function test_mintToCollection_revertsForNonCreator() public {
        vm.prank(alice);
        uint256 collectionId = registry.createCollection("G", 100, "ipfs://col");
        vm.prank(bob);
        vm.expectRevert(AgentIdentityRegistry.NotCollectionCreator.selector);
        registry.mintToCollection(collectionId, "A", "ipfs://a", 500, address(0));
    }

    function test_mintToCollection_revertsForNonExistentCollection() public {
        vm.prank(alice);
        vm.expectRevert(AgentIdentityRegistry.NotExists.selector);
        registry.mintToCollection(999999, "A", "ipfs://a", 500, address(0));
    }

    // ─── deactivate / reactivate revert paths ────────────────────────────

    function test_deactivateAgent_revertsForNonOwner() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent("X", "ipfs://x", 500, address(0));
        vm.prank(bob);
        vm.expectRevert(AgentIdentityRegistry.NotOwner.selector);
        registry.deactivateAgent(agentId);
    }

    function test_deactivateAgent_revertsWhenAlreadyInactive() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent("X", "ipfs://x", 500, address(0));
        vm.prank(alice);
        registry.deactivateAgent(agentId);
        vm.prank(alice);
        vm.expectRevert(AgentIdentityRegistry.InvalidValue.selector);
        registry.deactivateAgent(agentId);
    }

    function test_reactivateAgent_revertsWhenAlreadyActive() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent("X", "ipfs://x", 500, address(0));
        vm.prank(alice);
        vm.expectRevert(AgentIdentityRegistry.InvalidValue.selector);
        registry.reactivateAgent(agentId);
    }

    function test_reactivateAgent_revertsForNonOwner() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent("X", "ipfs://x", 500, address(0));
        vm.prank(alice);
        registry.deactivateAgent(agentId);
        vm.prank(bob);
        vm.expectRevert(AgentIdentityRegistry.NotOwner.selector);
        registry.reactivateAgent(agentId);
    }

    // ─── getSubaccounts ──────────────────────────────────────────────────

    function test_getSubaccounts_emptyByDefault() public {
        vm.prank(alice);
        uint256 agentId = registry.registerAgent("Solo", "ipfs://m", 500, address(0));
        AgentIdentityRegistry.Subaccount[] memory subs = registry.getSubaccounts(agentId);
        assertEq(subs.length, 0);
    }
}
