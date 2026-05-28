// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AgentRegistry
 * @dev ERC-8004 Agent Identity Registry - NFT-based agent identity system
 * Each agent is represented as an ERC-721 token with metadata
 */
contract AgentRegistry is ERC721, ERC721URIStorage, Ownable {
    uint256 private _nextTokenId;
    
    struct Agent {
        string name;
        string description;
        string a2aEndpoint;
        string mcpEndpoint;
        uint256 createdAt;
        bool active;
    }
    
    mapping(uint256 => Agent) public agents;
    mapping(bytes32 => uint256) public nameToTokenId;
    mapping(address => uint256[]) public ownerAgents;
    
    event AgentRegistered(uint256 indexed tokenId, address indexed owner, string name);
    event AgentUpdated(uint256 indexed tokenId, string name);
    event AgentDeactivated(uint256 indexed tokenId);
    event EndpointsUpdated(uint256 indexed tokenId, string a2aEndpoint, string mcpEndpoint);

    constructor() ERC721("ERC-8004 Agent", "AGENT") Ownable(msg.sender) {}

    /**
     * @dev Register a new agent identity
     * @param name Unique name for the agent
     * @param description Agent description
     * @param a2aEndpoint A2A protocol endpoint URL
     * @param mcpEndpoint MCP protocol endpoint URL
     * @param tokenURI Metadata URI for the agent
     */
    function registerAgent(
        string memory name,
        string memory description,
        string memory a2aEndpoint,
        string memory mcpEndpoint,
        string memory tokenURI
    ) public returns (uint256) {
        bytes32 nameHash = keccak256(abi.encodePacked(name));
        require(nameToTokenId[nameHash] == 0, "Agent name already registered");
        
        uint256 tokenId = _nextTokenId++;
        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, tokenURI);
        
        agents[tokenId] = Agent({
            name: name,
            description: description,
            a2aEndpoint: a2aEndpoint,
            mcpEndpoint: mcpEndpoint,
            createdAt: block.timestamp,
            active: true
        });
        
        nameToTokenId[nameHash] = tokenId + 1; // +1 to distinguish from default 0
        ownerAgents[msg.sender].push(tokenId);
        
        emit AgentRegistered(tokenId, msg.sender, name);
        return tokenId;
    }

    /**
     * @dev Update agent endpoints
     */
    function updateEndpoints(
        uint256 tokenId,
        string memory a2aEndpoint,
        string memory mcpEndpoint
    ) public {
        require(ownerOf(tokenId) == msg.sender, "Not agent owner");
        require(agents[tokenId].active, "Agent not active");
        
        agents[tokenId].a2aEndpoint = a2aEndpoint;
        agents[tokenId].mcpEndpoint = mcpEndpoint;
        
        emit EndpointsUpdated(tokenId, a2aEndpoint, mcpEndpoint);
    }

    /**
     * @dev Deactivate an agent
     */
    function deactivateAgent(uint256 tokenId) public {
        require(ownerOf(tokenId) == msg.sender, "Not agent owner");
        agents[tokenId].active = false;
        emit AgentDeactivated(tokenId);
    }

    /**
     * @dev Get agent by token ID
     */
    function getAgent(uint256 tokenId) public view returns (Agent memory) {
        require(_ownerOf(tokenId) != address(0), "Agent does not exist");
        return agents[tokenId];
    }

    /**
     * @dev Get agent by name
     */
    function getAgentByName(string memory name) public view returns (uint256, Agent memory) {
        bytes32 nameHash = keccak256(abi.encodePacked(name));
        uint256 tokenIdPlusOne = nameToTokenId[nameHash];
        require(tokenIdPlusOne > 0, "Agent not found");
        uint256 tokenId = tokenIdPlusOne - 1;
        return (tokenId, agents[tokenId]);
    }

    /**
     * @dev Get all agents owned by an address
     */
    function getAgentsByOwner(address owner) public view returns (uint256[] memory) {
        return ownerAgents[owner];
    }

    /**
     * @dev Get total number of registered agents
     */
    function totalAgents() public view returns (uint256) {
        return _nextTokenId;
    }

    // Required overrides
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
