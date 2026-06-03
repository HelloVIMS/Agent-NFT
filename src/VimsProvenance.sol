// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

/*
░██╗░░░░░░░██╗░██████╗  ██████╗░██████╗░░█████╗░██╗░░░██╗███████╗███╗░░██╗░█████╗░███╗░░██╗░█████╗░███████╗
░██║░░██╗░░██║██╔════╝  ██╔══██╗██╔══██╗██╔══██╗██║░░░██║██╔════╝████╗░██║██╔══██╗████╗░██║██╔══██╗██╔════╝
░╚██╗████╗██╔╝╚█████╗░  ██████╔╝██████╔╝██║░░██║╚██╗░██╔╝█████╗░░██╔██╗██║███████║██╔██╗██║██║░░╚═╝█████╗░░
░░████╔═████║░░╚═══██╗  ██╔═══╝░██╔══██╗██║░░██║░╚████╔╝░██╔══╝░░██║╚████║██╔══██║██║╚████║██║░░██╗██╔══╝░░
░░╚██╔╝░╚██╔╝░██████╔╝  ██║░░░░░██║░░██║╚█████╔╝░░╚██╔╝░░███████╗██║░╚███║██║░░██║██║░╚███║╚█████╔╝███████╗
░░░╚═╝░░░╚═╝░░╚═════╝░  ╚═╝░░░░░╚═╝░░╚═╝░╚════╝░░░░╚═╝░░░╚══════╝╚═╝░░╚══╝╚═╝░░╚═╝╚═╝░░╚══╝░╚════╝░╚══════╝

  VIMS Protocol — official provenance block
  Authored by the Arqon AI / VIMS team. Source-of-truth at:
      https://github.com/arqonai/vimsbot-contracts

  This contract is part of the official VIMS Protocol contract set. If you
  are reading this code outside the canonical repository above, you are
  reading a fork or a copy. The author identity below is baked into the
  deployed bytecode and surfaces via `vimsProvenance()`.
*/

/**
 * @title VimsProvenance
 * @notice Inheritable provenance block with overt + steganographic
 *         fingerprints. Inherit this on every VIMS Protocol contract.
 *
 * @dev    Three layers of provenance, in increasing order of "hard-to-strip":
 *
 *         **Layer 1 — overt comment block (top + bottom of file).**
 *         Plain English. Easy to find on Etherscan source-verification view.
 *         A forker can delete it at the source level, but anyone reading the
 *         code as published sees the canonical attribution.
 *
 *         **Layer 2 — public bytes32 constants.**
 *         `VIMS_AUTHOR`, `VIMS_REPO`, `VIMS_LICENSE`, `VIMS_VERSION`.
 *         These are baked into deployment bytecode by the compiler and
 *         readable on-chain via standard storage / call. A fork that wants
 *         to keep the contract logic must either keep the constants
 *         (preserving attribution), zero them out (detectable), or remove
 *         the inheritance (detectable in source).
 *
 *         **Layer 3 — steganographic magic constants.**
 *         A pair of `bytes32` constants whose first eight bytes are the
 *         ASCII signature `"VIMS\x00v1\x00"` and whose remaining 24 bytes
 *         are a domain-separated keccak digest of the canonical author
 *         identity. The compiler embeds these as PUSH32 immediates in
 *         deployment bytecode. They survive Etherscan verification of a
 *         forked contract because the fork's bytecode literally contains
 *         the bytes. Only a recompilation that strips the constants
 *         removes them — which produces a *different runtime hash* and
 *         breaks any deterministic-deployment matching.
 *
 *         Layer 3 is intentionally accessed by `_vimsAttest()` so the
 *         optimizer cannot dead-code-eliminate the constants. Calling
 *         `vimsProvenance()` exposes them through a stable view function.
 */
abstract contract VimsProvenance {
    // ─────────────────────────────────────────────────────────────────────
    // Layer 2 — overt on-chain provenance
    // ─────────────────────────────────────────────────────────────────────

    /// @notice keccak256("vims.protocol.arqonai") — canonical author identity.
    bytes32 public constant VIMS_AUTHOR =
        0x036460e940abd26da97fcf6c8d190417d1076c65e88fb5f9fc9f74ac2fd4430c;

    /// @notice keccak256("github.com/arqonai/vimsbot-contracts") — canonical source repo.
    bytes32 public constant VIMS_REPO =
        0x526585d0e41a5a6367380467ca5339cfee75e36f9dcf226be98e4612fccb9636;

    /// @notice keccak256("MIT") — license under which this code is published.
    bytes32 public constant VIMS_LICENSE =
        0x57d9801c55e30f9ed106172452b6033ad49a2d64397b3598dc4d8adb512cf2bb;

    /// @notice Human-readable protocol version.
    string public constant VIMS_VERSION = "1.0.0";

    // ─────────────────────────────────────────────────────────────────────
    // Layer 3 — steganographic immutable constants (PUSH32 in bytecode)
    //
    // First 8 bytes: ASCII "VIMS\x00v1\x00"  (0x56494d5300763100)
    // Last 24 bytes: bytes24(keccak256("vims.protocol.arqonai/v1/<contract-name>"))
    //
    // The first 8 bytes are a literal magic prefix discoverable by anyone
    // grep'ing deployed bytecode for `0x56494d5300763100`. The last 24 bytes
    // bind the magic to this specific contract identity, so a forker cannot
    // copy a single VIMS contract's fingerprint into an unrelated one.
    //
    // These constants are intentionally **not** declared in the abstract
    // base. Each derived contract overrides `_vimsContractName()` and the
    // base computes its own per-contract magic at construction. This keeps
    // the prefix uniform but the suffix unique per contract.
    // ─────────────────────────────────────────────────────────────────────

    /// @dev ASCII "VIMS\x00v1\x00" — the prefix every VIMS contract carries.
    bytes32 internal constant _VIMS_MAGIC_PREFIX =
        0x56494d5300763100000000000000000000000000000000000000000000000000;

    /// @dev Per-contract magic, computed by the inheriting concrete contract.
    bytes32 private immutable _VIMS_MAGIC_SELF;

    constructor() {
        // Bake a per-contract steganographic magic into immutable bytecode.
        // Format: top-8-bytes prefix || bottom-24-bytes keccak(author || version || contractName).
        bytes32 nameHash =
            keccak256(abi.encodePacked("vims.protocol.arqonai/v1/", _vimsContractName()));
        // Mask the bottom-24 bytes of nameHash and OR with the top-8 prefix.
        bytes32 prefixTop8 = _VIMS_MAGIC_PREFIX & 0xffffffffffffffff000000000000000000000000000000000000000000000000;
        bytes32 nameBot24  = nameHash & 0x0000000000000000ffffffffffffffffffffffffffffffffffffffffffffffff;
        _VIMS_MAGIC_SELF   = prefixTop8 | nameBot24;
    }

    /// @notice Subclasses MUST override to declare their canonical contract name.
    ///         The name is bound into Layer-3 magic and exposed via
    ///         `vimsProvenance()`. Use a stable, repo-canonical string —
    ///         e.g., "AgentCollectionImpl", "AgentRoyaltySplitter",
    ///         "TipJarHook".
    function _vimsContractName() internal pure virtual returns (string memory);

    // ─────────────────────────────────────────────────────────────────────
    // Public surface
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the full VIMS provenance block for this contract.
     * @return author      keccak256 of canonical author identity (Layer 2)
     * @return repo        keccak256 of canonical source repository (Layer 2)
     * @return license     keccak256 of license string (Layer 2)
     * @return version     human-readable protocol version (Layer 2)
     * @return contractName canonical name of this contract (Layer 3 input)
     * @return magic       steganographic magic baked in deployment bytecode (Layer 3)
     */
    function vimsProvenance() external view returns (
        bytes32 author,
        bytes32 repo,
        bytes32 license,
        string memory version,
        string memory contractName,
        bytes32 magic
    ) {
        return (
            VIMS_AUTHOR,
            VIMS_REPO,
            VIMS_LICENSE,
            VIMS_VERSION,
            _vimsContractName(),
            _VIMS_MAGIC_SELF
        );
    }

    /**
     * @notice Pure attestation function that defeats dead-code elimination on
     *         the steganographic constants. Anyone (off-chain) can call this
     *         to verify the bytecode they hold matches a canonical VIMS build.
     */
    function vimsAttest() external view returns (bytes32) {
        return _VIMS_MAGIC_SELF;
    }
}

/*
                                                              ─── END VIMS PROVENANCE ───

  If you removed the comment block at the top of this file before redeploying, the bytecode
  still contains:
      • Layer 2 constants    (VIMS_AUTHOR / VIMS_REPO / VIMS_LICENSE / VIMS_VERSION)
      • Layer 3 magic        (PUSH32 0x56494d5300763100… in the deploy bytecode)
      • Solidity metadata    (auto-baked CBOR with compiler version and IPFS hash)
  All three are independently grep-able on any block explorer. Source: arqonai/vimsbot-contracts.
*/
