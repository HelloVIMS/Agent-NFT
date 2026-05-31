// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable}        from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable}      from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Minimal slice of {AgentIdentityRegistry}: this registry only needs
///         to know who currently owns an agent NFT to gate writes.
interface IAgentOwnership {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/**
 * @title AgentEncryptionRegistry
 * @notice On-chain home for the long-lived encryption keypair attached to a
 *         VIMS agent. The keypair lets anyone seal data *to* the agent
 *         (`pubkey`) and lets only the NFT owner unseal it (the matching
 *         private key is wrapped under a KEK derived from a deterministic
 *         wallet signature; the wrapped blob is stored here in `wrappedPrivkey`).
 *
 * @dev    Design notes — read before editing.
 *
 *         1. **Public key shape.** We store a raw 32-byte X25519 public key
 *            (`bytes32`) — the entire on-chain curve point. ECIES wrapping in
 *            the browser is X25519-DH → HKDF-SHA256 → AES-256-GCM. Switching
 *            curves requires a new contract version (the format is part of
 *            the on-chain ABI).
 *
 *         2. **Wrapped private key shape.** Opaque to this contract; the
 *            client library defines the layout. Today: `[1B version][12B nonce][32B salt][N AES-GCM ct||tag]`.
 *            Length-capped to {MAX_WRAPPED_PRIVKEY_BYTES} to keep gas bounded
 *            and to surface client bugs (a healthy wrapped privkey is ~80B).
 *
 *         3. **Versioning.** Every successful write bumps `version[agentId]`.
 *            Clients use this as an "epoch" — encrypting code MUST refuse to
 *            seal against a stale pubkey, and any wrapped-AES-key included in
 *            an upload manifest MUST carry the epoch it was wrapped under so
 *            the unsealer knows whether it can still decrypt.
 *
 *         4. **Rotation.** `rotate` is the *only* state-changing entrypoint
 *            after the first write. It atomically updates pubkey + wrapped
 *            privkey + version, so the contract is never observable in an
 *            inconsistent half-rotated state. Useful for:
 *            - knowledge / skill upgrades (re-key + re-upload),
 *            - new NFT owner after a transfer ("rotate-on-acquire"),
 *            - planned key hygiene.
 *
 *         5. **No signature verification on-chain.** The wallet signature
 *            that derives the KEK never touches the chain — it's a private
 *            message signed in the browser, used as entropy for HKDF. The
 *            registry only verifies that the *caller* is the NFT owner.
 *
 *         6. **Upgradeable.** UUPS pattern, owner-gated upgrades, matching
 *            the rest of the VIMS contract suite.
 */
contract AgentEncryptionRegistry is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // ─── Errors ─────────────────────────────────────────────────────────
    error NotAgentOwner();
    error ZeroPubkey();
    error WrappedPrivkeyEmpty();
    error WrappedPrivkeyTooLarge(uint256 given, uint256 maxAllowed);
    error ZeroIdentityRegistry();
    error AlreadyInitialised(uint256 agentId);
    error NotYetInitialised(uint256 agentId);

    // ─── Constants ──────────────────────────────────────────────────────
    /// @notice Hard cap on the size of the wrapped-private-key blob. The
    ///         canonical layout is ~80 bytes; 1 KiB leaves head-room for
    ///         format changes without inviting DoS via huge SSTORE writes.
    uint256 public constant MAX_WRAPPED_PRIVKEY_BYTES = 1024;

    // ─── Storage ────────────────────────────────────────────────────────
    /// @notice Identity / ownership oracle. Set once at init, immutable
    ///         after upgrade (UUPS preserves this slot).
    IAgentOwnership public identityRegistry;

    struct KeyRecord {
        bytes32 pubkey;          // X25519 public key (32B)
        uint64  version;         // bumps on every write; 0 == uninitialised
        uint64  updatedAt;       // unix seconds, last write
        bytes   wrappedPrivkey;  // opaque ciphertext; client-defined layout
    }

    /// @notice agentId => latest key record. `version == 0` means the agent
    ///         has never published an encryption key. Clients MUST refuse
    ///         to encrypt against an uninitialised agent.
    mapping(uint256 => KeyRecord) internal _records;

    // ─── Events ─────────────────────────────────────────────────────────
    event KeyPublished(
        uint256 indexed agentId,
        bytes32 indexed pubkey,
        uint64  indexed version,
        address by,
        uint64  at
    );
    event KeyRotated(
        uint256 indexed agentId,
        bytes32 indexed oldPubkey,
        bytes32 indexed newPubkey,
        uint64  newVersion,
        address by,
        uint64  at
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _identityRegistry) public initializer {
        if (_identityRegistry == address(0)) revert ZeroIdentityRegistry();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        identityRegistry = IAgentOwnership(_identityRegistry);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ─── Authorisation ──────────────────────────────────────────────────
    /// @dev Strict NFT-ownership check. Operators / approvals deliberately
    ///      excluded — a transient approval should never grant key-rotation
    ///      rights, which would let an approved spender lock the seller out
    ///      mid-transfer.
    modifier onlyAgentOwner(uint256 agentId) {
        if (identityRegistry.ownerOf(agentId) != msg.sender) revert NotAgentOwner();
        _;
    }

    // ─── State mutators ─────────────────────────────────────────────────

    /**
     * @notice First-time publication of an agent's encryption keypair.
     *         Reverts if the agent already has a record — use {rotate} for
     *         subsequent updates so the version counter never goes backwards.
     */
    function publish(uint256 agentId, bytes32 pubkey, bytes calldata wrappedPrivkey)
        external
        onlyAgentOwner(agentId)
    {
        if (_records[agentId].version != 0) revert AlreadyInitialised(agentId);
        _validate(pubkey, wrappedPrivkey);

        _records[agentId] = KeyRecord({
            pubkey:         pubkey,
            version:        1,
            updatedAt:      uint64(block.timestamp),
            wrappedPrivkey: wrappedPrivkey
        });
        emit KeyPublished(agentId, pubkey, 1, msg.sender, uint64(block.timestamp));
    }

    /**
     * @notice Rotate an agent's keypair. Atomic — pubkey, wrapped privkey,
     *         and version are all updated in one SSTORE batch so no observer
     *         can ever read a half-rotated record.
     *
     * @dev    Increments `version` by 1. Clients use this as the "epoch" for
     *         per-upload wrapped AES keys; a wrapped key under epoch N becomes
     *         undecryptable once the owner rotates to epoch N+1 (this is the
     *         desired behaviour for "expire all sealed content" flows).
     */
    function rotate(uint256 agentId, bytes32 newPubkey, bytes calldata newWrappedPrivkey)
        external
        onlyAgentOwner(agentId)
    {
        KeyRecord storage rec = _records[agentId];
        if (rec.version == 0) revert NotYetInitialised(agentId);
        _validate(newPubkey, newWrappedPrivkey);

        bytes32 oldPubkey = rec.pubkey;
        uint64 nextVersion = rec.version + 1;

        rec.pubkey         = newPubkey;
        rec.version        = nextVersion;
        rec.updatedAt      = uint64(block.timestamp);
        rec.wrappedPrivkey = newWrappedPrivkey;

        emit KeyRotated(agentId, oldPubkey, newPubkey, nextVersion, msg.sender, uint64(block.timestamp));
    }

    /// @dev Shared validation for publish/rotate. Kept private so future
    ///      changes (e.g., requiring a non-low-order pubkey) live in one place.
    function _validate(bytes32 pubkey, bytes calldata wrappedPrivkey) private pure {
        if (pubkey == bytes32(0)) revert ZeroPubkey();
        if (wrappedPrivkey.length == 0) revert WrappedPrivkeyEmpty();
        if (wrappedPrivkey.length > MAX_WRAPPED_PRIVKEY_BYTES) {
            revert WrappedPrivkeyTooLarge(wrappedPrivkey.length, MAX_WRAPPED_PRIVKEY_BYTES);
        }
    }

    // ─── Views ──────────────────────────────────────────────────────────

    function getPubkey(uint256 agentId) external view returns (bytes32) {
        return _records[agentId].pubkey;
    }

    function getWrappedPrivkey(uint256 agentId) external view returns (bytes memory) {
        return _records[agentId].wrappedPrivkey;
    }

    function getVersion(uint256 agentId) external view returns (uint64) {
        return _records[agentId].version;
    }

    function isInitialised(uint256 agentId) external view returns (bool) {
        return _records[agentId].version != 0;
    }

    /// @notice Single-call accessor returning everything a client needs to
    ///         encrypt to (or decrypt from) the agent — saves an RPC round
    ///         trip vs. four separate getters.
    function getRecord(uint256 agentId)
        external
        view
        returns (bytes32 pubkey, uint64 version, uint64 updatedAt, bytes memory wrappedPrivkey)
    {
        KeyRecord storage rec = _records[agentId];
        return (rec.pubkey, rec.version, rec.updatedAt, rec.wrappedPrivkey);
    }
}
