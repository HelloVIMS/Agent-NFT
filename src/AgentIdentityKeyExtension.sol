// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IAgentIdentityRegistry.sol";

/**
 * @title AgentIdentityKeyExtension
 * @notice Off-chain identity keys (Nostr npub today) bound to an ERC-8004
 *         agent, on the same 1:many model as Token-Bound Accounts: one
 *         primary identity registered with the mint, more added later.
 * @dev    Sibling of {AgentSkillsExtension} and {AgentAvatarExtension}.
 *
 * Why an extension rather than the registry
 * ═════════════════════════════════════════
 * {AgentIdentityRegistry} holds ~958 bytes under the EIP-170 ceiling and
 * BytecodeSizeAudit guards that margin. Subaccount bookkeeping for keys
 * does not fit there, so this mirrors `registerSubaccount` semantics from
 * the outside, authorising against {IAgentIdentityRegistry.ownerOf}.
 *
 * Shape mirrors TBAs deliberately
 * ═══════════════════════════════
 * Index 0 is the primary identity — the analogue of the primary TBA
 * deployed by `mintWithFullStack`. Later keys append, exactly as
 * `registerSubaccount` appends salted sub-TBAs, and carry the same
 * PERM_* bitmap so one permission model spans accounts and keys.
 * Deactivation (rather than deletion) frees the pubkey for re-use, as
 * `revokeSubaccount` frees an address.
 *
 * Registration is a separate transaction from the mint, and must be:
 * `mintWithFullStack` assigns the token id inside the call, so no caller
 * can name it beforehand. The daemon mints, reads the id from the
 * AgentRegistered log, then registers the primary key it generated
 * before minting. One user-visible operation, two transactions.
 *
 * What this contract does NOT claim
 * ═════════════════════════════════
 * 1. **No proof of control.** A registration asserts "the owner of agent
 *    N says this pubkey speaks for it", nothing more. Verifying a BIP-340
 *    schnorr signature on-chain has no precompile on Base and is not
 *    worth its gas here, so proof is bidirectional and off-chain: this
 *    registry says agent N claims pubkey X, and the holder of X publishes
 *    a Nostr event naming N. A verifier requires both; neither side alone
 *    is sufficient. Consumers MUST treat a bare link as a claim.
 *
 * 2. **No transfer of the secret.** A TBA moves with the NFT because
 *    control there is authorisation — ERC-6551 resolves the account from
 *    (chain, contract, tokenId) and nothing needs to move. An identity
 *    key is knowledge, and knowledge cannot be taken back from a seller.
 *    So a key registered under a previous owner is reported stale by
 *    {keysStale} the moment `ownerOf` changes, and the new owner is
 *    expected to rotate. Reading a stale key as authoritative would mean
 *    trusting an identity the previous owner can still sign for.
 */
contract AgentIdentityKeyExtension is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // ── Errors ────────────────────────────────────────────────────

    error NotOwner();
    error NotExists();
    error EmptyInput();
    error TooLarge();
    error AlreadyBound();
    error NotBound();
    error PrimaryAlreadySet();
    error PrimaryNotSet();
    error CannotDeactivatePrimary();
    error MaxKeys();
    error Unchanged();
    error ZeroIdentityRegistry();

    // ── Storage ───────────────────────────────────────────────────

    /// @notice The registry we authorise against.
    IAgentIdentityRegistry public identityRegistry;

    /**
     * @notice One identity key bound to an agent.
     * @dev    `pubkey` is 32 raw bytes. A Nostr key is an x-only
     *         secp256k1 point, which is exactly 32 bytes, so it is stored
     *         verbatim rather than hashed — a hash would make the key
     *         unusable for verification, which is the entire point of
     *         publishing it. `keyKind` names the interpretation so a
     *         future curve does not need a new contract.
     */
    struct IdentityKey {
        bytes32 pubkey;
        uint96  permissions;
        uint48  createdAt;
        bool    active;
        string  keyKind;
        string  label;
    }

    /// @notice agentId => keys, index 0 == primary identity.
    mapping(uint256 => IdentityKey[]) private _keys;

    /// @notice pubkey => agentId + 1 (0 == unbound). Enforces that one
    ///         key never claims to speak for two agents.
    mapping(bytes32 => uint256) private _pubkeyAgentIdPlusOne;

    /// @notice pubkey => index + 1 within its agent's key list.
    mapping(bytes32 => uint256) private _pubkeyIndexPlusOne;

    /// @notice agentId => the owner address that last wrote a key. When
    ///         this differs from `ownerOf`, every key is stale: see the
    ///         contract-level note on why a secret cannot transfer.
    mapping(uint256 => address) private _boundOwner;

    uint256 public constant MAX_KEYS_PER_AGENT = 32;
    uint256 public constant MAX_KEY_KIND_BYTES = 32;
    uint256 public constant MAX_LABEL_BYTES    = 64;

    // ── Events ────────────────────────────────────────────────────

    event PrimaryKeyRegistered(
        uint256 indexed agentId,
        bytes32 indexed pubkey,
        address indexed owner,
        string  keyKind,
        string  label,
        uint96  permissions
    );

    event KeyAdded(
        uint256 indexed agentId,
        bytes32 indexed pubkey,
        address indexed owner,
        uint256 index,
        string  keyKind,
        string  label,
        uint96  permissions
    );

    /// @dev Carries both sides so an indexer can retire the old pubkey
    ///      without replaying the whole log.
    event PrimaryKeyRotated(
        uint256 indexed agentId,
        bytes32 indexed oldPubkey,
        bytes32 indexed newPubkey,
        address owner
    );

    event KeyDeactivated(uint256 indexed agentId, bytes32 indexed pubkey, uint256 index);

    event KeyPermissionsUpdated(
        uint256 indexed agentId,
        bytes32 indexed pubkey,
        uint96  oldPermissions,
        uint96  newPermissions
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _identityRegistry) public initializer {
        if (_identityRegistry == address(0)) revert ZeroIdentityRegistry();
        __Ownable_init(msg.sender);
        identityRegistry = IAgentIdentityRegistry(_identityRegistry);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ── Modifiers ─────────────────────────────────────────────────

    modifier onlyAgentOwner(uint256 agentId) {
        address tokenOwner = identityRegistry.ownerOf(agentId);
        // A nonexistent token has no owner to compare against, and
        // comparing only `!= msg.sender` would let address(0) write to
        // an unminted id — both sides being zero satisfies it.
        if (tokenOwner == address(0)) revert NotExists();
        if (tokenOwner != msg.sender) revert NotOwner();
        _;
    }

    // ── Mutating ──────────────────────────────────────────────────

    /**
     * @notice Register the agent's primary identity — index 0, the
     *         analogue of the primary TBA. Callable once; afterwards the
     *         primary changes only through {rotatePrimaryKey}, so the
     *         slot cannot be silently repurposed.
     */
    function registerPrimaryKey(
        uint256 agentId,
        bytes32 pubkey,
        string calldata keyKind,
        string calldata label,
        uint96  permissions
    ) external onlyAgentOwner(agentId) {
        if (_keys[agentId].length != 0) revert PrimaryAlreadySet();
        _validate(pubkey, keyKind, label);
        _bind(agentId, pubkey, keyKind, label, permissions, 0);
        emit PrimaryKeyRegistered(agentId, pubkey, msg.sender, keyKind, label, permissions);
    }

    /**
     * @notice Add a further identity key, as {registerSubaccount} adds a
     *         further TBA. Requires a primary first: a key list whose
     *         index 0 is not the primary identity would break every
     *         consumer that resolves "the agent's identity" by index.
     * @return index position in the agent's key list.
     */
    function addKey(
        uint256 agentId,
        bytes32 pubkey,
        string calldata keyKind,
        string calldata label,
        uint96  permissions
    ) external onlyAgentOwner(agentId) returns (uint256 index) {
        if (_keys[agentId].length == 0) revert PrimaryNotSet();
        if (_keys[agentId].length >= MAX_KEYS_PER_AGENT) revert MaxKeys();
        _validate(pubkey, keyKind, label);
        index = _keys[agentId].length;
        _bind(agentId, pubkey, keyKind, label, permissions, index);
        emit KeyAdded(agentId, pubkey, msg.sender, index, keyKind, label, permissions);
    }

    /**
     * @notice Replace the primary identity key. This is the rotate-on-
     *         acquire path a new owner is expected to take after a
     *         transfer, and also covers a key compromise.
     * @dev    Atomic: the old pubkey is unbound and the new one bound in
     *         one call, so the contract is never observable with two
     *         live primaries or none.
     */
    function rotatePrimaryKey(
        uint256 agentId,
        bytes32 newPubkey,
        string calldata keyKind,
        string calldata label,
        uint96  permissions
    ) external onlyAgentOwner(agentId) {
        if (_keys[agentId].length == 0) revert PrimaryNotSet();
        _validate(newPubkey, keyKind, label);

        IdentityKey storage k = _keys[agentId][0];
        bytes32 old = k.pubkey;
        if (old == newPubkey) revert Unchanged();

        delete _pubkeyAgentIdPlusOne[old];
        delete _pubkeyIndexPlusOne[old];

        if (_pubkeyAgentIdPlusOne[newPubkey] != 0) revert AlreadyBound();

        k.pubkey      = newPubkey;
        k.keyKind     = keyKind;
        k.label       = label;
        k.permissions = permissions;
        k.createdAt   = uint48(block.timestamp);
        k.active      = true;

        _pubkeyAgentIdPlusOne[newPubkey] = agentId + 1;
        _pubkeyIndexPlusOne[newPubkey]   = 1;
        _boundOwner[agentId] = msg.sender;

        emit PrimaryKeyRotated(agentId, old, newPubkey, msg.sender);
    }

    /**
     * @notice Deactivate a key. Mirrors {revokeSubaccount}: the record
     *         stays for history, permissions drop to zero, and the
     *         pubkey becomes re-registerable.
     * @dev    The primary cannot be deactivated — an agent with no
     *         identity at index 0 is indistinguishable from one that
     *         never registered. Rotate it instead.
     */
    function deactivateKey(uint256 agentId, bytes32 pubkey) external onlyAgentOwner(agentId) {
        uint256 idxPlus = _pubkeyIndexPlusOne[pubkey];
        if (idxPlus == 0 || _pubkeyAgentIdPlusOne[pubkey] != agentId + 1) revert NotBound();
        if (idxPlus == 1) revert CannotDeactivatePrimary();

        IdentityKey storage k = _keys[agentId][idxPlus - 1];
        if (!k.active) revert NotBound();
        k.active = false;
        k.permissions = 0;

        delete _pubkeyAgentIdPlusOne[pubkey];
        delete _pubkeyIndexPlusOne[pubkey];
        _boundOwner[agentId] = msg.sender;

        emit KeyDeactivated(agentId, pubkey, idxPlus - 1);
    }

    /// @notice Update a key's PERM_* bitmap.
    function updateKeyPermissions(
        uint256 agentId,
        bytes32 pubkey,
        uint96  newPermissions
    ) external onlyAgentOwner(agentId) {
        uint256 idxPlus = _pubkeyIndexPlusOne[pubkey];
        if (idxPlus == 0 || _pubkeyAgentIdPlusOne[pubkey] != agentId + 1) revert NotBound();

        IdentityKey storage k = _keys[agentId][idxPlus - 1];
        if (!k.active) revert NotBound();
        uint96 old = k.permissions;
        if (old == newPermissions) revert Unchanged();
        k.permissions = newPermissions;
        _boundOwner[agentId] = msg.sender;

        emit KeyPermissionsUpdated(agentId, pubkey, old, newPermissions);
    }

    // ── Views ─────────────────────────────────────────────────────

    /// @notice Every key ever registered for an agent, including
    ///         deactivated ones (bounded by MAX_KEYS_PER_AGENT).
    function getKeys(uint256 agentId) external view returns (IdentityKey[] memory) {
        return _keys[agentId];
    }

    function getKey(uint256 agentId, uint256 index) external view returns (IdentityKey memory) {
        if (index >= _keys[agentId].length) revert NotBound();
        return _keys[agentId][index];
    }

    function keyCount(uint256 agentId) external view returns (uint256) {
        return _keys[agentId].length;
    }

    /// @notice The agent's primary identity. Reverts when unset so a
    ///         caller cannot mistake a zero pubkey for a real one.
    function primaryKey(uint256 agentId) external view returns (IdentityKey memory) {
        if (_keys[agentId].length == 0) revert PrimaryNotSet();
        return _keys[agentId][0];
    }

    /**
     * @notice Resolve a pubkey to the agent that claims it — the inverse
     *         lookup, mirroring the registry's account resolution.
     */
    function resolveKey(bytes32 pubkey)
        external
        view
        returns (uint256 agentId, uint256 index, bool bound, bool active, uint96 permissions)
    {
        uint256 plus = _pubkeyAgentIdPlusOne[pubkey];
        if (plus == 0) return (0, 0, false, false, 0);
        agentId = plus - 1;
        index = _pubkeyIndexPlusOne[pubkey] - 1;
        IdentityKey storage k = _keys[agentId][index];
        return (agentId, index, true, k.active, k.permissions);
    }

    /**
     * @notice True when the agent changed hands since its keys were last
     *         written, i.e. the registered identity belongs to a previous
     *         owner who still holds the secret.
     * @dev    Consumers MUST check this before treating a key as the
     *         agent's identity. It is the whole reason a key cannot be
     *         inherited the way a TBA is.
     */
    function keysStale(uint256 agentId) external view returns (bool) {
        if (_keys[agentId].length == 0) return false;
        address current = identityRegistry.ownerOf(agentId);
        if (current == address(0)) return true;
        return current != _boundOwner[agentId];
    }

    /// @notice The owner that last wrote a key for this agent.
    function boundOwner(uint256 agentId) external view returns (address) {
        return _boundOwner[agentId];
    }

    // ── Internal ──────────────────────────────────────────────────

    function _validate(bytes32 pubkey, string calldata keyKind, string calldata label) private pure {
        if (pubkey == bytes32(0)) revert EmptyInput();
        if (bytes(keyKind).length == 0) revert EmptyInput();
        if (bytes(keyKind).length > MAX_KEY_KIND_BYTES) revert TooLarge();
        if (bytes(label).length > MAX_LABEL_BYTES) revert TooLarge();
    }

    function _bind(
        uint256 agentId,
        bytes32 pubkey,
        string calldata keyKind,
        string calldata label,
        uint96  permissions,
        uint256 index
    ) private {
        if (_pubkeyAgentIdPlusOne[pubkey] != 0) revert AlreadyBound();
        _keys[agentId].push(IdentityKey({
            pubkey:      pubkey,
            permissions: permissions,
            createdAt:   uint48(block.timestamp),
            active:      true,
            keyKind:     keyKind,
            label:       label
        }));
        _pubkeyAgentIdPlusOne[pubkey] = agentId + 1;
        _pubkeyIndexPlusOne[pubkey]   = index + 1;
        _boundOwner[agentId] = msg.sender;
    }
}
