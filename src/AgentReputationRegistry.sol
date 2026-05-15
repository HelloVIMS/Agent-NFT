// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./AgentIdentityRegistry.sol";

/**
 * @title AgentReputationRegistry
 * @notice ERC-8004 compliant Reputation Registry for Agent agents
 * @dev Tracks feedback/ratings for agents from clients
 * @dev UUPS Upgradeable
 */
import {VimsProvenance} from "./VimsProvenance.sol";

contract AgentReputationRegistry is Initializable, VimsProvenance, OwnableUpgradeable, UUPSUpgradeable {
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentReputationRegistry";
    }

    AgentIdentityRegistry public identityRegistry;
    
    struct Feedback {
        address client;
        int128 value;        // Score (e.g., -100 to 100)
        uint8 decimals;      // Decimal places for value
        string tag1;         // Primary category (e.g., "quality")
        string tag2;         // Secondary category (e.g., "speed")
        string feedbackURI;  // IPFS URI for detailed feedback
        uint256 timestamp;
        bool revoked;
    }
    
    // agentId => feedbacks
    mapping(uint256 => Feedback[]) public feedbacks;
    
    // agentId => client => hasFeedback (prevent spam)
    mapping(uint256 => mapping(address => bool)) public clientHasFeedback;
    
    // agentId => tag => average score
    mapping(uint256 => mapping(string => int256)) public tagScores;
    mapping(uint256 => mapping(string => uint256)) public tagCounts;
    
    event FeedbackGiven(
        uint256 indexed agentId,
        address indexed client,
        int128 value,
        string tag1,
        string feedbackURI
    );
    
    event FeedbackRevoked(
        uint256 indexed agentId,
        address indexed client,
        uint256 feedbackIndex
    );
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address _identityRegistry) public initializer {
        __Ownable_init(msg.sender);
        identityRegistry = AgentIdentityRegistry(_identityRegistry);
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    /**
     * @notice Give feedback to an agent
     * @param agentId The agent's token ID
     * @param value Score value (recommend -100 to 100)
     * @param decimals Decimal places for the value
     * @param tag1 Primary category tag
     * @param tag2 Secondary category tag
     * @param feedbackURI IPFS URI with detailed feedback
     */
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 decimals,
        string calldata tag1,
        string calldata tag2,
        string calldata feedbackURI
    ) external {
        // Verify agent exists
        require(identityRegistry.ownerOf(agentId) != address(0), "Agent does not exist");
        
        // Prevent self-review
        require(identityRegistry.ownerOf(agentId) != msg.sender, "Cannot review own agent");
        
        // Prevent duplicate feedback (can revoke and re-submit)
        require(!clientHasFeedback[agentId][msg.sender], "Already gave feedback");
        
        feedbacks[agentId].push(Feedback({
            client: msg.sender,
            value: value,
            decimals: decimals,
            tag1: tag1,
            tag2: tag2,
            feedbackURI: feedbackURI,
            timestamp: block.timestamp,
            revoked: false
        }));
        
        clientHasFeedback[agentId][msg.sender] = true;
        
        // Update tag scores
        if (bytes(tag1).length > 0) {
            tagScores[agentId][tag1] += int256(value);
            tagCounts[agentId][tag1]++;
        }
        if (bytes(tag2).length > 0) {
            tagScores[agentId][tag2] += int256(value);
            tagCounts[agentId][tag2]++;
        }
        
        emit FeedbackGiven(agentId, msg.sender, value, tag1, feedbackURI);
    }
    
    /**
     * @notice Revoke your feedback for an agent
     * @param agentId The agent's token ID
     */
    function revokeFeedback(uint256 agentId) external {
        require(clientHasFeedback[agentId][msg.sender], "No feedback to revoke");
        
        Feedback[] storage agentFeedbacks = feedbacks[agentId];
        
        for (uint256 i = 0; i < agentFeedbacks.length; i++) {
            if (agentFeedbacks[i].client == msg.sender && !agentFeedbacks[i].revoked) {
                Feedback storage fb = agentFeedbacks[i];
                fb.revoked = true;
                
                // Update tag scores
                if (bytes(fb.tag1).length > 0) {
                    tagScores[agentId][fb.tag1] -= int256(fb.value);
                    tagCounts[agentId][fb.tag1]--;
                }
                if (bytes(fb.tag2).length > 0) {
                    tagScores[agentId][fb.tag2] -= int256(fb.value);
                    tagCounts[agentId][fb.tag2]--;
                }
                
                clientHasFeedback[agentId][msg.sender] = false;
                
                emit FeedbackRevoked(agentId, msg.sender, i);
                return;
            }
        }
        
        revert("Feedback not found");
    }
    
    /**
     * @notice Get reputation summary for an agent
     * @param agentId The agent's token ID
     * @return totalFeedbacks Number of non-revoked feedbacks
     * @return averageScore Average score across all feedbacks
     * @return lastFeedbackTime Timestamp of most recent feedback
     */
    function getReputationSummary(uint256 agentId) external view returns (
        uint256 totalFeedbacks,
        int256 averageScore,
        uint256 lastFeedbackTime
    ) {
        Feedback[] storage agentFeedbacks = feedbacks[agentId];
        
        if (agentFeedbacks.length == 0) {
            return (0, 0, 0);
        }
        
        int256 sum = 0;
        uint256 count = 0;
        uint256 lastTime = 0;
        
        for (uint256 i = 0; i < agentFeedbacks.length; i++) {
            if (!agentFeedbacks[i].revoked) {
                sum += int256(agentFeedbacks[i].value);
                count++;
                if (agentFeedbacks[i].timestamp > lastTime) {
                    lastTime = agentFeedbacks[i].timestamp;
                }
            }
        }
        
        return (
            count,
            count > 0 ? sum / int256(count) : int256(0),
            lastTime
        );
    }
    
    /**
     * @notice Get average score for a specific tag
     * @param agentId The agent's token ID
     * @param tag The tag to query
     */
    function getTagScore(uint256 agentId, string calldata tag) external view returns (
        int256 averageScore,
        uint256 feedbackCount
    ) {
        uint256 count = tagCounts[agentId][tag];
        if (count == 0) {
            return (0, 0);
        }
        
        return (
            tagScores[agentId][tag] / int256(count),
            count
        );
    }
    
    /**
     * @notice Get all feedbacks for an agent
     * @param agentId The agent's token ID
     */
    function getFeedbacks(uint256 agentId) external view returns (
        address[] memory clients,
        int128[] memory values,
        string[] memory tags,
        uint256[] memory timestamps,
        bool[] memory revoked
    ) {
        Feedback[] storage agentFeedbacks = feedbacks[agentId];
        uint256 len = agentFeedbacks.length;
        
        clients = new address[](len);
        values = new int128[](len);
        tags = new string[](len);
        timestamps = new uint256[](len);
        revoked = new bool[](len);
        
        for (uint256 i = 0; i < len; i++) {
            clients[i] = agentFeedbacks[i].client;
            values[i] = agentFeedbacks[i].value;
            tags[i] = agentFeedbacks[i].tag1;
            timestamps[i] = agentFeedbacks[i].timestamp;
            revoked[i] = agentFeedbacks[i].revoked;
        }
    }
    
    /**
     * @notice Get feedback count for an agent
     */
    function getFeedbackCount(uint256 agentId) external view returns (uint256) {
        return feedbacks[agentId].length;
    }
}
