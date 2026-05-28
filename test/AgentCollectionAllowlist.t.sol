// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";

contract AgentCollectionAllowlistTest is Test {
    AgentCollectionFactory public factory;
    AgentCollectionImpl public implementation;
    AgentCollectionImpl public collection;

    address public owner = address(0x1);
    address public creator = address(0x2);
    address public protocolFeeRecipient = address(0x5);

    // Allowlisted addresses
    address public alice = address(0xA1);
    address public bob = address(0xB0B);
    address public carol = address(0xCA0);
    // Not on allowlist
    address public eve = address(0xE9E);

    bytes32 public root;
    bytes32[] public aliceProof;
    bytes32[] public bobProof;
    bytes32[] public carolProof;
    bytes32[] public emptyProof;

    function setUp() public {
        vm.startPrank(owner);
        implementation = new AgentCollectionImpl();
        factory = new AgentCollectionFactory(address(implementation), protocolFeeRecipient);
        vm.stopPrank();

        vm.prank(creator);
        (, address contractAddress) = factory.createCollection(
            "AllowlistDrop",
            "ALWL",
            100,
            1000,
            500,
            "allowlist test"
        );
        collection = AgentCollectionImpl(contractAddress);

        // Build a simple 4-leaf merkle tree (alice, bob, carol, padding) sorted-pair style.
        // We use the same hashing convention OZ MerkleProof.verifyCalldata uses.
        bytes32 leafA = keccak256(abi.encodePacked(alice));
        bytes32 leafB = keccak256(abi.encodePacked(bob));
        bytes32 leafC = keccak256(abi.encodePacked(carol));
        bytes32 leafD = keccak256(abi.encodePacked(address(0xDEAD))); // padding leaf

        bytes32 nodeAB = _hashPair(leafA, leafB);
        bytes32 nodeCD = _hashPair(leafC, leafD);
        root = _hashPair(nodeAB, nodeCD);

        // alice's proof: [leafB, nodeCD]
        aliceProof.push(leafB);
        aliceProof.push(nodeCD);

        // bob's proof: [leafA, nodeCD]
        bobProof.push(leafA);
        bobProof.push(nodeCD);

        // carol's proof: [leafD, nodeAB]
        carolProof.push(leafD);
        carolProof.push(nodeAB);
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    // ============ Config ============

    function test_OnlyCreatorSetsAllowlistConfig() public {
        vm.prank(eve);
        vm.expectRevert(AgentCollectionImpl.NotCreator.selector);
        collection.setAllowlistConfig(root, block.timestamp + 1 days, 0.01 ether, 1);
    }

    function test_SetAllowlistConfigPersists() public {
        vm.prank(creator);
        collection.setAllowlistConfig(root, block.timestamp + 1 days, 0.01 ether, 2);

        (bytes32 r, uint256 endT, uint256 price, uint256 perWallet, bool active) =
            collection.getAllowlistConfig();
        assertEq(r, root);
        assertEq(endT, block.timestamp + 1 days);
        assertEq(price, 0.01 ether);
        assertEq(perWallet, 2);
        assertTrue(active);
    }

    // ============ Allowlist mint ============

    function test_AllowlistedCanMint() public {
        vm.prank(creator);
        collection.setAllowlistConfig(root, block.timestamp + 1 days, 0.01 ether, 1);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 id = collection.mintAgentAllowlist{value: 0.01 ether}("AliceAgent", "ipfs://x", aliceProof);
        assertEq(id, 1);
        assertEq(collection.ownerOf(1), alice);
        assertEq(collection.allowlistMintedPerWallet(alice), 1);
    }

    function test_NotAllowlistedReverts() public {
        vm.prank(creator);
        collection.setAllowlistConfig(root, block.timestamp + 1 days, 0.01 ether, 1);

        vm.deal(eve, 1 ether);
        vm.prank(eve);
        vm.expectRevert(AgentCollectionImpl.InvalidProof.selector);
        collection.mintAgentAllowlist{value: 0.01 ether}("EveAgent", "ipfs://x", aliceProof);
    }

    function test_AllowlistMintRequiresPayment() public {
        vm.prank(creator);
        collection.setAllowlistConfig(root, block.timestamp + 1 days, 0.01 ether, 1);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(AgentCollectionImpl.InsufficientPayment.selector);
        collection.mintAgentAllowlist{value: 0.001 ether}("A", "ipfs://x", aliceProof);
    }

    function test_AllowlistPerWalletLimit() public {
        vm.prank(creator);
        collection.setAllowlistConfig(root, block.timestamp + 1 days, 0, 1);

        vm.prank(alice);
        collection.mintAgentAllowlist("A1", "ipfs://x", aliceProof);

        vm.prank(alice);
        vm.expectRevert(AgentCollectionImpl.MaxPerWalletReached.selector);
        collection.mintAgentAllowlist("A2", "ipfs://x", aliceProof);
    }

    function test_AllowlistEndedReverts() public {
        vm.prank(creator);
        collection.setAllowlistConfig(root, block.timestamp + 1 hours, 0, 1);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        vm.expectRevert(AgentCollectionImpl.AllowlistEnded.selector);
        collection.mintAgentAllowlist("A", "ipfs://x", aliceProof);
    }

    function test_AllowlistNotConfiguredReverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentCollectionImpl.AllowlistNotConfigured.selector);
        collection.mintAgentAllowlist("A", "ipfs://x", aliceProof);
    }

    // ============ Public mint blocked during allowlist phase ============

    function test_PublicMintBlockedDuringAllowlist() public {
        vm.prank(creator);
        collection.setAllowlistConfig(root, block.timestamp + 1 days, 0, 1);
        vm.prank(creator);
        collection.setMintConfig(0, 0, 0, 0);

        vm.deal(eve, 1 ether);
        vm.prank(eve);
        vm.expectRevert(AgentCollectionImpl.AllowlistPhaseActive.selector);
        collection.mintAgent("E", "ipfs://x");
    }

    function test_PublicMintWorksAfterAllowlistEnds() public {
        vm.prank(creator);
        collection.setAllowlistConfig(root, block.timestamp + 1 hours, 0, 1);
        vm.prank(creator);
        collection.setMintConfig(0, 0, 0, 0);

        vm.warp(block.timestamp + 2 hours);
        vm.deal(eve, 1 ether);
        vm.prank(eve);
        uint256 id = collection.mintAgent("EveAgent", "ipfs://x");
        assertEq(id, 1);
        assertEq(collection.ownerOf(1), eve);
    }

    function test_PublicMintWorksWhenAllowlistDisabled() public {
        // No allowlist config = root is bytes32(0), public mint should work freely
        vm.prank(creator);
        collection.setMintConfig(0, 0, 0, 0);

        vm.prank(eve);
        uint256 id = collection.mintAgent("EveAgent", "ipfs://x");
        assertEq(id, 1);
    }

    // ============ isAllowlisted helper ============

    function test_IsAllowlistedTrueForListed() public {
        vm.prank(creator);
        collection.setAllowlistConfig(root, block.timestamp + 1 days, 0, 1);

        assertTrue(collection.isAllowlisted(alice, aliceProof));
        assertTrue(collection.isAllowlisted(bob, bobProof));
        assertTrue(collection.isAllowlisted(carol, carolProof));
    }

    function test_IsAllowlistedFalseForUnlisted() public {
        vm.prank(creator);
        collection.setAllowlistConfig(root, block.timestamp + 1 days, 0, 1);
        assertFalse(collection.isAllowlisted(eve, aliceProof));
    }

    function test_IsAllowlistedFalseWhenNoRoot() public view {
        assertFalse(collection.isAllowlisted(alice, aliceProof));
    }

    // ============ Royalty cap raised to 80% ============

    function test_MaxRoyaltyBpsIs80Percent() public view {
        assertEq(collection.MAX_ROYALTY_BPS(), 8000);
    }

    function test_RegisterAgentWith80PercentRoyalty() public {
        vm.prank(alice);
        uint256 id = collection.registerAgentWithRoyalty("A", "ipfs://x", 8000, 8000);
        (, uint256 sales, uint256 service) = collection.getCreatorRoyalty(id);
        assertEq(sales, 8000);
        assertEq(service, 8000);
    }

    function test_Above80PercentRoyaltyReverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentCollectionImpl.InvalidValue.selector);
        collection.registerAgentWithRoyalty("A", "ipfs://x", 8001, 0);
    }
}
