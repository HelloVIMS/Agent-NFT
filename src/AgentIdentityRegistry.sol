// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "./AgentRoyaltyVault.sol";

/**
 * @title AgentIdentityRegistry
 * @notice ERC-8004 compliant Identity Registry for Agent AI agents
 * @dev Each Agent is an NFT that can own a Token Bound Account (ERC-6551)
 * @dev UUPS Upgradeable - owner can upgrade implementation
 * @dev V2: On-chain SVG storage
 * @dev V3: Soulbound creator royalties with ERC-2981 support
 * @dev V5: .pixe storage extracted into `AgentPixeMemory` contract (Pixelog-aligned:
 *      typed categories, context tiers, generic storageURI).
 * @dev V6: On-chain Collections for generative minting
 */
import {VimsProvenance} from "./VimsProvenance.sol";

contract AgentIdentityRegistry is 
    Initializable, 
    ERC721Upgradeable, 
    ERC721URIStorageUpgradeable, 
    VimsProvenance, 
    OwnableUpgradeable, 
    UUPSUpgradeable,
    IERC2981
{
    using Strings for uint256;
    
    // Custom errors (saves ~2KB bytecode vs string messages)
    error NotOwner();
    error NotCreator();
    error InvalidAddress();
    error InvalidValue();
    error AlreadySet();
    error NotExists();
    error MaxReached();
    error EmptyInput();
    error TooLarge();
    error Unchanged();
    error CollectionFull();
    error CollectionLocked();
    error NotCollectionCreator();
    
    uint256 private _nextTokenId;
    uint256 private _nextCollectionId;
    
    struct AgentMetadata {
        string name;
        address tbaAddress;
        uint256 createdAt;
        bool active;
    }
    
    // V6: On-chain Collections for generative minting
    struct Collection {
        string name;
        address creator;
        uint256 maxSupply;
        uint256 mintedCount;
        uint256 createdAt;
        string baseURI;           // Shared metadata base for collection
        bool locked;              // Can't add more after lock
    }
    
    mapping(uint256 => AgentMetadata) public agents;
    mapping(address => uint256[]) public ownerAgents;
    
    // V2 Storage: On-chain SVG images
    mapping(uint256 => string) private _svgImages;
    
    // V5: .pixe storage extracted to AgentPixeMemory contract (Pixelog-aligned)
    // V5: Skill storage extracted to AgentSkillsExtension contract
    
    // V6 Storage: On-chain Collections
    mapping(uint256 => Collection) public collections;
    mapping(uint256 => uint256) public agentToCollection;   // agentId => collectionId (0 = no collection)
    mapping(uint256 => uint256[]) private _collectionAgents; // collectionId => agentIds[]
    
    // V3 Storage: Soulbound Creator Royalties
    // Creator address is IMMUTABLE once set - can never be transferred
    mapping(uint256 => address) private _agentCreator;
    mapping(uint256 => uint256) private _creatorRoyaltyBps;  // basis points (100 = 1%)
    
    uint256 public constant DEFAULT_CREATOR_ROYALTY_BPS = 1000;  // 10%
    uint256 public constant MAX_CREATOR_ROYALTY_BPS = 5000;      // 50% cap
    uint256 public constant MIN_CREATOR_ROYALTY_BPS = 0;         // 0% allowed (creator can opt out)
    
    // V2 Storage Limits
    uint256 public constant MAX_SVG_SIZE = 49152;                // 48KB max for on-chain SVG (aligned with AgentCollectionImpl)

    // V7 Storage: Secondary-market royalty splitter (ERC-2981)
    // Adds an additive system fee on top of the creator royalty so that VIMS
    // captures economics on secondary NFT sales. royaltyInfo() returns the
    // per-agent vault address; the vault (lazily deployed via CREATE2) splits
    // incoming ETH/ERC20 between creator and treasury at release time.
    uint256 public secondarySystemFeeBps;                        // current bps (default 50 = 0.5%)
    address public secondaryTreasury;                            // VIMS treasury for secondary royalties
    uint256 public constant DEFAULT_SECONDARY_SYSTEM_FEE_BPS = 50;   // 0.5%
    uint256 public constant MAX_SECONDARY_SYSTEM_FEE_BPS     = 500;  // 5% cap

    // V7 Events
    event SecondaryTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event SecondarySystemFeeUpdated(uint256 oldBps, uint256 newBps);
    event RoyaltyVaultDeployed(uint256 indexed agentId, address indexed vault);
    
    event AgentRegistered(
        uint256 indexed agentId,
        address indexed owner,
        string name,
        string agentURI
    );
    
    event AgentTBASet(
        uint256 indexed agentId,
        address indexed tbaAddress
    );
    
    event AgentDeactivated(uint256 indexed agentId);
    event AgentActivated(uint256 indexed agentId);
    event TBAAddressSet(uint256 indexed agentId, address indexed tbaAddress);
    
    // V2 Events
    event SVGImageSet(uint256 indexed agentId, uint256 svgLength);
    
    // V3 Events: Soulbound Creator Royalties
    event CreatorRoyaltySet(
        uint256 indexed agentId, 
        address indexed creator, 
        uint256 royaltyBps
    );
    event CreatorRoyaltyUpdated(
        uint256 indexed agentId, 
        uint256 oldRoyaltyBps, 
        uint256 newRoyaltyBps
    );
    
    // V5 Events: Skill files moved to AgentSkillsExtension contract
    
    // V6 Events: On-chain Collections
    event CollectionCreated(
        uint256 indexed collectionId, 
        address indexed creator, 
        string name, 
        uint256 maxSupply
    );
    event AgentAddedToCollection(
        uint256 indexed agentId, 
        uint256 indexed collectionId
    );
    event CollectionLockedEvent(uint256 indexed collectionId);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentIdentityRegistry";
    }

    function initialize() public initializer {
        __ERC721_init("Agent", "CLAW");
        __ERC721URIStorage_init();
        __Ownable_init(msg.sender);
    }

    /**
     * @notice V7 reinitializer: enable secondary-market 0.5% royalty splitter.
     * @dev    Call exactly once after upgrading the proxy. Sets the treasury
     *         and seeds `secondarySystemFeeBps` to the default.
     * @param  _treasury Treasury address that will receive the secondary fee.
     */
    function initializeV7(address _treasury) public reinitializer(7) {
        if (_treasury == address(0)) revert InvalidAddress();
        secondaryTreasury    = _treasury;
        secondarySystemFeeBps = DEFAULT_SECONDARY_SYSTEM_FEE_BPS;
        emit SecondaryTreasuryUpdated(address(0), _treasury);
        emit SecondarySystemFeeUpdated(0, DEFAULT_SECONDARY_SYSTEM_FEE_BPS);
    }

    /**
     * @notice V8 reinitializer: rename the ERC-721 collection (name + symbol).
     * @dev    The proxy was initially deployed with the legacy "ClawBot"/"CLAW"
     *         pair before the rebrand. ERC721's name/symbol live in namespaced
     *         storage and are only written inside `__ERC721_init_unchained`,
     *         which is `onlyInitializing`. A `reinitializer(8)` lets us call
     *         it exactly once more to overwrite both fields safely.
     * @param  name_   New collection name (e.g. "Agent")
     * @param  symbol_ New collection symbol (e.g. "AGENT")
     */
    function initializeV8(string memory name_, string memory symbol_)
        public
        reinitializer(8)
        onlyOwner
    {
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyInput();
        __ERC721_init_unchained(name_, symbol_);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    /**
     * @notice Register a new Agent agent with default creator royalty
     * @param name Human-readable name for the agent
     * @param agentURI IPFS URI containing agent metadata (ERC-8004 registration file)
     * @return agentId The token ID of the newly minted agent
     */
    function registerAgent(
        string calldata name,
        string calldata agentURI
    ) external returns (uint256 agentId) {
        return registerAgentWithRoyalty(name, agentURI, DEFAULT_CREATOR_ROYALTY_BPS);
    }
    
    /**
     * @notice Register a new Agent agent with custom creator royalty
     * @param name Human-readable name for the agent
     * @param agentURI IPFS URI containing agent metadata (ERC-8004 registration file)
     * @param royaltyBps Creator royalty in basis points (100 = 1%, max 5000 = 50%)
     * @return agentId The token ID of the newly minted agent
     */
    function registerAgentWithRoyalty(
        string calldata name,
        string calldata agentURI,
        uint256 royaltyBps
    ) public returns (uint256 agentId) {
        // V7: 0 bps is allowed; only the upper bound is enforced.
        if (royaltyBps > MAX_CREATOR_ROYALTY_BPS) revert InvalidValue();
        
        agentId = _nextTokenId++;
        
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);
        
        agents[agentId] = AgentMetadata({
            name: name,
            tbaAddress: address(0),
            createdAt: block.timestamp,
            active: true
        });
        
        // V3: Set soulbound creator royalty - IMMUTABLE creator address
        _agentCreator[agentId] = msg.sender;
        _creatorRoyaltyBps[agentId] = royaltyBps;
        
        emit AgentRegistered(agentId, msg.sender, name, agentURI);
        emit CreatorRoyaltySet(agentId, msg.sender, royaltyBps);
    }
    
    /**
     * @notice Set the Token Bound Account address for an agent
     * @param agentId The agent's token ID
     * @param tbaAddress The deployed TBA address
     */
    function setTBAAddress(uint256 agentId, address tbaAddress) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        if (tbaAddress == address(0)) revert InvalidAddress();
        if (agents[agentId].tbaAddress != address(0)) revert AlreadySet();
        
        agents[agentId].tbaAddress = tbaAddress;
        
        emit TBAAddressSet(agentId, tbaAddress);
    }
    
    /**
     * @notice Deactivate an agent (still owned, but marked inactive)
     * @param agentId The agent's token ID
     */
    function deactivateAgent(uint256 agentId) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        if (!agents[agentId].active) revert InvalidValue();
        
        agents[agentId].active = false;
        
        emit AgentDeactivated(agentId);
    }
    
    /**
     * @notice Reactivate a previously deactivated agent
     * @param agentId The agent's token ID
     */
    function reactivateAgent(uint256 agentId) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        if (agents[agentId].active) revert InvalidValue();
        
        agents[agentId].active = true;
        
        emit AgentActivated(agentId);
    }
    
    /**
     * @notice Alias for reactivateAgent
     */
    function activateAgent(uint256 agentId) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        if (agents[agentId].active) revert InvalidValue();
        
        agents[agentId].active = true;
        
        emit AgentActivated(agentId);
    }
    
    /**
     * @notice Update the agent's metadata URI
     * @param agentId The agent's token ID
     * @param newURI The new metadata URI
     */
    function updateAgentURI(uint256 agentId, string calldata newURI) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        _setTokenURI(agentId, newURI);
    }
    
    /**
     * @notice Get all agent IDs owned by an address
     * @param owner The owner address
     * @return Array of agent token IDs
     */
    function getAgentsByOwner(address owner) external view returns (uint256[] memory) {
        return ownerAgents[owner];
    }
    
    /**
     * @notice Get agent metadata
     * @param agentId The agent's token ID
     */
    function getAgent(uint256 agentId) external view returns (
        string memory name,
        address tbaAddress,
        uint256 createdAt,
        bool active,
        address owner
    ) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        
        AgentMetadata memory agent = agents[agentId];
        return (
            agent.name,
            agent.tbaAddress,
            agent.createdAt,
            agent.active,
            ownerOf(agentId)
        );
    }
    
    /**
     * @notice Get total number of agents minted
     */
    function totalSupply() external view returns (uint256) {
        return _nextTokenId;
    }
    
    // ============ V3: Soulbound Creator Royalties ============
    
    /**
     * @notice Get the soulbound creator and royalty info for an agent
     * @dev Creator address can NEVER be changed after minting
     * @param agentId The agent's token ID
     * @return creator The original creator address (soulbound)
     * @return royaltyBps The creator royalty in basis points
     */
    function getCreatorRoyalty(uint256 agentId) external view returns (
        address creator,
        uint256 royaltyBps
    ) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        return (_agentCreator[agentId], _creatorRoyaltyBps[agentId]);
    }
    
    /**
     * @notice Get just the soulbound creator address
     * @param agentId The agent's token ID
     * @return The original creator address (immutable)
     */
    function agentCreator(uint256 agentId) external view returns (address) {
        return _agentCreator[agentId];
    }
    
    /**
     * @notice Calculate the creator's cut for a given payment amount
     * @param agentId The agent's token ID
     * @param amount The total payment amount
     * @return creatorCut The amount that goes to the creator
     * @return ownerCut The amount that goes to the current owner
     */
    function calculateRoyaltySplit(uint256 agentId, uint256 amount) external view returns (
        uint256 creatorCut,
        uint256 ownerCut
    ) {
        uint256 royaltyBps = _creatorRoyaltyBps[agentId];
        creatorCut = (amount * royaltyBps) / 10000;
        ownerCut = amount - creatorCut;
    }
    
    /**
     * @notice Update the creator royalty percentage
     * @dev Creator can adjust royalty within MIN/MAX bounds (1%-50%)
     * @param agentId The agent's token ID
     * @param newRoyaltyBps The new royalty in basis points
     */
    function updateCreatorRoyalty(uint256 agentId, uint256 newRoyaltyBps) external {
        if (_agentCreator[agentId] != msg.sender) revert NotCreator();
        // V7: 0 bps is allowed; only the upper bound is enforced.
        if (newRoyaltyBps > MAX_CREATOR_ROYALTY_BPS) revert InvalidValue();
        if (newRoyaltyBps == _creatorRoyaltyBps[agentId]) revert Unchanged();
        
        uint256 oldRoyalty = _creatorRoyaltyBps[agentId];
        _creatorRoyaltyBps[agentId] = newRoyaltyBps;
        
        emit CreatorRoyaltyUpdated(agentId, oldRoyalty, newRoyaltyBps);
    }
    
    // ============ V2: On-chain SVG Storage ============
    
    /**
     * @notice Set the on-chain SVG image for an agent
     * @param agentId The agent's token ID
     * @param svg The SVG image data (without data URI prefix)
     */
    function setSVGImage(uint256 agentId, string calldata svg) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        if (bytes(svg).length == 0) revert EmptyInput();
        if (bytes(svg).length > MAX_SVG_SIZE) revert TooLarge();
        
        _svgImages[agentId] = svg;
        
        emit SVGImageSet(agentId, bytes(svg).length);
    }
    
    /**
     * @notice Get the on-chain SVG image for an agent
     * @param agentId The agent's token ID
     * @return The SVG image data
     */
    function getSVGImage(uint256 agentId) external view returns (string memory) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        return _svgImages[agentId];
    }
    
    /**
     * @notice Check if an agent has an on-chain SVG image
     * @param agentId The agent's token ID
     */
    function hasSVGImage(uint256 agentId) external view returns (bool) {
        return bytes(_svgImages[agentId]).length > 0;
    }
    
    // ============ V6: On-chain Collections ============
    
    /**
     * @notice Create a new collection for batch/generative minting
     * @param name Collection name
     * @param maxSupply Maximum number of agents in collection (0 = unlimited)
     * @param baseURI Shared metadata base URI for collection
     * @return collectionId The ID of the newly created collection
     */
    function createCollection(
        string calldata name,
        uint256 maxSupply,
        string calldata baseURI
    ) external returns (uint256 collectionId) {
        if (bytes(name).length == 0) revert EmptyInput();
        
        collectionId = ++_nextCollectionId;
        
        collections[collectionId] = Collection({
            name: name,
            creator: msg.sender,
            maxSupply: maxSupply,
            mintedCount: 0,
            createdAt: block.timestamp,
            baseURI: baseURI,
            locked: false
        });
        
        emit CollectionCreated(collectionId, msg.sender, name, maxSupply);
    }
    
    /**
     * @notice Mint a new agent directly into a collection
     * @param collectionId The collection to mint into
     * @param name Agent name
     * @param agentURI Agent metadata URI
     * @return agentId The token ID of the newly minted agent
     */
    function mintToCollection(
        uint256 collectionId,
        string calldata name,
        string calldata agentURI
    ) external returns (uint256 agentId) {
        return mintToCollectionWithRoyalty(collectionId, name, agentURI, DEFAULT_CREATOR_ROYALTY_BPS);
    }
    
    /**
     * @notice Mint a new agent into a collection with custom royalty
     * @param collectionId The collection to mint into
     * @param name Agent name
     * @param agentURI Agent metadata URI
     * @param royaltyBps Creator royalty in basis points
     * @return agentId The token ID of the newly minted agent
     */
    function mintToCollectionWithRoyalty(
        uint256 collectionId,
        string calldata name,
        string calldata agentURI,
        uint256 royaltyBps
    ) public returns (uint256 agentId) {
        Collection storage col = collections[collectionId];
        if (col.creator == address(0)) revert NotExists();
        if (col.creator != msg.sender) revert NotCollectionCreator();
        if (col.locked) revert CollectionLocked();
        if (col.maxSupply > 0 && col.mintedCount >= col.maxSupply) revert CollectionFull();
        
        // Mint the agent using existing logic
        agentId = registerAgentWithRoyalty(name, agentURI, royaltyBps);
        
        // Link agent to collection
        agentToCollection[agentId] = collectionId;
        _collectionAgents[collectionId].push(agentId);
        col.mintedCount++;
        
        emit AgentAddedToCollection(agentId, collectionId);
    }
    
    /**
     * @notice Lock a collection to prevent further minting
     * @param collectionId The collection to lock
     */
    function lockCollection(uint256 collectionId) external {
        Collection storage col = collections[collectionId];
        if (col.creator == address(0)) revert NotExists();
        if (col.creator != msg.sender) revert NotCollectionCreator();
        if (col.locked) revert CollectionLocked();
        
        col.locked = true;
        emit CollectionLockedEvent(collectionId);
    }
    
    /**
     * @notice Get all agent IDs in a collection
     * @param collectionId The collection ID
     * @return Array of agent token IDs
     */
    function getCollectionAgents(uint256 collectionId) external view returns (uint256[] memory) {
        return _collectionAgents[collectionId];
    }
    
    /**
     * @notice Get the total number of collections created
     */
    function totalCollections() external view returns (uint256) {
        return _nextCollectionId;
    }
    
    // ============ V5: Skill Files (.md) moved to AgentSkillsExtension ============
    // See AgentSkillsExtension.sol for skill management functions
    
    // ============ Enhanced tokenURI with on-chain SVG ============
    
    /**
     * @notice Returns the token URI with embedded on-chain SVG if available
     * @param tokenId The token ID
     */
    function tokenURI(uint256 tokenId) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable) returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert NotExists();
        
        // If no on-chain SVG, fall back to stored URI
        if (bytes(_svgImages[tokenId]).length == 0) {
            return super.tokenURI(tokenId);
        }
        
        // Build on-chain metadata with embedded SVG
        return _buildTokenURI(tokenId);
    }
    
    /**
     * @dev Internal helper to build token URI (reduces stack depth)
     */
    function _buildTokenURI(uint256 tokenId) internal view returns (string memory) {
        string memory svgBase64 = Base64.encode(bytes(_svgImages[tokenId]));
        
        // Build JSON in parts to avoid stack too deep
        bytes memory jsonPart1 = abi.encodePacked(
            '{"name":"', agents[tokenId].name, '",',
            '"description":"Agent AI Agent #', tokenId.toString(), '",',
            '"image":"data:image/svg+xml;base64,', svgBase64, '",'
        );
        
        bytes memory jsonPart2 = abi.encodePacked(
            '"attributes":[',
            '{"trait_type":"Active","value":"', agents[tokenId].active ? "true" : "false", '"},',
            '{"trait_type":"Has TBA","value":"', agents[tokenId].tbaAddress != address(0) ? "true" : "false", '"}',
            ']}'
        );
        
        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(abi.encodePacked(jsonPart1, jsonPart2))
        ));
    }
    
    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable, IERC165) returns (bool) {
        return 
            interfaceId == type(IERC2981).interfaceId ||
            super.supportsInterface(interfaceId);
    }
    
    // ============ ERC-2981 Royalty Standard ============
    
    /**
     * @notice ERC-2981 royalty info for marketplaces
     * @dev Returns the soulbound creator as the royalty receiver
     * @param tokenId The token ID
     * @param salePrice The sale price
     * @return receiver The royalty recipient (soulbound creator)
     * @return royaltyAmount The royalty amount
     */
    function royaltyInfo(uint256 tokenId, uint256 salePrice) 
        external 
        view 
        override 
        returns (address receiver, uint256 royaltyAmount) 
    {
        // V7: receiver is the per-agent royalty vault (CREATE2 deterministic).
        // The vault accepts the combined royalty and splits it on-chain into
        // creator share (creatorBps) + VIMS share (secondarySystemFeeBps).
        receiver = _royaltyVaultAddress(tokenId);
        uint256 totalBps = _creatorRoyaltyBps[tokenId] + secondarySystemFeeBps;
        royaltyAmount    = (salePrice * totalBps) / 10000;
    }

    // ============ V7: Secondary-Market Royalty Splitter ============

    /**
     * @notice Deterministic address of an agent's royalty vault.
     * @dev    Computed via CREATE2; safe to use as the ERC-2981 receiver
     *         even before the vault is deployed (ETH sent to an undeployed
     *         CREATE2 address is preserved and claimable on first deploy).
     * @param  agentId The agent's token ID.
     * @return The vault address (deployed or not).
     */
    function royaltyVaultAddress(uint256 agentId) external view returns (address) {
        return _royaltyVaultAddress(agentId);
    }

    function _royaltyVaultAddress(uint256 agentId) internal view returns (address) {
        bytes32 salt = bytes32(agentId);
        bytes memory bytecode = abi.encodePacked(
            type(AgentRoyaltyVault).creationCode,
            abi.encode(address(this), agentId)
        );
        return Create2.computeAddress(salt, keccak256(bytecode));
    }

    /**
     * @notice Deploy the per-agent royalty vault if not already deployed.
     * @dev    Permissionless. Idempotent: returns the existing vault if any
     *         code already lives at the deterministic address.
     * @param  agentId The agent's token ID. Must exist.
     * @return vault The vault address.
     */
    function deployRoyaltyVault(uint256 agentId) external returns (address vault) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        vault = _royaltyVaultAddress(agentId);
        if (vault.code.length > 0) return vault;
        bytes32 salt = bytes32(agentId);
        AgentRoyaltyVault deployed = new AgentRoyaltyVault{salt: salt}(address(this), agentId);
        vault = address(deployed);
        emit RoyaltyVaultDeployed(agentId, vault);
    }

    /**
     * @notice Owner: update the treasury that receives secondary-market system fees.
     */
    function setSecondaryTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidAddress();
        emit SecondaryTreasuryUpdated(secondaryTreasury, newTreasury);
        secondaryTreasury = newTreasury;
    }

    /**
     * @notice Owner: update the secondary-market system fee bps. Max 500 (5%).
     */
    function setSecondarySystemFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_SECONDARY_SYSTEM_FEE_BPS) revert InvalidValue();
        emit SecondarySystemFeeUpdated(secondarySystemFeeBps, newBps);
        secondarySystemFeeBps = newBps;
    }
    
    // Override transfer to update ownerAgents mapping
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        
        if (from != address(0)) {
            // Remove from previous owner's list
            uint256[] storage fromAgents = ownerAgents[from];
            for (uint256 i = 0; i < fromAgents.length; i++) {
                if (fromAgents[i] == tokenId) {
                    fromAgents[i] = fromAgents[fromAgents.length - 1];
                    fromAgents.pop();
                    break;
                }
            }
        }
        
        if (to != address(0)) {
            ownerAgents[to].push(tokenId);
        }
        
        return from;
    }
}
