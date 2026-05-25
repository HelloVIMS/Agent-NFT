// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "./interfaces/IAgentIdentityRegistry.sol";

/**
 * @title AgentContextRegistry
 * @notice Generic context-file registry for an Agent NFT. Stores typed files
 *         (Markdown, JSON, YAML, plain text) under named keys, with categories
 *         covering skills, personality, instructions, prompts, templates, etc.
 * @dev Supersedes the old `AgentSkillsExtension`. The schema is content-type
 *      and category aware so a single contract serves every "static context
 *      injection" use case. For aggregated, longform, version-history memory
 *      use `AgentMemory` (Pixelog `.pixe` capsules) instead.
 *
 * Composition with `AgentMemory`:
 *   - Use this contract for static, per-file context the agent loads at boot:
 *     skill modules, personality cards, system prompts, response templates.
 *   - Use `AgentMemory` for accumulated experiential memory: typed categories,
 *     context tiers, merkle-rooted consolidations.
 *
 * UUPS upgradeable. Only the agent NFT owner may write.
 */
import {VimsProvenance} from "./VimsProvenance.sol";

contract AgentContextRegistry is
    Initializable,
    VimsProvenance,
    OwnableUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable
{
    // ============ Errors ============
    error NotOwner();
    error NotExists();
    error AlreadyExists();
    error MaxReached();
    error EmptyInput();
    error TooLarge();
    error InvalidFileType();
    error InvalidCategory();
    error ZeroAddress();

    // ============ File-type constants ============
    uint8 public constant FILE_MD       = 0;
    uint8 public constant FILE_JSON     = 1;
    uint8 public constant FILE_YAML     = 2;
    uint8 public constant FILE_TXT      = 3;
    uint8 public constant FILE_OTHER    = 4;
    uint8 public constant MAX_FILE_TYPE = 4;

    // ============ Category constants ============
    uint8 public constant CAT_SKILL       = 0;
    uint8 public constant CAT_PERSONALITY = 1;
    uint8 public constant CAT_INSTRUCTION = 2;
    uint8 public constant CAT_PROMPT      = 3;
    uint8 public constant CAT_TEMPLATE    = 4;
    uint8 public constant CAT_PERSONA     = 5;
    uint8 public constant CAT_OTHER       = 6;
    uint8 public constant MAX_CATEGORY    = 6;

    // ============ Limits ============
    uint256 public constant MAX_FILES_PER_AGENT = 256;
    uint256 public constant MAX_NAME_LEN        = 64;
    uint256 public constant MAX_STORAGE_URI_LEN = 512;
    uint256 public constant MAX_DESCRIPTION_LEN = 256;

    // ============ Struct ============
    struct ContextFile {
        string  name;          // stable key, unique per agent
        string  storageURI;    // pixe:// | ipfs:// | ar:// | https://
        bytes32 contentHash;   // SHA-256 of file content
        string  description;
        uint48  updatedAt;
        uint8   fileType;      // 0=md 1=json 2=yaml 3=txt 4=other
        uint8   category;      // 0=skill 1=personality 2=instr 3=prompt 4=template 5=persona 6=other
        bool    enabled;
    }

    // ============ Storage ============
    IAgentIdentityRegistry public identityRegistry;

    mapping(uint256 => ContextFile[]) private _files;
    // agentId => name => index+1 (0 == not present)
    mapping(uint256 => mapping(string => uint256)) private _nameIndex;
    // agentId => category => list of indices
    mapping(uint256 => mapping(uint8 => uint256[])) private _byCategory;

    // ============ Events ============
    event FileAdded(
        uint256 indexed agentId,
        uint256 indexed index,
        string  name,
        bytes32 contentHash,
        uint8   fileType,
        uint8   category,
        string  storageURI
    );
    event FileUpdated(
        uint256 indexed agentId,
        uint256 indexed index,
        bytes32 contentHash,
        string  storageURI
    );
    event FileToggled(uint256 indexed agentId, uint256 indexed index, bool enabled);
    event IdentityRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // ============ Init ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentContextRegistry";
    }

    function initialize(address _identityRegistry) public initializer {
        if (_identityRegistry == address(0)) revert ZeroAddress();
        __Ownable_init(msg.sender);
        __Pausable_init();
        identityRegistry = IAgentIdentityRegistry(_identityRegistry);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Emergency stop on writes. Views remain available.
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setIdentityRegistry(address _identityRegistry) external onlyOwner {
        if (_identityRegistry == address(0)) revert ZeroAddress();
        emit IdentityRegistryUpdated(address(identityRegistry), _identityRegistry);
        identityRegistry = IAgentIdentityRegistry(_identityRegistry);
    }

    /// @dev Authorises either the agent NFT owner or any subaccount/primary
    ///      TBA bound to `agentId` that holds `PERM_CONTEXT_WRITE`.
    modifier onlyAgentOwner(uint256 agentId) {
        if (identityRegistry.ownerOf(agentId) != msg.sender) {
            if (!identityRegistry.hasPermission(msg.sender, identityRegistry.PERM_CONTEXT_WRITE())) {
                revert NotOwner();
            }
            // Confirm the bound agentId matches.
            (uint256 boundId, bool bound,,,) = identityRegistry.agentIdOf(msg.sender);
            if (!bound || boundId != agentId) revert NotOwner();
        }
        _;
    }

    // ============ Write API ============
    /**
     * @notice Add a new context file under a unique `name` for the agent.
     * @return index Position of the file in the per-agent list.
     */
    function addFile(
        uint256 agentId,
        string calldata name,
        string calldata storageURI,
        bytes32 contentHash,
        uint8   fileType,
        uint8   category,
        string calldata description
    ) external onlyAgentOwner(agentId) whenNotPaused returns (uint256 index) {
        _validate(name, storageURI, contentHash, fileType, category, description);
        if (_files[agentId].length >= MAX_FILES_PER_AGENT) revert MaxReached();
        if (_nameIndex[agentId][name] != 0) revert AlreadyExists();

        index = _files[agentId].length;
        _files[agentId].push(ContextFile({
            name:        name,
            storageURI:  storageURI,
            contentHash: contentHash,
            description: description,
            updatedAt:   uint48(block.timestamp),
            fileType:    fileType,
            category:    category,
            enabled:     true
        }));
        _nameIndex[agentId][name] = index + 1;
        _byCategory[agentId][category].push(index);

        emit FileAdded(agentId, index, name, contentHash, fileType, category, storageURI);
    }

    /**
     * @notice Update the URI / hash / description of an existing file.
     *         The file's `name`, `fileType` and `category` are immutable to
     *         keep retrieval keys stable.
     */
    function updateFile(
        uint256 agentId,
        string calldata name,
        string calldata storageURI,
        bytes32 contentHash,
        string calldata description
    ) external onlyAgentOwner(agentId) whenNotPaused {
        if (bytes(storageURI).length == 0) revert EmptyInput();
        if (bytes(storageURI).length > MAX_STORAGE_URI_LEN) revert TooLarge();
        if (contentHash == bytes32(0)) revert EmptyInput();
        if (bytes(description).length > MAX_DESCRIPTION_LEN) revert TooLarge();

        uint256 idxPlusOne = _nameIndex[agentId][name];
        if (idxPlusOne == 0) revert NotExists();
        uint256 index = idxPlusOne - 1;

        ContextFile storage f = _files[agentId][index];
        f.storageURI  = storageURI;
        f.contentHash = contentHash;
        f.description = description;
        f.updatedAt   = uint48(block.timestamp);

        emit FileUpdated(agentId, index, contentHash, storageURI);
    }

    /// @notice Toggle whether a file is currently active for the agent.
    function setEnabled(
        uint256 agentId,
        string calldata name,
        bool enabled
    ) external onlyAgentOwner(agentId) whenNotPaused {
        uint256 idxPlusOne = _nameIndex[agentId][name];
        if (idxPlusOne == 0) revert NotExists();
        uint256 index = idxPlusOne - 1;
        _files[agentId][index].enabled = enabled;
        emit FileToggled(agentId, index, enabled);
    }

    // ============ Read API ============
    function fileCount(uint256 agentId) external view returns (uint256) {
        return _files[agentId].length;
    }

    function hasFile(uint256 agentId, string calldata name) external view returns (bool) {
        uint256 idxPlusOne = _nameIndex[agentId][name];
        if (idxPlusOne == 0) return false;
        return _files[agentId][idxPlusOne - 1].enabled;
    }

    function getFile(uint256 agentId, string calldata name) external view returns (ContextFile memory) {
        uint256 idxPlusOne = _nameIndex[agentId][name];
        if (idxPlusOne == 0) revert NotExists();
        return _files[agentId][idxPlusOne - 1];
    }

    function getFileAt(uint256 agentId, uint256 index) external view returns (ContextFile memory) {
        if (index >= _files[agentId].length) revert NotExists();
        return _files[agentId][index];
    }

    function getAllFiles(uint256 agentId) external view returns (ContextFile[] memory) {
        return _files[agentId];
    }

    function filesByCategory(uint256 agentId, uint8 category) external view returns (uint256[] memory) {
        if (category > MAX_CATEGORY) revert InvalidCategory();
        return _byCategory[agentId][category];
    }

    /// @notice Paginated read of `_files[agentId]`.
    function getFilesRange(
        uint256 agentId,
        uint256 startIndex,
        uint256 count
    ) external view returns (ContextFile[] memory page) {
        ContextFile[] storage src = _files[agentId];
        uint256 len = src.length;
        if (startIndex >= len) return new ContextFile[](0);
        uint256 end = startIndex + count;
        if (end > len) end = len;
        page = new ContextFile[](end - startIndex);
        for (uint256 i = startIndex; i < end; ++i) page[i - startIndex] = src[i];
    }

    /// @notice Paginated read of `_byCategory[agentId][category]`.
    function filesByCategoryRange(
        uint256 agentId,
        uint8   category,
        uint256 startIndex,
        uint256 count
    ) external view returns (uint256[] memory page) {
        if (category > MAX_CATEGORY) revert InvalidCategory();
        uint256[] storage src = _byCategory[agentId][category];
        uint256 len = src.length;
        if (startIndex >= len) return new uint256[](0);
        uint256 end = startIndex + count;
        if (end > len) end = len;
        page = new uint256[](end - startIndex);
        for (uint256 i = startIndex; i < end; ++i) page[i - startIndex] = src[i];
    }

    // ============ Internal ============
    function _validate(
        string calldata name,
        string calldata storageURI,
        bytes32 contentHash,
        uint8   fileType,
        uint8   category,
        string calldata description
    ) internal pure {
        if (bytes(name).length == 0) revert EmptyInput();
        if (bytes(name).length > MAX_NAME_LEN) revert TooLarge();
        if (bytes(storageURI).length == 0) revert EmptyInput();
        if (bytes(storageURI).length > MAX_STORAGE_URI_LEN) revert TooLarge();
        if (contentHash == bytes32(0)) revert EmptyInput();
        if (bytes(description).length > MAX_DESCRIPTION_LEN) revert TooLarge();
        if (fileType > MAX_FILE_TYPE) revert InvalidFileType();
        if (category > MAX_CATEGORY) revert InvalidCategory();
    }
}
