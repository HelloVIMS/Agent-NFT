// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "./interfaces/IAgentIdentityRegistry.sol";

/**
 * @title AgentMemory
 * @notice V5 standalone .pixe memory storage for Agent NFTs, aligned with the
 *         current Pixelog architecture (typed categories, context tiers,
 *         storage-agnostic URIs, merkle-rooted consolidations).
 * @dev Replaces the inline V4 .pixe storage that lived inside
 *      `AgentIdentityRegistry`. UUPS upgradeable. Owner of the agent NFT is
 *      the only address authorised to write.
 *
 * Pixelog alignment:
 *   - Generic `storageURI` (`pixe://capsule/<sha256>`, `ipfs://<cid>`,
 *     `ar://<txid>`, `https://...`) — no longer Arweave-locked.
 *   - 6 typed memory categories (preference, instruction, fact, event,
 *     relationship, skill) plus a `mixed` bucket for unclassified deltas.
 *   - 3 context tiers (L0 ≤32 tokens summary, L1 ≤128 tokens overview,
 *     L2 unbounded full content).
 *   - Version kinds: delta, consolidated, capsule, memory.
 *   - Indexed by category and tier for O(1) partitioned retrieval.
 *
 * Spec: https://github.com/ArqonAi/Pixelog
 */
import {VimsProvenance} from "./VimsProvenance.sol";

contract AgentMemory is
    Initializable,
    VimsProvenance,
    OwnableUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable
{
    // ============ Errors ============
    error NotOwner();
    error NotExists();
    error MaxReached();
    error EmptyInput();
    error TooLarge();
    error InvalidCategory();
    error InvalidTier();
    error InvalidVersionType();
    error InvalidRange();
    error ZeroAddress();

    // ============ Category constants (mirror Pixelog `internal/memory/categories.go`) ============
    uint8 public constant CATEGORY_MIXED        = 0;
    uint8 public constant CATEGORY_PREFERENCE   = 1;
    uint8 public constant CATEGORY_INSTRUCTION  = 2;
    uint8 public constant CATEGORY_FACT         = 3;
    uint8 public constant CATEGORY_EVENT        = 4;
    uint8 public constant CATEGORY_RELATIONSHIP = 5;
    uint8 public constant CATEGORY_SKILL        = 6;
    uint8 public constant MAX_CATEGORY          = 6;

    // ============ Tier constants (mirror Pixelog `internal/memory/tiered.go`) ============
    uint8 public constant TIER_L0  = 0; // ≤32 tokens, abstract summary
    uint8 public constant TIER_L1  = 1; // ≤128 tokens, overview
    uint8 public constant TIER_L2  = 2; // unbounded, full content
    uint8 public constant MAX_TIER = 2;

    // ============ Version kind constants ============
    uint8 public constant TYPE_DELTA        = 0;
    uint8 public constant TYPE_CONSOLIDATED = 1;
    uint8 public constant TYPE_CAPSULE      = 2;
    uint8 public constant TYPE_MEMORY       = 3;
    uint8 public constant MAX_TYPE          = 3;

    // ============ Limits ============
    uint256 public constant MAX_PIXE_VERSIONS    = 10_000;
    uint256 public constant MAX_STORAGE_URI_LEN  = 512;
    uint256 public constant MAX_DESCRIPTION_LEN  = 256;

    // ============ Structs ============
    struct PixeVersion {
        string  storageURI;     // pixe:// | ipfs:// | ar:// | https://
        bytes32 contentHash;    // SHA-256 of capsule content
        uint8   versionType;    // 0=delta 1=consolidated 2=capsule 3=memory
        uint8   category;       // 0=mixed 1=pref 2=instr 3=fact 4=event 5=rel 6=skill
        uint8   tier;           // 0=L0 1=L1 2=L2
        uint16  baseVersion;    // For deltas: index of base version
        uint48  timestamp;      // Block timestamp (year 8.9M-safe)
        string  description;    // Human-readable description
    }

    struct ConsolidationRecord {
        uint16  fromVersion;
        uint16  toVersion;
        uint16  resultVersion;
        uint48  consolidatedAt;
        bytes32 merkleRoot;
    }

    // ============ Storage ============
    IAgentIdentityRegistry public identityRegistry;

    mapping(uint256 => PixeVersion[]) private _versions;
    mapping(uint256 => ConsolidationRecord[]) private _consolidations;
    mapping(uint256 => uint16) public latestConsolidatedVersion;

    // agentId => category => version indices (partitioned retrieval)
    mapping(uint256 => mapping(uint8 => uint256[])) private _byCategory;
    // agentId => tier => version indices
    mapping(uint256 => mapping(uint8 => uint256[])) private _byTier;

    // ============ Events ============
    event PixeVersionAdded(
        uint256 indexed agentId,
        uint256 indexed version,
        bytes32 contentHash,
        uint8 versionType,
        uint8 category,
        uint8 tier,
        string storageURI
    );

    event PixeConsolidated(
        uint256 indexed agentId,
        uint16 fromVersion,
        uint16 toVersion,
        uint16 indexed resultVersion,
        bytes32 merkleRoot
    );

    event IdentityRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // ============ Init ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentMemory";
    }

    function initialize(address _identityRegistry) public initializer {
        if (_identityRegistry == address(0)) revert ZeroAddress();
        __Ownable_init(msg.sender);
        __Pausable_init();
        identityRegistry = IAgentIdentityRegistry(_identityRegistry);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Emergency stop on writes. View functions remain available.
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setIdentityRegistry(address _identityRegistry) external onlyOwner {
        if (_identityRegistry == address(0)) revert ZeroAddress();
        emit IdentityRegistryUpdated(address(identityRegistry), _identityRegistry);
        identityRegistry = IAgentIdentityRegistry(_identityRegistry);
    }

    modifier onlyAgentOwner(uint256 agentId) {
        if (identityRegistry.ownerOf(agentId) != msg.sender) revert NotOwner();
        _;
    }

    // ============ Write API ============
    /**
     * @notice Append a new .pixe version for an agent.
     * @dev Caller must own the agent NFT. URI is generic; client enforces scheme.
     * @param agentId        Agent NFT token ID.
     * @param storageURI     Storage pointer (pixe://, ipfs://, ar://, https://).
     * @param contentHash    SHA-256 of capsule content for tamper detection.
     * @param versionType    0=delta, 1=consolidated, 2=capsule, 3=memory.
     * @param category       0=mixed..6=skill (see CATEGORY_* constants).
     * @param tier           0=L0..2=L2 (see TIER_* constants).
     * @param baseVersion    For deltas: the version index this delta builds on.
     * @param description    Human-readable description (≤256 bytes).
     * @return version       The new version index (length-1 of versions array).
     */
    function addVersion(
        uint256 agentId,
        string calldata storageURI,
        bytes32 contentHash,
        uint8   versionType,
        uint8   category,
        uint8   tier,
        uint16  baseVersion,
        string calldata description
    ) external onlyAgentOwner(agentId) whenNotPaused returns (uint256 version) {
        _validateInputs(storageURI, contentHash, versionType, category, tier, description);
        PixeVersion[] storage arr = _versions[agentId];
        if (arr.length >= MAX_PIXE_VERSIONS) revert MaxReached();
        if (versionType == TYPE_DELTA) {
            if (arr.length == 0) revert InvalidRange();
            if (baseVersion >= arr.length) revert InvalidRange();
        }

        version = arr.length;
        arr.push(PixeVersion({
            storageURI:  storageURI,
            contentHash: contentHash,
            versionType: versionType,
            category:    category,
            tier:        tier,
            baseVersion: baseVersion,
            timestamp:   uint48(block.timestamp),
            description: description
        }));

        _byCategory[agentId][category].push(version);
        _byTier[agentId][tier].push(version);

        emit PixeVersionAdded(agentId, version, contentHash, versionType, category, tier, storageURI);
    }

    /**
     * @notice Append a consolidated baseline that supersedes versions [fromVersion, toVersion].
     * @dev `merkleRoot` should commit to the contentHashes of all included versions
     *      so off-chain consumers can prove inclusion. Caller must own the agent NFT.
     */
    function consolidate(
        uint256 agentId,
        string  calldata storageURI,
        bytes32 contentHash,
        bytes32 merkleRoot,
        uint16  fromVersion,
        uint16  toVersion,
        uint8   category,
        uint8   tier,
        string  calldata description
    ) external onlyAgentOwner(agentId) whenNotPaused returns (uint256 version) {
        _validateInputs(storageURI, contentHash, TYPE_CONSOLIDATED, category, tier, description);
        if (merkleRoot == bytes32(0)) revert EmptyInput();
        PixeVersion[] storage arr = _versions[agentId];
        if (arr.length == 0) revert NotExists();
        if (arr.length >= MAX_PIXE_VERSIONS) revert MaxReached();
        if (toVersion >= arr.length) revert InvalidRange();
        if (fromVersion > toVersion) revert InvalidRange();

        version = arr.length;
        arr.push(PixeVersion({
            storageURI:  storageURI,
            contentHash: contentHash,
            versionType: TYPE_CONSOLIDATED,
            category:    category,
            tier:        tier,
            baseVersion: 0,
            timestamp:   uint48(block.timestamp),
            description: description
        }));

        _byCategory[agentId][category].push(version);
        _byTier[agentId][tier].push(version);

        _consolidations[agentId].push(ConsolidationRecord({
            fromVersion:    fromVersion,
            toVersion:      toVersion,
            resultVersion:  uint16(version),
            consolidatedAt: uint48(block.timestamp),
            merkleRoot:     merkleRoot
        }));

        latestConsolidatedVersion[agentId] = uint16(version);

        emit PixeConsolidated(agentId, fromVersion, toVersion, uint16(version), merkleRoot);
        emit PixeVersionAdded(agentId, version, contentHash, TYPE_CONSOLIDATED, category, tier, storageURI);
    }

    // ============ Read API ============
    function getVersion(uint256 agentId, uint256 version) external view returns (PixeVersion memory) {
        if (version >= _versions[agentId].length) revert NotExists();
        return _versions[agentId][version];
    }

    function getLatest(uint256 agentId) external view returns (uint256 version, PixeVersion memory v) {
        uint256 len = _versions[agentId].length;
        if (len == 0) revert NotExists();
        version = len - 1;
        v = _versions[agentId][version];
    }

    function getLatestConsolidated(uint256 agentId) external view returns (uint256 version, PixeVersion memory v) {
        uint256 len = _consolidations[agentId].length;
        if (len == 0) revert NotExists();
        version = uint256(latestConsolidatedVersion[agentId]);
        v = _versions[agentId][version];
    }

    function versionCount(uint256 agentId) external view returns (uint256) {
        return _versions[agentId].length;
    }

    function consolidationCount(uint256 agentId) external view returns (uint256) {
        return _consolidations[agentId].length;
    }

    function getConsolidation(uint256 agentId, uint256 index) external view returns (ConsolidationRecord memory) {
        if (index >= _consolidations[agentId].length) revert NotExists();
        return _consolidations[agentId][index];
    }

    function versionsByCategory(uint256 agentId, uint8 category) external view returns (uint256[] memory) {
        if (category > MAX_CATEGORY) revert InvalidCategory();
        return _byCategory[agentId][category];
    }

    function versionsByTier(uint256 agentId, uint8 tier) external view returns (uint256[] memory) {
        if (tier > MAX_TIER) revert InvalidTier();
        return _byTier[agentId][tier];
    }

    /**
     * @notice Paginated read of `_byCategory[agentId][category]` — bounded gas
     *         for clients that can't safely copy the full array via `eth_call`.
     */
    function versionsByCategoryRange(
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

    /// @notice Paginated read of `_byTier[agentId][tier]`.
    function versionsByTierRange(
        uint256 agentId,
        uint8   tier,
        uint256 startIndex,
        uint256 count
    ) external view returns (uint256[] memory page) {
        if (tier > MAX_TIER) revert InvalidTier();
        uint256[] storage src = _byTier[agentId][tier];
        uint256 len = src.length;
        if (startIndex >= len) return new uint256[](0);
        uint256 end = startIndex + count;
        if (end > len) end = len;
        page = new uint256[](end - startIndex);
        for (uint256 i = startIndex; i < end; ++i) page[i - startIndex] = src[i];
    }

    /// @notice True if the agent has at least one consolidation on record.
    ///         Use this to disambiguate `latestConsolidatedVersion(agentId) == 0`
    ///         from "version 0 is the latest consolidation".
    function hasConsolidations(uint256 agentId) external view returns (bool) {
        return _consolidations[agentId].length > 0;
    }

    /**
     * @notice Paginated read of version range — for frontends that only need a window.
     */
    function getVersionsRange(
        uint256 agentId,
        uint256 startIndex,
        uint256 count
    ) external view returns (PixeVersion[] memory page) {
        PixeVersion[] storage arr = _versions[agentId];
        uint256 len = arr.length;
        if (startIndex >= len) return new PixeVersion[](0);
        uint256 end = startIndex + count;
        if (end > len) end = len;
        page = new PixeVersion[](end - startIndex);
        for (uint256 i = startIndex; i < end; ++i) {
            page[i - startIndex] = arr[i];
        }
    }

    // ============ Internal ============
    function _validateInputs(
        string calldata storageURI,
        bytes32 contentHash,
        uint8   versionType,
        uint8   category,
        uint8   tier,
        string calldata description
    ) internal pure {
        if (bytes(storageURI).length == 0) revert EmptyInput();
        if (bytes(storageURI).length > MAX_STORAGE_URI_LEN) revert TooLarge();
        if (contentHash == bytes32(0)) revert EmptyInput();
        if (versionType > MAX_TYPE) revert InvalidVersionType();
        if (category > MAX_CATEGORY) revert InvalidCategory();
        if (tier > MAX_TIER) revert InvalidTier();
        if (bytes(description).length > MAX_DESCRIPTION_LEN) revert TooLarge();
    }
}
