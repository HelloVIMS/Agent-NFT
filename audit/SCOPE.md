# Audit Scope — vimsbot v0.9.1 → v1.0 mainnet

## In scope (P0)

The following contracts handle funds, identity, or upgrade authority and
**must** be audited before mainnet:

| File | LOC | Purpose | Notes |
|---|---|---|---|
| `src/AgentIdentityRegistry.sol` | 1,117 | ERC-721 hub. Identity + royalty bps + TBA wiring. UUPS. | 348 B from EIP-170. Owner controls upgrades. |
| `src/AgentCollectionImpl.sol` | (linked libs) | Per-collection ERC-721 + mint-payment + EIP-712 commit verifier. | 145 B from EIP-170 ceiling — fragile. |
| `src/AgentCollectionFactory.sol` | beacon proxy factory | Deploys collections, wires splitter as royalty receiver. | `setRoyaltyReceiverOnce` is one-shot — verify. |
| `src/AgentCollectionPaymentLib.sol` | linked lib | Primary-mint payment split helper. | DELEGATECALL surface — review storage layout assumptions. |
| `src/AgentCollectionEIP712.sol` | linked lib | Keeper-signed mint commitment (`verifyCommit`). | Replay protection lives here. |
| `src/AgentCollectionRenderer.sol` | linked lib | tokenURI renderer (baseURI + on-chain SVG fallback). | Reverts on bad inputs are non-trivial. |
| `src/AgentPaymentRouter.sol` | 778 | ETH + USDC split routing. System + creator + recipient. Reentrancy-guarded. | `pendingSystemRoyalties[token]` accumulator; needs Safe-driven withdraw. |
| `src/AgentX402Receiver.sol` | 649 | Atomic ERC-3009 settler with EIP-712 purpose binding. | Cross-NFT-adapter surface (`payForServiceForNFT`) — extra scrutiny. |
| `src/AgentRoyaltyVault.sol` | 128 | Secondary-market splitter (ERC-2981). | Per-agent CREATE2 derivation. |
| `src/AgentRoyaltySplitter.sol` | 210 | Primary-mint splitter, multi-payee. | Math-heavy; covered by audit fuzz. |
| `src/AgentRoyaltySplitterFactory.sol` | 113 | CREATE2 factory for splitters. | Address derivation must match SDK. |
| `src/AgentTBARegistry.sol` | 231 | VIMS-flavoured ERC-6551 registry wrapper + 4337 EntryPoint binding. | Non-upgradeable. |
| `src/AgentAccount.sol` | (TBA impl) | ERC-6551 + 4337 v0.7 account. Session keys, permission bitset. | EOA-equivalence threat model. |
| `src/AgentReputationRegistry.sol` | 351 | Signed feedback aggregator. UUPS. | Off-chain trust anchor; sig schema must be stable. |
| `src/AgentMemory.sol` | 393 | Versioned memory CIDs. UUPS. | Owner controls upgrades. |
| `src/AgentContextRegistry.sol` | 314 | Typed context files (md/json/yaml). UUPS. | Replaces legacy `skills` slot. |
| `src/AgentIdentityFullStackLib.sol` | 66 | Composes identity + TBA + memory in a single tx. DELEGATECALL. | Storage-layout sensitive. |
| `src/AgentIdentityURILib.sol` | 48 | tokenURI rendering for identity. | |
| `src/VimsProvenance.sol` | 169 | Provenance fingerprint inherited by every contract. | Adversarial spoofing surface — review. |

## In scope (P1)

Lower-impact contracts but still on the deploy critical path:

| File | LOC | Notes |
|---|---|---|
| `src/AgentRegistry.sol` | 141 | Legacy registry slot. Read-only on mainnet — but still in the bundle. |
| `src/ReputationRegistry.sol` | 121 | Older interface; SDK still references it. |
| `src/ValidationRegistry.sol` | 162 | ERC-8004 validation hooks. |
| `src/AgentSkillsExtension.sol` | 161 | Legacy skills extension. Audit before exposing. |
| `src/AgentEncryptionRegistry.sol` | 222 | Sentinel until first deploy — `MAINNET_READINESS.md` P1: deploy or remove. |
| `src/AgentLinkedAccountRegistry.sol` | 468 | Same — sentinel; review before any use. |

## Hooks (P1)

Reference hooks in `src/hooks/`. Each is a small (\< 200 LOC) adapter
implementing `IAgentEvolutionHook`. Audit focus:

- `BaseEvolutionHook.sol` — base storage + permission flag layout
- `EvolutionStagesHook.sol` — stage progression math
- `OracleHook.sol` — Chainlink stale-price guards
- `RevenueLevelHook.sol` — interaction with `AgentPaymentRouter`
- `ReputationLevelHook.sol` — interaction with `AgentReputationRegistry`
- `SoulboundHook.sol` — transfer veto path
- `TransferRecolorHook.sol`, `TimeOfDayHook.sol`, `SeasonalHook.sol`,
  `HueRotateHook.sol`, `TipJarHook.sol`, `GenerationHook.sol`,
  `VoteGatedHook.sol`, `AgentStatusHook.sol`

Hooks live behind `setCollectionHook` per collection; a malicious hook
can only damage the collection that opted into it. **Confirm this isolation.**

## Out of scope

- Vendored OpenZeppelin contracts (`lib/openzeppelin-contracts/`).
- ERC-6551 canonical registry at `0x000000006551c19487814612e58FE06813775758`
  (community standard, audited separately).
- EIP-4337 EntryPoint v0.7 at `0x0000000071727De22E5E9d8BAf0edAc6f37da032`.
- Chainlink price feeds (we treat them as an oracle dependency, not our code).
- USDC contract on each chain (Circle's deployment).
- Off-chain components: indexer (`vimsbot-subgraph`), discover-worker,
  marketplace UI, x402 facilitator. **In scope for separate review.**

## Test surface for auditors

```
test/                          ~600 unit tests
test/audit/                    audit-grade fuzz + invariant
  AgentRoyaltySplitter.fuzz.t.sol
  AgentPaymentRouter.fuzz.t.sol
  AgentX402Receiver.fuzz.t.sol
  BytecodeSize.audit.t.sol     EIP-170 ceiling guard
test/invariants/               (if present)
```

Run with:

```bash
forge test --match-path 'test/audit/**'
forge test --gas-report
```

## Severity expectations

- **Critical** — fund loss, unauthorized mint, unauthorized upgrade, identity hijack.
- **High** — DoS on a money path; royalty bypass > 1 BPS; signature replay.
- **Medium** — gas griefing; metadata corruption; off-by-one in splits ≤ 1 BPS.
- **Low / informational** — gas, style, docs.

## Known caveats (informational; pre-disclosed)

1. **EIP-170 margin on `AgentCollectionImpl`** — 145 B headroom.
   Tracked in `MAINNET_READINESS.md` P0 and `INVARIANTS.md §B`.
2. **Owner-controlled upgrades** — every UUPS proxy still uses
   `onlyOwner` `_authorizeUpgrade`. Mainnet hand-off to Safe + Timelock
   is in `RUNBOOK.md §1`.
3. **Pending system royalty pool** — `AgentPaymentRouter.pendingSystemRoyalties[token]`
   accumulates indefinitely; treasury withdraw path is owner-only and
   must be exercised in fork tests before launch.
4. **`AgentEncryptionRegistry` and `AgentLinkedAccountRegistry`** are
   shipped but deployed at sentinel zero addresses on testnet. Decision
   pending: deploy or remove for v1.0.
