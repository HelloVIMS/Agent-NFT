// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ReputationRegistry
 * @dev ERC-8004 Reputation Registry - On-chain reputation scoring for agents
 */
contract ReputationRegistry is Ownable {
    struct Review {
        address reviewer;
        uint8 score; // 0-100
        string[] tags;
        uint256 timestamp;
        string comment;
    }
    
    struct ReputationScore {
        uint256 totalScore;
        uint256 reviewCount;
        uint256 lastReviewAt;
    }
    
    mapping(uint256 => ReputationScore) public scores;
    mapping(uint256 => Review[]) public reviews;
    mapping(uint256 => mapping(address => bool)) public hasReviewed;
    
    address public agentRegistry;
    
    event ReviewSubmitted(uint256 indexed agentId, address indexed reviewer, uint8 score);
    event ReputationUpdated(uint256 indexed agentId, uint256 newAverage, uint256 totalReviews);

    constructor(address _agentRegistry) Ownable(msg.sender) {
        agentRegistry = _agentRegistry;
    }

    /**
     * @dev Submit a review for an agent
     * @param agentId The token ID of the agent in AgentRegistry
     * @param score Score from 0-100
     * @param tags Array of reputation tags
     * @param comment Optional comment
     */
    function submitReview(
        uint256 agentId,
        uint8 score,
        string[] memory tags,
        string memory comment
    ) public {
        require(score <= 100, "Score must be 0-100");
        require(!hasReviewed[agentId][msg.sender], "Already reviewed this agent");
        
        reviews[agentId].push(Review({
            reviewer: msg.sender,
            score: score,
            tags: tags,
            timestamp: block.timestamp,
            comment: comment
        }));
        
        hasReviewed[agentId][msg.sender] = true;
        
        // Update aggregate score
        scores[agentId].totalScore += score;
        scores[agentId].reviewCount++;
        scores[agentId].lastReviewAt = block.timestamp;
        
        uint256 average = scores[agentId].totalScore / scores[agentId].reviewCount;
        
        emit ReviewSubmitted(agentId, msg.sender, score);
        emit ReputationUpdated(agentId, average, scores[agentId].reviewCount);
    }

    /**
     * @dev Get reputation score for an agent
     */
    function getReputation(uint256 agentId) public view returns (
        uint256 averageScore,
        uint256 totalReviews,
        uint256 lastReviewAt
    ) {
        ReputationScore memory rep = scores[agentId];
        if (rep.reviewCount == 0) {
            return (0, 0, 0);
        }
        return (
            rep.totalScore / rep.reviewCount,
            rep.reviewCount,
            rep.lastReviewAt
        );
    }

    /**
     * @dev Get all reviews for an agent
     */
    function getReviews(uint256 agentId) public view returns (Review[] memory) {
        return reviews[agentId];
    }

    /**
     * @dev Get review count for an agent
     */
    function getReviewCount(uint256 agentId) public view returns (uint256) {
        return scores[agentId].reviewCount;
    }

    /**
     * @dev Check if address has reviewed an agent
     */
    function hasAddressReviewed(uint256 agentId, address reviewer) public view returns (bool) {
        return hasReviewed[agentId][reviewer];
    }

    /**
     * @dev Update agent registry address (owner only)
     */
    function setAgentRegistry(address _agentRegistry) public onlyOwner {
        agentRegistry = _agentRegistry;
    }
}
