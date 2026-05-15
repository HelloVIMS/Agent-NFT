# Agent NFT — Internal Security Audit (INQTEL-grade)

> **Scope:** all contracts under `src/` at HEAD of `main`.
> **Reviewer:** in-house, pre-external-audit pass. Findings ordered by severity.
> **Status:** pre-deployment. No mainnet artefacts exist yet.
> **Test coverage at audit time:** 255/255 passing across 10 suites.
> **Status update (post-fixes):** M-1, L-1, L-2, L-3, L-4, I-1, I-4 closed in this revision. I-2 (timelock ownership) is operational, performed at deployment. I-3 confirmed mitigated. I-5 (bridge) deferred to dedicated audit before cross-chain enable.

This document is the internal pre-flight check. It is **not** a substitute for
an independent third-party audit before mainnet. Treat every finding here as
an open issue until either fixed or explicitly accepted with rationale.

---

## Severity legend

| Tag | Meaning                                                                  |
| --- | ------------------------------------------------------------------------ |
| C   | Critical — funds loss, identity takeover, or upgrade hijack possible.    |
| H   | High — significant economic or governance harm; requires user action.    |
| M   | Medium — exploitable under specific conditions; design hardening needed. |
| L   | Low — defence-in-depth or correctness improvement.                       |
| I   | Informational — style, gas, observability.                               |

---

## Findings

### C-1 — None
No critical findings at this revision.

### H-1 — None
No high findings at this revision.

### M-1 · ✅ CLOSED — `AgentX402Receiver.payForService` auth-redirect by service collision

**File:** `src/AgentX402Receiver.sol:199-239`

EIP-3009 binds the signature only to `(from, to, value, validAfter,
validBefore, nonce)`. It does **not** bind the *purpose* of the payment
(`agentId`, `serviceId`). Consequence: if an attacker sees a user's signed
authorization in the mempool and a *different* registered service exists with
the **same `price` and same token**, the attacker can settle the auth against
that other `(agentId', serviceId')` pair. The user pays the same amount but
to the wrong agent and with the wrong split.

The nonce is single-use, so this is a one-shot front-run. Window = mempool
visibility duration before the legitimate facilitator transaction lands.

**Mitigation options (pick one before mainnet):**

1. **EIP-712 commit wrapper (recommended).** Add a second signature bound to
   `keccak256("AgentX402Pay(uint256 agentId,bytes32 serviceId,uint256 nonce,...)")`
   — verify it inside `payForService` before calling `receiveWithAuthorization`.
   Adds ~2k gas. Keeps EIP-3009 compatibility intact.
2. **Per-service token + price uniqueness invariant.** Reject `registerService`
   if any other agent already prices the same `(token, price)` pair. Cheap on
   gas at register-time but creates a global namespace constraint.
3. **Off-chain mitigation only.** Rely on the x402 facilitator using a
   private mempool / sequencer-ordered relay (e.g., Flashbots / CB sequencer).
   Reduces attack surface but is operational, not cryptographic.

**Resolution:** Implemented option 1 — EIP-712 `PaymentCommitment` typed-data
signature is required alongside the EIP-3009 authorization. The commitment
binds `(agentId, serviceId, token, amount, nonce, validBefore)` to the
payer's signature, making redirection cryptographically impossible. The
shared `nonce` is also the EIP-3009 nonce, so single-use semantics carry
over. See `AgentX402Receiver.PAYMENT_COMMITMENT_TYPEHASH` and
`hashPaymentCommitment(...)`. Two regression tests cover the attack vector:
`test_RevertWhen_CommitmentSignedByWrongKey` and
`test_RevertWhen_CommitmentRedirectsToOtherService`.

---

### L-1 · ✅ CLOSED — `AgentMemory.addVersion` delta-on-empty

**File:** `src/AgentMemory.sol:176`

```solidity
if (versionType == TYPE_DELTA && arr.length > 0 && baseVersion >= arr.length) revert InvalidRange();
```

When `arr.length == 0`, the guard short-circuits and a `TYPE_DELTA` entry is
appended with no parent. Off-chain Pixelog tooling may misinterpret this as a
delta over a phantom base.

**Resolution:** Implemented as written — see `AgentMemory.sol:187-190`.

---

### L-2 · ✅ CLOSED — unbounded view returns

**Files:**
- `src/AgentMemory.sol:282,287` — `versionsByCategory`, `versionsByTier` return entire arrays.
- `src/AgentContextRegistry.sol:228` — `getAllFiles` returns entire array.
- `src/AgentMemory.sol:` (no `getAllVersions`, paginated `getVersionsRange` exists — good).

For `MAX_PIXE_VERSIONS = 10_000` an indexed array can exceed the typical
`eth_call` gas ceilings of public RPC providers (~50M gas, copy of 10k uints
≈ 320 KB → roughly 8M gas for memory expansion alone). Off-chain readers
without their own node will hit RPC limits.

**Resolution:** Added paginated variants. Unbounded versions retained for
archive-node clients.
- `AgentMemory.versionsByCategoryRange`, `versionsByTierRange`, `getVersionsRange`
- `AgentContextRegistry.getFilesRange`, `filesByCategoryRange`

---

### L-3 · ✅ CLOSED — token allowlist

**File:** `src/AgentX402Receiver.sol:159-174`

`registerService` accepts *any* `token` address. A malicious or buggy
ERC-3009-shaped contract can be registered, and even though `safeTransfer` /
`receiveWithAuthorization` will revert on misbehaviour, the contract will
still emit a `ServiceRegistered` event that downstream indexers may treat as
authoritative.

**Resolution:** Implemented `mapping(address => bool) public allowedTokens`
with owner setter `setTokenAllowed(token, allowed)`. `registerService`
reverts with `TokenNotAllowed` for unlisted tokens. `DeployAgent.s.sol`
seeds USDC at deploy time.

---

### L-4 · ✅ CLOSED — `creatorCut` event accuracy

**File:** `src/AgentX402Receiver.sol:232-233`

```solidity
if (creatorCut > 0 && creator != address(0)) token.safeTransfer(creator, creatorCut);
else if (creatorCut > 0) agentCut += creatorCut;
```

If the creator address is unset (zero), the creator portion silently merges
into the agent cut. Behaviour is by design but is **not surfaced in events**:
the emitted `creatorCut` will be the *intended* amount even though the
creator received zero.

**Resolution:** `creatorCut` is zeroed and folded into `agentCut` before any
transfer or event emission. The `ServicePaid` event now reports the
actually-disbursed values. Same correction applied to the `quoteSplit` view
for consistency.

---

### I-1 · ✅ CLOSED — emergency pause

In incident response (e.g., a discovered M-1 exploit, or an OZ disclosure
affecting `Initializable`), there is no `paused` state. Owner can upgrade via
UUPS but that's a 30+ second operation across simulation, signing, and
broadcast. A `Pausable` mixin would let an emergency pause happen in one tx.

**Resolution:** All three contracts now inherit `PausableUpgradeable` and
expose owner-gated `pause()` / `unpause()`. Writes (`addVersion`,
`consolidate`, `addFile`, `updateFile`, `setEnabled`, `registerService`,
`updateService`, `payForService`) are gated by `whenNotPaused`. View
functions remain accessible during pause.

---

### I-2 · `AgentX402Receiver.systemFeeBps` — no minimum delay on changes

Owner can flip `systemFeeBps` from 0 → 500 (5%) atomically. Honest agents
between block N and N+1 may see their margin halved. Standard mitigation is
a 24h `Timelock`-controlled owner.

**Fix (operational, not contract):** transfer ownership to a `TimelockController`
before mainnet. Same applies to `setIdentityRegistry` on every UUPS contract.

---

### I-3 · Initialization front-running surface (UUPS proxies)

Every UUPS impl calls `_disableInitializers()` in its constructor — good. The
proxy `initialize()` is open to first-caller. Deployment scripts must be
atomic (proxy + initialize in one broadcast). The `DeployAgent.s.sol` script
already does this pattern via `abi.encodeCall(...initialize, (...))` to the
proxy constructor — confirmed safe.

No action — documenting the existing safety.

---

### I-4 · ✅ CLOSED (mitigated by getter) — `latestConsolidatedVersion` zero-collision

If `agentId` has zero consolidations, `latestConsolidatedVersion` returns 0,
which collides with version index 0. `getLatestConsolidated` correctly
guards on `_consolidations.length == 0`, but a third-party calling the public
mapping directly will misread version `0` as consolidated.

**Resolution:** Added `hasConsolidations(agentId) returns (bool)` view to
disambiguate "version 0 is latest consolidation" from "no consolidations
yet". `getLatestConsolidated` already reverts on empty history, so the
bug-prone code path is the public mapping; documentation now points
integrators at the safe getter. Storage layout preserved (no breaking
change to existing storage slot ordering).

---

### I-5 · `AgentBridge` — out of scope for this pass

The Hyperlane bridge was not deeply re-audited in this pass (test fixes
landed, but trust assumptions on the mailbox + remote bridge whitelist were
not re-verified). Pre-mainnet: dedicated bridge audit covering message
authenticity, replay, and economic griefing via fee underpayment.

---

## Coverage map

| Contract                  | Pass-through review | Targeted review | Tests        |
| ------------------------- | :-----------------: | :-------------: | ------------ |
| `AgentIdentityRegistry`   | ✓                   | ✓               | 42 + fuzz    |
| `AgentTBARegistry`        | ✓                   | ✓               | 12           |
| `AgentAccount`            | ✓                   | —               | 12           |
| `AgentReputationRegistry` | ✓                   | ✓               | 10           |
| `AgentPaymentRouter`      | ✓                   | —               | 9            |
| `AgentContextRegistry`    | ✓                   | ✓ (this pass)   | 23 + fuzz    |
| `AgentMemory`             | ✓                   | ✓ (this pass)   | 26 + fuzz    |
| `AgentX402Receiver`       | ✓                   | ✓ (this pass)   | 18 + fuzz    |
| `AgentCollectionFactory`  | ✓                   | —               | 14           |
| `hyperlane/AgentBridge`   | partial             | deferred        | 84 (TBA path)|

---

## Pre-mainnet checklist

- [ ] Close **M-1** with EIP-712 commit wrapper.
- [ ] Apply **L-1**, **L-2**, **L-3**, **L-4** fixes.
- [ ] Move all `Ownable` ownership to a `TimelockController` (>= 24h delay).
- [ ] Add `Pausable` to `AgentMemory`, `AgentContextRegistry`, `AgentX402Receiver`.
- [ ] External audit firm engagement (Trail of Bits / Spearbit / OpenZeppelin).
- [ ] Run `slither --triage-mode`, `mythril analyze`, and `halmos --solver z3`.
- [ ] Foundry invariant tests for memory/context monotonicity and x402 split-sum.
- [ ] Bridge re-audit (I-5) before enabling cross-chain agent transfers.
- [ ] Bug bounty program (Immunefi / Cantina) live before mainnet TVL.
- [ ] Deploy verified bytecode to Base Sepolia → 30-day soak → mainnet.
- [ ] Multisig (3-of-5 minimum) on `Ownable` and `TimelockController` admin role.
- [ ] Incident response runbook published (key revoke, pause, upgrade).

---

## Out-of-scope for this pass

- Off-chain x402 facilitator implementation (separate codebase).
- Pixelog Go binary (separate audit, separate threat model).
- Frontend signing flows (will be audited as part of UI security pass).
- Key custody (HSM / browser keystore selection).
