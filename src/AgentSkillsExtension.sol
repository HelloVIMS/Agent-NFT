// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IAgentIdentityRegistry.sol";

/**
 * @title AgentSkillsExtension
 * @notice V5 Extension: Skill files (.md) storage for Agent agents
 * @dev Separates skill storage from main registry to stay under 24KB limit
 */
contract AgentSkillsExtension is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    
    error NotOwner();
    error NotExists();
    error MaxReached();
    error EmptyInput();
    error AlreadySet();
    
    IAgentIdentityRegistry public identityRegistry;
    
    struct SkillVersion {
        string arweaveTxId;
        bytes32 contentHash;
        string skillName;
        uint48 timestamp;
        string description;
        bool enabled;
    }
    
    mapping(uint256 => SkillVersion[]) private _skillVersions;
    mapping(uint256 => mapping(string => uint256)) private _skillNameToIndex;
    
    uint256 public constant MAX_SKILL_VERSIONS = 100;
    
    event SkillAdded(uint256 indexed agentId, string skillName, bytes32 contentHash, string arweaveTxId);
    event SkillUpdated(uint256 indexed agentId, string skillName, uint256 indexed version, bytes32 contentHash);
    event SkillToggled(uint256 indexed agentId, string skillName, bool enabled);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address _identityRegistry) public initializer {
        __Ownable_init(msg.sender);
        identityRegistry = IAgentIdentityRegistry(_identityRegistry);
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    modifier onlyAgentOwner(uint256 agentId) {
        if (identityRegistry.ownerOf(agentId) != msg.sender) revert NotOwner();
        _;
    }
    
    function addSkill(
        uint256 agentId,
        string calldata skillName,
        string calldata arweaveTxId,
        bytes32 contentHash,
        string calldata description
    ) external onlyAgentOwner(agentId) returns (uint256 index) {
        if (bytes(skillName).length == 0) revert EmptyInput();
        if (bytes(arweaveTxId).length == 0) revert EmptyInput();
        if (contentHash == bytes32(0)) revert EmptyInput();
        if (_skillVersions[agentId].length >= MAX_SKILL_VERSIONS) revert MaxReached();
        if (_skillNameToIndex[agentId][skillName] != 0) revert AlreadySet();
        
        index = _skillVersions[agentId].length;
        
        _skillVersions[agentId].push(SkillVersion({
            arweaveTxId: arweaveTxId,
            contentHash: contentHash,
            skillName: skillName,
            timestamp: uint48(block.timestamp),
            description: description,
            enabled: true
        }));
        
        _skillNameToIndex[agentId][skillName] = index + 1;
        
        emit SkillAdded(agentId, skillName, contentHash, arweaveTxId);
    }
    
    function updateSkill(
        uint256 agentId,
        string calldata skillName,
        string calldata arweaveTxId,
        bytes32 contentHash,
        string calldata description
    ) external onlyAgentOwner(agentId) {
        uint256 indexPlusOne = _skillNameToIndex[agentId][skillName];
        if (indexPlusOne == 0) revert NotExists();
        
        uint256 index = indexPlusOne - 1;
        SkillVersion storage skill = _skillVersions[agentId][index];
        
        skill.arweaveTxId = arweaveTxId;
        skill.contentHash = contentHash;
        skill.timestamp = uint48(block.timestamp);
        skill.description = description;
        
        emit SkillUpdated(agentId, skillName, index, contentHash);
    }
    
    function toggleSkill(
        uint256 agentId,
        string calldata skillName,
        bool enabled
    ) external onlyAgentOwner(agentId) {
        uint256 indexPlusOne = _skillNameToIndex[agentId][skillName];
        if (indexPlusOne == 0) revert NotExists();
        
        _skillVersions[agentId][indexPlusOne - 1].enabled = enabled;
        
        emit SkillToggled(agentId, skillName, enabled);
    }
    
    function hasSkill(uint256 agentId, string calldata skillName) external view returns (bool) {
        uint256 indexPlusOne = _skillNameToIndex[agentId][skillName];
        if (indexPlusOne == 0) return false;
        return _skillVersions[agentId][indexPlusOne - 1].enabled;
    }
    
    function getSkill(uint256 agentId, string calldata skillName) external view returns (
        string memory arweaveTxId,
        bytes32 contentHash,
        uint256 timestamp,
        string memory description,
        bool enabled
    ) {
        uint256 indexPlusOne = _skillNameToIndex[agentId][skillName];
        if (indexPlusOne == 0) revert NotExists();
        
        SkillVersion memory skill = _skillVersions[agentId][indexPlusOne - 1];
        return (skill.arweaveTxId, skill.contentHash, skill.timestamp, skill.description, skill.enabled);
    }
    
    function getAllSkills(uint256 agentId) external view returns (SkillVersion[] memory) {
        return _skillVersions[agentId];
    }
    
    function getSkillCount(uint256 agentId) external view returns (uint256) {
        return _skillVersions[agentId].length;
    }
    
    function getSkillURL(uint256 agentId, string calldata skillName) external view returns (string memory) {
        uint256 indexPlusOne = _skillNameToIndex[agentId][skillName];
        if (indexPlusOne == 0) revert NotExists();
        
        SkillVersion memory skill = _skillVersions[agentId][indexPlusOne - 1];
        return string(abi.encodePacked("ar://", skill.arweaveTxId));
    }
    
    function setIdentityRegistry(address _identityRegistry) external onlyOwner {
        identityRegistry = IAgentIdentityRegistry(_identityRegistry);
    }
}
