// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentReputationRegistry.sol";

contract AgentReputationRegistryTest is Test {
    AgentIdentityRegistry public identityRegistry;
    AgentReputationRegistry public reputationRegistry;
    
    address public owner = address(0x1);
    address public agentOwner = address(0x2);
    address public client1 = address(0x3);
    address public client2 = address(0x4);
    
    uint256 public agentId;
    
    event FeedbackGiven(uint256 indexed agentId, address indexed client, bytes32 indexed subject, int128 value, string tag1, string feedbackURI);
    event FeedbackRevoked(uint256 indexed agentId, address indexed client, bytes32 indexed subject, uint256 feedbackIndex);
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy Identity Registry with proxy
        AgentIdentityRegistry identityImpl = new AgentIdentityRegistry();
        ERC1967Proxy identityProxy = new ERC1967Proxy(
            address(identityImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identityRegistry = AgentIdentityRegistry(address(identityProxy));
        
        // Deploy Reputation Registry with proxy
        AgentReputationRegistry reputationImpl = new AgentReputationRegistry();
        ERC1967Proxy reputationProxy = new ERC1967Proxy(
            address(reputationImpl),
            abi.encodeCall(AgentReputationRegistry.initialize, (address(identityRegistry)))
        );
        reputationRegistry = AgentReputationRegistry(address(reputationProxy));
        
        vm.stopPrank();
        
        // Create an agent
        vm.prank(agentOwner);
        agentId = identityRegistry.registerAgent("TestBot", "uri", 1000, address(0));
    }
    
    function test_GiveFeedback() public {
        vm.prank(client1);
        reputationRegistry.giveFeedback(
            agentId,
            80,     // score
            0,      // decimals
            "quality",
            "speed",
            "ipfs://feedback"
        );
        
        uint256 count = reputationRegistry.getFeedbackCount(agentId);
        assertEq(count, 1);
    }
    
    function test_GiveFeedback_MultipleClients() public {
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 80, 0, "quality", "", "");
        
        vm.prank(client2);
        reputationRegistry.giveFeedback(agentId, 90, 0, "quality", "", "");
        
        uint256 count = reputationRegistry.getFeedbackCount(agentId);
        assertEq(count, 2);
    }
    
    function test_GiveFeedback_RevertSelfReview() public {
        vm.prank(agentOwner);
        vm.expectRevert("Cannot review own agent");
        reputationRegistry.giveFeedback(agentId, 100, 0, "quality", "", "");
    }
    
    function test_GiveFeedback_RevertDuplicate() public {
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 80, 0, "quality", "", "");
        
        vm.prank(client1);
        vm.expectRevert("Already gave feedback");
        reputationRegistry.giveFeedback(agentId, 90, 0, "quality", "", "");
    }
    
    function test_GetReputationSummary() public {
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 80, 0, "quality", "", "");
        
        vm.prank(client2);
        reputationRegistry.giveFeedback(agentId, 60, 0, "quality", "", "");
        
        (uint256 totalFeedbacks, int256 averageScore, uint256 lastTime) = 
            reputationRegistry.getReputationSummary(agentId);
        
        assertEq(totalFeedbacks, 2);
        assertEq(averageScore, 70); // (80 + 60) / 2
        assertGt(lastTime, 0);
    }
    
    function test_GetReputationSummary_Empty() public view {
        (uint256 totalFeedbacks, int256 averageScore, uint256 lastTime) = 
            reputationRegistry.getReputationSummary(agentId);
        
        assertEq(totalFeedbacks, 0);
        assertEq(averageScore, 0);
        assertEq(lastTime, 0);
    }
    
    function test_GetTagScore() public {
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 80, 0, "quality", "speed", "");
        
        vm.prank(client2);
        reputationRegistry.giveFeedback(agentId, 60, 0, "quality", "", "");
        
        (int256 qualityScore, uint256 qualityCount) = reputationRegistry.getTagScore(agentId, "quality");
        (int256 speedScore, uint256 speedCount) = reputationRegistry.getTagScore(agentId, "speed");
        
        assertEq(qualityScore, 70); // (80 + 60) / 2
        assertEq(qualityCount, 2);
        assertEq(speedScore, 80);
        assertEq(speedCount, 1);
    }
    
    function test_RevokeFeedback() public {
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 80, 0, "quality", "", "");
        
        vm.prank(client1);
        reputationRegistry.revokeFeedback(agentId);
        
        // Check summary updated
        (uint256 totalFeedbacks,,) = reputationRegistry.getReputationSummary(agentId);
        assertEq(totalFeedbacks, 0);
        
        // Can give new feedback after revoke
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 90, 0, "quality", "", "");
        
        (totalFeedbacks,,) = reputationRegistry.getReputationSummary(agentId);
        assertEq(totalFeedbacks, 1);
    }
    
    function test_RevokeFeedback_RevertNoFeedback() public {
        vm.prank(client1);
        vm.expectRevert("No feedback to revoke");
        reputationRegistry.revokeFeedback(agentId);
    }
    
    function test_GetFeedbacks() public {
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 80, 0, "quality", "", "uri1");
        
        vm.prank(client2);
        reputationRegistry.giveFeedback(agentId, 60, 0, "speed", "", "uri2");
        
        (
            address[] memory clients,
            int128[] memory values,
            string[] memory tags,
            uint256[] memory timestamps,
            bool[] memory revoked
        ) = reputationRegistry.getFeedbacks(agentId);
        
        assertEq(clients.length, 2);
        assertEq(clients[0], client1);
        assertEq(clients[1], client2);
        assertEq(values[0], 80);
        assertEq(values[1], 60);
        assertEq(keccak256(bytes(tags[0])), keccak256(bytes("quality")));
        assertEq(keccak256(bytes(tags[1])), keccak256(bytes("speed")));
        assertGt(timestamps[0], 0);
        assertGt(timestamps[1], 0);
        assertFalse(revoked[0]);
        assertFalse(revoked[1]);
    }
    
    function test_NegativeScore() public {
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, -50, 0, "quality", "", "");
        
        (uint256 totalFeedbacks, int256 averageScore,) = 
            reputationRegistry.getReputationSummary(agentId);
        
        assertEq(totalFeedbacks, 1);
        assertEq(averageScore, -50);
    }
    
    function test_MixedScores() public {
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 100, 0, "quality", "", "");
        
        vm.prank(client2);
        reputationRegistry.giveFeedback(agentId, -100, 0, "quality", "", "");
        
        (uint256 totalFeedbacks, int256 averageScore,) = 
            reputationRegistry.getReputationSummary(agentId);
        
        assertEq(totalFeedbacks, 2);
        assertEq(averageScore, 0); // (100 + -100) / 2
    }

    // ─── Soulbound (v2) semantics ────────────────────────────────────
    //
    // Reviews bind to the wallet that owned the agent NFT at the
    // moment of attestation. When the NFT is sold, future reviews bind
    // to the new owner; past reviews stay with the previous owner.
    // These tests pin that contract.

    address public buyer = address(0x9);

    function test_Soulbound_ReviewsDontTransferWithNFT() public {
        // Alice (agentOwner) earns a great review while she owns #N.
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 100, 0, "quality", "", "");

        (uint256 before, int256 avgBefore,) =
            reputationRegistry.getReputationSummary(agentId);
        assertEq(before, 1);
        assertEq(avgBefore, 100);

        // Alice sells the NFT to Bob.
        vm.prank(agentOwner);
        identityRegistry.transferFrom(agentOwner, buyer, agentId);
        assertEq(identityRegistry.ownerOf(agentId), buyer);

        // The PUBLIC view of agent #N is now Bob's track record on
        // this agent — empty, because Bob just got it.
        (uint256 afterTransfer, int256 avgAfter,) =
            reputationRegistry.getReputationSummary(agentId);
        assertEq(afterTransfer, 0, "buyer must not inherit reviews");
        assertEq(avgAfter, 0);

        // Alice's track record on the agent during her tenure is still
        // queryable by anyone who knows to ask for it (marketplace
        // history view).
        (uint256 aliceTenure, int256 aliceAvg,) =
            reputationRegistry.getReputationByOwnerAgent(agentOwner, agentId);
        assertEq(aliceTenure, 1, "previous owner's track record persists");
        assertEq(aliceAvg, 100);
    }

    function test_Soulbound_NewOwnerEarnsFreshReputation() public {
        // Alice gets reviewed.
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 100, 0, "quality", "", "");

        // Sell to Bob.
        vm.prank(agentOwner);
        identityRegistry.transferFrom(agentOwner, buyer, agentId);

        // A new client reviews Bob's tenure of the same agent.
        // Same client1 can also review Bob now — he hasn't reviewed
        // Bob before, even though he reviewed Alice on the same NFT.
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, -50, 0, "quality", "", "");

        // Public view = Bob's track record only.
        (uint256 bobCount, int256 bobAvg,) =
            reputationRegistry.getReputationSummary(agentId);
        assertEq(bobCount, 1);
        assertEq(bobAvg, -50);

        // Alice's tenure still untouched.
        (uint256 aliceCount, int256 aliceAvg,) =
            reputationRegistry.getReputationByOwnerAgent(agentOwner, agentId);
        assertEq(aliceCount, 1);
        assertEq(aliceAvg, 100);
    }

    function test_Soulbound_OneReviewPerClientPerAgentTenure() public {
        // client1 reviews agent #N once.
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 80, 0, "quality", "", "");

        // Second review of the SAME (owner, agent) tenure must revert —
        // dedup applies per (owner, agent, client).
        vm.prank(client1);
        vm.expectRevert("Already gave feedback");
        reputationRegistry.giveFeedback(agentId, 60, 0, "quality", "", "");

        // Mint a SECOND agent owned by Alice.
        vm.prank(agentOwner);
        uint256 agentB = identityRegistry.registerAgent(
            "TestBot2", "uri2", 1000, address(0)
        );

        // client1 must be allowed to review the second agent — the
        // dedup must NOT collapse to wallet-level under the OWNER
        // subject, even though Alice owns both.
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentB, 80, 0, "quality", "", "");

        // Both summaries return one entry, distinct.
        (uint256 cA,,) = reputationRegistry.getReputationSummary(agentId);
        (uint256 cB,,) = reputationRegistry.getReputationSummary(agentB);
        assertEq(cA, 1);
        assertEq(cB, 1);
    }

    function test_Soulbound_RevokeAffectsOnlyMatchingAgent() public {
        // Alice owns two agents; client1 reviews both.
        vm.prank(agentOwner);
        uint256 agentB = identityRegistry.registerAgent(
            "TestBot2", "uri2", 1000, address(0)
        );

        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 100, 0, "quality", "", "");
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentB,  -50, 0, "quality", "", "");

        // Revoke ONLY the review of agent #N. Agent B's review must
        // remain intact even though both feedbacks live in the same
        // OWNER subject array.
        vm.prank(client1);
        reputationRegistry.revokeFeedback(agentId);

        (uint256 cA,,) = reputationRegistry.getReputationSummary(agentId);
        (uint256 cB, int256 avgB,) = reputationRegistry.getReputationSummary(agentB);
        assertEq(cA, 0, "revoked agent's count drops to 0");
        assertEq(cB, 1, "untouched agent's count survives");
        assertEq(avgB, -50);

        // client1 may now re-leave a review for agent #N (the dedup
        // flag was cleared by the revoke).
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 60, 0, "quality", "", "");
        (uint256 cAA, int256 avgAA,) = reputationRegistry.getReputationSummary(agentId);
        assertEq(cAA, 1);
        assertEq(avgAA, 60);
    }
}
