// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentReputationRegistry.sol";

/**
 * @title ReputationAnchorTest
 * @notice Tests the dynamic reputation anchor: reputation keyed to agentId
 *         when anchor=address(0) (transferable), and keyed to anchor address
 *         when anchor is non-zero (non-transferable).
 */
contract ReputationAnchorTest is Test {
    AgentIdentityRegistry public identityRegistry;
    AgentReputationRegistry public reputationRegistry;

    address public owner = address(0x1);
    address public creator = address(0x2);
    address public buyer = address(0x3);
    address public client1 = address(0x4);
    address public client2 = address(0x5);

    uint256 public anchoredAgentId;
    uint256 public transferableAgentId;

    function setUp() public {
        vm.startPrank(owner);

        AgentIdentityRegistry identityImpl = new AgentIdentityRegistry();
        ERC1967Proxy identityProxy = new ERC1967Proxy(
            address(identityImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identityRegistry = AgentIdentityRegistry(address(identityProxy));

        AgentReputationRegistry reputationImpl = new AgentReputationRegistry();
        ERC1967Proxy reputationProxy = new ERC1967Proxy(
            address(reputationImpl),
            abi.encodeCall(AgentReputationRegistry.initialize, (address(identityRegistry)))
        );
        reputationRegistry = AgentReputationRegistry(address(reputationProxy));

        vm.stopPrank();

        // Mint agent with reputation anchor (creator's address)
        vm.prank(creator);
        anchoredAgentId = identityRegistry.registerAgent(
            "AnchoredBot",
            "ipfs://anchored",
            1000, // 10% royalty
            creator // reputation locked to creator
        );

        // Mint agent without anchor (default, transferable)
        vm.prank(creator);
        transferableAgentId = identityRegistry.registerAgent(
            "TransferableBot",
            "ipfs://transferable",
            1000,
            address(0) // transferable
        );
    }

    // ============ Identity Registry Tests ============

    function test_RegisterAgentWithAnchor() public {
        assertEq(identityRegistry.reputationAnchorOf(anchoredAgentId), creator);

        (
            string memory name,
            address tba,
            uint256 createdAt,
            bool active,
            address agentOwner,
            address reputationAnchor
        ) = identityRegistry.getAgent(anchoredAgentId);

        assertEq(name, "AnchoredBot");
        assertEq(reputationAnchor, creator);
        assertEq(agentOwner, creator);
        assertGt(createdAt, 0);
        assertTrue(active);
    }

    function test_RegisterAgent_DefaultsToTransferable() public {
        assertEq(identityRegistry.reputationAnchorOf(transferableAgentId), address(0));

        (
            ,
            ,
            ,
            ,
            address agentOwner,
            address reputationAnchor
        ) = identityRegistry.getAgent(transferableAgentId);

        assertEq(reputationAnchor, address(0));
        assertEq(agentOwner, creator);
    }

    function test_DefaultAnchor_IsTransferable() public {
        vm.prank(creator);
        uint256 agentId = identityRegistry.registerAgent("DefaultBot", "ipfs://default", 500, address(0));

        assertEq(identityRegistry.reputationAnchorOf(agentId), address(0));
        (,,,,, address anchor) = identityRegistry.getAgent(agentId);
        assertEq(anchor, address(0));
    }

    function test_ReputationAnchorOf_RevertNonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(AgentIdentityRegistry.NotExists.selector));
        identityRegistry.reputationAnchorOf(999);
    }

    // ============ Transferable Reputation Tests ============

    function test_TransferableReputation_FollowsAgentId() public {
        // Client gives feedback to transferable agent
        vm.prank(client1);
        reputationRegistry.giveFeedback(transferableAgentId, 80, 0, "quality", "", "");

        (uint256 count1, int256 avg1,) = reputationRegistry.getReputationSummary(transferableAgentId);
        assertEq(count1, 1);
        assertEq(avg1, 80);

        // Creator sells the NFT to buyer
        vm.prank(creator);
        identityRegistry.transferFrom(creator, buyer, transferableAgentId);

        // New owner inherits the reputation
        (uint256 count2, int256 avg2,) = reputationRegistry.getReputationSummary(transferableAgentId);
        assertEq(count2, 1);
        assertEq(avg2, 80);
    }

    function test_TransferableReputation_BuyerCanContinue() public {
        vm.prank(client1);
        reputationRegistry.giveFeedback(transferableAgentId, 80, 0, "quality", "", "");

        // Transfer to buyer
        vm.prank(creator);
        identityRegistry.transferFrom(creator, buyer, transferableAgentId);

        // Buyer still receives the reputation on queries
        (uint256 count,,) = reputationRegistry.getReputationSummary(transferableAgentId);
        assertEq(count, 1);

        // New client can still review the agent (feedback keyed to agentId)
        vm.prank(client2);
        reputationRegistry.giveFeedback(transferableAgentId, 90, 0, "quality", "", "");

        (uint256 countAfter, int256 avgAfter,) = reputationRegistry.getReputationSummary(transferableAgentId);
        assertEq(countAfter, 2);
        assertEq(avgAfter, 85); // (80 + 90) / 2
    }

    // ============ Anchored Reputation Tests ============

    function test_AnchoredReputation_SurvivesSale() public {
        // Client gives feedback to anchored agent
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 80, 0, "quality", "", "");

        (uint256 count1, int256 avg1,) = reputationRegistry.getReputationSummary(anchoredAgentId);
        assertEq(count1, 1);
        assertEq(avg1, 80);

        // Creator sells the NFT to buyer
        vm.prank(creator);
        identityRegistry.transferFrom(creator, buyer, anchoredAgentId);

        // Reputation is still attached to creator's anchor, NOT the new owner
        // Querying by agentId still resolves through the anchor
        (uint256 count2, int256 avg2,) = reputationRegistry.getReputationSummary(anchoredAgentId);
        assertEq(count2, 1);
        assertEq(avg2, 80);
    }

    function test_AnchoredReputation_NewBuyerStartsFresh() public {
        // Give feedback to anchored agent
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 80, 0, "quality", "", "");

        // Transfer to buyer
        vm.prank(creator);
        identityRegistry.transferFrom(creator, buyer, anchoredAgentId);

        // New client tries to review the agent post-sale
        // The reputation is anchored to creator, so querying by agentId still
        // resolves to the anchored subject (creator's address as uint256)
        vm.prank(client2);
        reputationRegistry.giveFeedback(anchoredAgentId, 90, 0, "quality", "", "");

        // Both reviews are on the SAME anchored subject
        (uint256 count, int256 avg,) = reputationRegistry.getReputationSummary(anchoredAgentId);
        assertEq(count, 2);
        assertEq(avg, 85);
    }

    function test_AnchoredReputation_TwoAgentsSameAnchor() public {
        // Creator mints a second agent with the SAME anchor
        vm.prank(creator);
        uint256 agent2Id = identityRegistry.registerAgent(
            "AnchoredBot2",
            "ipfs://anchored2",
            1000,
            creator // same anchor as agent 1
        );

        // Different clients review different agents
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 100, 0, "quality", "", "");

        vm.prank(client2);
        reputationRegistry.giveFeedback(agent2Id, 50, 0, "quality", "", "");

        // Both agents share the SAME reputation subject (creator's anchor)
        // So querying either agentId returns the combined reputation
        (uint256 count1, int256 avg1,) = reputationRegistry.getReputationSummary(anchoredAgentId);
        (uint256 count2, int256 avg2,) = reputationRegistry.getReputationSummary(agent2Id);

        // Both point to the same anchor, so both show 2 reviews avg 75
        assertEq(count1, 2);
        assertEq(count2, 2);
        assertEq(avg1, 75); // (100 + 50) / 2
        assertEq(avg2, 75);
    }

    // ============ Tag Scores ============

    function test_Anchored_TagScoreResolvesThroughAnchor() public {
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 80, 0, "quality", "speed", "");

        (int256 qualityScore, uint256 qualityCount) = reputationRegistry.getTagScore(anchoredAgentId, "quality");
        (int256 speedScore, uint256 speedCount) = reputationRegistry.getTagScore(anchoredAgentId, "speed");

        assertEq(qualityScore, 80);
        assertEq(qualityCount, 1);
        assertEq(speedScore, 80);
        assertEq(speedCount, 1);
    }

    // ============ Revoke & Re-submit ============

    function test_Anchored_RevokePersistsAcrossTransfer() public {
        // Give and revoke feedback on anchored agent
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 80, 0, "quality", "", "");

        vm.prank(client1);
        reputationRegistry.revokeFeedback(anchoredAgentId);

        (uint256 countBefore,,) = reputationRegistry.getReputationSummary(anchoredAgentId);
        assertEq(countBefore, 0);

        // Transfer to buyer
        vm.prank(creator);
        identityRegistry.transferFrom(creator, buyer, anchoredAgentId);

        // Revoke state is still attached to the anchor
        (uint256 countAfter,,) = reputationRegistry.getReputationSummary(anchoredAgentId);
        assertEq(countAfter, 0);

        // Client can re-submit
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 90, 0, "quality", "", "");

        (uint256 countFinal,,) = reputationRegistry.getReputationSummary(anchoredAgentId);
        assertEq(countFinal, 1);
    }

    // ============ Audit regression tests ============

    /**
     * @dev CRITICAL-1 regression: subject namespace must be domain-separated.
     *      An anchor address whose uint160 representation collides with an
     *      existing agentId MUST NOT cause reputation pools to merge.
     *
     *      Setup:
     *        - transferableAgentId is some integer N
     *        - We force-mint a third agent whose anchor is address(uint160(N))
     *        - Reviews on the anchored agent must NOT show up on agent N.
     */
    function test_AUDIT_NoSubjectCollisionBetweenAnchorAndAgentId() public {
        // Pick the address whose uint160 representation == transferableAgentId.
        address collidingAnchor = address(uint160(transferableAgentId));

        // The colliding anchor must mint as msg.sender (HIGH-3 enforcement).
        vm.prank(collidingAnchor);
        uint256 collidingAgent = identityRegistry.registerAgent(
            "Collider",
            "ipfs://collide",
            0,
            collidingAnchor
        );

        // Review the colliding (anchored) agent.
        vm.prank(client1);
        reputationRegistry.giveFeedback(collidingAgent, -100, 0, "evil", "", "");

        // Transferable agent N must remain untouched.
        (uint256 nCount,,) = reputationRegistry.getReputationSummary(transferableAgentId);
        assertEq(nCount, 0, "transferable agent leaked from anchor namespace");

        // And the anchored agent has its own review.
        (uint256 aCount, int256 aAvg,) = reputationRegistry.getReputationSummary(collidingAgent);
        assertEq(aCount, 1);
        assertEq(aAvg, -100);
    }

    /**
     * @dev HIGH-3 regression: minter MUST NOT be able to set a foreign
     *      reputationAnchor (would enable reputation poisoning).
     */
    function test_AUDIT_RegisterRevertsOnForeignAnchor() public {
        address victim = address(0xDEADBEEF);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AgentIdentityRegistry.InvalidValue.selector));
        identityRegistry.registerAgent("Evil", "ipfs://evil", 0, victim);
    }

    /**
     * @dev CRITICAL-2 regression: getFeedbackCount must resolve through the
     *      reputation anchor. Previously it indexed feedbacks[agentId] directly.
     */
    function test_AUDIT_GetFeedbackCount_ResolvesAnchor() public {
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 80, 0, "quality", "", "");

        assertEq(
            reputationRegistry.getFeedbackCount(anchoredAgentId),
            1,
            "getFeedbackCount must resolve through anchor"
        );
    }

    /**
     * @dev MEDIUM-4 sanity: subject is exposed via reputationSubjectOf and is
     *      domain-separated for both anchor and agentId paths.
     */
    function test_AUDIT_ReputationSubjectIsDomainSeparated() public view {
        bytes32 anchored = reputationRegistry.reputationSubjectOf(anchoredAgentId);
        bytes32 transferable = reputationRegistry.reputationSubjectOf(transferableAgentId);

        bytes32 expectedAnchor = keccak256(abi.encode(keccak256("ANCHOR"), creator));
        bytes32 expectedAgent  = keccak256(abi.encode(keccak256("AGENT"),  transferableAgentId));

        assertEq(anchored, expectedAnchor);
        assertEq(transferable, expectedAgent);
        assertTrue(anchored != transferable);
    }

    /**
     * @dev getFeedbackAt is the canonical anchor-aware indexed accessor used
     *      by the ERC-8004 adapter. Verify it returns the same data the array
     *      view would, and resolves through the anchor.
     */
    /**
     * @dev Audit gap fix: identity registry must expose a reverse index so
     *      UIs can surface "this anchor controls N agents" — critical for
     *      marketplaces selling anchored NFTs (buyer must understand the
     *      shared-pool semantic).
     */
    function test_AUDIT_AnchorReverseIndex_EnumeratesSharedAgents() public {
        // anchoredAgentId already exists in setUp() with anchor=creator.
        // Mint two more anchored agents under the same anchor.
        vm.startPrank(creator);
        uint256 a2 = identityRegistry.registerAgent("A2", "ipfs://a2", 0, creator);
        uint256 a3 = identityRegistry.registerAgent("A3", "ipfs://a3", 0, creator);
        vm.stopPrank();

        assertEq(identityRegistry.anchorAgentCount(creator), 3);

        uint256[] memory ids = identityRegistry.agentsByAnchor(creator);
        assertEq(ids.length, 3);
        assertEq(ids[0], anchoredAgentId);
        assertEq(ids[1], a2);
        assertEq(ids[2], a3);

        // Transferable agents do not populate the anchor index.
        assertEq(identityRegistry.anchorAgentCount(address(0)), 0);
    }

    function test_AUDIT_AnchorReverseIndex_EmptyForUnusedAnchor() public view {
        assertEq(identityRegistry.anchorAgentCount(address(0xCAFE)), 0);
        uint256[] memory ids = identityRegistry.agentsByAnchor(address(0xCAFE));
        assertEq(ids.length, 0);
    }

    function test_AUDIT_GetFeedbackAt_ResolvesAnchor() public {
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 80, 0, "quality", "speed", "ipfs://x");

        (
            address fbClient,
            int128 fbValue,
            ,
            string memory fbTag1,
            ,
            ,
            ,
            bool fbRevoked
        ) = reputationRegistry.getFeedbackAt(anchoredAgentId, 0);

        assertEq(fbClient, client1);
        assertEq(fbValue, 80);
        assertEq(keccak256(bytes(fbTag1)), keccak256(bytes("quality")));
        assertFalse(fbRevoked);
    }
}
