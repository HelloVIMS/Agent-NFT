// SPDX-License-Identifier: AGPL-3.0-or-later
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
    
    // SECURITY: Subject keys are domain-separated bytes32 derived from
    // keccak256("AGENT", agentId) for transferable agents, or
    // keccak256("ANCHOR", anchorAddress) for anchored agents. This prevents
    // an attacker from minting an anchor address whose uint160 representation
    // collides with an existing agentId, which would otherwise merge two
    // independent reputation pools.

    // subject => feedbacks
    mapping(bytes32 => Feedback[]) public feedbacks;

    // subject => client => hasFeedback (prevent spam)
    mapping(bytes32 => mapping(address => bool)) public clientHasFeedback;

    // subject => tag => average score
    mapping(bytes32 => mapping(string => int256)) public tagScores;
    mapping(bytes32 => mapping(string => uint256)) public tagCounts;

    bytes32 private constant _SUBJECT_AGENT  = keccak256("AGENT");
    bytes32 private constant _SUBJECT_ANCHOR = keccak256("ANCHOR");

    event FeedbackGiven(
        uint256 indexed agentId,
        address indexed client,
        bytes32 indexed subject,
        int128 value,
        string tag1,
        string feedbackURI
    );

    event FeedbackRevoked(
        uint256 indexed agentId,
        address indexed client,
        bytes32 indexed subject,
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
    /**
     * @dev Resolve the reputation subject key for an agentId.
     *      Returns a domain-separated bytes32:
     *        - keccak256("ANCHOR", anchor)  if reputationAnchor is non-zero
     *        - keccak256("AGENT",  agentId) otherwise (transferable, follows NFT)
     *      Domain separation prevents agentId/anchor namespace collisions.
     */
    function _reputationSubject(uint256 agentId) internal view returns (bytes32 subject) {
        address anchor = identityRegistry.reputationAnchorOf(agentId);
        if (anchor != address(0)) {
            return keccak256(abi.encode(_SUBJECT_ANCHOR, anchor));
        }
        return keccak256(abi.encode(_SUBJECT_AGENT, agentId));
    }

    /**
     * @dev Canonicalise a caller into the address that should be recorded as
     *      the client and used for dedup. If `caller` is bound (primary TBA
     *      or subaccount) to some agent in the IdentityRegistry, returns that agent's NFT
     *      owner; otherwise returns `caller` unchanged. Bound callers MUST
     *      hold `PERM_REPUTATION` — this prevents an agent from spamming
     *      reviews by spawning fresh subaccounts.
     */
    function _canonicalClient(address caller) internal view returns (address canonical, uint256 boundAgentId, bool isBound) {
        (uint256 agentId, bool bound,,,) = identityRegistry.agentIdOf(caller);
        if (!bound) return (caller, 0, false);
        require(
            identityRegistry.hasPermission(caller, identityRegistry.PERM_REPUTATION()),
            "Subaccount lacks PERM_REPUTATION"
        );
        return (identityRegistry.ownerOf(agentId), agentId, true);
    }

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

        // Canonicalise bound subaccounts to their agent owner so dedup
        // and self-review checks operate on stable identity.
        (address client, uint256 callerAgentId, bool isBound) = _canonicalClient(msg.sender);

        // Prevent self-review (covers both NFT owner and any of its subaccounts)
        require(identityRegistry.ownerOf(agentId) != client, "Cannot review own agent");
        if (isBound) require(callerAgentId != agentId, "Cannot review own agent");

        // Prevent duplicate feedback (can revoke and re-submit). Dedup is
        // keyed on the canonical client to defeat subaccount spam.
        bytes32 subject = _reputationSubject(agentId);
        require(!clientHasFeedback[subject][client], "Already gave feedback");

        feedbacks[subject].push(Feedback({
            client: client,
            value: value,
            decimals: decimals,
            tag1: tag1,
            tag2: tag2,
            feedbackURI: feedbackURI,
            timestamp: block.timestamp,
            revoked: false
        }));
        
        clientHasFeedback[subject][client] = true;

        // Update tag scores
        if (bytes(tag1).length > 0) {
            tagScores[subject][tag1] += int256(value);
            tagCounts[subject][tag1]++;
        }
        if (bytes(tag2).length > 0) {
            tagScores[subject][tag2] += int256(value);
            tagCounts[subject][tag2]++;
        }
        
        emit FeedbackGiven(agentId, client, subject, value, tag1, feedbackURI);
    }
    
    /**
     * @notice Revoke your feedback for an agent
     * @param agentId The agent's token ID
     */
    function revokeFeedback(uint256 agentId) external {
        // Same canonicalisation as giveFeedback so a subaccount can revoke
        // a feedback that the canonical client recorded.
        (address client,, ) = _canonicalClient(msg.sender);
        bytes32 subject = _reputationSubject(agentId);
        require(clientHasFeedback[subject][client], "No feedback to revoke");

        Feedback[] storage agentFeedbacks = feedbacks[subject];
        
        for (uint256 i = 0; i < agentFeedbacks.length; i++) {
            if (agentFeedbacks[i].client == client && !agentFeedbacks[i].revoked) {
                Feedback storage fb = agentFeedbacks[i];
                fb.revoked = true;
                
                // Update tag scores
                if (bytes(fb.tag1).length > 0) {
                    tagScores[subject][fb.tag1] -= int256(fb.value);
                    tagCounts[subject][fb.tag1]--;
                }
                if (bytes(fb.tag2).length > 0) {
                    tagScores[subject][fb.tag2] -= int256(fb.value);
                    tagCounts[subject][fb.tag2]--;
                }

                clientHasFeedback[subject][client] = false;
                
                emit FeedbackRevoked(agentId, client, subject, i);
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
        bytes32 subject = _reputationSubject(agentId);
        Feedback[] storage agentFeedbacks = feedbacks[subject];
        
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
        bytes32 subject = _reputationSubject(agentId);
        uint256 count = tagCounts[subject][tag];
        if (count == 0) {
            return (0, 0);
        }
        
        return (
            tagScores[subject][tag] / int256(count),
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
        bytes32 subject = _reputationSubject(agentId);
        Feedback[] storage agentFeedbacks = feedbacks[subject];
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
     * @notice Get feedback array length (includes revoked) for an agent.
     *         Resolves through the reputation anchor when set.
     * @dev    For an active count excluding revoked entries, use
     *         {getReputationSummary}.
     */
    function getFeedbackCount(uint256 agentId) external view returns (uint256) {
        return feedbacks[_reputationSubject(agentId)].length;
    }

    /**
     * @notice Indexed accessor for feedback storage that resolves through the
     *         reputation anchor. This is the canonical way for adapters and
     *         indexers to iterate feedbacks by `agentId` regardless of
     *         whether the subject is the agentId or the anchor address.
     * @dev    Reverts if `index` is out of range.
     */
    function getFeedbackAt(uint256 agentId, uint256 index) external view returns (
        address client,
        int128 value,
        uint8 decimals,
        string memory tag1,
        string memory tag2,
        string memory feedbackURI,
        uint256 timestamp,
        bool revoked
    ) {
        Feedback storage fb = feedbacks[_reputationSubject(agentId)][index];
        return (
            fb.client,
            fb.value,
            fb.decimals,
            fb.tag1,
            fb.tag2,
            fb.feedbackURI,
            fb.timestamp,
            fb.revoked
        );
    }

    /**
     * @notice Returns the raw subject key used to store this agent's
     *         reputation. Useful for off-chain indexers.
     */
    function reputationSubjectOf(uint256 agentId) external view returns (bytes32) {
        return _reputationSubject(agentId);
    }
}
