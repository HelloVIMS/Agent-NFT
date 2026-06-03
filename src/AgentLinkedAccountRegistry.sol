// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "./interfaces/IAgentIdentityRegistry.sol";
import {VimsProvenance} from "./VimsProvenance.sol";

/**
 * @title AgentLinkedAccountRegistry
 * @notice Option B of the 1:Many TBA architecture: external / cross-chain
 *         account linking. Where `AgentIdentityRegistry` stores on-chain
 *         subaccounts (typically salted ERC-6551 TBAs), this registry stores
 *         arbitrary off-this-chain accounts that should be attributed to an
 *         agent: other-chain EVM wallets, Solana addresses, Bitcoin xpubs,
 *         hosted email/x402 endpoints, ChangeNOW payout addresses, etc.
 *
 * Permission bitmap mirrors AgentIdentityRegistry's PERM_* constants so a
 * single permission model spans both registries.
 *
 * Three link modes are supported:
 *   1. Owner-attested:    The agent NFT owner asserts the link. Useful for
 *                         non-EVM or other-chain accounts where on-chain
 *                         signature verification is impossible.
 *   2. Self-attested:     The linked account itself signs an EIP-712
 *                         `LinkAttestation` proving ownership. Verified via
 *                         SignatureChecker (works for EOAs and ERC-1271
 *                         smart accounts on this chain).
 *   3. Externally-attested: A trusted attester contract
 *                         (`trustedAttesters[msg.sender] == true`) submits
 *                         the link after verifying an underlying proof:
 *                         bridge message (LayerZero / CCIP / Hyperlane /
 *                         Axelar), VAA (Wormhole), Merkle proof,
 *                         Eigenlayer AVS attestation, etc. The attester
 *                         contract is the trust anchor; the registry only
 *                         records the link and stamps it with the attester
 *                         address so downstream indexers can audit the
 *                         provenance. See `linkAccountAttested`.
 *
 * UUPS upgradeable.
 */
contract AgentLinkedAccountRegistry is
    Initializable,
    VimsProvenance,
    OwnableUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable
{
    using ECDSA for bytes32;

    // ============ Errors ============
    error NotOwner();
    error NotExists();
    error AlreadyLinked();
    error NotLinked();
    error MaxReached();
    error EmptyInput();
    error TooLarge();
    error InvalidSignature();
    error ExpiredAttestation();
    error ZeroAddress();
    error Unchanged();
    // External attester errors
    error NotAttester();
    error AttesterAlreadyRegistered();
    error AttesterNotRegistered();

    // ============ Constants ============
    uint256 public constant MAX_LINKS_PER_AGENT = 64;
    uint256 public constant MAX_KIND_LEN  = 32;
    uint256 public constant MAX_LABEL_LEN = 64;

    // Permission bits (mirror AgentIdentityRegistry)
    uint96 public constant PERM_PAY        = 1 << 0;
    uint96 public constant PERM_REPUTATION = 1 << 1;
    uint96 public constant PERM_PAYOUT     = 1 << 2; // can receive payouts from royalty vault / payment router
    uint96 public constant PERM_ALL        = type(uint96).max;

    // EIP-712 typehash for self-attested links.
    //   LinkAttestation(uint256 agentId,uint256 chainId,bytes32 accountId,uint256 nonce,uint256 deadline)
    bytes32 public constant LINK_ATTESTATION_TYPEHASH = keccak256(
        "LinkAttestation(uint256 agentId,uint256 chainId,bytes32 accountId,uint256 nonce,uint256 deadline)"
    );

    // ============ Types ============
    struct LinkedAccount {
        uint256  chainId;        // EIP-155 chain id; 0 == off-chain / non-EVM
        bytes32  accountId;      // canonical id: EVM = bytes32(uint160(addr)); else hash of native repr
        string   accountKind;    // free-form: "evm","solana","bitcoin","email","x402","changenow",...
        string   label;          // human label
        uint96   permissions;    // PERM_* bitmap
        uint48   linkedAt;
        bool     active;
        bool     selfAttested;   // true iff a valid LinkAttestation was supplied
        address  attestedBy;     // external attester contract address (0 == owner/self-attested)
    }

    // ============ Storage ============
    IAgentIdentityRegistry public identityRegistry;

    // agentId => linked accounts list
    mapping(uint256 => LinkedAccount[]) private _linked;
    // chainId => accountId => agentId+1 (0 == not linked anywhere)
    mapping(uint256 => mapping(bytes32 => uint256)) private _resolveAgent;
    // chainId => accountId => index+1 in _linked[agentId]
    mapping(uint256 => mapping(bytes32 => uint256)) private _resolveIndex;
    // attestation replay guard: agentId => nonce
    mapping(uint256 => uint256) public attestationNonce;

    // ---- External attesters (bridge / oracle / Merkle / AVS) ----
    /// @notice Owner-managed allowlist of attester contracts that may
    ///         submit links via `linkAccountAttested`.
    mapping(address => bool) public trustedAttesters;
    /// @notice Machine-readable proof-system tag per attester:
    ///         "layerzero" | "ccip" | "hyperlane" | "wormhole" | "axelar"
    ///       | "merkle"    | "eigenlayer-avs" | "custom".
    mapping(address => string) public attesterKind;

    // ============ Events ============
    event AccountLinked(
        uint256 indexed agentId,
        uint256 indexed chainId,
        bytes32 indexed accountId,
        string  accountKind,
        uint96  permissions,
        bool    selfAttested
    );
    event AccountUnlinked(uint256 indexed agentId, uint256 indexed chainId, bytes32 indexed accountId);
    event AccountAttestedExternal(
        uint256 indexed agentId,
        address indexed attester,
        uint256 chainId,
        bytes32 indexed accountId,
        string  attesterKind
    );
    event AttesterRegistered(address indexed attester, string kind);
    event AttesterRevoked(address indexed attester);
    event AccountPermissionsUpdated(
        uint256 indexed agentId,
        bytes32 indexed accountId,
        uint96 oldPermissions,
        uint96 newPermissions
    );
    event IdentityRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // ============ Init ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentLinkedAccountRegistry";
    }

    function initialize(address _identityRegistry) public initializer {
        if (_identityRegistry == address(0)) revert ZeroAddress();
        __Ownable_init(msg.sender);
        __Pausable_init();
        __EIP712_init("AgentLinkedAccountRegistry", "1");
        identityRegistry = IAgentIdentityRegistry(_identityRegistry);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setIdentityRegistry(address _identityRegistry) external onlyOwner {
        if (_identityRegistry == address(0)) revert ZeroAddress();
        emit IdentityRegistryUpdated(address(identityRegistry), _identityRegistry);
        identityRegistry = IAgentIdentityRegistry(_identityRegistry);
    }

    // ============ External Attester Admin ============

    /**
     * @notice Register an external attester contract. The attester becomes
     *         a trust anchor: it can link any (chainId, accountId) to any
     *         agentId via `linkAccountAttested`. Use ONLY for contracts
     *         that perform real proof verification before forwarding
     *         (LayerZero/CCIP/Hyperlane/Wormhole receivers, Merkle-proof
     *         verifiers, Eigenlayer AVS aggregators).
     * @param  attester  Address of the attester contract.
     * @param  kind      Machine-readable tag ("layerzero", "wormhole", etc.).
     */
    function registerAttester(address attester, string calldata kind) external onlyOwner {
        if (attester == address(0)) revert ZeroAddress();
        if (trustedAttesters[attester]) revert AttesterAlreadyRegistered();
        if (bytes(kind).length == 0) revert EmptyInput();
        if (bytes(kind).length > MAX_KIND_LEN) revert TooLarge();
        trustedAttesters[attester] = true;
        attesterKind[attester] = kind;
        emit AttesterRegistered(attester, kind);
    }

    /**
     * @notice Revoke an external attester. Existing links it produced
     *         persist (use `unlinkAccount` to remove specific ones); only
     *         future calls from this attester are blocked.
     */
    function revokeAttester(address attester) external onlyOwner {
        if (!trustedAttesters[attester]) revert AttesterNotRegistered();
        trustedAttesters[attester] = false;
        delete attesterKind[attester];
        emit AttesterRevoked(attester);
    }

    modifier onlyAgentOwner(uint256 agentId) {
        if (identityRegistry.ownerOf(agentId) != msg.sender) revert NotOwner();
        _;
    }

    // ============ Helpers ============

    /// @notice Canonical EVM accountId encoding: bytes32(uint160(addr)).
    function evmAccountId(address addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function eip712Digest(
        uint256 agentId,
        uint256 chainId,
        bytes32 accountId,
        uint256 nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            LINK_ATTESTATION_TYPEHASH,
            agentId,
            chainId,
            accountId,
            nonce,
            deadline
        )));
    }

    // ============ Write API ============

    /**
     * @notice Owner-attested link. The agent NFT owner asserts that
     *         (chainId, accountId) belongs to the agent. No on-chain
     *         signature verification (use this for non-EVM / other-chain).
     */
    function linkAccount(
        uint256 agentId,
        uint256 chainId,
        bytes32 accountId,
        string calldata accountKind,
        string calldata label,
        uint96 permissions
    ) external onlyAgentOwner(agentId) whenNotPaused returns (uint256 index) {
        return _link(agentId, chainId, accountId, accountKind, label, permissions, false, address(0));
    }

    /**
     * @notice Self-attested link via EIP-712 signature. The signer is the
     *         linked EVM account itself (recovered from `signature` against
     *         the LinkAttestation digest). Works for EOAs and ERC-1271
     *         smart wallets on the current chain. The agent NFT owner does
     *         NOT need to be the same key, but does need to submit the tx
     *         (or any tx) — caller is unconstrained, the signature carries
     *         the authority.
     *
     * @dev    `chainId` MUST equal `block.chainid` for self-attested links
     *         since SignatureChecker only works against this-chain accounts.
     *         For other-chain EVM addresses use `linkAccount` (owner-attested)
     *         or supply an oracle attestation in a future revision.
     */
    function linkAccountWithAttestation(
        uint256 agentId,
        address linkedEvmAccount,
        string calldata accountKind,
        string calldata label,
        uint96 permissions,
        uint256 deadline,
        bytes calldata signature
    ) external onlyAgentOwner(agentId) whenNotPaused returns (uint256 index) {
        if (linkedEvmAccount == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert ExpiredAttestation();

        bytes32 accountId = evmAccountId(linkedEvmAccount);
        uint256 nonce = attestationNonce[agentId]++;
        bytes32 digest = eip712Digest(agentId, block.chainid, accountId, nonce, deadline);

        if (!SignatureChecker.isValidSignatureNow(linkedEvmAccount, digest, signature)) {
            revert InvalidSignature();
        }

        return _link(agentId, block.chainid, accountId, accountKind, label, permissions, true, address(0));
    }

    /**
     * @notice Externally-attested link. Callable ONLY by a registered
     *         attester contract. The attester is responsible for verifying
     *         the underlying proof (bridge message, VAA, Merkle proof, AVS
     *         signature, ...) BEFORE invoking this function — the registry
     *         trusts `msg.sender` as authoritative and only records the
     *         link with the attester address stamped for audit.
     *
     *         No agent NFT owner check is performed. The attester model
     *         exists precisely for cases where the agent owner cannot
     *         sign on this chain (e.g. attesting a Solana account via
     *         Wormhole VAA, or attesting a remote-EVM account via
     *         LayerZero message).
     *
     * @param  agentId      Agent NFT id receiving the link.
     * @param  chainId      EIP-155 chain id of the linked account, or 0 for
     *                      off-chain / non-EVM. For non-EVM use a stable
     *                      synthetic id documented in `accountKind`.
     * @param  accountId    Canonical account id (bytes32(uint160(addr))
     *                      for EVM, hash of native repr otherwise).
     * @param  accountKind  "evm","solana","bitcoin","email","changenow",...
     * @param  label        Free-form human label.
     * @param  permissions  PERM_* bitmap.
     */
    function linkAccountAttested(
        uint256 agentId,
        uint256 chainId,
        bytes32 accountId,
        string calldata accountKind,
        string calldata label,
        uint96 permissions
    ) external whenNotPaused returns (uint256 index) {
        if (!trustedAttesters[msg.sender]) revert NotAttester();
        // The agent NFT must exist; this also guards against agentId == 0
        // collisions in resolveAgent storage (it stores agentId + 1).
        identityRegistry.ownerOf(agentId);

        index = _link(agentId, chainId, accountId, accountKind, label, permissions, false, msg.sender);
        emit AccountAttestedExternal(agentId, msg.sender, chainId, accountId, attesterKind[msg.sender]);
    }

    function _link(
        uint256 agentId,
        uint256 chainId,
        bytes32 accountId,
        string calldata accountKind,
        string calldata label,
        uint96 permissions,
        bool selfAttested,
        address attestedByAddr
    ) internal returns (uint256 index) {
        if (accountId == bytes32(0)) revert EmptyInput();
        if (bytes(accountKind).length == 0) revert EmptyInput();
        if (bytes(accountKind).length > MAX_KIND_LEN) revert TooLarge();
        if (bytes(label).length > MAX_LABEL_LEN) revert TooLarge();
        if (_resolveAgent[chainId][accountId] != 0) revert AlreadyLinked();
        if (_linked[agentId].length >= MAX_LINKS_PER_AGENT) revert MaxReached();

        index = _linked[agentId].length;
        _linked[agentId].push(LinkedAccount({
            chainId:      chainId,
            accountId:    accountId,
            accountKind:  accountKind,
            label:        label,
            permissions:  permissions,
            linkedAt:     uint48(block.timestamp),
            active:       true,
            selfAttested: selfAttested,
            attestedBy:   attestedByAddr
        }));
        _resolveAgent[chainId][accountId] = agentId + 1;
        _resolveIndex[chainId][accountId] = index + 1;

        emit AccountLinked(agentId, chainId, accountId, accountKind, permissions, selfAttested);
    }

    function unlinkAccount(
        uint256 agentId,
        uint256 chainId,
        bytes32 accountId
    ) external onlyAgentOwner(agentId) whenNotPaused {
        if (_resolveAgent[chainId][accountId] != agentId + 1) revert NotLinked();
        uint256 idxPlus = _resolveIndex[chainId][accountId];
        if (idxPlus == 0) revert NotLinked();

        LinkedAccount storage la = _linked[agentId][idxPlus - 1];
        la.active = false;
        la.permissions = 0;
        delete _resolveAgent[chainId][accountId];
        delete _resolveIndex[chainId][accountId];

        emit AccountUnlinked(agentId, chainId, accountId);
    }

    function updatePermissions(
        uint256 agentId,
        uint256 chainId,
        bytes32 accountId,
        uint96 newPermissions
    ) external onlyAgentOwner(agentId) whenNotPaused {
        if (_resolveAgent[chainId][accountId] != agentId + 1) revert NotLinked();
        uint256 idxPlus = _resolveIndex[chainId][accountId];
        if (idxPlus == 0) revert NotLinked();

        LinkedAccount storage la = _linked[agentId][idxPlus - 1];
        if (!la.active) revert NotLinked();
        uint96 old = la.permissions;
        if (old == newPermissions) revert Unchanged();
        la.permissions = newPermissions;

        emit AccountPermissionsUpdated(agentId, accountId, old, newPermissions);
    }

    // ============ Read API ============

    function agentIdOf(uint256 chainId, bytes32 accountId) external view returns (
        uint256 agentId,
        bool    linked,
        uint96  permissions,
        bool    active
    ) {
        uint256 plus = _resolveAgent[chainId][accountId];
        if (plus == 0) return (0, false, 0, false);
        agentId = plus - 1;
        linked = true;
        uint256 idxPlus = _resolveIndex[chainId][accountId];
        if (idxPlus == 0) return (agentId, true, 0, false);
        LinkedAccount memory la = _linked[agentId][idxPlus - 1];
        return (agentId, true, la.permissions, la.active);
    }

    function agentIdOfEvm(uint256 chainId, address addr) external view returns (
        uint256 agentId,
        bool    linked,
        uint96  permissions,
        bool    active
    ) {
        return this.agentIdOf(chainId, evmAccountId(addr));
    }

    function hasPermission(uint256 chainId, bytes32 accountId, uint96 perm) external view returns (bool) {
        uint256 plus = _resolveAgent[chainId][accountId];
        if (plus == 0) return false;
        uint256 idxPlus = _resolveIndex[chainId][accountId];
        if (idxPlus == 0) return false;
        LinkedAccount memory la = _linked[plus - 1][idxPlus - 1];
        if (!la.active) return false;
        return (la.permissions & perm) == perm;
    }

    function getLinkedAccounts(uint256 agentId) external view returns (LinkedAccount[] memory) {
        return _linked[agentId];
    }

    function linkedAccountCount(uint256 agentId) external view returns (uint256) {
        return _linked[agentId].length;
    }

    /**
     * @notice Return the attester contract that originally produced this
     *         link, or address(0) if it was owner-attested or self-attested.
     */
    function attesterOf(uint256 chainId, bytes32 accountId) external view returns (address) {
        uint256 plus = _resolveAgent[chainId][accountId];
        if (plus == 0) return address(0);
        uint256 idxPlus = _resolveIndex[chainId][accountId];
        if (idxPlus == 0) return address(0);
        return _linked[plus - 1][idxPlus - 1].attestedBy;
    }
}
