# Pixelog Integration — IPFS / Arweave hooks for `AgentMemory`

The `.pixe` capsule format from [ArqonAi/Pixelog](https://github.com/ArqonAi/Pixelog)
already ships first-class IPFS and Arweave publishers, a unified
`publish.Publisher` interface, and a tiered `CapsuleResolver` that walks
local SSD → IPFS → Arweave on read. **Nothing additional is required on the
contract side** — `AgentMemory.storageURI` is a generic string and accepts
every URI scheme Pixelog emits.

This document describes the canonical end-to-end flow.

---

## URI schemes Pixelog emits

| Scheme                                | Resolves to                                                        |
| ------------------------------------- | ------------------------------------------------------------------ |
| `pixe://capsule/<sha256>`             | content-addressed capsule, walks resolver tiers                    |
| `pixe://memory/<ns>/<category>/<id>`  | typed memory entry inside an agent's namespace                     |
| `pixe://agent/<tokenID>`              | latest capsule for an Agent NFT                                    |
| `pixe://agent/<tokenID>/capsule/<v>`  | specific version of an Agent NFT's capsule                         |
| `pixe://arweave/<txID>`               | direct Arweave anchor                                              |
| `ipfs://<cid>`                        | direct IPFS gateway / Kubo lookup                                  |
| `ar://<txID>`                         | direct Arweave gateway lookup                                      |
| `https://...`                         | any HTTPS-served capsule                                           |

Reference parser: `pixelog/internal/memory/uri.go`.
Reference resolver: `pixelog/internal/memory/resolver.go`.

---

## Pixelog publisher surface

Every backend implements:

```go
type Publisher interface {
    Network() string                                     // "ipfs" | "arweave" | ...
    Publish(ctx context.Context, data []byte,
            mimeType string) (Result, error)
}
```

Concrete implementations:
- `pixelog/pkg/publish/ipfs/kubo.go` — Kubo daemon or Pinata-compatible HTTP API.
- `pixelog/pkg/publish/arweave/arweave.go` — direct Arweave gateway with deephash + chunked upload + merkle proofs.

Wired via `cmd/pixe publish`:

```bash
# Publish the active .pixe capsule to one or more durability networks.
PIXE_TARGETS=ipfs,arweave \
IPFS_API=http://127.0.0.1:5001 \
ARWEAVE_GATEWAY=https://arweave.net \
ARWEAVE_WALLET=./wallet.json \
pixe publish ./agent-001.pixe
```

The CLI prints each `Result` with `network`, `cid`/`txID`, and the canonical
`pixe://` URI to anchor on-chain.

---

## End-to-end agent-memory flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              AGENT RUNTIME                              │
│                                                                         │
│  pixe consolidate    →  capsule bytes  +  sha256                        │
│         │                                                               │
│         ▼                                                               │
│  pixe publish (IPFS + Arweave)                                          │
│         │                                                               │
│         ▼                                                               │
│  storageURI = "pixe://capsule/<sha256>"   (resolves IPFS → Arweave)     │
│  contentHash = 0x<sha256>                                               │
└─────────────────────────────────────────┬───────────────────────────────┘
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              ON-CHAIN                                   │
│                                                                         │
│  AgentMemory.addVersion(                                                │
│      agentId, storageURI, contentHash,                                  │
│      TYPE_CAPSULE, CATEGORY_FACT, TIER_L2,                              │
│      0, "Q4 reading list consolidation"                                 │
│  );                                                                     │
│                                                                         │
│  → emits PixeVersionAdded(agentId, version, ..., storageURI)            │
│  → indexers can subscribe and warm IPFS pins / Arweave caches eagerly   │
└─────────────────────────────────────────────────────────────────────────┘
```

On the read side, any agent (or third party with the agent ID) calls:

```solidity
PixeVersion memory v = mem.getLatest(agentId);
// v.storageURI == "pixe://capsule/0xabc..."
// v.contentHash == 0xabc...
```

…and hands `v.storageURI` to the Pixelog `CapsuleResolver`, which transparently
walks **local SSD → IPFS → Arweave**, verifies SHA-256 against the on-chain
`contentHash`, and returns the parsed `EraCapsule`.

---

## Why no contract changes are needed

`AgentMemory.storageURI` is a `string` of length ≤ 512 bytes. The contract
intentionally does **not** parse, validate, or constrain the URI scheme.
Validation is the resolver's job — and `contentHash` (SHA-256) is the
tamper-detection invariant the chain enforces by witnessing it.

This separation gives you:
- **Storage-protocol agnosticism.** Tomorrow's Filecoin, Walrus, or Storj
  endpoints work without contract redeployment.
- **Tier independence.** The same `addVersion` call covers L0 / L1 / L2 tiers
  even though they live in different on-disk shapes.
- **No coupling to a particular pin service.** Pinata, Web3.Storage, Spheron,
  Kubo-self-hosted — all interchangeable.

---

## Operational pattern

Recommended sequencing for a new memory write:

1. **`pixe add`** the file locally — content-addressed, encrypted at rest.
2. **`pixe consolidate`** if rolling up a window — produces a new merkle root.
3. **`pixe publish --targets ipfs,arweave`** — emits both anchors.
4. **`AgentMemory.addVersion(...)`** with `storageURI = pixe://capsule/<hash>`
   and `contentHash = sha256`. Capsule will resolve via either backend.
5. (Optional) **`AgentMemory.consolidate(...)`** when superseding a window —
   pass the merkle root from step 2 for off-chain inclusion proofs.

Failures are isolated per backend: if Arweave is down at step 3, IPFS still
provides resolution and the contract write proceeds. Re-publish to Arweave
later without updating the chain — `pixe://capsule/<hash>` is the same
identifier on both networks.

---

## Indexer hooks

Subscribe to `AgentMemory.PixeVersionAdded` to keep an off-chain mirror of
every agent's memory tree. A reference indexer can:

1. Filter on `agentId` (indexed).
2. Decode `storageURI` and pre-fetch via Pixelog's resolver.
3. Verify `contentHash` against capsule bytes.
4. Pin to its own IPFS node + cross-pin to Arweave for redundancy.
5. Expose a lightweight HTTP API: `GET /agents/:id/memory?category=fact&tier=L2`.

This is the pattern Pixelog's `cmd/server` already implements for non-NFT
agents — adding the chain-event subscription is ~50 LoC of `ethers.js` or
`go-ethereum`.

---

## Reference

- **Pixelog repo:** <https://github.com/ArqonAi/Pixelog>
- **CLI:** `pixe init | add | consolidate | publish`
- **URI parser:** `internal/memory/uri.go`
- **Resolver:** `internal/memory/resolver.go`
- **IPFS publisher:** `pkg/publish/ipfs/kubo.go`
- **Arweave publisher:** `pkg/publish/arweave/arweave.go`
- **Categories:** `internal/memory/categories.go` (mirrored on-chain in `AgentMemory.CATEGORY_*`)
- **Tiers:** `internal/memory/tiered.go` (mirrored on-chain in `AgentMemory.TIER_L0/L1/L2`)
