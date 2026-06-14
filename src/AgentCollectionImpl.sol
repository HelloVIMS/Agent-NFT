// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IAgentEvolutionHook} from "./hooks/IAgentEvolutionHook.sol";
import {EvolutionTypes} from "./hooks/EvolutionTypes.sol";
import {AgentCollectionRenderer} from "./AgentCollectionRenderer.sol";
import {AgentCollectionEIP712} from "./AgentCollectionEIP712.sol";
import {AgentCollectionPaymentLib} from "./AgentCollectionPaymentLib.sol";
import {AgentCollectionPixeLib} from "./AgentCollectionPixeLib.sol";

/**
 * @title AgentCollectionImpl
 * @notice Full-featured ERC-721 implementation for Agent collections
 * @dev Deployed via BeaconProxy from AgentCollectionFactory
 * @dev Each collection gets its own contract = separate OpenSea collection
 * @dev Includes: TBA, Pixe versioning, on-chain SVG, soulbound royalties
 * @dev Protected against reentrancy attacks on payment functions
 */
import {VimsProvenance} from "./VimsProvenance.sol";
import {AgentCollectionAtomicLib} from "./AgentCollectionAtomicLib.sol";

contract AgentCollectionImpl is 
    Initializable, 
    ERC721Upgradeable, 
    ERC721URIStorageUpgradeable,
    VimsProvenance,
    IERC2981
{
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentCollectionImpl";
    }

    // Custom errors
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
    error CollectionLocked();
    error MaxSupplyReached();
    error MintingNotActive();
    error MintingIsPaused();
    error MaxPerWalletReached();
    error InsufficientPayment();
    error TransferFailed();
    error ReentrancyGuardReentrantCall();
    error AllowlistPhaseActive();
    error InvalidProof();
    error AllowlistNotConfigured();
    error AllowlistEnded();
    // Evolution hook errors
    error HookPermissionMissing(uint256 flag);
    error HookInvalidReturn();
    error HookKeeperNotSet();
    error HookSignatureExpired();
    error HookSignatureInvalid();
    error HookNonceUsed();
    error HookAddressInvalid();
    /// @dev Setter does not match the token's locked-at-mint metadata mode.
    error MetadataModeLocked();
    /// @dev `mintAgent('','')` invoked but `collectionBaseURI` was never set.
    ///      Modes are locked at mint — no silent fallback to empty URI.
    error CollectionBaseURINotSet();

    // Reentrancy guard
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus;

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrancyGuardReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    uint256 private _nextTokenId;

    // Collection metadata
    address public collectionCreator;
    address public factory;
    uint256 public maxSupply;
    uint256 public defaultSalesRoyaltyBps;    // Default for secondary sales
    uint256 public defaultServiceRoyaltyBps;  // Default for x402 service payments
    string public collectionDescription;
    bool public locked;
    
    // Protocol fee configuration (immutable per collection)
    address public protocolFeeRecipient;
    uint256 public protocolPrimaryFeeBps;    // Fee on primary sales (mints)
    uint256 public protocolSecondaryFeeBps;  // Fee on secondary sales

    struct AgentMetadata {
        string name;
        address tbaAddress;
        uint256 createdAt;
        bool active;
    }

    // V4: Enhanced .pixe versioning
    struct PixeVersion {
        string arweaveTxId;
        bytes32 contentHash;
        uint8 versionType;       // 0=delta, 1=consolidated
        uint48 timestamp;
        uint16 baseVersion;
        string description;
    }

    struct ConsolidationRecord {
        uint16 fromVersion;
        uint16 toVersion;
        bytes32 merkleRoot;
        uint16 resultVersion;
        uint48 consolidatedAt;
    }

    /// @notice Per-token metadata source. Locked at mint — a token's
    ///         resolution path is determined exactly once and can never
    ///         change. No fallbacks, no precedence chain in `tokenURI()`.
    enum MetadataMode {
        ExplicitURI,  // 0 — default; URI stored via ERC-721URIStorage
        BaseURI,      // 1 — sequential composed from `collectionBaseURI`
        OnChainSVG    // 2 — rendered from `_svgImages[id]`
    }
    mapping(uint256 => MetadataMode) public metadataMode;

    mapping(uint256 => AgentMetadata) public agents;
    mapping(address => uint256[]) public ownerAgents;
    mapping(uint256 => string) private _svgImages;
    mapping(uint256 => PixeVersion[]) private _pixeVersions;
    mapping(uint256 => ConsolidationRecord[]) private _consolidations;
    mapping(uint256 => uint16) public latestConsolidatedVersion;

    // Soulbound creator royalties (split: sales vs service)
    mapping(uint256 => address) private _agentCreator;
    mapping(uint256 => uint256) private _salesRoyaltyBps;    // ERC-2981 secondary sales
    mapping(uint256 => uint256) private _serviceRoyaltyBps;  // x402 service payments

    uint256 public constant DEFAULT_SALES_ROYALTY_BPS = 1000;    // 10% default for sales
    uint256 public constant DEFAULT_SERVICE_ROYALTY_BPS = 500;   // 5% default for services
    uint256 public constant MAX_ROYALTY_BPS = 8000;              // 80% max
    uint256 public constant MIN_ROYALTY_BPS = 0;                 // 0% min (can waive)
    uint256 public constant MAX_PIXE_VERSIONS = 1000;
    uint256 public constant MAX_SVG_SIZE = 49152;                // 48KB

    // Mint pricing
    uint256 public mintPrice;
    bool public mintingPaused;
    uint256 public maxPerWallet;
    uint256 public mintStartTime;
    uint256 public mintEndTime;
    mapping(address => uint256) public mintedPerWallet;

    // Allowlist (merkle) phase — runs before public mint
    bytes32 public allowlistRoot;
    uint256 public allowlistEndTime;
    uint256 public allowlistPrice;
    uint256 public allowlistMaxPerWallet;
    mapping(address => uint256) public allowlistMintedPerWallet;

    // ============ Evolution hooks (Uniswap-v4-style) ============
    /// @notice Collection-wide hook applied to every token unless an agent-level
    ///         override is configured via {hookOf}. Set with {setCollectionHook}.
    address public collectionHook;
    /// @notice Per-agent hook override. Takes precedence over {collectionHook}.
    mapping(uint256 => address) public hookOf;
    /// @notice Cached permissions bitset for an active hook (collection-wide or per-agent).
    ///         Reduces external `permissions()` calls during the hot mint/transfer path.
    mapping(address => uint256) public hookPermissions;
    /// @notice Off-chain compute keeper authorized to submit signed `commitEvolution` results.
    address public evolutionKeeper;
    /// @notice Monotonic per-agent nonce protecting `commitEvolution` against replay.
    mapping(uint256 => uint256) public commitNonce;
    /// @notice Latest off-chain state hash committed for an agent (0 → never evolved).
    mapping(uint256 => bytes32) public evolutionStateHash;

    // ============ Multi-recipient royalty splits (v2) ============
    //
    // When non-zero, `royaltyReceiver` replaces `collectionCreator` as the
    // destination for primary mint revenue and ERC-2981 secondary royalties.
    // Governance (hooks, mint config, allowlist, lock) remains with
    // `collectionCreator`. The factory wires this slot exactly once,
    // immediately after proxy deployment, when the user opts into on-chain
    // royalty splits via {AgentCollectionFactory.createCollectionWithSplits}.
    //
    // Appended at the end of storage so the layout stays compatible with
    // proxies deployed before this slot existed (they read 0 and fall back
    // to {collectionCreator} via {_financialRecipient}).
    address public royaltyReceiver;

    // ============ Generative drop support (Pattern B) ============
    //
    // When `collectionBaseURI` is non-empty, any token minted through
    // `mintAgent` / `mintAgentAllowlist` with an EMPTY `agentURI` resolves
    // its `tokenURI(id)` to `string.concat(collectionBaseURI, id, ".json")`.
    // This lets a creator upload N pre-shuffled metadata JSONs once and open
    // up permissionless public / allowlist minting where callers don't need
    // to pass (and can't forge) per-token URIs.
    //
    // Governed by `collectionCreator`. Appended at the end of storage for
    // beacon-proxy upgrade safety.
    string public collectionBaseURI;

    // Events
    event AgentRegistered(uint256 indexed agentId, address indexed owner, string name, string agentURI);
    event AgentTBASet(uint256 indexed agentId, address indexed tbaAddress);
    event AgentDeactivated(uint256 indexed agentId);
    event AgentActivated(uint256 indexed agentId);
    event TBAAddressSet(uint256 indexed agentId, address indexed tbaAddress);
    event SVGImageSet(uint256 indexed agentId, uint256 svgLength);
    event PixeVersionAdded(uint256 indexed agentId, uint256 indexed version, bytes32 contentHash, uint8 versionType, string arweaveTxId);
    event PixeConsolidated(uint256 indexed agentId, uint16 fromVersion, uint16 toVersion, uint16 indexed resultVersion, bytes32 merkleRoot);
    event CreatorRoyaltySet(uint256 indexed agentId, address indexed creator, uint256 salesBps, uint256 serviceBps);
    event SalesRoyaltyUpdated(uint256 indexed agentId, uint256 oldBps, uint256 newBps);
    event ServiceRoyaltyUpdated(uint256 indexed agentId, uint256 oldBps, uint256 newBps);
    event CollectionLockedEvent();
    event MintConfigUpdated(uint256 price, uint256 maxPerWallet, uint256 startTime, uint256 endTime);
    event MintingPaused(bool paused);
    event ProtocolFeeCollected(address indexed recipient, uint256 amount);
    event AllowlistConfigUpdated(bytes32 root, uint256 endTime, uint256 price, uint256 maxPerWallet);
    event AllowlistMint(address indexed minter, uint256 indexed agentId);
    event BaseURISet(string baseURI);
    // Evolution hook events
    event CollectionHookSet(address indexed previousHook, address indexed newHook, uint256 permissions);
    event AgentHookSet(uint256 indexed agentId, address indexed previousHook, address indexed newHook, uint256 permissions);
    event EvolutionKeeperSet(address indexed previousKeeper, address indexed newKeeper);
    event EvolutionApplied(uint256 indexed agentId, bytes32 indexed triggerKind, bytes32 newStateHash, bool svgChanged, bool uriChanged);
    event EvolutionRequested(uint256 indexed agentId, bytes32 indexed triggerKind, uint256 nonce, bytes payload);
    event EvolutionCommitted(uint256 indexed agentId, bytes32 indexed triggerKind, uint256 nonce, bytes32 newStateHash);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        uint256 salesRoyaltyBps_,
        uint256 serviceRoyaltyBps_,
        address creator_,
        string memory description_,
        address protocolFeeRecipient_,
        uint256 protocolPrimaryFeeBps_,
        uint256 protocolSecondaryFeeBps_
    ) public initializer {
        __ERC721_init(name_, symbol_);
        __ERC721URIStorage_init();
        _reentrancyStatus = _NOT_ENTERED;
        
        collectionCreator = creator_;
        factory = msg.sender;
        maxSupply = maxSupply_;
        defaultSalesRoyaltyBps = salesRoyaltyBps_;
        defaultServiceRoyaltyBps = serviceRoyaltyBps_;
        collectionDescription = description_;
        
        // Protocol fees (immutable after initialization)
        protocolFeeRecipient = protocolFeeRecipient_;
        protocolPrimaryFeeBps = protocolPrimaryFeeBps_;
        protocolSecondaryFeeBps = protocolSecondaryFeeBps_;
        
        _nextTokenId = 1;
    }

    // ============ Agent Registration ============

    function registerAgent(
        string calldata name_,
        string calldata agentURI
    ) external returns (uint256 agentId) {
        return registerAgentWithRoyalty(name_, agentURI, defaultSalesRoyaltyBps, defaultServiceRoyaltyBps);
    }

    function registerAgentWithRoyalty(
        string calldata name_,
        string calldata agentURI,
        uint256 salesBps,
        uint256 serviceBps
    ) public returns (uint256 agentId) {
        if (locked) revert CollectionLocked();
        if (maxSupply > 0 && _nextTokenId > maxSupply) revert MaxSupplyReached();
        if (salesBps > MAX_ROYALTY_BPS) revert InvalidValue();
        if (serviceBps > MAX_ROYALTY_BPS) revert InvalidValue();

        agentId = _nextTokenId++;
        _writeAgentRecord(agentId, name_, agentURI, salesBps, serviceBps, true);
    }

    /// @dev Storage-write + hook + event block shared by the free
    ///      `registerAgentWithRoyalty` path and the paid `_executeMint` path.
    ///      `forceSetTokenURI=true` always writes the URI (free path);
    ///      `forceSetTokenURI=false` writes only when non-empty (paid path's
    ///      generative-drop fallback). Centralising avoids the two paths
    ///      drifting apart and keeps the impl under EIP-170.
    function _writeAgentRecord(
        uint256 agentId,
        string calldata name_,
        string calldata agentURI,
        uint256 salesBps,
        uint256 serviceBps,
        bool /* unused, kept for ABI continuity */
    ) private {
        // Lock the metadata resolution mode at mint. Either an explicit
        // per-token URI was provided (ExplicitURI — enum default 0, no
        // SSTORE) or the collection has pre-configured `collectionBaseURI`
        // (BaseURI). OnChainSVG mode is reachable only via
        // `mintAgentWithSVG` so the SVG bytes are committed atomically.
        // No silent fallbacks.
        bool explicit = bytes(agentURI).length > 0;
        if (!explicit && bytes(collectionBaseURI).length == 0) revert CollectionBaseURINotSet();

        _commitAgent(agentId, name_, salesBps, serviceBps);
        if (explicit) {
            _setTokenURI(agentId, agentURI);
        } else {
            metadataMode[agentId] = MetadataMode.BaseURI;
        }
        emit AgentRegistered(agentId, msg.sender, name_, agentURI);
        emit CreatorRoyaltySet(agentId, msg.sender, salesBps, serviceBps);
        _callAfterMint(agentId, msg.sender, "");
    }

    /// @dev Shared mint-time storage write: hooks, ERC-721 mint, agent
    ///      record, soulbound creator + royalty bps. Callers append the
    ///      mode-specific writes (URI / SVG / nothing-for-BaseURI) and
    ///      emit the canonical events.
    function _commitAgent(
        uint256 agentId,
        string calldata name_,
        uint256 salesBps,
        uint256 serviceBps
    ) private {
        _callBeforeMint(agentId, msg.sender, "");
        _safeMint(msg.sender, agentId);
        agents[agentId] = AgentMetadata({
            name: name_,
            tbaAddress: address(0),
            createdAt: block.timestamp,
            active: true
        });
        _agentCreator[agentId]      = msg.sender;
        _salesRoyaltyBps[agentId]   = salesBps;
        _serviceRoyaltyBps[agentId] = serviceBps;
    }

    /// @notice Mint an agent and atomically commit its on-chain SVG.
    ///         Mode locked to `OnChainSVG`; mutation restricted to the
    ///         same mode via {setSVGImage}.
    function mintAgentWithSVG(
        string calldata name_,
        string calldata svg
    ) external returns (uint256 agentId) {
        if (locked) revert CollectionLocked();
        if (maxSupply > 0 && _nextTokenId > maxSupply) revert MaxSupplyReached();
        if (bytes(svg).length == 0) revert EmptyInput();
        if (bytes(svg).length > MAX_SVG_SIZE) revert TooLarge();

        agentId = _nextTokenId++;
        _commitAgent(agentId, name_, defaultSalesRoyaltyBps, defaultServiceRoyaltyBps);
        metadataMode[agentId] = MetadataMode.OnChainSVG;
        _svgImages[agentId]   = svg;

        emit AgentRegistered(agentId, msg.sender, name_, "");
        emit CreatorRoyaltySet(agentId, msg.sender, defaultSalesRoyaltyBps, defaultServiceRoyaltyBps);
        emit SVGImageSet(agentId, bytes(svg).length);
        _callAfterMint(agentId, msg.sender, "");
    }

    // ============ Paid Minting with Protocol Fees ============

    /**
     * @notice Mint an agent with payment (protocol fee automatically collected)
     * @param name_ Agent name
     * @param agentURI Agent metadata URI
     */
    function mintAgent(
        string calldata name_,
        string calldata agentURI
    ) external payable nonReentrant returns (uint256 agentId) {
        _assertStandardMintGate();
        agentId = _nextTokenId++;
        mintedPerWallet[msg.sender]++;
        _executeMint(agentId, name_, agentURI);
    }

    /// @dev Shared validation for the public mint paths (`mintAgent` and
    ///      `mintAgentWithFullStack`). Pulled out to keep the two paths
    ///      in lock-step and to reclaim bytecode under EIP-170.
    ///
    ///      `allowlistEndTime` semantics:
    ///        - 0           → allowlist runs forever (public mint stays closed)
    ///        - >block.ts   → allowlist still active (public mint blocked)
    ///        - <=block.ts  → allowlist ended (public mint open)
    ///      Mirrors `mintAgentAllowlist`'s termination check so both paths
    ///      agree on what "no end time" means.
    function _assertStandardMintGate() private view {
        if (allowlistRoot != bytes32(0)) {
            if (allowlistEndTime == 0 || block.timestamp <= allowlistEndTime) {
                revert AllowlistPhaseActive();
            }
        }
        if (locked) revert CollectionLocked();
        if (mintingPaused) revert MintingIsPaused();
        if (mintStartTime > 0 && block.timestamp < mintStartTime) revert MintingNotActive();
        if (mintEndTime > 0 && block.timestamp > mintEndTime) revert MintingNotActive();
        if (maxSupply > 0 && _nextTokenId > maxSupply) revert MaxSupplyReached();
        if (maxPerWallet > 0 && mintedPerWallet[msg.sender] >= maxPerWallet) revert MaxPerWalletReached();
        if (msg.value < mintPrice) revert InsufficientPayment();
    }

    /// @dev Common path shared by `mintAgent` and `mintAgentAllowlist`. Writes
    ///      the agent record + royalty defaults, splits `msg.value` between
    ///      protocol fee and creator revenue, emits the canonical events, and
    ///      runs the before/after-mint hooks. Centralised here to keep the
    ///      impl bytecode under EIP-170 and ensure the two mint paths cannot
    ///      drift apart silently.
    function _executeMint(uint256 agentId, string calldata name_, string calldata agentURI) private {
        // Empty `agentURI` signals "resolve via collectionBaseURI + id + .json"
        // in the tokenURI() override below — the generative-drop path where
        // the creator pre-uploads all metadata to a shared folder. The
        // `_writeAgentRecord` helper handles that conditional + the rest of
        // the storage writes + before/after-mint hooks + events.
        _writeAgentRecord(
            agentId, name_, agentURI,
            defaultSalesRoyaltyBps, defaultServiceRoyaltyBps,
            /* forceSetTokenURI */ false
        );

        AgentCollectionPaymentLib.splitMintPayment(
            protocolFeeRecipient,
            protocolPrimaryFeeBps,
            _financialRecipient()
        );
    }

    /**
     * @notice Mint during the allowlist phase by submitting a merkle proof
     * @dev Leaf format: keccak256(abi.encodePacked(addr))
     * @param name_ Agent name
     * @param agentURI Agent metadata URI
     * @param proof Merkle proof for msg.sender against `allowlistRoot`
     */
    function mintAgentAllowlist(
        string calldata name_,
        string calldata agentURI,
        bytes32[] calldata proof
    ) external payable nonReentrant returns (uint256 agentId) {
        if (allowlistRoot == bytes32(0)) revert AllowlistNotConfigured();
        if (allowlistEndTime > 0 && block.timestamp > allowlistEndTime) revert AllowlistEnded();
        if (locked) revert CollectionLocked();
        if (mintingPaused) revert MintingIsPaused();
        if (maxSupply > 0 && _nextTokenId > maxSupply) revert MaxSupplyReached();
        if (allowlistMaxPerWallet > 0 && allowlistMintedPerWallet[msg.sender] >= allowlistMaxPerWallet) revert MaxPerWalletReached();
        if (msg.value < allowlistPrice) revert InsufficientPayment();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        if (!MerkleProof.verifyCalldata(proof, allowlistRoot, leaf)) revert InvalidProof();

        agentId = _nextTokenId++;
        allowlistMintedPerWallet[msg.sender]++;
        _executeMint(agentId, name_, agentURI);
        emit AllowlistMint(msg.sender, agentId);
    }

    /**
     * @notice Configure the merkle allowlist phase (creator only)
     * @param root_ Merkle root over keccak256(abi.encodePacked(addr)) leaves. Pass bytes32(0) to disable.
     * @param endTime_ Unix timestamp when allowlist phase ends and public mint begins. 0 = no end (allowlist forever).
     * @param price_ Allowlist mint price (wei)
     * @param maxPerWallet_ Per-wallet cap during allowlist phase (0 = unlimited)
     */
    function setAllowlistConfig(
        bytes32 root_,
        uint256 endTime_,
        uint256 price_,
        uint256 maxPerWallet_
    ) external {
        if (msg.sender != collectionCreator) revert NotCreator();
        allowlistRoot = root_;
        allowlistEndTime = endTime_;
        allowlistPrice = price_;
        allowlistMaxPerWallet = maxPerWallet_;
        emit AllowlistConfigUpdated(root_, endTime_, price_, maxPerWallet_);
    }

    /**
     * @notice Read the allowlist phase config
     */
    function getAllowlistConfig() external view returns (
        bytes32 root,
        uint256 endTime,
        uint256 price,
        uint256 perWalletLimit,
        bool active
    ) {
        bool isActive = allowlistRoot != bytes32(0)
            && (allowlistEndTime == 0 || block.timestamp <= allowlistEndTime);
        return (allowlistRoot, allowlistEndTime, allowlistPrice, allowlistMaxPerWallet, isActive);
    }

    /**
     * @notice Verify a merkle proof for an address against the allowlist root
     */
    function isAllowlisted(address account, bytes32[] calldata proof) external view returns (bool) {
        if (allowlistRoot == bytes32(0)) return false;
        bytes32 leaf = keccak256(abi.encodePacked(account));
        return MerkleProof.verifyCalldata(proof, allowlistRoot, leaf);
    }

    /**
     * @notice Set the shared metadata base URI for this collection.
     *         When set, any token minted with an empty `agentURI` resolves
     *         its `tokenURI` to `string.concat(baseURI, tokenId, ".json")`.
     *         Pre-existing tokens with an explicit `_tokenURI` are not
     *         affected. Creator-only; pass an empty string to clear.
     */
    function setBaseURI(string calldata baseURI_) external {
        if (msg.sender != collectionCreator) revert NotCreator();
        collectionBaseURI = baseURI_;
        emit BaseURISet(baseURI_);
    }

    /**
     * @notice Configure mint settings (creator only)
     */
    function setMintConfig(
        uint256 price_,
        uint256 maxPerWallet_,
        uint256 startTime_,
        uint256 endTime_
    ) external {
        if (msg.sender != collectionCreator) revert NotCreator();
        
        mintPrice = price_;
        maxPerWallet = maxPerWallet_;
        mintStartTime = startTime_;
        mintEndTime = endTime_;
        
        emit MintConfigUpdated(price_, maxPerWallet_, startTime_, endTime_);
    }

    /**
     * @notice Pause or unpause minting (creator only)
     */
    function setPauseMinting(bool paused_) external {
        if (msg.sender != collectionCreator) revert NotCreator();
        mintingPaused = paused_;
        emit MintingPaused(paused_);
    }

    /**
     * @notice Get mint configuration
     */
    function getMintConfig() external view returns (
        uint256 price,
        uint256 perWalletLimit,
        uint256 startTime,
        uint256 endTime,
        bool paused,
        uint256 currentSupply,
        uint256 maxSupply_
    ) {
        return (
            mintPrice,
            maxPerWallet,
            mintStartTime,
            mintEndTime,
            mintingPaused,
            _nextTokenId - 1,
            maxSupply
        );
    }

    // ============ TBA Management ============

    function setTBAAddress(uint256 agentId, address tbaAddress) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        if (tbaAddress == address(0)) revert InvalidAddress();
        if (agents[agentId].tbaAddress != address(0)) revert AlreadySet();

        agents[agentId].tbaAddress = tbaAddress;
        emit TBAAddressSet(agentId, tbaAddress);
    }

    // ============ Agent Status ============

    function deactivateAgent(uint256 agentId) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        if (!agents[agentId].active) revert InvalidValue();
        agents[agentId].active = false;
        emit AgentDeactivated(agentId);
    }

    function reactivateAgent(uint256 agentId) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        if (agents[agentId].active) revert InvalidValue();
        agents[agentId].active = true;
        emit AgentActivated(agentId);
    }

    function updateAgentURI(uint256 agentId, string calldata newURI) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        // Mode lock: only ExplicitURI tokens accept URI updates.
        if (metadataMode[agentId] != MetadataMode.ExplicitURI) revert MetadataModeLocked();
        if (bytes(newURI).length == 0) revert EmptyInput();
        _setTokenURI(agentId, newURI);
    }

    // ============ View Functions ============

    function getAgentsByOwner(address owner) external view returns (uint256[] memory) {
        return ownerAgents[owner];
    }

    function getAgent(uint256 agentId) external view returns (
        string memory name_,
        address tbaAddress,
        uint256 createdAt,
        bool active,
        address owner
    ) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        AgentMetadata memory agent = agents[agentId];
        return (agent.name, agent.tbaAddress, agent.createdAt, agent.active, ownerOf(agentId));
    }

    function totalSupply() external view returns (uint256) {
        return _nextTokenId - 1;
    }

    // ============ Soulbound Creator Royalties (Dual: Sales + Service) ============

    function getCreatorRoyalty(uint256 agentId) external view returns (address creator, uint256 salesBps, uint256 serviceBps) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        return (_agentCreator[agentId], _salesRoyaltyBps[agentId], _serviceRoyaltyBps[agentId]);
    }

    function getSalesRoyalty(uint256 agentId) external view returns (uint256) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        return _salesRoyaltyBps[agentId];
    }

    function getServiceRoyalty(uint256 agentId) external view returns (uint256) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        return _serviceRoyaltyBps[agentId];
    }

    function agentCreator(uint256 agentId) external view returns (address) {
        return _agentCreator[agentId];
    }

    function calculateSalesRoyaltySplit(uint256 agentId, uint256 amount) external view returns (uint256 creatorCut, uint256 ownerCut) {
        uint256 royaltyBps = _salesRoyaltyBps[agentId];
        creatorCut = (amount * royaltyBps) / 10000;
        ownerCut = amount - creatorCut;
    }

    function calculateServiceRoyaltySplit(uint256 agentId, uint256 amount) external view returns (uint256 creatorCut, uint256 ownerCut) {
        uint256 royaltyBps = _serviceRoyaltyBps[agentId];
        creatorCut = (amount * royaltyBps) / 10000;
        ownerCut = amount - creatorCut;
    }

    function updateSalesRoyalty(uint256 agentId, uint256 newBps) external {
        if (_agentCreator[agentId] != msg.sender) revert NotCreator();
        if (newBps > MAX_ROYALTY_BPS) revert InvalidValue();
        if (newBps == _salesRoyaltyBps[agentId]) revert Unchanged();

        uint256 oldBps = _salesRoyaltyBps[agentId];
        _salesRoyaltyBps[agentId] = newBps;
        emit SalesRoyaltyUpdated(agentId, oldBps, newBps);
    }

    function updateServiceRoyalty(uint256 agentId, uint256 newBps) external {
        if (_agentCreator[agentId] != msg.sender) revert NotCreator();
        if (newBps > MAX_ROYALTY_BPS) revert InvalidValue();
        if (newBps == _serviceRoyaltyBps[agentId]) revert Unchanged();

        uint256 oldBps = _serviceRoyaltyBps[agentId];
        _serviceRoyaltyBps[agentId] = newBps;
        emit ServiceRoyaltyUpdated(agentId, oldBps, newBps);
    }

    // ============ On-chain SVG Storage ============

    function setSVGImage(uint256 agentId, string calldata svg) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        // Mode is locked at mint. Only OnChainSVG-mode tokens can have
        // their SVG bytes mutated; ExplicitURI / BaseURI tokens reject
        // the call rather than silently storing dead bytes that would
        // never be served by `tokenURI`.
        if (metadataMode[agentId] != MetadataMode.OnChainSVG) revert MetadataModeLocked();
        if (bytes(svg).length == 0) revert EmptyInput();
        if (bytes(svg).length > MAX_SVG_SIZE) revert TooLarge();

        _svgImages[agentId] = svg;
        emit SVGImageSet(agentId, bytes(svg).length);
    }

    function getSVGImage(uint256 agentId) external view returns (string memory) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        return _svgImages[agentId];
    }

    function hasSVGImage(uint256 agentId) external view returns (bool) {
        return bytes(_svgImages[agentId]).length > 0;
    }

    // ============ Pixe Versioning ============

    function addPixeVersion(
        uint256 agentId,
        string calldata arweaveTxId,
        bytes32 contentHash,
        string calldata description
    ) external returns (uint256 version) {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        // Delegate to library — DELEGATECALL preserves storage, msg.sender,
        // and emits events as if they fired from this impl. Bytecode budget:
        // ~1 KB recovered vs the inlined block (audit P0 invariant B.2).
        version = AgentCollectionPixeLib.addPixeVersion(
            // Cast our local PixeVersion[] storage map to the lib's matching
            // type. The two struct definitions have identical layout (kept
            // in lockstep by `audit/INVARIANTS.md` §J.2).
            _pixeVersionsForLib(),
            latestConsolidatedVersion,
            MAX_PIXE_VERSIONS,
            agentId,
            arweaveTxId,
            contentHash,
            description
        );
    }

    function consolidateVersions(
        uint256 agentId,
        string calldata arweaveTxId,
        bytes32 contentHash,
        bytes32 merkleRoot,
        string calldata description
    ) external returns (uint256 version) {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        version = AgentCollectionPixeLib.consolidateVersions(
            _pixeVersionsForLib(),
            _consolidationsForLib(),
            latestConsolidatedVersion,
            MAX_PIXE_VERSIONS,
            agentId,
            arweaveTxId,
            contentHash,
            merkleRoot,
            description
        );
    }

    /// @dev Type-cast helper — the impl's `PixeVersion` and the library's
    ///      have identical storage layout, so we expose the storage map to
    ///      the library through assembly without copying. This keeps the
    ///      types decoupled at the source level while sharing one storage
    ///      slot tree.
    function _pixeVersionsForLib()
        private
        view
        returns (mapping(uint256 => AgentCollectionPixeLib.PixeVersion[]) storage s)
    {
        mapping(uint256 => PixeVersion[]) storage src = _pixeVersions;
        assembly { s.slot := src.slot }
    }

    function _consolidationsForLib()
        private
        view
        returns (mapping(uint256 => AgentCollectionPixeLib.ConsolidationRecord[]) storage s)
    {
        mapping(uint256 => ConsolidationRecord[]) storage src = _consolidations;
        assembly { s.slot := src.slot }
    }

    function getPixeVersion(uint256 agentId, uint256 version) external view returns (
        string memory arweaveTxId,
        bytes32 contentHash,
        uint8 versionType,
        uint256 timestamp,
        uint16 baseVersion,
        string memory description
    ) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        if (version >= _pixeVersions[agentId].length) revert NotExists();

        PixeVersion memory pv = _pixeVersions[agentId][version];
        return (pv.arweaveTxId, pv.contentHash, pv.versionType, pv.timestamp, pv.baseVersion, pv.description);
    }

    function getLatestPixe(uint256 agentId) external view returns (
        string memory arweaveTxId,
        bytes32 contentHash,
        uint8 versionType,
        uint256 timestamp,
        string memory description,
        uint256 version
    ) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        if (_pixeVersions[agentId].length == 0) revert NotExists();

        version = _pixeVersions[agentId].length - 1;
        PixeVersion memory pv = _pixeVersions[agentId][version];
        return (pv.arweaveTxId, pv.contentHash, pv.versionType, pv.timestamp, pv.description, version);
    }

    function getLatestConsolidatedPixe(uint256 agentId) external view returns (
        string memory arweaveTxId,
        bytes32 contentHash,
        uint256 timestamp,
        string memory description,
        uint256 version
    ) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        if (_pixeVersions[agentId].length == 0) revert NotExists();

        version = latestConsolidatedVersion[agentId];
        PixeVersion memory pv = _pixeVersions[agentId][version];
        return (pv.arweaveTxId, pv.contentHash, pv.timestamp, pv.description, version);
    }

    function getPixeVersionCount(uint256 agentId) external view returns (uint256) {
        return _pixeVersions[agentId].length;
    }

    function getAllPixeVersions(uint256 agentId) external view returns (PixeVersion[] memory) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        return _pixeVersions[agentId];
    }

    function getConsolidationHistory(uint256 agentId) external view returns (ConsolidationRecord[] memory) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        return _consolidations[agentId];
    }

    function verifyContentHash(uint256 agentId, uint256 version, bytes32 contentHash) external view returns (bool) {
        if (version >= _pixeVersions[agentId].length) revert NotExists();
        return _pixeVersions[agentId][version].contentHash == contentHash;
    }

    function getPixeURL(uint256 agentId, uint256 version) external view returns (string memory) {
        if (version >= _pixeVersions[agentId].length) revert NotExists();
        PixeVersion memory pv = _pixeVersions[agentId][version];
        return string(abi.encodePacked("ar://", pv.arweaveTxId));
    }

    // ============ Collection Management ============

    function lockCollection() external {
        if (msg.sender != collectionCreator) revert NotCreator();
        if (locked) revert CollectionLocked();
        locked = true;
        emit CollectionLockedEvent();
    }

    function contractURI() external view returns (string memory) {
        return AgentCollectionRenderer.buildContractURI(
            name(),
            collectionDescription,
            defaultSalesRoyaltyBps,
            _financialRecipient()
        );
    }

    // ============ Token URI with On-chain SVG ============

    function tokenURI(uint256 tokenId) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable) returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert NotExists();

        // Strict switch on the per-token mode set at mint. No fallbacks.
        // Each branch resolves the canonical metadata source for the
        // mode the creator committed to when the token was minted.
        MetadataMode mode = metadataMode[tokenId];

        if (mode == MetadataMode.OnChainSVG) {
            AgentMetadata storage a = agents[tokenId];
            return AgentCollectionRenderer.buildTokenURI(AgentCollectionRenderer.TokenURIInput({
                tokenId:               tokenId,
                maxSupply:             maxSupply,
                svg:                   bytes(_svgImages[tokenId]),
                agentName:             a.name,
                collectionDescription: collectionDescription,
                collectionName:        name(),
                active:                a.active,
                hasTBA:                a.tbaAddress != address(0),
                salesBps:              _salesRoyaltyBps[tokenId],
                serviceBps:            _serviceRoyaltyBps[tokenId],
                pixeVersionsLen:       _pixeVersions[tokenId].length,
                createdAt:             a.createdAt,
                agentCreator:          _agentCreator[tokenId]
            }));
        }

        if (mode == MetadataMode.BaseURI) {
            return AgentCollectionRenderer.buildSequentialURI(collectionBaseURI, tokenId);
        }

        // ExplicitURI (default). Returns the per-token frozen URI string.
        return super.tokenURI(tokenId);
    }

    // ============ ERC-2981 Royalty ============

    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view override returns (address receiver, uint256 royaltyAmount) {
        // When the collection opted into multi-recipient royalty splits,
        // the splitter contract is the canonical ERC-2981 receiver.
        // Otherwise fall back to the per-token soulbound creator.
        receiver = royaltyReceiver != address(0) ? royaltyReceiver : _agentCreator[tokenId];
        royaltyAmount = (salePrice * _salesRoyaltyBps[tokenId]) / 10000;
    }

    /**
     * @notice Wire the per-collection royalty splitter exactly once. Callable
     *         only by the deploying factory immediately after proxy init.
     * @dev    Once set, the value is immutable. The splitter becomes the
     *         destination for primary mint revenue, contractURI fee_recipient,
     *         and ERC-2981 royalty receiver. Governance (hooks, mint config,
     *         lock) stays with collectionCreator.
     */
    function setRoyaltyReceiverOnce(address receiver_) external {
        if (msg.sender != factory) revert NotCreator();
        if (receiver_ == address(0)) revert InvalidAddress();
        if (royaltyReceiver != address(0)) revert AlreadySet();
        royaltyReceiver = receiver_;
    }

    function _financialRecipient() internal view returns (address) {
        return royaltyReceiver != address(0) ? royaltyReceiver : collectionCreator;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, ERC721URIStorageUpgradeable, IERC165) returns (bool) {
        return 
            interfaceId == type(IERC2981).interfaceId ||  // ERC-2981: Royalties
            interfaceId == bytes4(0x80040001) ||          // ERC-8004: Agent Identity
            interfaceId == bytes4(0x6551daf8) ||          // ERC-6551: TBA
            super.supportsInterface(interfaceId);
    }

    // ============ Evolution Hooks ============
    //
    // Uniswap-v4-style pluggable mutation system. A hook is a contract implementing
    // `IAgentEvolutionHook` whose lifecycle entry points are invoked at well-known
    // host events (mint/transfer) and on permissionless `triggerEvolve` calls.
    //
    // Hook resolution: per-agent override `hookOf[id]` wins over `collectionHook`.
    // Off-chain compute: hooks declaring `FLAG_REQUIRES_KEEPER` (or returning
    // `requiresKeeper = true`) cause the host to emit `EvolutionRequested`; the
    // configured `evolutionKeeper` finalises with a signed `commitEvolution`.

    /// @notice Hook currently active for a given agent (per-agent override > collection-wide).
    /// @dev EIP-712 typed-data hashing and signer recovery for the keeper
    ///      `commitEvolution` flow are delegated to {AgentCollectionEIP712}.

    function activeHookFor(uint256 agentId) public view returns (address hook, uint256 perms) {
        hook = hookOf[agentId];
        if (hook == address(0)) hook = collectionHook;
        if (hook != address(0)) perms = hookPermissions[hook];
    }

    /// @dev Validate a hook address and cache its permissions bitset, returning
    ///      the (possibly zero) perms. Pass address(0) to clear without checks.
    function _registerHookPerms(address hook) private returns (uint256 perms) {
        if (hook == address(0)) return 0;
        if (hook.code.length == 0) revert HookAddressInvalid();
        try IAgentEvolutionHook(hook).permissions() returns (uint256 p) {
            perms = p;
        } catch {
            revert HookAddressInvalid();
        }
        hookPermissions[hook] = perms;
    }

    /// @notice Set the collection-wide hook (creator only). Pass address(0) to clear.
    function setCollectionHook(address hook) external {
        if (msg.sender != collectionCreator) revert NotCreator();
        address prev = collectionHook;
        uint256 perms = _registerHookPerms(hook);
        collectionHook = hook;
        emit CollectionHookSet(prev, hook, perms);
    }

    /// @notice Set / clear a per-agent hook override (token owner only).
    function setHook(uint256 agentId, address hook) external {
        if (ownerOf(agentId) != msg.sender) revert NotOwner();
        address prev = hookOf[agentId];
        uint256 perms = _registerHookPerms(hook);
        hookOf[agentId] = hook;
        emit AgentHookSet(agentId, prev, hook, perms);
    }

    /// @notice Authorise an off-chain compute keeper for `commitEvolution` (creator only).
    function setEvolutionKeeper(address keeper) external {
        if (msg.sender != collectionCreator) revert NotCreator();
        address prev = evolutionKeeper;
        evolutionKeeper = keeper;
        emit EvolutionKeeperSet(prev, keeper);
    }

    /// @notice Permissionless trigger entry point. The active hook decides whether
    ///         to mutate. If the hook declares FLAG_REQUIRES_KEEPER (or returns
    ///         requiresKeeper=true), host emits EvolutionRequested and waits for
    ///         a signed `commitEvolution` from the keeper.
    function triggerEvolve(
        uint256 agentId,
        bytes32 triggerKind,
        bytes calldata payload
    ) external nonReentrant returns (EvolutionTypes.EvolutionResult memory result) {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        (address hook, uint256 perms) = activeHookFor(agentId);
        if (hook == address(0)) revert HookAddressInvalid();
        if (!EvolutionTypes.hasFlag(perms, EvolutionTypes.FLAG_ON_TRIGGER)) {
            revert HookPermissionMissing(EvolutionTypes.FLAG_ON_TRIGGER);
        }

        result = IAgentEvolutionHook(hook).onTrigger(agentId, triggerKind, payload);

        bool needsKeeper = result.requiresKeeper
            || EvolutionTypes.hasFlag(perms, EvolutionTypes.FLAG_REQUIRES_KEEPER);

        if (needsKeeper) {
            uint256 n = ++commitNonce[agentId];
            emit EvolutionRequested(agentId, triggerKind, n, payload);
            return result;
        }

        if (result.svgChanged) {
            _applyEvolution(agentId, triggerKind, result);
        }
    }

    /// @notice Apply a hook result that was computed off-chain by the authorised keeper.
    /// @dev    EIP-712 signed by `evolutionKeeper`.
    function commitEvolution(
        uint256 agentId,
        bytes32 triggerKind,
        EvolutionTypes.EvolutionResult calldata result,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        if (_ownerOf(agentId) == address(0)) revert NotExists();
        // Deadline / nonce / EIP-712 signer recovery are all delegated to the
        // external library so the impl stays under the EIP-170 size ceiling.
        AgentCollectionEIP712.verifyCommit(
            name(),
            evolutionKeeper,
            agentId,
            triggerKind,
            result,
            nonce,
            deadline,
            signature,
            commitNonce[agentId]
        );

        commitNonce[agentId] = nonce;

        if (result.svgChanged) {
            _applyEvolution(agentId, triggerKind, result);
        } else if (result.newStateHash != bytes32(0)) {
            evolutionStateHash[agentId] = result.newStateHash;
        }

        emit EvolutionCommitted(agentId, triggerKind, nonce, result.newStateHash);
    }

    function _applyEvolution(
        uint256 agentId,
        bytes32 triggerKind,
        EvolutionTypes.EvolutionResult memory result
    ) internal {
        bool uriChanged = bytes(result.newSvgUri).length > 0;
        bool inlineChanged = result.newSvgInline.length > 0;

        if (uriChanged) {
            _setTokenURI(agentId, result.newSvgUri);
        }
        if (inlineChanged) {
            if (result.newSvgInline.length > MAX_SVG_SIZE) revert TooLarge();
            _svgImages[agentId] = string(result.newSvgInline);
            emit SVGImageSet(agentId, result.newSvgInline.length);
        }
        if (result.newStateHash != bytes32(0)) {
            evolutionStateHash[agentId] = result.newStateHash;
        }
        emit EvolutionApplied(agentId, triggerKind, result.newStateHash, inlineChanged, uriChanged);
    }

    // ── Internal lifecycle dispatchers ───────────────────────────────────────

    function _callBeforeMint(uint256 agentId, address to, bytes memory data) internal {
        (address hook, uint256 perms) = activeHookFor(agentId);
        if (hook == address(0)) return;
        if (!EvolutionTypes.hasFlag(perms, EvolutionTypes.FLAG_BEFORE_MINT)) return;
        bytes4 sel = IAgentEvolutionHook(hook).beforeMint(agentId, to, data);
        if (sel != IAgentEvolutionHook.beforeMint.selector) revert HookInvalidReturn();
    }

    function _callAfterMint(uint256 agentId, address to, bytes memory data) internal {
        (address hook, uint256 perms) = activeHookFor(agentId);
        if (hook == address(0)) return;
        if (!EvolutionTypes.hasFlag(perms, EvolutionTypes.FLAG_AFTER_MINT)) return;
        bytes4 sel = IAgentEvolutionHook(hook).afterMint(agentId, to, data);
        if (sel != IAgentEvolutionHook.afterMint.selector) revert HookInvalidReturn();
    }

    function _callBeforeTransfer(uint256 tokenId, address from, address to) internal {
        (address hook, uint256 perms) = activeHookFor(tokenId);
        if (hook == address(0)) return;
        if (!EvolutionTypes.hasFlag(perms, EvolutionTypes.FLAG_BEFORE_TRANSFER)) return;
        bytes4 sel = IAgentEvolutionHook(hook).beforeTransfer(tokenId, from, to);
        if (sel != IAgentEvolutionHook.beforeTransfer.selector) revert HookInvalidReturn();
    }

    function _callAfterTransfer(uint256 tokenId, address from, address to) internal {
        (address hook, uint256 perms) = activeHookFor(tokenId);
        if (hook == address(0)) return;
        if (!EvolutionTypes.hasFlag(perms, EvolutionTypes.FLAG_AFTER_TRANSFER)) return;
        bytes4 sel = IAgentEvolutionHook(hook).afterTransfer(tokenId, from, to);
        if (sel != IAgentEvolutionHook.afterTransfer.selector) revert HookInvalidReturn();
    }

    // ============ Internal ============

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        // Pre-transfer hook fires only on actual transfers, NOT on mints (from == 0)
        // or burns (to == 0). Mints/burns are governed by mint/burn-specific hooks.
        address currentOwner = _ownerOf(tokenId);
        if (currentOwner != address(0) && to != address(0)) {
            _callBeforeTransfer(tokenId, currentOwner, to);
        }

        address from = super._update(to, tokenId, auth);

        if (from != address(0)) {
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

        if (from != address(0) && to != address(0)) {
            _callAfterTransfer(tokenId, from, to);
        }

        return from;
    }

    // ============ Phase C: atomic full-stack mint + adapter ===============
    //
    // Wires this collection into {AgentX402Receiver}'s V2 NFT-scoped surface:
    //
    //   1. {IAgentNFTAdapter} — serviceRoyaltyOf / tbaOf views the receiver
    //      uses at settlement time to compute the 3-way split. `ownerOf` is
    //      satisfied by the inherited ERC-721 implementation.
    //
    //   2. `linkedX402Receiver` — once the collection creator wires this
    //      pointer AND calls {AgentX402Receiver.selfRegisterCollection}, the
    //      `mintAgentWithFullStack` path can register a priced service in
    //      the same tx as the mint. The receiver authorises the call because
    //      it sees `msg.sender == address(this) == trustedRegistrarFor[this]`.

    /// @notice {IAgentNFTAdapter} adapter view — collection-level financial
    ///         recipient + per-token service royalty bps. Matches the
    ///         {IAgentNFTAdapter} ABI by selector; the interface is NOT in
    ///         the inheritance tree because doing so forces a diamond-
    ///         resolution `ownerOf` override that bloats bytecode without
    ///         improving ABI compatibility.
    function serviceRoyaltyOf(uint256 tokenId)
        external
        view
        returns (address creator, uint256 bps)
    {
        ownerOf(tokenId); // existence revert
        creator = _financialRecipient();
        bps     = _serviceRoyaltyBps[tokenId];
    }

    /// @notice {IAgentNFTAdapter} adapter view — token-bound account address.
    function tbaOf(uint256 tokenId) external view returns (address) {
        ownerOf(tokenId); // existence revert
        return agents[tokenId].tbaAddress;
    }

    /**
     * @notice Atomic mint + x402 service register. Same payment + supply +
     *         allowlist gating as `mintAgent`, plus an optional service-
     *         registration leg. Reverts if the allowlist phase is still
     *         active — mirrors `mintAgent`.
     *
     * @dev    For the service leg to land:
     *           - `linkedX402Receiver` must be set (creator-only setter)
     *           - the collection must have been onboarded via
     *             {AgentX402Receiver.selfRegisterCollection}
     *           - all of (serviceId, token, price) must be non-zero
     *
     *         If any precondition fails, the mint still succeeds and the
     *         service leg is silently skipped — matches the additive
     *         semantics of {AgentIdentityRegistry.mintWithFullStack}.
     *
     * @param  name_      Agent display name.
     * @param  agentURI   Metadata URI (empty ⇒ generative path uses
     *                    `collectionBaseURI + tokenId + .json`).
     * @param  tbaSalt    Reserved for a future collection-side TBA wiring
     *                    leg. Currently unused.
     * @param  serviceId  bytes32(0) to skip the service leg.
     * @param  token      ERC-20 (must be allowlisted on the receiver).
     * @param  price      Service price in `token` base units.
     * @return agentId    Newly minted token id.
     * @return tba        Always address(0) in this iteration; reserved for
     *                    the collection-side TBA leg follow-up.
     */
    function mintAgentWithFullStack(
        string calldata name_,
        string calldata agentURI,
        bytes32 tbaSalt,
        bytes32 serviceId,
        address token,
        uint256 price
    ) external payable nonReentrant returns (uint256 agentId, address tba) {
        // Same gating as `mintAgent` — centralised in `_assertStandardMintGate`
        // so both paths can never drift apart silently.
        _assertStandardMintGate();

        agentId = _nextTokenId++;
        mintedPerWallet[msg.sender]++;
        _executeMint(agentId, name_, agentURI);

        // ─── Atomic TBA + x402 service ──────────────────────────────────
        // Delegates to {AgentCollectionAtomicLib} which holds the pinned
        // ERC-6551 registry + receiver addresses (see lib for rationale).
        // The lib returns the deterministic TBA whether or not it was
        // freshly created (idempotent at the registry layer); we mirror
        // the binding into our own `agents[id].tbaAddress` slot so the
        // {tbaOf} adapter view + downstream consumers stay coherent.
        tba = AgentCollectionAtomicLib.deployTBAAndRegisterService(
            agentId, tbaSalt, serviceId, token, price
        );

        agents[agentId].tbaAddress = tba;
        emit TBAAddressSet(agentId, tba);
    }
}
