// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

/**
 * @title IAgentLinkAttester
 * @notice Reference interface for external attester contracts that bridge
 *         cross-chain or proof-based identity claims into
 *         `AgentLinkedAccountRegistry`.
 *
 *         An attester is the trust anchor for one specific proof system:
 *         a LayerZero endpoint listener, a CCIP receiver, a Hyperlane
 *         mailbox handler, a Wormhole VAA verifier, an Eigenlayer AVS
 *         attestation aggregator, or a custom Merkle-proof verifier.
 *
 *         The attester MUST verify the underlying claim against its proof
 *         system BEFORE calling `AgentLinkedAccountRegistry.linkAccountAttested`.
 *         The registry treats `msg.sender` as authoritative — if a
 *         malicious attester is registered, it can link arbitrary
 *         accounts to any agent. Registrations are owner-gated and
 *         revocable.
 *
 *         This interface is advisory. Concrete attesters do not have to
 *         implement it — the registry only checks
 *         `trustedAttesters[msg.sender]` — but implementing it gives
 *         off-chain indexers a uniform handle for discovery.
 */
interface IAgentLinkAttester {
    /**
     * @notice Machine-readable tag identifying the proof system this
     *         attester anchors. Conventional values:
     *           "layerzero" | "ccip" | "hyperlane" | "wormhole"
     *         | "axelar"    | "merkle" | "eigenlayer-avs" | "custom"
     */
    function attesterKind() external view returns (string memory);

    /**
     * @notice Address of the registry this attester forwards to. Lets
     *         indexers verify the attester is wired to the expected
     *         registry without trusting off-chain configuration.
     */
    function registry() external view returns (address);

    /**
     * @notice Owner-side admin path that an off-chain operator hits to
     *         actually submit a proof. Concrete attesters define their
     *         own arguments (e.g. LayerZero `_lzReceive` payload, VAA
     *         bytes, Merkle proof + leaf). This signature is documentary
     *         only — DO NOT call through this interface; route via the
     *         attester's concrete entry point instead.
     */
    // function submitAttestation(bytes calldata proof) external;
}
