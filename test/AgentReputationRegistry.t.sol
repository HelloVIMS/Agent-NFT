// SPDX-License-Identifier: MIT
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
}
