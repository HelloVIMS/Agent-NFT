# Mainnet Readiness Checklist

> **Status:** v0.9.1 testnet on Base Sepolia (84532). Pre-mainnet. Do not
> consider this list complete until every P0 item is checked off and the
> external audit report is published.

Generated 2026-06-14. Owner: protocol team. Update in lockstep with sprint reviews.

---

## P0 — blockers (cannot ship without)

### Contracts
- [ ] **External security audit** — Trail of Bits / Spearbit / Code4rena round on:
  - `AgentIdentityRegistry`
  - `AgentCollectionImpl` (+ libraries)
  - `AgentRoyaltySplitter`
  - `AgentPaymentRouter`
  - `AgentX402Receiver`
  - `AgentMemory`, `AgentContextRegistry`, `AgentReputationRegistry`
- [ ] **Bug bounty live** on Immunefi (target: $50–$250k) before primary mints open.
- [x] **EIP-170 margin recovery on `AgentCollectionImpl`** ~~(145 B)~~ —
      **resolved 2026-06-14** by extracting Pixelog versioning to
      `AgentCollectionPixeLib`. Margin now **1,250 B** (5%).
- [ ] **EIP-170 margin on `AgentIdentityRegistry`** (348 B). Same family
      of risk, smaller blast radius — track for v1.0.
- [ ] **Mainnet deploy + `deployments/<chain>.json`** for every supported chain.
      Today `core/contracts.ts` chains 8453 / 1 / 10 / 42161 / 137 all use ZERO
      addresses; SDK throws on every mainnet call. Use `script/DeployMainnet.s.sol`
      (see `audit/RUNBOOK.md`).
- [ ] **Multisig treasury** (Gnosis Safe) replacing single EOA `0xE48840eD…`.
      `aeyeosTreasury` + protocol fee recipients all routed through Safe.
- [ ] **Multisig + timelock for upgrades.** `_authorizeUpgrade` is `onlyOwner`
      on every UUPS proxy. Wire OZ `TimelockController` (24–48 h delay) + Safe.
- [ ] **Per-chain USDC address** in `core/contracts.ts` and `v7/contracts.ts`.
      Base Sepolia `0x036C…` must NOT leak into Base mainnet (`0x833589…`) or
      Ethereum (`0xA0b86…`).
- [ ] **Production x402 facilitator URL** wired into
      `vimsbot-marketplace/src/lib/x402-payment.ts` + signed-attestation key
      rotation procedure.
- [ ] **Treasury withdrawal path tested.** `AgentPaymentRouter.pendingSystemRoyalties[token]`
      pools indefinitely. Add fork tests for the Safe-driven withdrawal.

### SDK / marketplace / infra
- [ ] **Real RPC URLs** (Alchemy / Infura / QuickNode) with key rotation —
      not viem default `http()`.
- [ ] **Production WalletConnect project ID** in `marketplace/src/lib/wagmi.ts`.
- [ ] **Subgraph + discover-worker mainnet indexers** spun up; today both point
      only at Base Sepolia.
- [ ] **`LEGACY_IDENTITY_REGISTRIES`** plan documented (token metadata
      persistence, `ownerOf` fallback) for the moment a mainnet redeploy happens.

---

## P1 — strongly recommended

### Contracts
- [ ] **Pause Guardian** role separate from owner — can `pause()`
      `AgentX402Receiver` / `AgentCollectionImpl` / `AgentPaymentRouter`
      without full multisig quorum.
- [ ] **Fork tests against real mainnet state** (`forge test --fork-url $BASE_RPC`).
      USDC EIP-3009 path, ERC-6551 canonical registry, OpenSea ERC-2981
      enforcement.
- [ ] **Invariant suite for `AgentIdentityRegistry`** (no orphan agents,
      `owner == 0` ⇔ inactive, `totalSupply` monotonic).
- [ ] **Lock economic params** — `SYSTEM_ROYALTY_BPS=50`, `MAX_ROYALTY_BPS=8000`,
      `minAutoTransferETH/USDC`. Final values reviewed by audit; `setSystemFeeBps`
      reachable only via timelock (or removed).
- [ ] **Hyperlane `AgentBridge`** either deployed + audited, or removed from
      the SDK entirely. Half-shipped is worse than not shipped.
- [ ] **`AgentEncryptionRegistry`, `AgentLinkedAccountRegistry`** — same: deploy
      or remove.
- [ ] **Subgraph schema frozen** at v0.9.1 → v1.0; mainnet indexer doesn't
      break on schema changes.

### Operations
- [ ] **Monitoring** (OpenZeppelin Defender / Tenderly Alerts):
  - `pendingSystemRoyalties` >> threshold
  - owner-key activity
  - revert spikes on `payAgent*`
  - bytecode-size canary on every redeploy
- [ ] **Keeper infrastructure** for evolution hooks (`requiresKeeper: true`).
      Today no keeper bot exists; `EvolutionRequested` events go unconsumed.
- [ ] **Runbook** in `audit/RUNBOOK.md`: pause, rotate treasury, withdraw
      stuck funds, deploy a new impl behind the timelock.
- [ ] **Incident response on-call rotation** + Slack/Discord webhook firing
      into it.

### Marketplace UX / safety
- [ ] **Mainnet/testnet chain switcher** with explicit "you are on testnet"
      banner. Today the app hardcodes 84532.
- [ ] **`quoteSplit` confirmation modal** before any `payAgent` — force user
      to acknowledge per-leg amounts.
- [ ] **Arweave / IPFS gateway redundancy** — at least 2 gateways with
      health-check fallback. Today `pinata.cloud` is single-point-of-failure.
- [ ] **Cloudflare / WAF** in front of subgraph + worker indexers.

### Legal / compliance
- [ ] **Terms of Service + Privacy Policy** linked from marketplace footer.
- [ ] **Geo-blocking** of restricted jurisdictions (royalty splits arguably
      cross "investment contract" territory). Counsel review.
- [ ] **OFAC sanctions screening** (Chainalysis Free / TRM Labs) on treasury
      inflows. Required by most US-touching infra providers.
- [ ] **DMCA / takedown flow** for infringing agent metadata. Marketplace
      currently has no admin moderation.

---

## P2 — polish before "1.0" tag

- [ ] Storybook / visual regression for Mint UI.
- [ ] E2E tests against mainnet fork (Playwright currently localhost-only).
- [ ] Public TypeScript SDK published to npm — `v0.9.1` → `1.0.0` on mainnet.
- [ ] Mainnet ABI manifest pinned + signed; `sync-abi:check` rejects unsigned
      manifests.
- [ ] Subgraph + worker open-sourced with deployment instructions for community
      indexers.
- [ ] Bug bounty page published before bounty starts.

---

## Rollout sequence (recommended)

1. **Sprint A** — items #1, #3, #4, #5 from this conversation (this PR / branch).
   Hardens the codebase before any auditor sees it.
2. **Sprint B** — wire Safe + Timelock on testnet. Run for ≥ 2 weeks.
3. **Sprint C** — kick off audit. Address findings in a dedicated branch.
4. **Sprint D** — bug bounty live, monitoring + keeper infra deployed.
5. **Sprint E** — mainnet deploy in stages: Base mainnet → Ethereum L1 if
   demand justifies the L1 gas. **Cap mint volume in week 1** with allowlist.
6. **Sprint F** — open mints, Hyperlane bridge, additional chains.

---

## Cross-references

- `audit/THREAT_MODEL.md` — actor model, attack surfaces, mitigations.
- `audit/INVARIANTS.md` — protocol invariants enforced by tests.
- `audit/SCOPE.md` — auditor scope sheet (in / out of scope contracts).
- `audit/RUNBOOK.md` — operational runbook (pause, withdraw, upgrade).
- `script/DeployMainnet.s.sol` — chain-parameterised deploy entrypoint.
