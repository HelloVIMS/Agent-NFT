// SPDX-License-Identifier: AGPL-3.0-or-later
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

import {AgentIdentityFullStackLib} from "./AgentIdentityFullStackLib.sol";
import {AgentIdentityURILib} from "./AgentIdentityURILib.sol";

/**
 * @title AgentIdentityRegistry
 * @notice ERC-8004 compliant Identity Registry for Agent AI agents
 * @dev Each Agent is an NFT that can own a Token Bound Account (ERC-6551)
 * @dev UUPS Upgradeable - owner can upgrade implementation
 * @dev On-chain SVG storage.
 * @dev Soulbound creator royalties with ERC-2981 support.
 * @dev .pixe storage is extracted into `AgentPixeMemory` (Pixelog-aligned:
 *      typed categories, context tiers, generic storageURI).
 * @dev On-chain Collections for generative minting.
 * @dev 1:Many subaccount registry (Option A). Multiple authorised accounts
 *      (typically salted ERC-6551 sub-TBAs) can act on behalf of a single
 *      agentId, each with a granular permission bitmap. Reverse lookup
 *      (`agentIdOf`) lets downstream registries (payments, reputation,
 *      context) enforce 1:many semantics on-chain.
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
    // Subaccount errors
    error AlreadyBound();
    error NotBound();
    error MaxSubaccounts();
    error PermissionDenied();
    
    uint256 private _nextTokenId;
    uint256 private _nextCollectionId;

    struct AgentMetadata {
        string name;
        address tbaAddress;
        uint256 createdAt;
        bool active;
        address reputationAnchor; // V7: immutable reputation anchor (address(0) = transferable)
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

    // O(1) removal index for `ownerAgents`. Stores `index + 1` so the zero
    // value naturally encodes "not present". Without this, `_update` would be
    // O(n) over the owner's full holdings on every transfer — a whale-DoS
    // vector. With the index, removal is swap-and-pop in O(1).
    mapping(uint256 => uint256) private _ownerAgentsIndexPlusOne;

    // Anchor reverse index: agents grouped by reputation anchor (V7).
    // Lets indexers/UI surface "this anchor controls N agents" so buyers can
    // see the shared-pool semantics of anchored agents at a glance.
    mapping(address => uint256[]) private _anchorAgents;
    
    // On-chain SVG images.
    mapping(uint256 => string) private _svgImages;
    
    // .pixe storage extracted to AgentPixeMemory contract (Pixelog-aligned).
    // Skill storage extracted to AgentSkillsExtension contract.

    // On-chain Collections.
    mapping(uint256 => Collection) public collections;
    mapping(uint256 => uint256) public agentToCollection;   // agentId => collectionId (0 = no collection)
    mapping(uint256 => uint256[]) private _collectionAgents; // collectionId => agentIds[]
    
    // Soulbound creator royalties.
    // Creator address is IMMUTABLE once set - can never be transferred
    mapping(uint256 => address) private _agentCreator;
    mapping(uint256 => uint256) private _creatorRoyaltyBps;  // basis points (100 = 1%)
    
    uint256 public constant DEFAULT_CREATOR_ROYALTY_BPS = 1000;  // 10%
    uint256 public constant MAX_CREATOR_ROYALTY_BPS = 5000;      // 50% cap
    uint256 public constant MIN_CREATOR_ROYALTY_BPS = 0;         // 0% allowed (creator can opt out)
    
    // On-chain SVG storage limit.
    uint256 public constant MAX_SVG_SIZE = 49152;                // 48KB max for on-chain SVG (aligned with AgentCollectionImpl)

    // Secondary-market royalty splitter (ERC-2981).
    // Adds an additive system fee on top of the creator royalty so that VIMS
    // captures economics on secondary NFT sales. royaltyInfo() returns the
    // per-agent vault address; the vault (lazily deployed via CREATE2) splits
    // incoming ETH/ERC20 between creator and treasury at release time.
    uint256 public secondarySystemFeeBps;                        // current bps (default 100 = 1%)
    address public secondaryTreasury;                            // VIMS treasury for secondary royalties
    uint256 public constant DEFAULT_SECONDARY_SYSTEM_FEE_BPS = 100;  // 1%
    uint256 public constant MAX_SECONDARY_SYSTEM_FEE_BPS     = 500;  // 5% cap

    // ============ Storage: 1:Many Subaccounts ============
    //
    // A subaccount is any address (typically a salted ERC-6551 TBA, but the
    // registry is address-agnostic) authorised to act on behalf of a given
    // agentId. The primary TBA (set via `setTBAAddress`) is implicitly bound
    // with `PERM_ALL` and exposed under `agentIdOf` once `bindPrimaryTBA` has
    // been called (idempotent, permissionless).
    //
    // Permission bits are an open-ended bitmap so downstream contracts can
    // gate writes without requiring a registry upgrade.
    uint96 public constant PERM_PAY           = 1 << 0;  // route inbound payments to this agentId
    uint96 public constant PERM_REPUTATION    = 1 << 1;  // record reputation entries
    uint96 public constant PERM_CONTEXT_WRITE = 1 << 2;  // write to AgentContextRegistry
    uint96 public constant PERM_MEMORY_WRITE  = 1 << 3;  // write to AgentMemory / .pixe
    uint96 public constant PERM_TREASURY      = 1 << 4;  // operate royalty vault
    uint96 public constant PERM_LINK          = 1 << 5;  // manage linked external accounts
    uint96 public constant PERM_ALL           = type(uint96).max;

    uint256 public constant MAX_SUBACCOUNTS_PER_AGENT = 64;

    struct Subaccount {
        address account;       // authorised address
        bytes32 salt;          // CREATE2 salt used to derive the sub-TBA (informational)
        uint96  permissions;   // bitmap of PERM_* flags
        uint48  createdAt;
        bool    active;
    }

    mapping(uint256 => Subaccount[]) private _subaccounts;
    // account => agentId+1 (0 == not bound). Covers both primary TBA and subs.
    mapping(address => uint256) private _accountAgentIdPlusOne;
    // account => index+1 in _subaccounts[agentId]. 0 == primary TBA (or unbound).
    mapping(address => uint256) private _accountSubIndexPlusOne;

    // Subaccount events
    event SubaccountRegistered(
        uint256 indexed agentId,
        address indexed account,
        bytes32 salt,
        uint96  permissions
    );
    event SubaccountPermissionsUpdated(
        uint256 indexed agentId,
        address indexed account,
        uint96  oldPermissions,
        uint96  newPermissions
    );
    event SubaccountRevoked(uint256 indexed agentId, address indexed account);
    event PrimaryTBABound(uint256 indexed agentId, address indexed account);

    // Secondary-market events
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

    // V7 Events: Reputation anchor
    event ReputationAnchorSet(
        uint256 indexed agentId,
        address indexed anchor
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

    /**
     * @notice Single canonical initializer for v1.
     *         Seeds:
     *           - ERC-721 name/symbol ("Agent"/"AGENT")
     *           - URI storage extension
     *           - Owner = `msg.sender`
     *           - Secondary treasury = `msg.sender` (owner can later reassign
     *             via `setSecondaryTreasury`)
     *           - Secondary system fee = `DEFAULT_SECONDARY_SYSTEM_FEE_BPS`
     *
     * @dev   v1 — single-call initializer, no reinitializer chain. The
     *        contract is fresh-deployed (as a UUPS proxy) on every chain;
     *        future migrations should use `reinitializer(N)` with a
     *        sequentially incremented N.
     */
    function initialize() public initializer {
        __ERC721_init("Agent", "AGENT");
        __ERC721URIStorage_init();
        __Ownable_init(msg.sender);

        secondaryTreasury     = msg.sender;
        secondarySystemFeeBps = DEFAULT_SECONDARY_SYSTEM_FEE_BPS;
        emit SecondaryTreasuryUpdated(address(0), msg.sender);
        emit SecondarySystemFeeUpdated(0, DEFAULT_SECONDARY_SYSTEM_FEE_BPS);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    /**
     * @notice Register a new Agent agent.
     * @param name Human-readable name for the agent
     * @param agentURI IPFS URI containing agent metadata (ERC-8004 registration file)
     * @param royaltyBps Creator royalty in basis points (100 = 1%, max 5000 = 50%).
     *        0 bps is allowed; only the upper bound is enforced.
     * @param reputationAnchor If non-zero, reputation is permanently keyed to this
     *        address and does NOT transfer with the NFT. If address(0), reputation
     *        follows the agentId (transferable).
     *
     * @dev SECURITY: `reputationAnchor` MUST be `msg.sender` or `address(0)` —
     *      enforced to prevent reputation poisoning via foreign anchors. A
     *      malicious minter cannot seed reviews against an anchor they don't
     *      control. The anchor commitment is therefore self-attested at mint.
     * @return agentId The token ID of the newly minted agent
     */
    function registerAgent(
        string calldata name,
        string calldata agentURI,
        uint256 royaltyBps,
        address reputationAnchor
    ) public returns (uint256 agentId) {
        if (royaltyBps > MAX_CREATOR_ROYALTY_BPS) revert InvalidValue();
        if (reputationAnchor != address(0) && reputationAnchor != msg.sender) {
            revert InvalidValue();
        }

        agentId = _nextTokenId++;

        // Checks-Effects-Interactions: write all state BEFORE _safeMint so
        // the ERC721Received callback (interactions) cannot observe a half-
        // initialised agent (missing creator, anchor, URI, etc.).
        agents[agentId] = AgentMetadata({
            name: name,
            tbaAddress: address(0),
            createdAt: block.timestamp,
            active: true,
            reputationAnchor: reputationAnchor
        });
        _agentCreator[agentId] = msg.sender;
        _creatorRoyaltyBps[agentId] = royaltyBps;
        if (reputationAnchor != address(0)) {
            _anchorAgents[reputationAnchor].push(agentId);
        }

        emit AgentRegistered(agentId, msg.sender, name, agentURI);
        emit CreatorRoyaltySet(agentId, msg.sender, royaltyBps);
        if (reputationAnchor != address(0)) {
            emit ReputationAnchorSet(agentId, reputationAnchor);
        }

        // ERC721Received callback fires here; state is fully initialised.
        _setTokenURI(agentId, agentURI);
        _safeMint(msg.sender, agentId);
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

        // Enforce that the TBA address is not already bound to another
        // agent before we accept it as the primary surface. We then claim it
        // as the primary (sub index = 0, full permissions implicit).
        uint256 plus = _accountAgentIdPlusOne[tbaAddress];
        if (plus != 0 && plus != agentId + 1) revert AlreadyBound();

        agents[agentId].tbaAddress = tbaAddress;
        if (plus == 0) {
            _accountAgentIdPlusOne[tbaAddress] = agentId + 1;
            emit PrimaryTBABound(agentId, tbaAddress);
        }

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
        address owner,
        address reputationAnchor
    ) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();

        AgentMetadata memory agent = agents[agentId];
        return (
            agent.name,
            agent.tbaAddress,
            agent.createdAt,
            agent.active,
            ownerOf(agentId),
            agent.reputationAnchor
        );
    }

    /**
     * @notice Get the immutable reputation anchor for an agent.
     * @dev If address(0), reputation is transferable (follows agentId).
     *      If non-zero, reputation is permanently keyed to that address.
     * @param agentId The agent's token ID
     * @return The reputation anchor address
     */
    function reputationAnchorOf(uint256 agentId) external view returns (address) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        return agents[agentId].reputationAnchor;
    }

    /**
     * @notice Enumerate all agentIds that share the same reputation anchor.
     * @dev    Anchored agents pool reputation by anchor address (per the
     *         V7 design). Off-chain indexers and marketplace UIs use this to
     *         surface "this anchor controls N agents" so buyers understand
     *         that buying an anchored agent does NOT grant them control of
     *         the reputation. Returns an empty array for unused anchors.
     */
    function agentsByAnchor(address anchor) external view returns (uint256[] memory) {
        return _anchorAgents[anchor];
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
     * @notice Update the creator royalty percentage
     * @dev Creator can adjust royalty within MIN/MAX bounds (1%-50%)
     * @param agentId The agent's token ID
     * @param newRoyaltyBps The new royalty in basis points
     */
    function updateCreatorRoyalty(uint256 agentId, uint256 newRoyaltyBps) external {
        if (_agentCreator[agentId] != msg.sender) revert NotCreator();
        // 0 bps is allowed; only the upper bound is enforced.
        if (newRoyaltyBps > MAX_CREATOR_ROYALTY_BPS) revert InvalidValue();
        if (newRoyaltyBps == _creatorRoyaltyBps[agentId]) revert Unchanged();
        
        uint256 oldRoyalty = _creatorRoyaltyBps[agentId];
        _creatorRoyaltyBps[agentId] = newRoyaltyBps;
        
        emit CreatorRoyaltyUpdated(agentId, oldRoyalty, newRoyaltyBps);
    }
    
    // ============ On-chain SVG Storage ============
    
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
     * @notice Mint a new agent directly into a collection.
     * @param collectionId The collection to mint into
     * @param name Agent name
     * @param agentURI Agent metadata URI
     * @param royaltyBps Creator royalty in basis points
     * @param reputationAnchor Optional immutable reputation anchor (address(0) = transferable)
     * @return agentId The token ID of the newly minted agent
     */
    function mintToCollection(
        uint256 collectionId,
        string calldata name,
        string calldata agentURI,
        uint256 royaltyBps,
        address reputationAnchor
    ) external returns (uint256 agentId) {
        Collection storage col = collections[collectionId];
        if (col.creator == address(0)) revert NotExists();
        if (col.creator != msg.sender) revert NotCollectionCreator();
        if (col.locked) revert CollectionLocked();
        if (col.maxSupply > 0 && col.mintedCount >= col.maxSupply) revert CollectionFull();

        agentId = registerAgent(name, agentURI, royaltyBps, reputationAnchor);

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
     * @dev Internal helper to build token URI. Delegates to the external
     *      library {AgentIdentityURILib} so the ~1 KB Base64 + JSON
     *      concatenation lives outside the impl bytecode (EIP-170 ceiling).
     *      Output is byte-identical to the prior in-impl version.
     */
    function _buildTokenURI(uint256 tokenId) internal view returns (string memory) {
        return AgentIdentityURILib.buildOnChainTokenURI(
            tokenId,
            agents[tokenId].name,
            _svgImages[tokenId],
            agents[tokenId].active,
            agents[tokenId].tbaAddress != address(0)
        );
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
        // Receiver is the per-agent royalty vault (CREATE2 deterministic).
        // The vault accepts the combined royalty and splits it on-chain into
        // creator share (creatorBps) + VIMS share (secondarySystemFeeBps).
        receiver = _royaltyVaultAddress(tokenId);
        uint256 totalBps = _creatorRoyaltyBps[tokenId] + secondarySystemFeeBps;
        royaltyAmount    = (salePrice * totalBps) / 10000;
    }

    // ============ Secondary-Market Royalty Splitter ============

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
    
    // ============ 1:Many Subaccount API ============

    /**
     * @notice Bind the primary-TBA reverse lookup for an agent. Idempotent
     *         and permissionless. Useful when `setTBAAddress` was called on
     *         a prior implementation that did not yet seed the reverse map.
     */
    function bindPrimaryTBA(uint256 agentId) external {
        address tba = agents[agentId].tbaAddress;
        if (tba == address(0)) revert NotBound();
        uint256 plus = _accountAgentIdPlusOne[tba];
        if (plus == agentId + 1) return; // already bound
        if (plus != 0) revert AlreadyBound();
        _accountAgentIdPlusOne[tba] = agentId + 1;
        emit PrimaryTBABound(agentId, tba);
    }

    /**
     * @notice Register a subaccount authorised to act on behalf of `agentId`.
     * @dev    Caller must own the agent NFT. The subaccount address must not
     *         already be bound to any agent. Typically `account` is a salted
     *         ERC-6551 TBA derived from the agent NFT, but the registry is
     *         deliberately address-agnostic so non-6551 addresses (e.g. a
     *         multisig owned by the agent owner) can also be authorised.
     */
    function registerSubaccount(
        uint256 agentId,
        address account,
        bytes32 salt,
        uint96  permissions
    ) external returns (uint256 index) {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        if (account == address(0)) revert InvalidAddress();
        if (_accountAgentIdPlusOne[account] != 0) revert AlreadyBound();
        if (_subaccounts[agentId].length >= MAX_SUBACCOUNTS_PER_AGENT) revert MaxSubaccounts();

        index = _subaccounts[agentId].length;
        _subaccounts[agentId].push(Subaccount({
            account:     account,
            salt:        salt,
            permissions: permissions,
            createdAt:   uint48(block.timestamp),
            active:      true
        }));
        _accountAgentIdPlusOne[account] = agentId + 1;
        _accountSubIndexPlusOne[account] = index + 1;

        emit SubaccountRegistered(agentId, account, salt, permissions);
    }

    /**
     * @notice Update the permission bitmap for an existing subaccount.
     */
    function updateSubaccountPermissions(
        uint256 agentId,
        address account,
        uint96  newPermissions
    ) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        uint256 idxPlus = _accountSubIndexPlusOne[account];
        if (idxPlus == 0 || _accountAgentIdPlusOne[account] != agentId + 1) revert NotBound();

        Subaccount storage s = _subaccounts[agentId][idxPlus - 1];
        if (!s.active) revert NotBound();
        uint96 old = s.permissions;
        if (old == newPermissions) revert Unchanged();
        s.permissions = newPermissions;
        emit SubaccountPermissionsUpdated(agentId, account, old, newPermissions);
    }

    /**
     * @notice Revoke a subaccount. The address becomes unbound and may be
     *         re-registered later (to the same or a different agent).
     */
    function revokeSubaccount(uint256 agentId, address account) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        uint256 idxPlus = _accountSubIndexPlusOne[account];
        if (idxPlus == 0 || _accountAgentIdPlusOne[account] != agentId + 1) revert NotBound();

        Subaccount storage s = _subaccounts[agentId][idxPlus - 1];
        s.active = false;
        s.permissions = 0;
        delete _accountAgentIdPlusOne[account];
        delete _accountSubIndexPlusOne[account];
        emit SubaccountRevoked(agentId, account);
    }

    // ----- views -----

    /**
     * @notice Resolve any authorised address to its owning agent.
     * @return agentId      The agent token id (0 if unbound; check `bound`).
     * @return bound        True if `account` is currently bound to an agent.
     * @return isPrimary    True if this is the primary TBA (full permissions).
     * @return permissions  PERM_ALL for primary TBA, otherwise the subaccount bitmap.
     * @return active       True if both the agent and the binding are active.
     */
    function agentIdOf(address account) external view returns (
        uint256 agentId,
        bool    bound,
        bool    isPrimary,
        uint96  permissions,
        bool    active
    ) {
        uint256 plus = _accountAgentIdPlusOne[account];
        if (plus == 0) return (0, false, false, 0, false);
        agentId = plus - 1;
        bound   = true;
        uint256 subPlus = _accountSubIndexPlusOne[account];
        if (subPlus == 0) {
            return (agentId, true, true, PERM_ALL, agents[agentId].active);
        }
        Subaccount memory s = _subaccounts[agentId][subPlus - 1];
        return (agentId, true, false, s.permissions, s.active && agents[agentId].active);
    }

    /**
     * @notice On-chain permission check used by downstream registries.
     * @dev    Returns true iff `account` is currently bound to *some* agent
     *         and holds *all* bits in `perm`. Primary TBA always passes.
     */
    function hasPermission(address account, uint96 perm) external view returns (bool) {
        uint256 plus = _accountAgentIdPlusOne[account];
        if (plus == 0) return false;
        uint256 agentId = plus - 1;
        if (!agents[agentId].active) return false;
        uint256 subPlus = _accountSubIndexPlusOne[account];
        if (subPlus == 0) return true; // primary TBA
        Subaccount memory s = _subaccounts[agentId][subPlus - 1];
        if (!s.active) return false;
        return (s.permissions & perm) == perm;
    }

    /**
     * @notice Strict variant of `hasPermission` that reverts. Useful as a
     *         single-call guard inside payable / write paths.
     */
    function requirePermission(address account, uint96 perm, uint256 expectedAgentId) external view {
        uint256 plus = _accountAgentIdPlusOne[account];
        if (plus == 0 || plus - 1 != expectedAgentId) revert NotBound();
        if (!agents[expectedAgentId].active) revert PermissionDenied();
        uint256 subPlus = _accountSubIndexPlusOne[account];
        if (subPlus == 0) return;
        Subaccount memory s = _subaccounts[expectedAgentId][subPlus - 1];
        if (!s.active) revert PermissionDenied();
        if ((s.permissions & perm) != perm) revert PermissionDenied();
    }

    function getSubaccounts(uint256 agentId) external view returns (Subaccount[] memory) {
        return _subaccounts[agentId];
    }

    function subaccountCount(uint256 agentId) external view returns (uint256) {
        return _subaccounts[agentId].length;
    }

    // Override transfer to maintain ownerAgents in O(1).
    // Uses a swap-and-pop pattern indexed by `_ownerAgentsIndexPlusOne` so
    // gas is constant regardless of holdings — eliminates the whale-DoS
    // vector on transfer.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);

        if (from != address(0)) {
            uint256[] storage fromAgents = ownerAgents[from];
            uint256 idxPlus = _ownerAgentsIndexPlusOne[tokenId];
            // Defensive: idxPlus should always be non-zero for an existing
            // owner's token, but fall back to no-op rather than reverting
            // a transfer if storage was ever migrated without the index.
            if (idxPlus != 0) {
                uint256 idx  = idxPlus - 1;
                uint256 last = fromAgents.length - 1;
                if (idx != last) {
                    uint256 lastTokenId = fromAgents[last];
                    fromAgents[idx] = lastTokenId;
                    _ownerAgentsIndexPlusOne[lastTokenId] = idx + 1;
                }
                fromAgents.pop();
                delete _ownerAgentsIndexPlusOne[tokenId];
            }
        }

        if (to != address(0)) {
            ownerAgents[to].push(tokenId);
            _ownerAgentsIndexPlusOne[tokenId] = ownerAgents[to].length; // index+1
        }

        return from;
    }

    // ============ Full-stack mint wiring (appended after audit) ============

    /// @notice Owner-only setter for the trusted TBA registry. Pass address(0)
    ///         to disable the atomic TBA leg of `mintWithFullStack`.
    function setTrustedTBARegistry(address newRegistry) external onlyOwner {
        address old = trustedTBARegistry;
        trustedTBARegistry = newRegistry;
        emit TrustedTBARegistryUpdated(old, newRegistry);
    }

    /// @notice Owner-only setter for the linked x402 receiver. Pass address(0)
    ///         to disable the atomic service-registration leg of
    ///         `mintWithFullStack`.
    function setLinkedX402Receiver(address newReceiver) external onlyOwner {
        address old = linkedX402Receiver;
        linkedX402Receiver = newReceiver;
        emit LinkedX402ReceiverUpdated(old, newReceiver);
    }

    /// @notice Internal helper that binds a TBA to an agent without the
    ///         per-caller ownership check used by the public `setTBAAddress`.
    ///         Used exclusively by `mintWithFullStack` where the registry is
    ///         itself the orchestrator and the binding precedes any external
    ///         hand-off of the NFT.
    function _bindTBAUnchecked(uint256 agentId, address tbaAddress) internal {
        if (tbaAddress == address(0)) revert InvalidAddress();
        if (agents[agentId].tbaAddress != address(0)) revert AlreadySet();

        uint256 plus = _accountAgentIdPlusOne[tbaAddress];
        if (plus != 0 && plus != agentId + 1) revert AlreadyBound();

        agents[agentId].tbaAddress = tbaAddress;
        if (plus == 0) {
            _accountAgentIdPlusOne[tbaAddress] = agentId + 1;
            emit PrimaryTBABound(agentId, tbaAddress);
        }
        emit TBAAddressSet(agentId, tbaAddress);
    }

    /**
     * @notice Atomic full-stack mint: registers the agent NFT, deploys + binds
     *         its token-bound account, and optionally registers an x402
     *         service — all in a single transaction.
     *
     *         Each leg is independent: pass address(0) for `collection` to
     *         mint standalone (currently the only mode), pass bytes32(0)
     *         for `serviceId` (or 0 for `price` / address(0) for `token`)
     *         to skip the service-registration leg.
     *
     * @dev    Service registration is performed via the trusted-registrar
     *         path on the linked receiver, which authorises this registry
     *         as msg.sender. The receiver MUST set `trustedAgentRegistry`
     *         to this contract or the leg will revert.
     *
     * @param  name        Agent display name.
     * @param  agentURI    Metadata URI (IPFS/Arweave/HTTPS).
     * @param  royaltyBps  Creator royalty in bps (0–`MAX_CREATOR_ROYALTY_BPS`).
     * @param  collection  Reserved for future collection-bound mints; pass
     *                     address(0) for a standalone mint.
     * @param  tbaSalt     Salt forwarded to the TBA registry's `createAccount`.
     * @param  serviceId   bytes32 service identifier; pass bytes32(0) to skip.
     * @param  token       ERC-20 token used to charge for the service.
     * @param  price       Service price in `token` base units.
     * @return agentId     Newly minted token id.
     * @return tba         Deployed token-bound account address.
     */
    function mintWithFullStack(
        string calldata name,
        string calldata agentURI,
        uint256 royaltyBps,
        address collection,
        bytes32 tbaSalt,
        bytes32 serviceId,
        address token,
        uint256 price
    ) external returns (uint256 agentId, address tba) {
        if (collection != address(0)) revert InvalidValue();

        // Leg 1 — register the agent under the caller (transferable anchor).
        agentId = registerAgent(name, agentURI, royaltyBps, address(0));

        // Leg 2 — TBA via library (delegatecall). Library returns address(0)
        // when no trusted registry is wired.
        tba = AgentIdentityFullStackLib.tbaLeg(trustedTBARegistry, agentId, tbaSalt);
        if (tba != address(0) && agents[agentId].tbaAddress == address(0)) {
            _bindTBAUnchecked(agentId, tba);
        }

        // Leg 3 — x402 service via library. Skipped silently when inputs zero.
        AgentIdentityFullStackLib.serviceLeg(
            linkedX402Receiver, agentId, msg.sender, serviceId, token, price
        );
    }

    // ============ Full-stack mint storage (appended after audit) ============

    /// @notice Trusted ERC-6551 TBA registry used by `mintWithFullStack`.
    address public trustedTBARegistry;

    /// @notice Linked x402 settlement receiver used by `mintWithFullStack`.
    address public linkedX402Receiver;

    /// @notice Emitted when the trusted TBA registry pointer changes.
    event TrustedTBARegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    /// @notice Emitted when the linked x402 receiver pointer changes.
    event LinkedX402ReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);

    // ============ Collection-level metadata (OpenSea / Blur) ============
    //
    // OpenSea / Blur fetch `contractURI()` for the registry's collection
    // landing page (name, description, banner, fee_recipient). Storing
    // the full URI lets reads be a single SLOAD; build the JSON
    // off-chain (or via {AgentIdentityURILib.buildContractURIIdentity})
    // and pin via {setContractURI}.

    string private _contractURI;

    event ContractURIUpdated(string uri);

    /// @notice OpenSea / Blur compatible collection-level metadata URI.
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Owner: set the collection-level metadata URI. Accepts
    ///         `data:application/json;base64,…`, `ipfs://…`, `https://…`.
    function setContractURI(string calldata uri) external onlyOwner {
        _contractURI = uri;
        emit ContractURIUpdated(uri);
    }

    // ============ Storage Gap ============
    //
    // Reserved slots for future upgrades. Reduce this number by the number of
    // new storage variables added in a future implementation; never increase
    // it. Without this, adding any new storage variable after a child contract
    // is appended in a future inheritance change would shift slots and corrupt
    // state.
    // Shrunk from 50 → 48 when `trustedTBARegistry` + `linkedX402Receiver`
    //   were appended for the atomic full-stack mint path.
    // Shrunk from 48 → 47 when `_contractURI` was appended for OpenSea/Blur
    //   collection-level metadata. Budget recovered by removing
    //   redundant getters (`agentCreator`, `anchorAgentCount`,
    //   `hasSVGImage`, `calculateRoyaltySplit`).
    uint256[47] private __gap;
}
