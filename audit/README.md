# vimsbot Audit Prep Packet

> Read order: **SCOPE.md → THREAT_MODEL.md → INVARIANTS.md → RUNBOOK.md**.
>
> Companion docs (in `docs/`):
> - `MAINNET_READINESS.md` — go-live checklist
> - `AUDIT_2026-05-09.md`, `INQTEL_AUDIT_2026-05-09.md`,
>   `SECURITY_AUDIT_FINDINGS.md`, `ECONOMIC_AUDIT.md` — historical
>   internal audits (testnet)

## What this protocol is

An on-chain registry + payment + evolution layer for AI agents. Every
agent is an ERC-721 NFT minted by `AgentIdentityRegistry`; each agent
optionally owns a Token-Bound Account (ERC-6551) wired through
`AgentTBARegistry` and an EntryPoint v0.7 4337 module
(`AgentAccount`).

Revenue flows:

```
                 ┌──────────────────┐
   buyer ──ETH──▶│ AgentPaymentRtr  │── 0.5% ─▶ pendingSystemRoyalties
                 │   (or USDC)      │── creator% ─▶ creator (auto-fwd)
                 └────────┬─────────┘── recipient% ─▶ TBA / owner
                          │
                          └──── EIP-3009 sigs ──▶ AgentX402Receiver
                                                 (atomic split + nonce guard)
   secondary  ──ERC-2981─▶ AgentRoyaltyVault ─── creator + treasury
```

Generative collections live as their own ERC-721 contracts deployed
through `AgentCollectionFactory` against a beacon proxy
(`AgentCollectionImpl`); each token in a collection is itself an agent
NFT in the global identity registry, so secondary royalty + x402
service registration all "just work" through the same primitives.

Evolution = on-chain mutable metadata. Curated reference hooks in
`src/hooks/` mutate `tokenURI` on lifecycle events
(`BeforeMint/AfterMint/Transfer/OnTrigger`).

## Quick stats

- Solidity: 0.8.20 (target), pinned to 0.8.24 by foundry.toml.
- LOC (.sol, src only): ~8,200.
- Test count (forge): **614** unit + fuzz + invariant.
- External deps: OpenZeppelin v5, ERC-6551 canonical registry, Chainlink AggregatorV3.

## Repository layout

```
src/                           production contracts
  AgentIdentityRegistry.sol    ERC-721 identity + memory + reputation hub
  AgentCollectionImpl.sol      per-collection ERC-721 (beacon proxy target)
  AgentCollectionFactory.sol   creates collections + splitters
  AgentPaymentRouter.sol       split routing (system / creator / agent)
  AgentX402Receiver.sol        atomic ERC-3009 settler with EIP-712 commits
  AgentRoyaltyVault.sol        ERC-2981 secondary royalty splitter
  AgentRoyaltySplitter.sol     primary-mint splitter (CREATE2)
  hooks/                       evolution hook reference impls
  *Lib.sol, *EIP712.sol, …     linked libraries (bytecode budget)

test/                          forge unit + fuzz + invariant
  audit/                       audit-grade properties (this PR)

script/                        forge scripts
  DeployMainnet.s.sol          chain-parameterised production deploy
  DeployHooks.s.sol            reference hook deploys

audit/                         this packet
  SCOPE.md                     in/out of scope contracts
  THREAT_MODEL.md              actor model + attack surface
  INVARIANTS.md                protocol invariants enforced by tests
  RUNBOOK.md                   ops procedures (pause, rotate, upgrade)
```

## Running the suite

```bash
forge test                 # full unit + fuzz + invariant
forge test --gas-report    # gas baseline
forge snapshot             # gas snapshot diff
forge coverage             # line + branch coverage
```

## Key external integrations to scrutinise

1. **ERC-6551 canonical registry** at `0x000000006551c19487814612e58FE06813775758` —
   we trust it on every chain; a compromise of that address breaks our TBA
   derivation. Mitigation: pin the address in `core/contracts.ts`.
2. **EIP-3009 (USDC `receiveWithAuthorization`)** — `AgentX402Receiver`
   relies on USDC's nonce uniqueness; we layer an EIP-712 "purpose
   commitment" on top so a leaked authorization can't be redirected to
   an unrelated agent. See `THREAT_MODEL.md §3`.
3. **Chainlink AggregatorV3** in `OracleHook` — stale-price guards are
   enforced; reverts cleanly if `updatedAt` is too old.
4. **EIP-712 signature flow** — `AgentX402Receiver.hashPaymentCommitment`
   binds (agentId, serviceId, token, amount, nonce, validBefore). Tampering
   any field breaks recovery; replays caught by USDC's own nonce guard.

## Versioning

Pre-mainnet semver: **v0.9.1** (testnet). 1.0 ships at mainnet.
See `docs/MAINNET_READINESS.md`.
