// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {EvolutionTypes} from "./hooks/EvolutionTypes.sol";

/**
 * @title  AgentCollectionEIP712
 * @notice External library handling EIP-712 typed-data hashing and signature
 *         recovery for {AgentCollectionImpl}'s `commitEvolution` keeper flow.
 *
 * @dev    Pure functions only — no storage, no privileged callers. Linked
 *         into the impl at compile time and dispatched via DELEGATECALL,
 *         keeping the impl bytecode well under EIP-170.
 */
library AgentCollectionEIP712 {
    bytes32 internal constant COMMIT_TYPEHASH = keccak256(
        "Commit(uint256 agentId,bytes32 triggerKind,bytes32 resultHash,uint256 nonce,uint256 deadline)"
    );

    bytes32 internal constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    /// @notice Recreate the per-collection EIP-712 domain separator. The
    ///         caller supplies its own {ERC721.name} so the impl never has to
    ///         materialise the constant in its own bytecode.
    function domainSeparator(
        string memory collectionName,
        address verifyingContract
    ) external view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256(bytes(collectionName)),
            keccak256(bytes("1")),
            block.chainid,
            verifyingContract
        ));
    }

    /// @notice Hash an {EvolutionResult} for inclusion in the Commit struct.
    function hashResult(EvolutionTypes.EvolutionResult memory r) external pure returns (bytes32) {
        return keccak256(abi.encode(
            r.svgChanged,
            keccak256(bytes(r.newSvgUri)),
            keccak256(r.newSvgInline),
            r.newStateHash,
            r.requiresKeeper
        ));
    }

    /**
     * @notice Recover the signer of a `Commit` for the given agent and
     *         keeper-supplied parameters.
     * @return signer Recovered address (compare against the configured keeper).
     */
    function recoverCommitSigner(
        bytes32 domainSep,
        uint256 agentId,
        bytes32 triggerKind,
        bytes32 resultHash,
        uint256 nonce,
        uint256 deadline,
        bytes memory signature
    ) external pure returns (address signer) {
        bytes32 structHash = keccak256(abi.encode(
            COMMIT_TYPEHASH, agentId, triggerKind, resultHash, nonce, deadline
        ));
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSep, structHash);
        signer = ECDSA.recover(digest, signature);
    }

    /// @notice Mirrors the impl's {commitEvolution} validation block end-to-end:
    ///         deadline check, monotonic nonce check, EIP-712 digest recovery,
    ///         and signer == keeper assertion. Pulled out so the impl bytecode
    ///         stays under the EIP-170 ceiling. Returns silently on success.
    /// @dev    The impl supplies the *current* on-chain nonce; this function
    ///         enforces strictly-increasing semantics. Caller writes
    ///         `commitNonce[agentId] = nonce` after this returns.
    error HookKeeperNotSet();
    error HookSignatureExpired();
    error HookSignatureInvalid();
    error HookNonceUsed();

    function verifyCommit(
        string memory collectionName,
        address keeper,
        uint256 agentId,
        bytes32 triggerKind,
        EvolutionTypes.EvolutionResult calldata result,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature,
        uint256 currentNonce
    ) external view {
        if (keeper == address(0)) revert HookKeeperNotSet();
        if (block.timestamp > deadline) revert HookSignatureExpired();
        if (nonce <= currentNonce) revert HookNonceUsed();

        bytes32 ds = keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256(bytes(collectionName)),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
        bytes32 rh = keccak256(abi.encode(
            result.svgChanged,
            keccak256(bytes(result.newSvgUri)),
            keccak256(result.newSvgInline),
            result.newStateHash,
            result.requiresKeeper
        ));
        bytes32 structHash = keccak256(abi.encode(
            COMMIT_TYPEHASH, agentId, triggerKind, rh, nonce, deadline
        ));
        bytes32 digest = MessageHashUtils.toTypedDataHash(ds, structHash);
        address signer = ECDSA.recover(digest, signature);
        if (signer != keeper) revert HookSignatureInvalid();
    }
}
