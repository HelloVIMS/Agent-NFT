# Escrow for agent services — plan

Status: design, not scheduled. Written 2026-09-29.
Scope: time-based access services first (the case that needs it most), one-shot jobs second.

## Problem

`AgentX402Receiver.payForService` pulls the buyer's USDC and splits it in the same transaction:
system fee to the treasury, creator royalty, the rest to the agent. That is right for a one-shot job
that is delivered in the same request. It is wrong for anything delivered over time.

An access service sells, say, 30 days of calls or model tokens on the seller's machine. If that
machine is down for 24 hours, the buyer paid for 30 days and got 29, and nothing in the protocol
notices. Today the seller is paid in full at purchase.

Goal: the buyer's payment is held, released to the seller as service is actually delivered, and the
share for downtime goes back to the buyer. 24 h of downtime on a 30-day block refunds 1/30 (3.33%),
minus any SLA allowance.

## Design

### Contracts

**New `AgentServiceEscrow` (UUPS, pausable, same owner/timelock as the receiver).** Separate from the
receiver so the receiver's audited payment path is unchanged and the new code is a bounded audit
unit.

- Funding. The buyer signs the same two messages as today, with the escrow as the target:
  an EIP-3009 `receiveWithAuthorization` to the escrow (EIP-3009 requires `msg.sender == to`, so the
  escrow must be the recipient) and an EIP-712 commitment binding
  `(agent, serviceId, token, amount, nonce, validBefore, termSeconds, epochSeconds, slaBps, watcherSet)`.
  The seller's daemon submits `open(...)` and pays gas, as it does for `payForService`.
- Splitting stays in one place. On release the escrow calls a new receiver function
  `distributeFromEscrow(token, amount, agent, serviceId)`, restricted to the escrow role, which runs the
  receiver's existing fee/royalty/TBA split. No second copy of the split logic.
- Release. Time is divided into epochs (proposal: 1 h). The seller calls
  `claim(escrowId, epochs[], attestations[])`. An epoch is payable when a quorum of the escrow's watchers
  signed it as up. Payable amount = `amount × upEpochs / totalEpochs`, less what was already claimed.
- Close. After `term + disputeWindow`, anyone calls `close(escrowId)`: the unclaimed remainder (down
  epochs, plus up epochs the seller never claimed) is refunded to the buyer.
- SLA allowance. `slaBps` (e.g. 100 = 99% uptime) lets that many down epochs count as up, so a few
  minutes of restart don't generate refunds.
- Early cancel (optional, v2): the buyer ends early; future epochs refund, less a cancellation fee set
  by the seller in the service terms.

### Watchers and evidence

The contract cannot see whether a machine is up, so attestations come from **watchers**: nodes that
probe the seller and sign what they saw.

- Probe. Each watcher, every few minutes per active escrow:
  1. The seller's signed heartbeat on the discover swarm is fresh (already published every 60 s).
  2. A vimslink call to the seller's always-allowed liveness route (`GET /api/health` over the tunnel,
     never metered) succeeds.
  An epoch is up for a watcher if at least k of its probes in that epoch succeeded (proposal: 2 of the
  ~12).
- Attestation. EIP-712 `{escrowId, epoch, up}` signed by the watcher's key. Watchers publish
  attestations on the discover swarm channel. Sellers collect them for claims, buyers for disputes.
- Quorum. The escrow records a watcher set and an M-of-N threshold when it opens. An epoch is payable
  only with M up-attestations. Conflicting attestations for the same epoch resolve to down, so the
  buyer gets the benefit of the doubt.
- Who watches. This is the open decision. Options:
  1. **VIMS nodes at launch.** The production origin plus one independent host. Simple and fast, but
     the operator is trusted.
  2. **An open, staked watcher set.** Watchers bond USDC in a `WatcherRegistry`, and provably false
     attestations (for example, up while the seller's own heartbeats show a gap) are slashed. This is
     trust-minimised, but it is a larger contract and an economic design to audit.
  Recommended path: launch with (1), and design the attestation format so (2) can replace the set
  without migrating escrows.

### Disputes

With quorum attestations, most disputes never happen: down epochs simply aren't payable. The remaining
cases:

- Seller claims up epochs the buyer believes were down. Claims only become final after
  `disputeWindow` (proposal: 48 h). Within it, the buyer can call `challenge(escrowId, epoch, downAttestations)`.
  A down quorum for a claimed epoch reverses that epoch's payment.
- Watchers are unavailable. Epochs with no quorum are not payable and refund at close. This pushes
  sellers to keep watcher coverage healthy, which is the right incentive.
- One-shot jobs (v2). Hold the payment until the buyer accepts, or until an acceptance window passes,
  which auto-releases it. A rejection needs an arbiter: a re-run by an independent agent, or a
  watcher-style verifier panel. That is a separate design, and the reason jobs come second.

## Off-chain changes

- **Daemon, seller side.** Access fulfilment keys grant validity to escrow state. The grant stays active
  while the escrow is funded and open, and is revoked at close. Claims run on a schedule (daily) with
  gathered attestations. Earnings show gross, claimable, claimed and refunded amounts.
- **Daemon, watcher mode.** `VIMS_WATCHER=1` probes active escrows from the escrow's `Opened` events,
  signs attestations with a dedicated key, and publishes them. It runs on its own port per the
  deployment rules.
- **Buyer side.** Hire dialog and Access page: "held in escrow · released as delivered", a live view of
  up/down epochs, and `challenge` from the UI during the window. Renewals (subscriptions) open a new
  escrow per block.
- **SDK.** Mandate/payment signing gains the escrow domain and the extra commitment fields.
  `checkSellerManifest` accepts the escrow as a valid receiver.

## Sizing

| Piece | Size | Notes |
|---|---|---|
| `AgentServiceEscrow` | ~400–600 lines Solidity | open / claim / challenge / close, EIP-712, UUPS |
| Receiver `distributeFromEscrow` | ~40 lines | upgrade of the existing receiver proxy |
| `WatcherRegistry` (staked, later) | ~300 lines + economics review | only for option 2 |
| Tests | invariant suite: funds conserved (claimed + refunded + held = funded), no double claim, no claim after close | Foundry, fork tests against Base USDC |
| Daemon watcher + claims + UI | medium | reuses heartbeat, vimslink, ledger, grants |
| Audit | adds ~1 contract to the external audit scope in `MAINNET_READINESS.md` | escrow should land before the external audit, not after |

## Decisions needed

1. Watchers at launch: VIMS nodes (recommended first) or an open, staked set.
2. Epoch length (1 h proposed) and dispute window (48 h proposed).
3. Default SLA allowance (99% proposed), and whether sellers may set their own.
4. Whether escrow is required for access services or optional per service. Recommended: required
   for access services, optional for jobs.
5. Who pays gas for claims and closes. Proposal: seller for claims, anyone for close, with the refund
   going to the buyer regardless.
