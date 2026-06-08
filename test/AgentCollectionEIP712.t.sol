// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentCollectionEIP712} from "../src/AgentCollectionEIP712.sol";
import {EvolutionTypes} from "../src/hooks/EvolutionTypes.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title  AgentCollectionEIP712Test
 * @notice Unit tests for the EIP-712 helper library used by the impl's
 *         keeper-signed `commitEvolution` flow. The library is the source
 *         of truth for the domain separator and the Commit typehash —
 *         drift here would silently invalidate every keeper signature
 *         issued by the off-chain service.
 *
 *         The `verifyCommit` happy-path is intentionally left to the
 *         integration suite (`test/AgentCollectionFullStack.t.sol`)
 *         because verifyCommit re-derives the domain separator using
 *         the library's own deployed address (`address(this)` resolves
 *         to the library when called externally), which the test harness
 *         cannot ergonomically pre-image. The revert paths *can* be
 *         tested in isolation because they fire before signature recovery.
 */
contract AgentCollectionEIP712Test is Test {
    // Deterministic keeper signer.
    uint256 internal constant KEEPER_PK = 0xBEEF;
    address internal keeper;

    address internal verifyingContract = address(0xC0FFEE);
    string  internal constant COLLECTION_NAME = "Agent Genesis";

    function setUp() public {
        keeper = vm.addr(KEEPER_PK);
    }

    // ─── domainSeparator pinning ──────────────────────────────────────────

    function test_domainSeparator_isStable() public view {
        bytes32 a = AgentCollectionEIP712.domainSeparator(COLLECTION_NAME, verifyingContract);
        bytes32 b = AgentCollectionEIP712.domainSeparator(COLLECTION_NAME, verifyingContract);
        assertEq(a, b, "must be deterministic for same inputs");
    }

    function test_domainSeparator_differsByCollectionName() public view {
        bytes32 a = AgentCollectionEIP712.domainSeparator("A", verifyingContract);
        bytes32 b = AgentCollectionEIP712.domainSeparator("B", verifyingContract);
        assertTrue(a != b, "collection name must domain-separate");
    }

    function test_domainSeparator_differsByVerifyingContract() public view {
        bytes32 a = AgentCollectionEIP712.domainSeparator(COLLECTION_NAME, address(0xAA));
        bytes32 b = AgentCollectionEIP712.domainSeparator(COLLECTION_NAME, address(0xBB));
        assertTrue(a != b, "verifyingContract must domain-separate");
    }

    function test_domainSeparator_differsByChainId() public {
        bytes32 a = AgentCollectionEIP712.domainSeparator(COLLECTION_NAME, verifyingContract);
        vm.chainId(99);
        bytes32 b = AgentCollectionEIP712.domainSeparator(COLLECTION_NAME, verifyingContract);
        assertTrue(a != b, "chainid must domain-separate");
    }

    // ─── hashResult ───────────────────────────────────────────────────────

    function test_hashResult_zeroStruct() public pure {
        EvolutionTypes.EvolutionResult memory r;
        bytes32 h = AgentCollectionEIP712.hashResult(r);
        bytes32 expected = keccak256(abi.encode(
            false,
            keccak256(bytes("")),
            keccak256(""),
            bytes32(0),
            false
        ));
        assertEq(h, expected);
    }

    function test_hashResult_changesWithEachField() public pure {
        EvolutionTypes.EvolutionResult memory base;
        bytes32 h0 = AgentCollectionEIP712.hashResult(base);

        EvolutionTypes.EvolutionResult memory svgChanged;
        svgChanged.svgChanged = true;
        assertTrue(AgentCollectionEIP712.hashResult(svgChanged) != h0);

        EvolutionTypes.EvolutionResult memory uri;
        uri.newSvgUri = "ipfs://abc";
        assertTrue(AgentCollectionEIP712.hashResult(uri) != h0);

        EvolutionTypes.EvolutionResult memory inline_;
        inline_.newSvgInline = "<svg/>";
        assertTrue(AgentCollectionEIP712.hashResult(inline_) != h0);

        EvolutionTypes.EvolutionResult memory state;
        state.newStateHash = keccak256("state");
        assertTrue(AgentCollectionEIP712.hashResult(state) != h0);

        EvolutionTypes.EvolutionResult memory keeper_;
        keeper_.requiresKeeper = true;
        assertTrue(AgentCollectionEIP712.hashResult(keeper_) != h0);
    }

    // ─── recoverCommitSigner ──────────────────────────────────────────────

    function test_recoverCommitSigner_roundTrip() public view {
        bytes32 ds = AgentCollectionEIP712.domainSeparator(COLLECTION_NAME, verifyingContract);
        EvolutionTypes.EvolutionResult memory r;
        r.svgChanged = true;
        r.newSvgInline = "<svg>r1</svg>";
        bytes32 rh = AgentCollectionEIP712.hashResult(r);

        uint256 agentId = 7;
        bytes32 trig = bytes32("custom");
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signCommit(ds, agentId, trig, rh, nonce, deadline);
        address recovered = AgentCollectionEIP712.recoverCommitSigner(ds, agentId, trig, rh, nonce, deadline, sig);
        assertEq(recovered, keeper);
    }

    function test_recoverCommitSigner_tamperedFieldChangesRecoveredAddress() public view {
        // EIP-712 invariant: any field tampered should fail signer recovery
        // to the original signer.
        bytes32 ds = AgentCollectionEIP712.domainSeparator(COLLECTION_NAME, verifyingContract);
        EvolutionTypes.EvolutionResult memory r;
        bytes32 rh = AgentCollectionEIP712.hashResult(r);
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signCommit(ds, 7, bytes32("a"), rh, 1, deadline);

        // Tamper each field separately.
        assertTrue(AgentCollectionEIP712.recoverCommitSigner(ds, 8, bytes32("a"), rh, 1, deadline, sig) != keeper, "agentId");
        assertTrue(AgentCollectionEIP712.recoverCommitSigner(ds, 7, bytes32("b"), rh, 1, deadline, sig) != keeper, "trig");
        assertTrue(AgentCollectionEIP712.recoverCommitSigner(ds, 7, bytes32("a"), rh, 2, deadline, sig) != keeper, "nonce");
        assertTrue(AgentCollectionEIP712.recoverCommitSigner(ds, 7, bytes32("a"), rh, 1, deadline + 1, sig) != keeper, "deadline");
    }

    // ─── verifyCommit revert paths ────────────────────────────────────────
    // These revert BEFORE signature recovery, so they don't depend on the
    // library's runtime address resolution.

    function test_verifyCommit_revertsOnUnsetKeeper() public {
        EvolutionTypes.EvolutionResult memory r;
        bytes memory sig = new bytes(65);
        vm.expectRevert(AgentCollectionEIP712.HookKeeperNotSet.selector);
        AgentCollectionEIP712.verifyCommit(
            COLLECTION_NAME, address(0), 1, bytes32("t"), r, 1, block.timestamp + 1, sig, 0
        );
    }

    function test_verifyCommit_revertsOnExpiredDeadline() public {
        EvolutionTypes.EvolutionResult memory r;
        bytes memory sig = new bytes(65);
        // Move forward so block.timestamp > deadline cleanly.
        vm.warp(1000);
        vm.expectRevert(AgentCollectionEIP712.HookSignatureExpired.selector);
        AgentCollectionEIP712.verifyCommit(
            COLLECTION_NAME, keeper, 1, bytes32("t"), r, 1, 999, sig, 0
        );
    }

    function test_verifyCommit_revertsOnReplayedNonce() public {
        EvolutionTypes.EvolutionResult memory r;
        bytes memory sig = new bytes(65);
        vm.expectRevert(AgentCollectionEIP712.HookNonceUsed.selector);
        AgentCollectionEIP712.verifyCommit(
            COLLECTION_NAME, keeper, 1, bytes32("t"), r, 5, block.timestamp + 1 hours, sig, 5
        );
    }

    function test_verifyCommit_revertsOnNonceEqualToCurrent() public {
        // Nonce must be STRICTLY greater than currentNonce — equal is rejected.
        EvolutionTypes.EvolutionResult memory r;
        bytes memory sig = new bytes(65);
        vm.expectRevert(AgentCollectionEIP712.HookNonceUsed.selector);
        AgentCollectionEIP712.verifyCommit(
            COLLECTION_NAME, keeper, 1, bytes32("t"), r, 3, block.timestamp + 1 hours, sig, 3
        );
    }

    // ─── helpers ──────────────────────────────────────────────────────────

    function _signCommit(
        bytes32 domainSep,
        uint256 agentId,
        bytes32 triggerKind,
        bytes32 resultHash,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 typehash = keccak256("Commit(uint256 agentId,bytes32 triggerKind,bytes32 resultHash,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typehash, agentId, triggerKind, resultHash, nonce, deadline));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSep, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEEPER_PK, digest);
        return abi.encodePacked(r, s, v);
    }
}
