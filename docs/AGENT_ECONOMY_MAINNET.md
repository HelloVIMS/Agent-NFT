# Agent economy on mainnet — feasibility and plan

Status: planning, deferred. Written 2026-09-29.
Complements `MAINNET_READINESS.md` (the protocol checklist). This document covers what the agent
economy adds on top of it, where it stands, the order to do things in, and what has to be decided.

## Where things stand

Everything runs on Base Sepolia (84532). The full paid path is exercised live there:

- On-chain hires: mandate, payment commitment and USDC authorization, settled by
  `AgentX402Receiver` (0.5% system fee, royalty, rest to the agent's TBA), with signed delivery
  receipts.
- Outputs:
  - In the window, VIMS Drive, Nostr DM and email: delivered live.
  - Pull request: tested against GitHub/GitLab stand-ins only.
- Access services: blocks of calls or model tokens, a metered vimslink grant per purchase, and
  auto-renewal.
- Transport: swarm discovery, then a direct vimslink tunnel from desktop and from agent.vims.com, with
  swarm fallback.
- Agents hiring agents: job subcontracts with per-hop receipts, and a delegated hiring allowance.

Nothing is deployed on any mainnet. In the SDK, chains 8453, 1, 10, 42161 and 137 have zero addresses.

## Blockers inherited from `MAINNET_READINESS.md`

These gate everything below. Status as of this writing:

| Item | Status |
|---|---|
| External audit (receiver, router, identity, collection, memory/context/reputation) | not started |
| Gnosis Safe treasury replacing EOA `0xE488…61b9` | not done; that EOA is owner and treasury on Base Sepolia |
| Safe + `TimelockController` (24–48 h) on every UUPS `_authorizeUpgrade` | not done; `onlyOwner` today |
| Pause guardian separate from owner | not done |
| Mainnet deploy via `script/DeployMainnet.s.sol` + `deployments/<chain>.json` | script exists, never run on mainnet |
| Per-chain USDC wiring in SDK and marketplace | Base mainnet USDC is in the deploy script, not yet in the SDK chain maps |
| Bug bounty | not live |

## What the agent economy adds

1. **Audit scope.** The receiver's payment path is already in scope. Add:
   - the access-service and subcontract semantics, which are off-chain but spend funds: the
     daemon's `hireViaMandate` caps, the buyer budget and the delegated allowance;
   - the new escrow contract, if it ships first (recommended, see `ESCROW_PLAN.md`).
2. **Chain-parameterised daemon.** Several paths default to `chain_id` 84532:
   - access purchases and the subcontractor;
   - the discover catalog;
   - the hire tool.
   Mainnet needs:
   - a per-install default chain, with testnet opt-in for development;
   - chain id carried in every ledger entry (already a field);
   - explorer links per chain (the UI has 84532 and 8453).
3. **Discover indexer and worker on mainnet.** The chain indexer, agent.vims.com's worker and the
   heartbeat relay all point at Base Sepolia. Each needs a mainnet deployment and chain-scoped
   storage, so testnet agents never appear as mainnet agents.
4. **Seller key custody.** A seller's daemon holds the EOA that broadcasts settlements and signs
   receipts, and today pays its subcontractors from the same key. On mainnet:
   - split the settlement broadcaster (gas only) from the spending wallet (subcontracts, access
     purchases);
   - keep the spending wallet in the OS keychain behind the budget.
   The keychain and budget exist; the split does not.
5. **Buyer protections before real money.**
   - The daily buyer budget and delegated allowance exist.
   - Add a per-agent spending cap and an allowlist option for autonomous hires.
   - Escrow for time-based access (see `ESCROW_PLAN.md`).
6. **Operations.**
   - Monitoring for owner-key activity, `pendingSystemRoyalties`, revert spikes on settlement, and
     watcher coverage once escrow exists (Defender/Tenderly).
   - A runbook for pausing the receiver and escrow.
7. **Identity registry: settle the mainnet version.**
   - The repo source isn't what Base Sepolia runs. An unreleased "API cleanup" (`daa16ee`) removed
     `mintToCollectionWithRoyalty`, `hasSVGImage`, `agentCreator`, `anchorAgentCount` and
     `calculateRoyaltySplit`, which the app still calls, and added `contractURI`. Decide the final
     surface once, and deploy that to mainnet with the SDK unpinned in the same change
     (`vimsbot-sdk/scripts/abi-pins`).
   - Remove the on-chain SVG slot. While `setSVGImage` is set, `tokenURI()` returns generated JSON
     instead of the agent's metadata, which hides its services and avatars, and it can't be cleared.
     The mint UI no longer uses it: SVGs go into on-chain metadata as `image_data`, which does the
     same job without the trap.
8. **Test listings.** Base Sepolia has permanent test listings on agent #241: `vims-e2e-access`,
   `vims-e2e-deliver`, `vims-e2e-report` (removed locally). They stay on testnet. Mainnet starts
   clean.

## Order

1. Treasury Safe, timelock and pause guardian on **Base Sepolia first**, then rehearse an upgrade and a
   pause through them. Cheap, and it de-risks the step people get wrong.
2. Escrow contract plus the receiver's `distributeFromEscrow`, with invariant tests, on Base Sepolia.
3. Freeze the contract set. Run the external audit on everything including escrow. Fix findings.
4. Daemon and SDK chain parameterisation, the key split, and mainnet indexer/worker, all verifiable
   on testnet with the mainnet code paths.
5. Deploy to **Base mainnet only** (lowest fees, and where USDC EIP-3009 is canonical). Verify
   contracts. Publish `deployments/base.json`.
6. Bug bounty live before opening sales. Start with a spending cap per agent, and raise it after a
   quiet period.
7. Other chains only on demand, each a separate deploy and indexer.

## Feasibility

- **Technically:** feasible with the current architecture. Nothing in the paid path is
  testnet-specific except addresses and defaults. The deploy script is chain-parameterised and
  asserts the chain id.
- **Main risks:**
  - funds held in upgradeable contracts behind a single EOA, fixed by step 1;
  - the escrow's watcher trust model (`ESCROW_PLAN.md`);
  - autonomous spending bugs in daemons, mitigated by budgets and caps and made visible in the
    ledger.
- **Critical path:** the external audit (lead time and fix cycle), then escrow if it is included.
  Everything else can proceed in parallel.

## Decisions needed

1. Target date. It decides whether escrow lands before the audit (recommended) or after, which means
   a second audit.
2. Treasury Safe signers and threshold; timelock delay (24 or 48 h).
3. Launch chain: Base mainnet only (recommended), or more.
4. Whether mainnet listings require escrow for access services from day one.
5. Launch caps: per-agent daily sales cap and default buyer budget for new installs.
