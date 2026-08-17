// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IAgentIdentityRegistry.sol";

/**
 * @title AgentAvatarExtension
 * @notice Per-token 3D avatar manifest registry for ERC-8004 agents.
 * @dev    Sibling of {AgentSkillsExtension}. Keeps 3D avatar payload
 *         *out* of the main {AgentCollectionImpl} bytecode (which is
 *         already at ~23.7 KB against the EIP-170 24 KB ceiling) while
 *         still giving each token a canonical, owner-signed pointer to
 *         its avatar files.
 *
 * Design
 * ══════
 * The NFT commits to a *manifest* — a small on-chain record — that
 * points at an off-chain JSON document containing the actual avatar
 * files (VRM / GLB / USDZ / ...). Files themselves live on IPFS or an
 * HTTPS host to keep gas costs sane; the manifest URI + content hash
 * are on-chain so:
 *
 *   • Any client can verify the fetched manifest hasn't been tampered
 *     with (recompute sha256, compare against `contentHash`).
 *   • Indexers can watch a single event ({AvatarManifestUpdated}) to
 *     rebuild the "what's the current avatar for token N?" query
 *     without replaying tokenURI updates.
 *   • The main collection contract stays untouched — this extension
 *     talks to it only through {IAgentIdentityRegistry.ownerOf} for
 *     authorisation.
 *
 * Manifest JSON shape (off-chain, referenced by `manifestURI`)
 * ────────────────────────────────────────────────────────────
 * {
 *   "version": 1,
 *   "avatars": [
 *     {
 *       "format": "vrm",              // vrm | glb | usdz | fbx | png
 *       "uri":    "ipfs://bafy…/gemma.vrm",
 *       "sha256": "3f2a…",            // 32-byte hex of file bytes
 *       "size":   3820481,             // bytes
 *       "lod":    "high"              // low | med | high
 *     },
 *     ...
 *   ]
 * }
 *
 * The contract itself does not validate the manifest's JSON — that
 * would balloon bytecode and gas. Clients are responsible for parsing
 * + validating against `contentHash`. This mirrors how ERC-721
 * `tokenURI` metadata is treated everywhere: trust-on-hash, verify
 * off-chain.
 *
 * Authorisation
 * ─────────────
 * Only the current owner of the agent NFT may set / clear the
 * manifest ({onlyAgentOwner}). Because ERC-721 owner changes on every
 * secondary sale, the manifest naturally follows the token — a buyer
 * inherits the previous owner's avatar until they update it, which is
 * the same UX every marketplace user expects.
 */
contract AgentAvatarExtension is Initializable, OwnableUpgradeable, UUPSUpgradeable {

    // ── Errors ────────────────────────────────────────────────────
    error NotOwner();
    error NotExists();
    error EmptyInput();
    error URITooLong();

    // ── Storage ───────────────────────────────────────────────────

    /// @notice Handle to the identity registry we authorise against.
    IAgentIdentityRegistry public identityRegistry;

    /// @notice The full manifest record. Fields deliberately packed so
    ///         a single SSTORE covers `contentHash + updatedAt +
    ///         fileCount + version` (32 + 6 + 2 + 2 = 42 bits within
    ///         one slot alongside the hash).
    struct AvatarManifest {
        string  manifestURI;      // ipfs://... or https://...
        bytes32 contentHash;      // sha256 of the manifest JSON bytes
        uint48  updatedAt;        // block.timestamp at last set
        uint16  fileCount;        // number of avatar files inside the manifest (0 = unknown, indexed off-chain)
        uint16  version;          // monotonically increasing per token
    }

    /// @notice tokenId => manifest
    mapping(uint256 => AvatarManifest) private _manifests;

    /// @notice Per-agent history length (each `setAvatarManifest`
    ///         bumps `version`). Kept as a separate mapping so old
    ///         history can be reconstructed from events without
    ///         replaying full manifests through storage.
    mapping(uint256 => uint16) public latestVersion;

    /// @notice Maximum length of the manifest URI. Long enough for
    ///         any realistic IPFS CID or HTTPS URL; short enough to
    ///         keep abusive writes gas-bounded.
    uint256 public constant MAX_URI_LENGTH = 512;

    // ── Events ────────────────────────────────────────────────────

    /// @notice Emitted every time an owner sets or updates their
    ///         token's avatar manifest.
    event AvatarManifestUpdated(
        uint256 indexed tokenId,
        address indexed setter,
        string  manifestURI,
        bytes32 contentHash,
        uint16  version,
        uint16  fileCount
    );

    /// @notice Emitted when an owner clears their token's manifest
    ///         (reverting to the collection's fallback avatar, i.e.
    ///         the tokenURI `image_data` SVG or nothing).
    event AvatarManifestCleared(uint256 indexed tokenId, address indexed setter);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice UUPS initialiser. Called once by the proxy immediately
     *         after deployment. `_identityRegistry` should be the
     *         canonical {AgentCollectionImpl} proxy — anything else
     *         would let a malicious registry authorise strangers.
     */
    function initialize(address _identityRegistry) public initializer {
        __Ownable_init(msg.sender);
        identityRegistry = IAgentIdentityRegistry(_identityRegistry);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ── Modifiers ─────────────────────────────────────────────────

    modifier onlyAgentOwner(uint256 tokenId) {
        address tokenOwner = identityRegistry.ownerOf(tokenId);
        // A token that does not exist has no owner to compare against.
        // Checking only `!= msg.sender` made an unowned token writable by
        // address(0), because both sides were zero and the guard passed.
        // Unreachable through the canonical registry, which reverts on an
        // unminted id — but this contract's authorisation must not depend
        // on a collaborator's revert, and NotExists was declared for this
        // case and never raised.
        if (tokenOwner == address(0)) revert NotExists();
        if (tokenOwner != msg.sender) revert NotOwner();
        _;
    }

    // ── Mutating functions ────────────────────────────────────────

    /**
     * @notice Set (or replace) the avatar manifest for a token.
     * @dev    Reverts if any input field is empty. Silently overwrites
     *         any previous manifest — history is reconstructable from
     *         {AvatarManifestUpdated} logs.
     *
     * @param tokenId      the ERC-721 token id
     * @param manifestURI  off-chain pointer (ipfs:// or https://)
     * @param contentHash  sha256 of the fetched manifest bytes
     * @param fileCount    number of avatar entries inside the manifest
     *                     (informational; not enforced on-chain)
     */
    function setAvatarManifest(
        uint256 tokenId,
        string calldata manifestURI,
        bytes32 contentHash,
        uint16  fileCount
    ) external onlyAgentOwner(tokenId) {
        if (bytes(manifestURI).length == 0)          revert EmptyInput();
        if (bytes(manifestURI).length > MAX_URI_LENGTH) revert URITooLong();
        if (contentHash == bytes32(0))                revert EmptyInput();

        uint16 nextVersion;
        unchecked { nextVersion = latestVersion[tokenId] + 1; }

        _manifests[tokenId] = AvatarManifest({
            manifestURI: manifestURI,
            contentHash: contentHash,
            updatedAt:   uint48(block.timestamp),
            fileCount:   fileCount,
            version:     nextVersion
        });
        latestVersion[tokenId] = nextVersion;

        emit AvatarManifestUpdated(
            tokenId,
            msg.sender,
            manifestURI,
            contentHash,
            nextVersion,
            fileCount
        );
    }

    /**
     * @notice Clear a token's avatar manifest. After this call
     *         `getAvatarManifest(tokenId)` returns a zero record and
     *         `hasAvatarManifest(tokenId)` is false. Emits
     *         {AvatarManifestCleared} for indexers.
     */
    function clearAvatarManifest(uint256 tokenId) external onlyAgentOwner(tokenId) {
        AvatarManifest memory prev = _manifests[tokenId];
        if (bytes(prev.manifestURI).length == 0) revert NotExists();

        delete _manifests[tokenId];
        // `latestVersion` intentionally retained: after re-set the
        // next version continues incrementing so replayers see a
        // monotonic sequence per token.

        emit AvatarManifestCleared(tokenId, msg.sender);
    }

    // ── View functions ────────────────────────────────────────────

    /**
     * @notice Return the raw manifest struct. Callers that want
     *         boolean existence should use {hasAvatarManifest}.
     */
    function getAvatarManifest(uint256 tokenId) external view returns (AvatarManifest memory) {
        return _manifests[tokenId];
    }

    /// @notice True iff a manifest is currently set for the token.
    function hasAvatarManifest(uint256 tokenId) external view returns (bool) {
        return bytes(_manifests[tokenId].manifestURI).length != 0;
    }

    /**
     * @notice Convenience getter tailored for the meeting broadcast
     *         path — returns the URI and hash in one call so the Go
     *         client doesn't need to decode the packed struct.
     */
    function getAvatarPointer(uint256 tokenId)
        external
        view
        returns (string memory manifestURI, bytes32 contentHash)
    {
        AvatarManifest memory m = _manifests[tokenId];
        return (m.manifestURI, m.contentHash);
    }
}
