// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentCollectionImpl}    from "../../src/AgentCollectionImpl.sol";
import {AgentCollectionFactory} from "../../src/AgentCollectionFactory.sol";
import {EvolutionTypes}         from "../../src/hooks/EvolutionTypes.sol";
import {IAgentEvolutionHook}    from "../../src/hooks/IAgentEvolutionHook.sol";
import {BaseEvolutionHook}      from "../../src/hooks/BaseEvolutionHook.sol";

/// @dev Minimal keeper-style hook so commitEvolution can target it.
contract _KeeperHook is BaseEvolutionHook {
    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER | EvolutionTypes.FLAG_REQUIRES_KEEPER;
    }
    function onTrigger(uint256, bytes32, bytes calldata)
        external pure override
        returns (EvolutionTypes.EvolutionResult memory r)
    { r.requiresKeeper = true; return r; }
}

/// @notice Audit-grade EIP-712 cross-domain replay tests for commitEvolution.
///         Verifies the typed-data binding to (chainId, verifyingContract,
///         agentId, nonce) so a signature minted in one context cannot be
///         replayed in another.
contract EIP712ReplayAudit is Test {
    AgentCollectionFactory factory;
    AgentCollectionImpl    impl;

    AgentCollectionImpl    cA; // collection A
    AgentCollectionImpl    cB; // collection B
    _KeeperHook            hook;

    address treasury = address(0xFEE);
    address creator  = address(0xC0FFEE);
    address minter   = address(0xBEEF);

    uint256 keeperPk = 0xA11CE;
    address keeper;

    function setUp() public {
        keeper = vm.addr(keeperPk);
        impl    = new AgentCollectionImpl();
        factory = new AgentCollectionFactory(address(impl), treasury);
        hook    = new _KeeperHook();

        cA = _newCollection("AlphaCol","ACOL");
        cB = _newCollection("BetaCol", "BCOL");

        for (uint8 i; i < 2; ++i) {
            AgentCollectionImpl c = i == 0 ? cA : cB;
            vm.prank(creator);
            c.setCollectionHook(address(hook));
            vm.prank(creator);
            c.setEvolutionKeeper(keeper);
            vm.prank(minter);
            c.registerAgent("a","ipfs://a"); // mint id=1
            vm.prank(minter);
            c.registerAgent("b","ipfs://b"); // mint id=2
        }
    }

    function _newCollection(string memory n, string memory s) internal returns (AgentCollectionImpl c) {
        vm.prank(creator);
        (, address addr) = factory.createCollection(n, s, 100, 1000, 500, "");
        c = AgentCollectionImpl(addr);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Cross-collection replay: a sig built for collection A's domain MUST
    // NOT be accepted by collection B (verifyingContract differs).
    // ─────────────────────────────────────────────────────────────────────
    function test_AUDIT_EIP712_crossCollectionReplayFails() public {
        EvolutionTypes.EvolutionResult memory r;
        r.newStateHash = bytes32(uint256(1));
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sigForA = _sign(cA, 1, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline);

        // Submitting against collection B reverts (signer mismatch).
        vm.expectRevert(AgentCollectionImpl.HookSignatureInvalid.selector);
        cB.commitEvolution(1, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline, sigForA);

        // Sanity: same sig is accepted by collection A.
        cA.commitEvolution(1, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline, sigForA);
        assertEq(cA.commitNonce(1), nonce);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Cross-agent replay within the same collection: a sig for agent #1
    // MUST NOT be accepted as a sig for agent #2 (agentId is in the
    // struct hash).
    // ─────────────────────────────────────────────────────────────────────
    function test_AUDIT_EIP712_crossAgentReplayFails() public {
        EvolutionTypes.EvolutionResult memory r;
        r.newStateHash = bytes32(uint256(0xa));
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sigFor1 = _sign(cA, 1, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline);

        vm.expectRevert(AgentCollectionImpl.HookSignatureInvalid.selector);
        cA.commitEvolution(2, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline, sigFor1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Cross-trigger replay: the trigger kind is part of the struct hash so
    // a sig for TRIGGER_CUSTOM MUST NOT be accepted as TRIGGER_TRANSFER.
    // ─────────────────────────────────────────────────────────────────────
    function test_AUDIT_EIP712_crossTriggerReplayFails() public {
        EvolutionTypes.EvolutionResult memory r;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sigCustom = _sign(cA, 1, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline);

        vm.expectRevert(AgentCollectionImpl.HookSignatureInvalid.selector);
        cA.commitEvolution(1, EvolutionTypes.TRIGGER_TRANSFER, r, nonce, deadline, sigCustom);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Cross-chain replay: chainId is part of the EIP-712 domain. Forking
    // chainId at runtime breaks the recovered signer.
    // ─────────────────────────────────────────────────────────────────────
    function test_AUDIT_EIP712_crossChainReplayFails() public {
        EvolutionTypes.EvolutionResult memory r;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        // Sign at chainId = 84532 (Base Sepolia)
        vm.chainId(84532);
        bytes memory sig = _sign(cA, 1, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline);

        // Replay on a different chain
        vm.chainId(1);
        vm.expectRevert(AgentCollectionImpl.HookSignatureInvalid.selector);
        cA.commitEvolution(1, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline, sig);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Nonce monotonicity: older nonces (<= current) MUST be rejected even
    // if otherwise valid. Also: nonces don't need to be sequential — a
    // jump from 1 to 100 is fine, but going back to 50 must fail.
    // ─────────────────────────────────────────────────────────────────────
    function test_AUDIT_EIP712_nonceMonotonic() public {
        EvolutionTypes.EvolutionResult memory r;
        uint256 deadline = block.timestamp + 1 hours;

        // Submit at nonce = 100 (jump).
        bytes memory s1 = _sign(cA, 1, EvolutionTypes.TRIGGER_CUSTOM, r, 100, deadline);
        cA.commitEvolution(1, EvolutionTypes.TRIGGER_CUSTOM, r, 100, deadline, s1);
        assertEq(cA.commitNonce(1), 100);

        // Older nonce 50 with a fresh signature must fail.
        bytes memory s2 = _sign(cA, 1, EvolutionTypes.TRIGGER_CUSTOM, r, 50, deadline);
        vm.expectRevert(AgentCollectionImpl.HookNonceUsed.selector);
        cA.commitEvolution(1, EvolutionTypes.TRIGGER_CUSTOM, r, 50, deadline, s2);

        // Equal nonce also fails.
        bytes memory s3 = _sign(cA, 1, EvolutionTypes.TRIGGER_CUSTOM, r, 100, deadline);
        vm.expectRevert(AgentCollectionImpl.HookNonceUsed.selector);
        cA.commitEvolution(1, EvolutionTypes.TRIGGER_CUSTOM, r, 100, deadline, s3);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Signature malleability: OpenZeppelin v5 ECDSA rejects high-S sigs.
    // We don't synthesise a malleable sig manually here (the recover path
    // would just diverge), but we assert that a tampered signature with
    // flipped S is rejected.
    // ─────────────────────────────────────────────────────────────────────
    function test_AUDIT_EIP712_tamperedSignatureRejected() public {
        EvolutionTypes.EvolutionResult memory r;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _sign(cA, 1, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline);
        // Flip a byte in the S value.
        sig[33] = bytes1(uint8(sig[33]) ^ 0x01);

        vm.expectRevert(); // OZ ECDSA reverts on InvalidSignature or recovers wrong signer
        cA.commitEvolution(1, EvolutionTypes.TRIGGER_CUSTOM, r, nonce, deadline, sig);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────
    function _digest(
        AgentCollectionImpl c,
        uint256 agentId,
        bytes32 triggerKind,
        EvolutionTypes.EvolutionResult memory r,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 typehash = keccak256(
            "Commit(uint256 agentId,bytes32 triggerKind,bytes32 resultHash,uint256 nonce,uint256 deadline)"
        );
        bytes32 resultHash = keccak256(abi.encode(
            r.svgChanged, keccak256(bytes(r.newSvgUri)), keccak256(r.newSvgInline),
            r.newStateHash, r.requiresKeeper
        ));
        bytes32 structHash = keccak256(abi.encode(typehash, agentId, triggerKind, resultHash, nonce, deadline));
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(c.name())),
            keccak256(bytes("1")),
            block.chainid,
            address(c)
        ));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _sign(
        AgentCollectionImpl c,
        uint256 agentId,
        bytes32 triggerKind,
        EvolutionTypes.EvolutionResult memory r,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        (uint8 v, bytes32 sR, bytes32 sS) = vm.sign(keeperPk, _digest(c, agentId, triggerKind, r, nonce, deadline));
        return abi.encodePacked(sR, sS, v);
    }
}
