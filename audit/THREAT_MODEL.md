# Threat Model — vimsbot v0.9.1 → v1.0

## 1. Actors

| Actor | Capabilities | Trust assumption |
|---|---|---|
| **Protocol owner** (Safe + Timelock at v1.0) | Upgrade UUPS proxies, set treasury, set system fee, pause | Multisig ≥ 4-of-7, 24–48 h timelock |
| **Treasury** | Withdraw `pendingSystemRoyalties` | Same Safe |
| **Pause Guardian** (P1) | Pause `AgentX402Receiver` / `PaymentRouter` / `CollectionImpl` | Limited Safe (e.g. 2-of-3) for fast response |
| **Creator** | Mint agents, set royalty bps, deploy collections, register x402 services, deploy bespoke hooks, manage whitelist | Untrusted with respect to other creators / buyers |
| **Buyer** | Pay agents, mint from collections, sign x402 commitments | Untrusted |
| **Keeper** | Submit signed mint commitments, trigger evolution hooks where `requiresKeeper` | Authority delegated by collection creator via EIP-712 sig |
| **Validator** (ERC-8004) | Validation registry attestations | Untrusted; signatures are auditable |
| **External attacker** | Mempool watcher, EOA-equivalent attacker, MEV searcher, Sybil | Worst case |

## 2. Trust boundaries

```
[Browser / SDK]          [Smart contracts on chain]      [Off-chain infra]
                                                         (subgraph, worker,
RPC ────────────────▶  identity / payment / x402  ◀──── x402 facilitator,
EIP-712 sigs ───────▶                              ───▶ keeper bot)
                          ▲
                          │ events
                          ▼
                       [Safe + Timelock]
```

- The SDK must NEVER assume off-chain infra is trustworthy. All
  signature verification happens on-chain.
- The x402 facilitator is a **convenience signer**: it proves the
  buyer's payment authorization moved through it, but the AgentX402Receiver
  still verifies the (cv, cr, cs) commitment from the buyer
  independently.
- Keepers can only act where the collection creator delegated them
  (per-collection `keeper` address; commitment signed under
  `AgentCollectionEIP712`).

## 3. Attack surface — by money path

### 3.1 Primary mint (collection)

`AgentCollectionImpl.mintAgent / mintAgentAllowlist`

| # | Threat | Mitigation | Test |
|---|---|---|---|
| 3.1.1 | Replay a mint commitment for a different collection | Domain separator in EIP-712 binds (chainId, contract address) | `test/AgentCollectionImpl.t.sol` |
| 3.1.2 | Front-run an allowlist mint with a stolen Merkle proof | Proof-leaf binds to `(msg.sender, agentId)` | `test/AgentCollectionAllowlist.t.sol` |
| 3.1.3 | Bypass royalty by buying directly from creator | Out of scope (UX); secondary royalties enforced by `AgentRoyaltyVault` |  |
| 3.1.4 | Re-enter mint to drain payment splitter | `nonReentrant` on `mintAgent`; payment lib uses `.call` then check | reentrancy fuzz in `audit/` |
| 3.1.5 | Mint past `maxSupply` via integer wrap | Solidity 0.8 checked arithmetic + explicit `>=` guard |  |

### 3.2 Service payment

`AgentPaymentRouter.payAgent / payAgentUSDC / payAgentTo / payAgentToUSDC`

| # | Threat | Mitigation | Test |
|---|---|---|---|
| 3.2.1 | Sub-1-BPS rounding griefing accumulates value in router | Splits sum to exactly `amount` via after-system rounding; conservation invariant fuzzed | `AgentPaymentRouter.fuzz.t.sol` |
| 3.2.2 | Re-entrant call drains via creator's `receive()` | `nonReentrant` + `_processCreatorRoyalty` uses pull pattern (`pendingRoyalties`) | unit + reentrancy mock |
| 3.2.3 | `payAgentTo` to non-permissioned subaccount | `_assertSubaccountPermitted` rejects if `agentIdOf(sub) != agentId` | unit |
| 3.2.4 | Treasury frozen if treasury call reverts | System fee accumulates in `pendingSystemRoyalties[token]`; Safe withdraws explicitly | RUNBOOK §3 |
| 3.2.5 | Exempt-path abuse | `payAgentExempt` requires `isExempt(agentId, msg.sender)`; only creator-whitelisted addresses pass | unit + fuzz |

### 3.3 x402 service settlement

`AgentX402Receiver.payForService / payForServiceForNFT`

| # | Threat | Mitigation | Test |
|---|---|---|---|
| 3.3.1 | Replay an EIP-3009 authorization to drain buyer | USDC's own per-(from, nonce) nonce guard | `AgentX402Receiver.fuzz.t.sol` |
| 3.3.2 | Reuse a USDC sig across services | EIP-712 commitment `hashPaymentCommitment(agentId, serviceId, token, amount, nonce, validBefore)` recovered against `from` | `testFuzz_TamperServiceIdReverts` |
| 3.3.3 | Tamper amount, deadline, nonce, or agentId after sig | Same as 3.3.2; ECDSA recovery breaks | full tamper fuzz suite |
| 3.3.4 | Pay an inactive / zero-price service | `if (!svc.active || svc.price == 0) revert ServiceInactive()` | unit |
| 3.3.5 | Cross-NFT-adapter confusion (different nft + tokenId, same agentId) | `payForServiceForNFT` uses adapter-specific commit hash | unit |
| 3.3.6 | Disallowed token used | `allowedTokens[token]` allowlist (audit L-3) | unit |
| 3.3.7 | DoS by spamming `registerServiceFromIdentity` | Only the agent's owner / creator can register | unit |

### 3.4 Royalty splitter

`AgentRoyaltySplitter` (primary), `AgentRoyaltyVault` (secondary)

| # | Threat | Mitigation | Test |
|---|---|---|---|
| 3.4.1 | Wrong-payee receives funds via direct call | `release()` walks the canonical payee list; no payee, no payout | invariant fuzz |
| 3.4.2 | Storage-layout collision via DELEGATECALL libs | Splitters are not DELEGATECALL targets; libs in `*Lib.sol` only used via factory deploy |  |
| 3.4.3 | Owner can drain residual ETH | `recoverETH` / `recoverToken` are owner-gated; mainnet owner = Safe+Timelock | RUNBOOK §3 |

### 3.5 Identity / TBA

`AgentIdentityRegistry`, `AgentTBARegistry`, `AgentAccount`

| # | Threat | Mitigation | Test |
|---|---|---|---|
| 3.5.1 | Hijack an agent by minting ID collision | IDs are sequential (`_nextAgentId`) — no caller-provided IDs | unit |
| 3.5.2 | Spoof TBA derivation via custom registry | SDK + contracts both pin canonical ERC-6551 registry address | `tests/unit/tba.test.ts` |
| 3.5.3 | Session-key escalation | `AgentAccount` enforces (allowedTargets, allowedSelectors, maxValuePerTx, maxTotalValue) | unit |
| 3.5.4 | 4337 EntryPoint v0.7 vs v0.6 confusion | EntryPoint address pinned at construction; immutable | unit |
| 3.5.5 | Force re-init of UUPS proxy | `_disableInitializers` in every implementation constructor | unit |

### 3.6 Evolution hooks

`src/hooks/*`

| # | Threat | Mitigation | Test |
|---|---|---|---|
| 3.6.1 | Hook reverts in `BeforeMint` → DoS mints | Hosts wrap hook calls in `try/catch`; AfterMint failures are best-effort | unit |
| 3.6.2 | Malicious hook drains payment via `BEFORE_TRANSFER` reentry | Host calls hook with strict permission flag; reentrancy guard on payment paths | reentrancy fuzz |
| 3.6.3 | Stale Chainlink price triggers wrong stage | `OracleHook` checks `updatedAt` against staleness threshold; reverts on stale | unit |
| 3.6.4 | Bespoke hook deployed by creator for one collection affects another | Hooks are per-collection (`setCollectionHook`); host enforces caller match |  |

## 4. Attack vectors out of scope (handled separately)

- **MEV / sandwich** — payment paths are not price-sensitive (fixed-price agents); ignore.
- **L1 reorg** — base on Base + reorg-resistant; minted token IDs are sequential, no race.
- **Censoring sequencer** — affects all L2 protocols equally; document as a known risk.
- **51% attack** on the underlying L2 — out of scope.
- **DNS hijack of marketplace UI** — separate operational threat; CSP + SRI in place.
- **Phishing of creator wallets** — user education; out of code scope.

## 5. Privileged operations cheat sheet

| Operation | Owner | Pause Guardian | Anyone |
|---|:---:|:---:|:---:|
| `_authorizeUpgrade` (UUPS) | ✓ | | |
| `setAeyeosTreasury` (PaymentRouter) | ✓ | | |
| `setSystemFeeBps` (X402Receiver) | ✓ | | |
| `setTokenAllowed` (X402Receiver) | ✓ | | |
| `pause` / `unpause` | ✓ | (P1: ✓) | |
| `withdrawSystemRoyalties` (PaymentRouter) | ✓ | | |
| `setMinAutoTransferETH/USDC` (PaymentRouter) | ✓ | | |
| `addInfrastructure` (PaymentRouter) | ✓ | | |
| `addToCreatorWhitelist` (PaymentRouter) | (creator) | | |
| `release()` on splitter / vault | | | ✓ |

## 6. Cryptography assumptions

- secp256k1 ECDSA — standard.
- keccak256 — standard.
- EIP-712 typed structured data — domain separator includes chainId +
  contract address; replay-safe across chains and contracts.
- We do NOT use BLS, BN254, or any pairing primitive.

## 7. Upgrade story

UUPS, all contracts. Today: `onlyOwner`. v1.0:
`onlyOwner` where owner = Safe + Timelock(48 h). See RUNBOOK §1.

There is no built-in path to renounce upgradability or migrate to a
new proxy implementation type. **By design** for the v1.0 cut.

## 8. Disclosed deltas vs prior testnet audits

- v0.9.1 lowered `MIN_CREATOR_ROYALTY_BPS` from 100 (1%) to 0 — opt-out
  permitted. Confirmed by `INQTEL_AUDIT_2026-05-09.md`.
- v0.9.1 added `AgentCollectionPaymentLib` to keep impl bytecode under
  EIP-170 once `collectionBaseURI` was introduced. New library is
  scope-in (see `SCOPE.md`).
- `AgentX402Receiver.payForServiceForNFT` (cross-collection adapters)
  is new and untested in production traffic.
