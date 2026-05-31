// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title EvolutionTypes
 * @notice Shared types for the SVG evolution hook system.
 * @dev Mirrors the Uniswap v4 hook lifecycle pattern, adapted for ERC-721 visual mutation.
 */
library EvolutionTypes {
    // ─────────────────────────────────────────────────────────────────────────
    // Permission flag bits — packed into a uint256 returned by `permissions()`.
    // Same composability model as Uniswap v4: a hook declares which lifecycle
    // callbacks it implements and the collection only invokes those.
    // ─────────────────────────────────────────────────────────────────────────
    uint256 internal constant FLAG_BEFORE_MINT      = 1 << 0;
    uint256 internal constant FLAG_AFTER_MINT       = 1 << 1;
    uint256 internal constant FLAG_BEFORE_TRANSFER  = 1 << 2;
    uint256 internal constant FLAG_AFTER_TRANSFER   = 1 << 3;
    uint256 internal constant FLAG_ON_TRIGGER       = 1 << 4;
    /// @dev When set, on-chain hook execution emits `EvolutionRequested` and
    ///      the actual SVG mutation must be applied via a signed `commitEvolution`
    ///      call from the configured keeper. Required for hooks that need
    ///      off-chain compute (LLM, generative re-render, oracle queries).
    uint256 internal constant FLAG_REQUIRES_KEEPER  = 1 << 5;

    // ─────────────────────────────────────────────────────────────────────────
    // Canonical trigger kinds. Hooks are free to introduce custom kinds; these
    // are the well-known ones the collection contract emits itself.
    // ─────────────────────────────────────────────────────────────────────────
    bytes32 internal constant TRIGGER_TRANSFER       = keccak256("transfer");
    bytes32 internal constant TRIGGER_TIME_TICK      = keccak256("time.tick");
    bytes32 internal constant TRIGGER_SERVICE_X402   = keccak256("service.x402");
    bytes32 internal constant TRIGGER_MEMORY_WRITE   = keccak256("memory.write");
    bytes32 internal constant TRIGGER_ORACLE_UPDATE  = keccak256("oracle.update");
    bytes32 internal constant TRIGGER_REPUTATION     = keccak256("reputation.update");
    bytes32 internal constant TRIGGER_CUSTOM         = keccak256("custom");
    bytes32 internal constant TRIGGER_STATUS_CHANGE  = keccak256("status.change");

    /**
     * @notice Result of a hook lifecycle callback or trigger evaluation.
     * @param svgChanged    true → caller should persist `newSvgUri`/`newSvgInline`
     * @param newSvgUri     non-empty → write to `_setTokenURI`
     * @param newSvgInline  non-empty → write to `_svgImages` for fully on-chain SVG
     * @param newStateHash  domain commitment for off-chain state continuity (0 → unchanged)
     * @param requiresKeeper true → don't apply inline; emit `EvolutionRequested` instead
     */
    struct EvolutionResult {
        bool    svgChanged;
        string  newSvgUri;
        bytes   newSvgInline;
        bytes32 newStateHash;
        bool    requiresKeeper;
    }

    /// @notice Empty result helper for hooks that observe-only on a given trigger.
    function noOp() internal pure returns (EvolutionResult memory r) {
        // all-zero struct is a valid no-op; explicit constructor for clarity at call sites.
        return r;
    }

    function hasFlag(uint256 flags, uint256 flag) internal pure returns (bool) {
        return (flags & flag) != 0;
    }
}
