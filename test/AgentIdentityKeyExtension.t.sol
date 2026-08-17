// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentIdentityKeyExtension} from "../src/AgentIdentityKeyExtension.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Minimal stub honouring only `ownerOf`, the sole method
///      AgentIdentityKeyExtension calls on the identity registry.
contract MockKeyIdentityRegistry {
    mapping(uint256 => address) public owners;
    function setOwner(uint256 id, address who) external { owners[id] = who; }
    function ownerOf(uint256 id) external view returns (address) { return owners[id]; }
}

contract AgentIdentityKeyExtensionTest is Test {
    AgentIdentityKeyExtension internal ext;
    MockKeyIdentityRegistry internal idReg;

    address internal admin    = makeAddr("admin");
    address internal agentEoa = makeAddr("agent-owner");
    address internal buyer    = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant AGENT_A = 1;
    uint256 internal constant AGENT_B = 2;

    // x-only secp256k1 pubkeys are 32 bytes, so an npub lands in bytes32
    // verbatim. These stand in for real ones.
    bytes32 internal constant NPUB_1 = keccak256("npub-primary-1");
    bytes32 internal constant NPUB_2 = keccak256("npub-secondary-2");
    bytes32 internal constant NPUB_3 = keccak256("npub-tertiary-3");

    string constant KIND = "nostr";

    // Mirrors AgentIdentityRegistry's PERM_* bitmap, which this
    // extension shares rather than inventing a second scheme.
    uint96 internal constant PERM_PAY = 1 << 0;
    uint96 internal constant PERM_CONTEXT_WRITE = 1 << 2;

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
    event PrimaryKeyRotated(
        uint256 indexed agentId,
        bytes32 indexed oldPubkey,
        bytes32 indexed newPubkey,
        address owner
    );
    event KeyDeactivated(uint256 indexed agentId, bytes32 indexed pubkey, uint256 index);

    function setUp() public {
        idReg = new MockKeyIdentityRegistry();
        idReg.setOwner(AGENT_A, agentEoa);
        idReg.setOwner(AGENT_B, buyer);

        AgentIdentityKeyExtension impl = new AgentIdentityKeyExtension();
        bytes memory init = abi.encodeCall(AgentIdentityKeyExtension.initialize, (address(idReg)));
        vm.prank(admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        ext = AgentIdentityKeyExtension(address(proxy));
    }

    function _registerPrimary(uint256 agentId, address owner_, bytes32 pubkey) internal {
        vm.prank(owner_);
        ext.registerPrimaryKey(agentId, pubkey, KIND, "primary", PERM_PAY);
    }

    // ── init ──────────────────────────────────────────────────────

    function test_initialize_setsOwnerAndRegistry() public view {
        assertEq(ext.owner(), admin);
        assertEq(address(ext.identityRegistry()), address(idReg));
    }

    function test_initialize_rejectsZeroRegistry() public {
        AgentIdentityKeyExtension impl = new AgentIdentityKeyExtension();
        bytes memory init = abi.encodeCall(AgentIdentityKeyExtension.initialize, (address(0)));
        // A zero registry would make ownerOf revert on every call, so the
        // extension would deploy and then reject every write.
        vm.expectRevert(AgentIdentityKeyExtension.ZeroIdentityRegistry.selector);
        new ERC1967Proxy(address(impl), init);
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        ext.initialize(address(idReg));
    }

    // ── primary key: "minted with an identity" ────────────────────

    function test_registerPrimaryKey_ownerCanRegister() public {
        vm.expectEmit(true, true, true, true, address(ext));
        emit PrimaryKeyRegistered(AGENT_A, NPUB_1, agentEoa, KIND, "primary", PERM_PAY);
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);

        assertEq(ext.keyCount(AGENT_A), 1);
        AgentIdentityKeyExtension.IdentityKey memory k = ext.primaryKey(AGENT_A);
        assertEq(k.pubkey, NPUB_1);
        assertEq(k.keyKind, KIND);
        assertEq(k.permissions, PERM_PAY);
        assertTrue(k.active);
        assertEq(k.createdAt, uint48(block.timestamp));
    }

    function test_registerPrimaryKey_strangerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(AgentIdentityKeyExtension.NotOwner.selector);
        ext.registerPrimaryKey(AGENT_A, NPUB_1, KIND, "primary", PERM_PAY);
    }

    /// Same hole that existed in AgentAvatarExtension: an unowned token
    /// resolves to address(0), so a `!= msg.sender` check alone would let
    /// address(0) claim an identity for a token that does not exist.
    function test_registerPrimaryKey_unmintedTokenIsWritableByNobody() public {
        uint256 unminted = 999;
        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.NotExists.selector);
        ext.registerPrimaryKey(unminted, NPUB_1, KIND, "primary", PERM_PAY);

        vm.prank(address(0));
        vm.expectRevert(AgentIdentityKeyExtension.NotExists.selector);
        ext.registerPrimaryKey(unminted, NPUB_1, KIND, "primary", PERM_PAY);
    }

    function test_registerPrimaryKey_twiceReverts() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.PrimaryAlreadySet.selector);
        ext.registerPrimaryKey(AGENT_A, NPUB_2, KIND, "second attempt", PERM_PAY);
    }

    function test_registerPrimaryKey_rejectsEmptyInputs() public {
        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.EmptyInput.selector);
        ext.registerPrimaryKey(AGENT_A, bytes32(0), KIND, "primary", PERM_PAY);

        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.EmptyInput.selector);
        ext.registerPrimaryKey(AGENT_A, NPUB_1, "", "primary", PERM_PAY);
    }

    function test_registerPrimaryKey_rejectsOversizedStrings() public {
        string memory longKind = _repeat("k", ext.MAX_KEY_KIND_BYTES() + 1);
        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.TooLarge.selector);
        ext.registerPrimaryKey(AGENT_A, NPUB_1, longKind, "primary", PERM_PAY);

        string memory longLabel = _repeat("l", ext.MAX_LABEL_BYTES() + 1);
        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.TooLarge.selector);
        ext.registerPrimaryKey(AGENT_A, NPUB_1, KIND, longLabel, PERM_PAY);
    }

    function test_registerPrimaryKey_atExactlyMaxStringLengthsIsAccepted() public {
        string memory kindAtLimit = _repeat("k", ext.MAX_KEY_KIND_BYTES());
        string memory labelAtLimit = _repeat("l", ext.MAX_LABEL_BYTES());
        vm.prank(agentEoa);
        ext.registerPrimaryKey(AGENT_A, NPUB_1, kindAtLimit, labelAtLimit, PERM_PAY);
        assertEq(ext.primaryKey(AGENT_A).keyKind, kindAtLimit);
    }

    function test_primaryKey_revertsWhenUnset() public {
        vm.expectRevert(AgentIdentityKeyExtension.PrimaryNotSet.selector);
        ext.primaryKey(AGENT_A);
    }

    // ── additional keys: "add more later, like more TBAs" ─────────

    function test_addKey_appendsAndIndexes() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);

        vm.expectEmit(true, true, true, true, address(ext));
        emit KeyAdded(AGENT_A, NPUB_2, agentEoa, 1, KIND, "laptop", PERM_CONTEXT_WRITE);
        vm.prank(agentEoa);
        uint256 idx = ext.addKey(AGENT_A, NPUB_2, KIND, "laptop", PERM_CONTEXT_WRITE);

        assertEq(idx, 1, "second key must land at index 1");
        assertEq(ext.keyCount(AGENT_A), 2);
        assertEq(ext.getKey(AGENT_A, 1).pubkey, NPUB_2);
        // The primary must be untouched by an append.
        assertEq(ext.primaryKey(AGENT_A).pubkey, NPUB_1);
    }

    /// Index 0 has to be the primary, or every consumer resolving "the
    /// agent's identity" by index gets an arbitrary extra key instead.
    function test_addKey_withoutPrimaryReverts() public {
        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.PrimaryNotSet.selector);
        ext.addKey(AGENT_A, NPUB_2, KIND, "laptop", PERM_CONTEXT_WRITE);
    }

    function test_addKey_strangerReverts() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        vm.prank(stranger);
        vm.expectRevert(AgentIdentityKeyExtension.NotOwner.selector);
        ext.addKey(AGENT_A, NPUB_2, KIND, "laptop", PERM_CONTEXT_WRITE);
    }

    /// One pubkey must never claim to speak for two agents — the
    /// reverse-lookup invariant the registry enforces for TBA addresses.
    function test_addKey_pubkeyCannotBeBoundTwice() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        _registerPrimary(AGENT_B, buyer, NPUB_2);

        // Same agent, same key twice.
        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.AlreadyBound.selector);
        ext.addKey(AGENT_A, NPUB_1, KIND, "dupe", PERM_PAY);

        // Different agent trying to claim agent A's key.
        vm.prank(buyer);
        vm.expectRevert(AgentIdentityKeyExtension.AlreadyBound.selector);
        ext.addKey(AGENT_B, NPUB_1, KIND, "steal", PERM_PAY);
    }

    function test_addKey_capIsEnforced() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        uint256 max = ext.MAX_KEYS_PER_AGENT();
        // Fill to the cap (primary already occupies one slot).
        for (uint256 i = 1; i < max; ++i) {
            vm.prank(agentEoa);
            ext.addKey(AGENT_A, keccak256(abi.encode("fill", i)), KIND, "fill", 0);
        }
        assertEq(ext.keyCount(AGENT_A), max);

        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.MaxKeys.selector);
        ext.addKey(AGENT_A, keccak256("one-too-many"), KIND, "over", 0);
    }

    // ── rotation ──────────────────────────────────────────────────

    function test_rotatePrimaryKey_replacesAtomically() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);

        vm.expectEmit(true, true, true, true, address(ext));
        emit PrimaryKeyRotated(AGENT_A, NPUB_1, NPUB_2, agentEoa);
        vm.prank(agentEoa);
        ext.rotatePrimaryKey(AGENT_A, NPUB_2, KIND, "rotated", PERM_PAY);

        assertEq(ext.primaryKey(AGENT_A).pubkey, NPUB_2);
        assertEq(ext.keyCount(AGENT_A), 1, "rotation must replace, not append");

        // The retired key must no longer resolve to the agent, or a
        // verifier would accept a key the owner has abandoned.
        (,, bool boundOld,,) = ext.resolveKey(NPUB_1);
        assertFalse(boundOld, "old pubkey still resolves after rotation");
        (uint256 agentId,, bool boundNew, bool active,) = ext.resolveKey(NPUB_2);
        assertTrue(boundNew);
        assertTrue(active);
        assertEq(agentId, AGENT_A);
    }

    function test_rotatePrimaryKey_toSameKeyReverts() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.Unchanged.selector);
        ext.rotatePrimaryKey(AGENT_A, NPUB_1, KIND, "same", PERM_PAY);
    }

    /// Rotation unbinds the old key before binding the new one, so a
    /// rejected rotation must leave the original binding intact rather
    /// than an agent with no resolvable identity.
    function test_rotatePrimaryKey_toBoundKeyRevertsAndKeepsOldBinding() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        _registerPrimary(AGENT_B, buyer, NPUB_2);

        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.AlreadyBound.selector);
        ext.rotatePrimaryKey(AGENT_A, NPUB_2, KIND, "steal", PERM_PAY);

        assertEq(ext.primaryKey(AGENT_A).pubkey, NPUB_1, "failed rotation lost the primary");
        (uint256 agentId,, bool bound,,) = ext.resolveKey(NPUB_1);
        assertTrue(bound, "failed rotation unbound the old key");
        assertEq(agentId, AGENT_A);
    }

    function test_rotatePrimaryKey_withoutPrimaryReverts() public {
        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.PrimaryNotSet.selector);
        ext.rotatePrimaryKey(AGENT_A, NPUB_1, KIND, "rotated", PERM_PAY);
    }

    // ── deactivation ──────────────────────────────────────────────

    function test_deactivateKey_freesPubkeyAndKeepsHistory() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        vm.prank(agentEoa);
        ext.addKey(AGENT_A, NPUB_2, KIND, "laptop", PERM_CONTEXT_WRITE);

        vm.expectEmit(true, true, false, true, address(ext));
        emit KeyDeactivated(AGENT_A, NPUB_2, 1);
        vm.prank(agentEoa);
        ext.deactivateKey(AGENT_A, NPUB_2);

        // Record survives for history, but carries no authority.
        AgentIdentityKeyExtension.IdentityKey memory k = ext.getKey(AGENT_A, 1);
        assertFalse(k.active);
        assertEq(k.permissions, 0, "a revoked key must not keep permissions");
        assertEq(k.pubkey, NPUB_2, "history must still name the key");
        assertEq(ext.keyCount(AGENT_A), 2, "deactivation must not shrink the list");

        (,, bool bound,,) = ext.resolveKey(NPUB_2);
        assertFalse(bound, "deactivated key must not resolve");

        // Freed, so it can be re-registered — as revokeSubaccount frees
        // an address.
        vm.prank(agentEoa);
        uint256 idx = ext.addKey(AGENT_A, NPUB_2, KIND, "relinked", PERM_PAY);
        assertEq(idx, 2);
        (uint256 agentId,, bool reBound, bool active,) = ext.resolveKey(NPUB_2);
        assertTrue(reBound);
        assertTrue(active);
        assertEq(agentId, AGENT_A);
    }

    /// An agent with nothing at index 0 is indistinguishable from one
    /// that never registered, so the primary is rotate-only.
    function test_deactivateKey_primaryCannotBeDeactivated() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.CannotDeactivatePrimary.selector);
        ext.deactivateKey(AGENT_A, NPUB_1);
    }

    function test_deactivateKey_twiceReverts() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        vm.prank(agentEoa);
        ext.addKey(AGENT_A, NPUB_2, KIND, "laptop", 0);
        vm.prank(agentEoa);
        ext.deactivateKey(AGENT_A, NPUB_2);

        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.NotBound.selector);
        ext.deactivateKey(AGENT_A, NPUB_2);
    }

    function test_deactivateKey_otherAgentsKeyReverts() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        _registerPrimary(AGENT_B, buyer, NPUB_2);
        vm.prank(buyer);
        ext.addKey(AGENT_B, NPUB_3, KIND, "b-extra", 0);

        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.NotBound.selector);
        ext.deactivateKey(AGENT_A, NPUB_3);
    }

    // ── permissions ───────────────────────────────────────────────

    function test_updateKeyPermissions_changesBitmap() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        vm.prank(agentEoa);
        ext.updateKeyPermissions(AGENT_A, NPUB_1, PERM_PAY | PERM_CONTEXT_WRITE);
        assertEq(ext.primaryKey(AGENT_A).permissions, PERM_PAY | PERM_CONTEXT_WRITE);

        (,,,, uint96 perms) = ext.resolveKey(NPUB_1);
        assertEq(perms, PERM_PAY | PERM_CONTEXT_WRITE);
    }

    function test_updateKeyPermissions_unchangedReverts() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.Unchanged.selector);
        ext.updateKeyPermissions(AGENT_A, NPUB_1, PERM_PAY);
    }

    function test_updateKeyPermissions_unboundReverts() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.NotBound.selector);
        ext.updateKeyPermissions(AGENT_A, NPUB_3, PERM_PAY);
    }

    // ── transfer semantics: the reason keys differ from TBAs ──────

    /// A TBA moves with the NFT because control there is authorisation.
    /// A key is knowledge, and the seller keeps it. So after a transfer
    /// the registered identity MUST report stale until the new owner
    /// rotates — anything else means trusting an identity the previous
    /// owner can still sign for.
    function test_keysStale_afterTransferUntilRotated() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        assertFalse(ext.keysStale(AGENT_A), "freshly registered keys are not stale");
        assertEq(ext.boundOwner(AGENT_A), agentEoa);

        // Secondary sale.
        idReg.setOwner(AGENT_A, buyer);
        assertTrue(ext.keysStale(AGENT_A), "keys must be stale for the new owner");

        // The old owner can no longer touch them.
        vm.prank(agentEoa);
        vm.expectRevert(AgentIdentityKeyExtension.NotOwner.selector);
        ext.rotatePrimaryKey(AGENT_A, NPUB_2, KIND, "old owner", PERM_PAY);

        // Rotate-on-acquire clears it.
        vm.prank(buyer);
        ext.rotatePrimaryKey(AGENT_A, NPUB_2, KIND, "buyer key", PERM_PAY);
        assertFalse(ext.keysStale(AGENT_A), "rotation by the new owner must clear staleness");
        assertEq(ext.boundOwner(AGENT_A), buyer);
        assertEq(ext.primaryKey(AGENT_A).pubkey, NPUB_2);
    }

    function test_keysStale_falseWhenNoKeysRegistered() public view {
        // Nothing registered is not the same as something inherited.
        assertFalse(ext.keysStale(AGENT_A));
    }

    function test_keysStale_trueWhenTokenBurned() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        idReg.setOwner(AGENT_A, address(0));
        assertTrue(ext.keysStale(AGENT_A), "a burned token's keys cannot be authoritative");
    }

    /// Staleness is per-agent: one agent changing hands must not
    /// invalidate another's identity.
    function test_keysStale_isPerAgent() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        _registerPrimary(AGENT_B, buyer, NPUB_2);

        idReg.setOwner(AGENT_A, stranger);
        assertTrue(ext.keysStale(AGENT_A));
        assertFalse(ext.keysStale(AGENT_B), "staleness leaked across agents");
    }

    // ── views ─────────────────────────────────────────────────────

    function test_resolveKey_unboundReturnsFalse() public view {
        (uint256 agentId, uint256 index, bool bound, bool active, uint96 perms) = ext.resolveKey(NPUB_3);
        assertEq(agentId, 0);
        assertEq(index, 0);
        assertFalse(bound);
        assertFalse(active);
        assertEq(perms, 0);
    }

    function test_getKeys_returnsFullHistory() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        vm.prank(agentEoa);
        ext.addKey(AGENT_A, NPUB_2, KIND, "laptop", 0);
        vm.prank(agentEoa);
        ext.deactivateKey(AGENT_A, NPUB_2);

        AgentIdentityKeyExtension.IdentityKey[] memory all = ext.getKeys(AGENT_A);
        assertEq(all.length, 2);
        assertTrue(all[0].active);
        assertFalse(all[1].active);
    }

    function test_getKey_outOfRangeReverts() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        vm.expectRevert(AgentIdentityKeyExtension.NotBound.selector);
        ext.getKey(AGENT_A, 1);
    }

    // ── upgrade ───────────────────────────────────────────────────

    function test_authorizeUpgrade_onlyOwner() public {
        AgentIdentityKeyExtension impl2 = new AgentIdentityKeyExtension();
        vm.prank(stranger);
        vm.expectRevert();
        ext.upgradeToAndCall(address(impl2), "");
    }

    /// An upgrade that loses the key bindings would leave agents whose
    /// identities silently stop resolving, with nothing reverting to say
    /// so. Assert the state, not just that the call succeeded.
    function test_upgrade_preservesKeysAndBindings() public {
        _registerPrimary(AGENT_A, agentEoa, NPUB_1);
        vm.prank(agentEoa);
        ext.addKey(AGENT_A, NPUB_2, KIND, "laptop", PERM_CONTEXT_WRITE);
        _registerPrimary(AGENT_B, buyer, NPUB_3);

        AgentIdentityKeyExtension impl2 = new AgentIdentityKeyExtension();
        vm.prank(admin);
        ext.upgradeToAndCall(address(impl2), "");

        assertEq(ext.keyCount(AGENT_A), 2, "key list lost across upgrade");
        assertEq(ext.primaryKey(AGENT_A).pubkey, NPUB_1, "primary lost across upgrade");
        assertEq(ext.getKey(AGENT_A, 1).permissions, PERM_CONTEXT_WRITE, "permissions lost across upgrade");
        assertEq(ext.primaryKey(AGENT_B).pubkey, NPUB_3, "second agent lost across upgrade");
        assertEq(ext.boundOwner(AGENT_A), agentEoa, "bound owner lost across upgrade");
        assertEq(ext.owner(), admin);
        assertEq(address(ext.identityRegistry()), address(idReg));

        // Reverse lookups must survive too: they live in separate
        // mappings a layout change could shift independently.
        (uint256 agentId,, bool bound,,) = ext.resolveKey(NPUB_2);
        assertTrue(bound, "reverse lookup lost across upgrade");
        assertEq(agentId, AGENT_A);

        // And the contract stays writable.
        vm.prank(agentEoa);
        ext.addKey(AGENT_A, keccak256("post-upgrade"), KIND, "new", 0);
        assertEq(ext.keyCount(AGENT_A), 3);
    }

    // ── fuzz ──────────────────────────────────────────────────────

    function testFuzz_registerPrimaryKey_arbitraryValidInput(
        uint256 agentId,
        bytes32 pubkey,
        uint96 permissions
    ) public {
        vm.assume(pubkey != bytes32(0));
        // address(0) can never be an owner, and agentId must be ownable.
        agentId = bound(agentId, 1, type(uint128).max);
        idReg.setOwner(agentId, agentEoa);

        vm.prank(agentEoa);
        ext.registerPrimaryKey(agentId, pubkey, KIND, "fuzz", permissions);

        AgentIdentityKeyExtension.IdentityKey memory k = ext.primaryKey(agentId);
        assertEq(k.pubkey, pubkey);
        assertEq(k.permissions, permissions);
        assertTrue(k.active);
        (uint256 resolved,, bool bound,,) = ext.resolveKey(pubkey);
        assertTrue(bound);
        assertEq(resolved, agentId);
        assertFalse(ext.keysStale(agentId));
    }

    function _repeat(string memory unit, uint256 times) internal pure returns (string memory) {
        bytes memory u = bytes(unit);
        bytes memory buf = new bytes(u.length * times);
        for (uint256 i; i < times; ++i) {
            for (uint256 j; j < u.length; ++j) {
                buf[i * u.length + j] = u[j];
            }
        }
        return string(buf);
    }
}
