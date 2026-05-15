# VIMS Contract Provenance & Anti-Fork Fingerprint

Three independent layers of provenance bake into every VIMS Protocol contract that inherits `VimsProvenance`. Each layer is independently verifiable. Stripping all three at once is detectable; stripping any one of them leaves the other two as evidence.

---

## Layer 1 — Overt comment block

A literal ASCII-art VIMS banner sits at the top of `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/VimsProvenance.sol` and a closing comment at the bottom. Every concrete contract that inherits adds its own short header (e.g. `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/hooks/SoulboundHook.sol:8-15`) pointing back to the canonical repo.

**Visibility.** Plain English in source. Anyone reading on Etherscan's verified-source view sees the banner.

**Resilience.** Trivially strippable in source. Use Layer 2/3 to detect the strip.

**Verification recipe.** `grep -i "vims protocol" src/**/*.sol` should return a hit per file.

---

## Layer 2 — Public on-chain constants

Every `VimsProvenance` derivative exposes:

| Constant       | Type      | Value preimage                              |
|----------------|-----------|---------------------------------------------|
| `VIMS_AUTHOR`  | `bytes32` | `keccak256("vims.protocol.arqonai")`        |
| `VIMS_REPO`    | `bytes32` | `keccak256("github.com/arqonai/vimsbot-contracts")` |
| `VIMS_LICENSE` | `bytes32` | `keccak256("MIT")`                          |
| `VIMS_VERSION` | `string`  | `"1.0.0"`                                   |

**Verification recipe — anyone can run:**

```bash
# All four constants must match these EXACT values:
cast keccak "vims.protocol.arqonai"
#  → 0x036460e940abd26da97fcf6c8d190417d1076c65e88fb5f9fc9f74ac2fd4430c
cast keccak "github.com/arqonai/vimsbot-contracts"
#  → 0x526585d0e41a5a6367380467ca5339cfee75e36f9dcf226be98e4612fccb9636
cast keccak "MIT"
#  → 0x57d9801c55e30f9ed106172452b6033ad49a2d64397b3598dc4d8adb512cf2bb

# Read them from any deployed VIMS contract:
cast call <ADDR> "VIMS_AUTHOR()(bytes32)"  --rpc-url $RPC
cast call <ADDR> "VIMS_REPO()(bytes32)"    --rpc-url $RPC
cast call <ADDR> "VIMS_LICENSE()(bytes32)" --rpc-url $RPC
cast call <ADDR> "VIMS_VERSION()(string)"  --rpc-url $RPC
```

**Visibility.** Public state — readable by any caller, indexed on Etherscan.

**Resilience.** A forker cannot leave the constants intact and call themselves a different protocol — anyone calling `vimsProvenance()` reads the canonical author, repo, license, and version. A forker who *removes* the inheritance produces a different runtime hash; you can still detect them by their absence (forks of VIMS that fail `cast call <ADDR> "vimsProvenance()"` are by definition not canonical).

---

## Layer 3 — Steganographic magic bytes

Every concrete VIMS contract bakes a `bytes32 immutable _VIMS_MAGIC_SELF` into its deployment bytecode. Format:

```
0x56494d5300763100  ||  bytes24(keccak256("vims.protocol.arqonai/v1/" || contractName))
   └── ASCII "VIMS\x00v1\x00" ──────────┘     └── per-contract identity binding ────────────────┘
        (8 bytes)                                          (24 bytes)
```

The compiler emits the immutable as a `PUSH32` instruction in the deployment bytecode. After deployment, the same 32-byte sequence appears in the **runtime** bytecode (the constant is read from immutable storage, which is inlined into runtime code by Solidity).

**Visibility.** Hexdump the runtime bytecode and grep for `56494d5300763100`:

```bash
cast code <ADDR> --rpc-url $RPC | grep -o "56494d5300763100[0-9a-f]\{48\}"
```

The match length is exactly 64 hex chars (32 bytes). The first 16 are always `56494d5300763100`; the last 48 are the per-contract identity binding.

**Verification recipe — recompute the magic from the contract name:**

```bash
NAME="SoulboundHook"
PREIMAGE="vims.protocol.arqonai/v1/$NAME"
HASH=$(cast keccak "$PREIMAGE" | sed 's/^0x//')
SUFFIX="${HASH:16:48}"            # bottom 24 bytes
PREFIX="56494d5300763100"
echo "Expected magic: 0x${PREFIX}${SUFFIX}"

# Compare with on-chain attest:
cast call <ADDR> "vimsAttest()(bytes32)" --rpc-url $RPC
```

The two must match exactly. They do for canonical VIMS deployments; they cannot be made to match for a fork that did not also use the canonical preimage.

**Resilience.** This is the layer most resistant to silent forking:

1. **Immutables can't be optimised away** because `vimsAttest()` and `vimsProvenance()` read them.
2. **A forker who keeps the inheritance** carries the canonical magic — proves provenance.
3. **A forker who strips the inheritance** breaks every callsite that read the constants and changes the contract's runtime bytecode hash, which makes the fork detectable by deterministic-deployment matching (any third party can compute the canonical bytecode from the audited source and check against on-chain code).
4. **A forker who copies the magic into a different contract** has it tied to the wrong contract name — `_vimsContractName()` still returns the original name, so `vimsProvenance()` exposes the lie.
5. **A forker who edits `_vimsContractName()` to lie** changes the deploy-time computation and the resulting magic no longer matches the canonical preimage table — externally verifiable.

There is no zero-cost way to remove Layer 3 without measurable evidence somewhere in the bytecode or the verification process.

---

## Off-chain canonical bytecode registry

VIMS will publish a signed JSON registry at the canonical repo:

```jsonc
// docs/canonical-bytecode.json (planned)
{
  "version": "1.0.0",
  "compiler": "0.8.24+commit.e11b9ed9",
  "optimizer": { "enabled": true, "runs": 200 },
  "contracts": {
    "SoulboundHook":    { "runtimeHash": "0x…", "magic": "0x56494d5300763100…" },
    "AgentCollectionImpl": { "runtimeHash": "0x…", "magic": "0x56494d5300763100…" }
  },
  "signature": { "address": "0xVIMS…", "sig": "0x…" }
}
```

Anyone can verify `runtimeHash == keccak256(deployedBytecodeStrippedOfMetadata)` for any deployed VIMS contract by:

```bash
# 1. Fetch bytecode from canonical chain
cast code <ADDR> --rpc-url $RPC > /tmp/runtime.hex

# 2. Strip the trailing Solidity metadata (variable length CBOR)
#    (use tools like 'solc' or 'forge inspect <Contract> bytecode')

# 3. Compare hash to canonical registry
keccak < /tmp/runtime-stripped.hex
```

A forker who recompiles strips the metadata correctly only if their compiler version matches; even then, any source-level edit produces a different hash. Combined with Layer 3 magic in the bytecode, this gives **two independent fingerprints** that have to be preserved for a fork to claim VIMS provenance.

---

## Threat-model summary

| Forker action                        | Detectable by                          |
|---------------------------------------|-----------------------------------------|
| Removes top/bottom comment banner     | `grep` against canonical source         |
| Removes `VimsProvenance` inheritance  | `cast call vimsProvenance()` reverts; runtime hash differs from canonical |
| Keeps inheritance, changes `_vimsContractName()` | `vimsAttest()` no longer matches preimage table |
| Copies magic from one contract to another | `vimsProvenance().contractName` exposes the lie |
| Recompiles cleanly with VIMS branding | runtime hash matches canonical → not actually a fork, just a redeployment |
| Recompiles after stripping VIMS magic | runtime bytecode no longer contains `56494d5300763100` magic prefix → grep test fails |

Each row above is **independently verifiable** by anyone with an RPC endpoint and `cast`. The combination of Layers 1-3 plus the off-chain canonical hash registry is the strongest practical anti-fork attestation that's compatible with permissionless source publication.

---

## Currently fingerprinted contracts

Verified by `test/VimsProvenance.t.sol` (hooks) and `test/VimsProvenanceCore.t.sol` (core). Each contract is asserted to embed its magic in runtime bytecode, carry the canonical VIMS prefix, and have a globally unique per-contract suffix.

**Hooks (7/7):**

- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/hooks/SoulboundHook.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/hooks/GenerationHook.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/hooks/SeasonalHook.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/hooks/HueRotateHook.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/hooks/TipJarHook.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/hooks/ReputationLevelHook.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/hooks/VoteGatedHook.sol`

**Core (14/14 of intended core surface):**

- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentRoyaltyVault.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentRoyaltySplitter.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentRoyaltySplitterFactory.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentReputationRegistry.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentMemory.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentContextRegistry.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentX402Receiver.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentIdentityRegistry.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentAccount.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentTBARegistry.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentCollectionFactory.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentCollectionImpl.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentPaymentRouter.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/hyperlane/AgentBridge.sol`

**Bytecode-budget notes:**

- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentCollectionImpl.sol` was within 199 bytes of the EIP-170 24,576-byte ceiling pre-fingerprint. Two surgical changes made the fingerprint fit cleanly:
  1. **Mint-path consolidation** — extracted the ~30-line shared body of `mintAgent` and `mintAgentAllowlist` into a single private `_executeMint(...)` helper. Beyond bytecode savings, this guarantees the two mint paths cannot drift apart silently (royalty defaults, payment split, event emissions, hook firing).
  2. **`optimizer_runs = 1`** — global compiler setting in `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/foundry.toml`. Favors deployed-bytecode size over runtime gas (Foundry 1.5.1 does not yet support reliable per-file optimizer overrides; the `compilation_restrictions` syntax was tried and silently produced inconsistent results). Each external call across the protocol pays a small amount of additional runtime gas vs. `runs=200` — accepted as the cost of permanent on-chain VIMS attribution on every contract.
  
  Final size: **23,694 bytes** (882-byte margin).

**Deliberately excluded — legacy/dead code:**

- `AgentRegistry.sol`, `AgentSkillsExtension.sol` — superseded; flagged for removal in the coherence audit.
- `adapters/AgentReputationERC8004Adapter.sol` — adapter to a third-party-shaped registry; has its own provenance via importing the canonical `IERC8004Reputation` from a fingerprinted hook. Adding the mixin to adapters is unnecessary noise.

— Cascade, 2026-05-09
