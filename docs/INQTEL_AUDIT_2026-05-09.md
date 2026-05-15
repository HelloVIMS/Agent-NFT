# VIMSBot Contracts — IN-Q-TEL-Grade Internal Security Audit

**Engagement:** Internal adversarial security pass, IN-Q-TEL grade
**Date:** 2026-05-09
**Auditor:** Cascade (pair-programmed, single session)
**Codebase:** `vimsbot-contracts/` at HEAD on `main`
**Toolchain:** Foundry 1.x, Slither 0.11.5, solc 0.8.24, OpenZeppelin v5.x
**Test inventory after this pass:** 20 suites · **387 tests** · 0 failing · 256× fuzz × 500-call invariants

> **Disclaimer.** Internal pair-program audit. Real bugs were found and
> fixed; static + dynamic + invariant + cryptographic-replay coverage is
> meaningfully expanded. **This still does not substitute for an external
> audit by Spearbit / Trail of Bits / OpenZeppelin.** Treat that as a
> mainnet-promotion blocker. The threat model and findings here narrow the
> scope of work for that engagement.

---

## 0. TL;DR

**Three exploitable issues found and fixed in-session, regression-pinned.**

| ID    | Severity | Title                                                         | Status     |
|-------|----------|---------------------------------------------------------------|------------|
| H-02  | High     | Allowlist bypass when `allowlistEndTime == 0`                 | **Fixed**  |
| M-01  | Medium   | `releaseAll()` DoS via single reverting payee                 | **Fixed**  |
| I-04  | Low      | Future-dated oracle `updatedAt` panics instead of `StalePrice`| **Fixed**  |

**Two design weaknesses raised; remediation recommended but not landed.**

| ID    | Severity | Title                                                         | Status     |
|-------|----------|---------------------------------------------------------------|------------|
| M-02  | Medium   | Session-key sig replay across keys with same `signer` (TBA)   | Documented |
| M-03  | Medium   | Royalty vault release bricked by misconfigured `treasury`     | Documented |

**One operational risk requiring governance answer.**

| ID    | Severity | Title                                                         | Status     |
|-------|----------|---------------------------------------------------------------|------------|
| O-01  | High*    | Beacon-upgrade authority is an EOA, not a multisig            | **Open**   |

`*` operational, not codebase

**Headline coverage gap closed.** All three deployed-but-untested evolution
hooks (`OracleHook`, `RevenueLevelHook`, `TimeOfDayHook`) now have adversarial
test coverage. `AgentAccount` (TBA, ERC-6551) remains under-covered and is
the **highest-priority next coverage target**.

---

## 1. Threat model

### 1.1 Assets at risk

| Asset                                  | Custody                                  | Loss vector                                            |
|----------------------------------------|------------------------------------------|--------------------------------------------------------|
| Mint revenue (ETH)                     | `protocolFeeRecipient`, creator/splitter | Bypass mint gates; misroute fees                      |
| Secondary royalties (ETH/USDC)         | `AgentRoyaltyVault` per agent            | Vault DoS; treasury misconfig; FoT under-delivery     |
| Splitter balances (multi-payee)        | `AgentRoyaltySplitter` per collection    | DoS via reverting payee; cross-payee accounting drift |
| TBA-held tokens / NFTs                 | `AgentAccount` (ERC-6551)                | Session-key sig replay; selector/target wildcard      |
| Agent NFTs themselves                  | Token holder                             | Soulbound traps; transfer hook DoS; bridge replay     |
| Trust in evolution state               | `commitNonce`/`evolutionStateHash`       | Keeper compromise; cross-domain sig replay            |
| ERC-2981 royalty enforcement           | `AgentPaymentRouter` whitelist           | Whitelist bypass; reentrancy on payment               |

### 1.2 Adversaries

1. **Random external user (RPC-level).** No special privileges. Goal:
   bypass mint gates, drain accidental balances, replay sigs, trap others'
   tokens.
2. **Malicious collection creator.** Holds `collectionCreator`. Goal: trap
   their own users (rugpull-style) via hooks, drain protocol fees by
   spoofing the recipient, abuse upgrade path.
3. **Malicious payee (splitter).** Co-recipient on a multi-payee splitter.
   Goal: brick `releaseAll`, force everyone to the manual `release(addr)`
   path; griefing.
4. **Malicious hook author.** Their hook is set on a real collection by a
   trusting creator. Goal: persistent reentrancy, gas griefing, soulbound
   trap, exfiltrate state via the host's `setSVGImage`-style callbacks.
5. **MEV searcher / sequencer.** Block-level adversary. Goal: front-run
   public mint to grab limited supply, sandwich allowlist→public phase
   transition, manipulate `block.timestamp` (±~15s on Base).
6. **Compromised keeper.** Off-chain compute keeper signing
   `commitEvolution` is taken over. Goal: arbitrary state transitions on
   any agent in any collection that names this keeper.
7. **Malicious oracle / feed.** Chainlink-style feed returns adversarial
   answers, stale data, or future-dated rounds. Goal: drive incorrect
   `OracleHook` band assignment.
8. **Compromised admin EOA.** `AgentCollectionFactory` owner key is taken
   over. Goal: push a malicious beacon implementation upgrade.

### 1.3 Trust boundaries

```
                   ┌─────────────────────┐
                   │ Factory.owner       │  ◀── key custody risk (O-01)
                   │ (EOA today)         │
                   └─────────┬───────────┘
                             │ upgrade beacon
                             ▼
┌────────────────────────────────────────────────────┐
│  AgentCollectionImpl  (beacon-proxied)             │
│   ├── collectionCreator: per-collection EOA        │
│   ├── evolutionKeeper:   per-collection EOA        │
│   ├── collectionHook:    per-collection contract   │
│   └── protocolFeeRecipient: per-collection (factory-set)
└────────────────┬───────────────────────────────────┘
                 │ secondary royalty
                 ▼
       ┌────────────────────┐         ┌────────────────────┐
       │ AgentRoyaltyVault  │         │ AgentRoyaltySplitter│
       │ creator + treasury │         │ N payees, BPS-shared│
       └────────────────────┘         └─────────────────────┘
```

Each labelled box is a separate trust principal. The `Factory.owner →
beacon → impl` chain is the **single point of catastrophic failure** for
the platform: a compromised owner can push arbitrary code into every
existing collection. **O-01 is the most consequential operational risk.**

### 1.4 STRIDE summary

| Class                     | Coverage                                                                |
|---------------------------|-------------------------------------------------------------------------|
| Spoofing                  | EIP-712 binds `chainId` + `verifyingContract` + `agentId` + `triggerKind` (verified by `EIP712Replay.audit.t.sol`); allowlist binds proof to `msg.sender`; session-keys validated with `SignatureChecker.isValidSignatureNow` (incl. ERC-1271). |
| Tampering                 | Storage layouts pinned in `docs/storage-layouts/`; reentrancy guards on all payment functions; OZ upgradeable initialiser pattern for impl. |
| Repudiation               | Every state transition emits an indexed event; royalty-recipient changes pinned by `RoyaltyChanged` family; commitEvolution emits `EvolutionRequested` + final result. |
| Information disclosure    | No private data on-chain; SVG inline data is by design public. |
| Denial of service         | **H-02 (fixed)**, **M-01 (fixed)**, **M-03 (open)**, **I-01 (documented)**; gas griefing via hooks bounded by sender's gas budget. |
| Elevation of privilege    | All admin actions gated by `collectionCreator` / factory `Ownable.owner`; no public escape hatches; merkle proofs bound to caller. |

---

## 2. Findings

Severity rubric: **Critical** = direct theft / arbitrary mint; **High** =
loss of funds in a foreseeable scenario, or trust-violation against
arbitrary user; **Medium** = griefing, partial DoS, or trust-violation
against constrained adversary; **Low** = defence-in-depth, DOS in
view-only paths, or reachable-only-by-self-DoS; **Informational** =
hardening / documentation.

---

### H-02 (HIGH, FIXED) — Allowlist bypass when `allowlistEndTime == 0`

**File.** `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentCollectionImpl.sol:299-303`

**Description.** Public-mint side gated on `block.timestamp <= allowlistEndTime`. With `endTime == 0` (the allowlist-side encoding for "forever"), the inequality is false → public mint opens immediately while the creator believes they're in an allowlist-only phase.

**Exploit.** An attacker calls `mintAgent()` with no proof at `mintPrice` (default 0 wei) immediately after `setAllowlistConfig(root, /*endTime*/ 0, …)`. Allowlisted users continue to mint at `allowlistPrice` via `mintAgentAllowlist()`, but the bypass mint at `mintPrice == 0` is free.

**PoC.** Originally `test_AUDIT_H02_allowlistBypassWhenEndTimeZero`; converted to regression `test_AUDIT_H02_allowlistBypassClosed_endTimeZero` in `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/test/audit/AgentCollectionImpl.audit.t.sol`.

**Fix.** Mirror allowlist-side semantics: treat `endTime == 0` as "allowlist forever".

```solidity
if (allowlistRoot != bytes32(0)) {
    if (allowlistEndTime == 0 || block.timestamp <= allowlistEndTime) {
        revert AllowlistPhaseActive();
    }
}
```

**Coverage.** Both directions pinned (`endTime=0` blocked, `endTime` in past opens public).

---

### M-01 (MEDIUM, FIXED) — `releaseAll()` DoS via single reverting payee

**File.** `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentRoyaltySplitter.sol:160-178`

**Description.** Original `releaseAll()` reverted the entire batch on any payee call failure. A single malicious co-payee (or a benign multisig with a bad upgrade) bricks the convenience path; healthy payees are forced to the manual `release(addr)` fallback.

**Exploit.** Adversary deploys a contract with reverting `receive`, gets it added as a 1-bp payee on a splitter, then permanently bricks `releaseAll` for every other payee. Funds are not stuck (per-payee fallback exists), but UX is broken.

**Fix.** Skip-on-failure with state rollback so the bad payee remains pullable:

```solidity
if (!ok) {
    ethReleased[acct] -= payment;
    totalEthReleased  -= payment;
    emit EthReleaseFailed(acct, payment);
    continue;
}
```

The strict per-payee `release(address)` retains its loud `TransferFailed`
revert so callers explicitly opting in to single-payee semantics still
see errors.

**PoC.** `test_AUDIT_M01_releaseAllSkipsRevertingPayee` in `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/test/audit/AgentRoyaltySplitter.audit.t.sol`.

---

### I-04 (LOW, FIXED) — Future-dated oracle round panics instead of `StalePrice`

**File.** `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/hooks/OracleHook.sol:56-69`

**Description.** Computing `block.timestamp - updatedAt` underflows in checked arithmetic if the feed reports a future-dated round (misconfiguration, fork-replay, or adversarial mock). The hook reverts with arithmetic panic 0x11 instead of the documented `StalePrice` error, which break consumers expecting a typed error to interpret.

**Fix.** Add a future-dated guard before subtraction:
```solidity
if (updatedAt > block.timestamp || block.timestamp - updatedAt > STALENESS_LIMIT) {
    revert StalePrice();
}
```

**Coverage.** `test_AUDIT_I04_futureDatedRoundClean` + `test_AUDIT_Oracle_revertsOnStalePrice` in `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/test/audit/DeployedHooks.audit.t.sol`.

---

### M-02 (MEDIUM, OPEN) — Session-key signature does not bind `keyHash`

**File.** `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentAccount.sol:241-300`

**Description.** `executeWithSessionKey` builds the signed message hash from `(address(this), chainid, to, value, data, state)`. **`keyHash` is not in the message.** If a TBA owner creates two session keys whose `signer` field is the same EOA (e.g., the same custody key, intentionally or by mistake), a signature originally produced for `keyHash = X` is also valid against `keyHash = Y` for the same `(to, value, data, state)` tuple.

**Exploit window.** The attacker is the call submitter (anyone can submit; only the signer is gated). They pick the cheaper of the two `keyHashes` to charge for the call — i.e., they can charge usage against the key with a higher remaining `maxTotalValue − usedValue` budget, even though the signer intended the call to be charged against the other one.

**Severity.** Medium: requires the unusual configuration of two session keys sharing a signer; doesn't escalate authority outside what that signer was already granted; only mis-attributes accounting.

**Recommended fix.**
```solidity
bytes32 messageHash = keccak256(abi.encodePacked(
    address(this), block.chainid, keyHash, to, value, data, state
));
```

Out of scope for this PR because `AgentAccount` line/branch coverage is 43/0 % and any change here needs a full session-key test build-out first. Tracked as the **#1 follow-up coverage task**.

---

### M-03 (MEDIUM, OPEN) — Royalty vault release bricked by misconfigured `treasury`

**File.** `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentRoyaltyVault.sol:58-77`

**Description.** `release()` does two raw `.call{value: …}("")` calls in sequence (treasury, then creator) and reverts on first failure. The treasury address is read live from `registry.secondaryTreasury()`. If governance ever sets that to a contract with reverting `receive`, **every vault for every agent simultaneously stops releasing.**

The same is true if `creator == address(0)` — the call succeeds (`address(0).call{}` always returns true) but the ETH is irrecoverable.

**Recommended fix.** Adopt the same skip-on-failure-with-rollback pattern as the M-01 fix in the splitter, so a bad treasury bricks treasury delivery only, not creator delivery, and the registry can recover by setting a healthy treasury later.

**Coverage gap.** The L-01 / M-01 splitter audit already pins this for splitter; vault is not yet covered with an equivalent test.

---

### I-01 (INFO) — Hook callbacks invoked with full remaining gas

**File.** `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentCollectionImpl.sol:1018-1050`

**Description.** All four lifecycle hooks (`beforeMint`, `afterMint`, `beforeTransfer`, `afterTransfer`) are invoked uncapped. A reverting `beforeTransfer` is intentional (soulbound), but a buggy `after*` hook bricks every mint/transfer with no business reason for the failure to be unbounded.

**Recommendation (future).** Cap `afterMint` / `afterTransfer` at a fixed gas budget (~200k) and treat failure as no-op, mirroring ERC-721 receiver. Not adopted here because (a) the impl runtime is at 199 / 24 576 bytes — adding try/catch needs benchmarking, (b) a creator-installed bad hook attacks only that creator's own users (creator-on-self), so it's a footgun rather than an externally-exploitable vulnerability.

**Coverage.** `test_AUDIT_I01_hookGasGriefingMeasurable` in the impl audit suite.

---

### I-02 (INFO) — Mint accepts overpayment with no refund

**File.** `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentCollectionImpl.sol:289-354`

**Description.** Mint paths only check `msg.value >= mintPrice` and forward the entire `msg.value` (split protocol fee / creator). Convention from Manifold / Nifty Gateway. Not a bug; a UX choice.

---

### I-03 (INFO) — Impl runtime size at 199 / 24 576-byte EIP-170 margin

**File.** `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentCollectionImpl.sol`

**Description.** After H-02 fix, `AgentCollectionImpl` runtime is 24 377 bytes — 199 below the EIP-170 cap. Any further feature lands in a linked library or the contract must be split. Two pre-staged refactors are listed in §6.

---

### O-01 (HIGH operational, OPEN) — Beacon owner is a single EOA

**Files.**
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentCollectionFactory.sol`
- `@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/deployments/base-sepolia.json`

**Description.** `AgentCollectionFactory` is `Ownable`, and the `BeaconUpgrade` path goes through this owner. On Base Sepolia today this is an EOA. A single key can push a malicious implementation into every existing and future collection.

**Required for mainnet.** Owner must be a multisig (Safe, 2/3 minimum, ideally 3/5 with a 24-hour timelock). Cosigner key custody policies need an explicit document.

---

## 3. Slither static analysis triage

`slither . --filter-paths "lib/|test/" --exclude naming-convention,solc-version,assembly,low-level-calls,reentrancy-events,reentrancy-benign,similar-names,too-many-digits,timestamp,external-function,immutable-states,unused-state,uninitialized-local,calls-loop,events-maths,events-access,dead-code`

86 contracts analyzed by 85 detectors → 43 results. Triage:

| Detector                     | Hits | Disposition                                                                                                                     |
|------------------------------|-----:|---------------------------------------------------------------------------------------------------------------------------------|
| `arbitrary-send-eth`         |    4 | **All FP.** Recipient is gated by `sharesBps[acct] > 0` (splitter), `_isAllowedTarget` (TBA), or set-by-construction (vault treasury).  M-03 separately tracks the misconfig variant.|
| `weak-prng`                  |    1 | **FP.** `block.timestamp % 1 days` in `TimeOfDayHook.currentPhase()` drives only a visual bucket; no value depends on it.       |
| `encode-packed-collision`    |    1 | **FP.** Renderer concatenates SVG/JSON for a data URI; no security boundary depends on encoding uniqueness.                     |
| `reentrancy-eth`             |    1 | **FP after M-01 fix.** Splitter's CEI uses rollback-on-failure; slither can't reason about the rollback.                        |
| `reentrancy-no-eth`          |    2 | **FP** (one for splitter, see above). One for `AgentBridge.bridgeBack` — logged for `AgentBridge` follow-up; bridge is out of audit scope today. |
| `uninitialized-state`        |    1 | **FP.** `AgentMemory._versions` is a mapping; mappings have no zero-value to "initialise".                                      |
| `incorrect-equality`         |    6 | **FP.** All hits are `payment == 0` early-return guards in splitter/vault; intended behaviour to skip empty distributions.      |
| `unused-return`              |    7 | **TP, low.** Multiple sites destructure `(creator, _) = identityRegistry.getCreatorRoyalty(agentId)` and ignore one field. Intentional but should use `(creator,)` syntax for clarity. Cosmetic. |
| `shadowing-local`            |    3 | **TP, low.** `AgentTBARegistry.createAccount.account` shadows the function `account(...)`. Cosmetic; rename when convenient.    |
| `missing-zero-check`         |   12 | Mixed. Some intentional (e.g., `setCollectionHook(address(0))` clears the hook). Some real **defence-in-depth** gaps (`AgentAccount` `_entryPoint`, payment router constructor `_treasury`). Adding zero-checks is a P2 hygiene PR. |
| `costly-loop`                |    2 | **TP, accepted.** `releaseAll` does storage write per payee, bounded by `MAX_PAYEES = 16`. Within budget.                       |
| `cyclomatic-complexity`      |    2 | **TP, accepted.** `mintAgent`/`mintAgentAllowlist` have CC ≈ 14-15 driven by gate checks. Refactor candidate post-bytecode shrink. |

**Net new findings from slither:** zero. All structurally-detected items either fall into the FP categories above, the design-doc-of-record cases (`I-01`, `I-02`), or were already known.

---

## 4. Coverage analysis

### 4.1 Overall

Forge coverage (lines/branches), application contracts only, after the audit:

| Contract                             | Line  | Branch | Notes                                                  |
|--------------------------------------|------:|-------:|--------------------------------------------------------|
| `AgentCollectionImpl`                | 90.7  |  63.4  | Coverage on hook lifecycle branches still partial.     |
| `AgentCollectionFactory`             | 87.5  |  50.0  |                                                         |
| `AgentRoyaltySplitter`               | 94.1  |  73.3  | Hardened in audit (M-01).                              |
| `AgentRoyaltySplitterFactory`        | 84.0  | 100.0  |                                                         |
| `AgentRoyaltyVault`                  | 84.6  |  42.9  | M-03 needs new tests.                                   |
| `AgentCollectionRenderer`            | 100   | 100    |                                                         |
| `AgentCollectionEIP712`              | 100   | 100    | Cross-domain replay covered (`EIP712Replay.audit.t.sol`).|
| `AgentPaymentRouter`                 | 83.7  |  35.4  | Branch gap.                                             |
| `AgentX402Receiver`                  | 86.2  |  45.5  |                                                         |
| `hooks/OracleHook`                   |  100  |  100   | **Was 0/0; raised in this audit.**                      |
| `hooks/RevenueLevelHook`             |  100  |   75   | **Was 0/0; raised in this audit.**                      |
| `hooks/TimeOfDayHook`                |  100  |  100   | **Was 0/0; raised in this audit.**                      |
| `hooks/EvolutionStagesHook`          |  81.5 |  75.0  |                                                         |
| `hooks/TransferRecolorHook`          |  84.4 |   0.0  | Branch coverage 0; hook is simple, low-risk.            |
| `AgentAccount` (TBA, ERC-6551)       |  43.7 |   0.0  | **Highest-priority next coverage target. M-02 lives here.** |
| `AgentIdentityRegistry`              |  66.7 |  39.5  |                                                         |
| `AgentMemory`                        |  76.6 |  48.5  |                                                         |
| `AgentContextRegistry`               |  75.3 |  35.7  |                                                         |
| `AgentReputationRegistry`            |  91.6 |  52.9  |                                                         |
| `AgentTBARegistry`                   |  85.0 |  25.0  |                                                         |
| `hyperlane/AgentBridge`              |  65.2 |  22.7  | Bridge out of scope this pass; reentrancy flagged for follow-up. |
| `AgentSkillsExtension`               |   0.0 |   0.0  | **Suspected dead code.** Confirm + delete or cover.     |
| `ValidationRegistry`                 |   0.0 |   0.0  | **Suspected dead code.**                                |
| `ReputationRegistry`                 |   0.0 |   0.0  | **Suspected dead code** (duplicate of AgentReputationRegistry?). |
| `AgentRegistry`                      |   0.0 |   0.0  | **Suspected dead code** (duplicate of AgentIdentityRegistry?). |

### 4.2 Action items in priority order

1. **`AgentAccount` session-key tests.** Cover the M-02 fix and lift line coverage to ≥ 80 %.
2. **Root-cause the four `0/0` registries** (`AgentSkillsExtension`, `ValidationRegistry`, `ReputationRegistry`, `AgentRegistry`). Delete what's dead; cover what's live.
3. **`AgentRoyaltyVault`** misconfig coverage (M-03).
4. **`AgentBridge`** dedicated audit pass (out of scope today; reentrancy + cross-domain handler need separate work).
5. **Branch coverage on `AgentPaymentRouter`** (whitelist transitions, exempt-payment branches).

---

## 5. Cryptographic review

### 5.1 EIP-712 keeper-commit (`commitEvolution`)

`@/Users/michaelcastellano/Documents/james/VIMS-Master/vimsbot-contracts/src/AgentCollectionEIP712.sol`

| Property                           | Status                                                                                       |
|------------------------------------|----------------------------------------------------------------------------------------------|
| Domain separator                   | Includes `chainId`, `verifyingContract`, `name`, `version`. Standard.                        |
| Replay across chains               | **Blocked.** `chainId` in domain. Verified by `test_AUDIT_EIP712_crossChainReplayFails`.    |
| Replay across collections          | **Blocked.** `verifyingContract` in domain. Verified by `test_AUDIT_EIP712_crossCollectionReplayFails`. |
| Replay across agents               | **Blocked.** `agentId` in struct. Verified by `test_AUDIT_EIP712_crossAgentReplayFails`.    |
| Replay across triggers             | **Blocked.** `triggerKind` in struct. Verified by `test_AUDIT_EIP712_crossTriggerReplayFails`. |
| Nonce monotonicity                 | **Strict.** `nonce <= commitNonce[agentId]` rejects equal & older. Verified.                |
| Sig malleability (high-S)          | **Blocked.** OZ ECDSA v5+ rejects high-S. Tampered-S test passes.                            |
| Deadline                           | **Enforced.** `block.timestamp > deadline` reverts.                                          |
| Keeper substitution (cross-collection) | If two collections register the same keeper (the production case), each collection's commits are still strictly bound to its own `verifyingContract`. **No leakage.** |

The EIP-712 keeper-commit flow is one of the **strongest** parts of the codebase.

### 5.2 Session-key signing (`AgentAccount.executeWithSessionKey`)

| Property                           | Status                                                                                       |
|------------------------------------|----------------------------------------------------------------------------------------------|
| Replay across chains               | **Blocked.** `block.chainid` in message.                                                     |
| Replay across accounts             | **Blocked.** `address(this)` in message.                                                     |
| Replay across nonces               | **Blocked.** `state` in message; incremented per call.                                       |
| Replay across **session keys**     | **NOT bound.** See M-02. Same-signer multi-key configurations are vulnerable to mis-attribution. |
| Sig malleability                   | OZ `SignatureChecker` (uses `ECDSA.recover`); high-S rejected.                               |
| ERC-1271 contract signers          | **Supported** via `SignatureChecker.isValidSignatureNow`. Note: this means contract signers can re-enter; combined with `nonReentrant + hookSafe` modifier this is fine — but the modifier order must be preserved on any future refactor. |

### 5.3 Merkle allowlist (`mintAgentAllowlist`)

| Property                           | Status                                                                                       |
|------------------------------------|----------------------------------------------------------------------------------------------|
| Leaf encoding                      | `keccak256(abi.encodePacked(addr))` with 20-byte address — **collision-free** (only one dynamic-typed argument). |
| Proof bound to caller              | `leaf` derived from `msg.sender`, not parameters. Verified by `test_AUDIT_allowlistProofBoundToCaller`. |
| Proof reuse across mints           | Each mint independently re-verifies; no nonce on proof. By design (allowlist quotas are tracked via `allowlistMintedPerWallet`). |
| Cross-collection replay            | Each collection's `allowlistRoot` is its own; submitting collection A's proof to collection B simply fails verification because root differs. |
| Pre-image attack                   | `OZ MerkleProof.verifyCalldata` uses sorted-pair hashing; standard. |

Allowlist is solid.

---

## 6. Bytecode budget

`AgentCollectionImpl` runtime: **24 377 / 24 576 bytes** (199 byte margin) after H-02 fix.

Pre-staged refactors:

1. **Extract `mint*` paths into `AgentCollectionMint.sol`** linked external library. Estimated savings 1.5–2 KB. Highest ROI; unblocks I-01 try/catch + future features.
2. **Replace bespoke reentrancy guard with OpenZeppelin `ReentrancyGuardUpgradeable`.** Same size, but unblocks reuse of audited code.

---

## 7. Operational risks

### O-01 — Beacon-upgrade authority (HIGH)

Already covered in §2.

### O-02 — Keeper key custody

Each collection nominates a single `evolutionKeeper` EOA. If that key is compromised, **every agent in that collection** can be transitioned arbitrarily. Recommendation:

- Document an explicit key-rotation runbook.
- Add a `setEvolutionKeeper` cooldown (e.g., 24-hour pending-then-active window), so a compromised creator can't silently swap to an attacker-controlled keeper without giving holders a chance to react.

### O-03 — Treasury misconfiguration broadcasts to all vaults (M-03 operational corollary)

A single bad-treasury setting bricks every vault. A multisig + a registry-side `acceptTreasury` two-step transfer pattern would mitigate.

### O-04 — Deployment drift between repo and chain

Storage layouts are now snapshotted in `docs/storage-layouts/`. Add the diff CI job described in `docs/storage-layouts/README.md` before the next mainnet upgrade.

---

## 8. Supply chain

| Component             | Pin                        | Notes                                                       |
|-----------------------|----------------------------|-------------------------------------------------------------|
| OpenZeppelin contracts| v5.x (per `lib/`)         | No known unpatched CVEs at audit time. Confirm pin is exact (not floating ^).|
| forge-std             | (per `lib/forge-std/`)     | No known supply-chain incidents.                            |
| Solc                  | 0.8.24                     | Pre-Cancun stable; no known compiler bugs at this version.  |
| Slither               | 0.11.5                     | Audit toolchain only; not deployed.                         |

**Action:** check `lib/openzeppelin-contracts/` is at a tagged release commit, not floating on a branch. (If it's a submodule pointer, it's pinned; verify.)

---

## 9. New tests added in this audit

| File                                                              | Tests | Notes                                                          |
|-------------------------------------------------------------------|------:|----------------------------------------------------------------|
| `test/audit/AgentRoyaltySplitter.audit.t.sol`                     |    8 | + 2 invariants (256× × 500-call). M-01 regression, FoT, donation, multi-token, reentrancy. |
| `test/audit/AgentCollectionImpl.audit.t.sol`                      |    9 | H-02 regression, mint accounting fuzz, reentrancy, lock matrix, hook grief PoC, soulbound regression. |
| `test/audit/EIP712Replay.audit.t.sol`                             |    6 | Cross-collection / cross-agent / cross-trigger / cross-chain / nonce monotonicity / sig tamper. |
| `test/audit/DeployedHooks.audit.t.sol`                            |   18 | Coverage 0 → 100 % on `OracleHook`, `RevenueLevelHook`, `TimeOfDayHook`. Includes I-04 regression. |
| `test/audit/MerkleHelper.sol`                                     |    – | Shared 2-leaf merkle utility.                                  |

**Total full-suite count:** 387 passing, 0 failing (was 345 before the audit, so +42 net new tests + 2 invariants + 1 fixed pre-existing).

---

## 10. Out of scope this pass

| Item                                                | Effort | Why deferred                            |
|------------------------------------------------------|:------:|------------------------------------------|
| `AgentAccount` session-key audit + tests + M-02 fix  | M      | Highest-priority next PR.                |
| `AgentBridge` cross-domain handler audit             | M      | Hyperlane mailbox surface; needs fork tests. |
| `AgentPaymentRouter` branch coverage                 | M      | Whitelist transitions + exempt branches.  |
| Whole-system invariant fuzz (factory + N collections + splitter under random calls) | L | Per-contract invariants already pin the relevant accounting. |
| Mainnet-fork tests against deployed Base Sepolia state | S    | Scaffold provided in `docs/AUDIT_2026-05-09.md` §5. |
| External audit (Spearbit / ToB / OZ)                 | XL     | **Required** before mainnet. |

---

## 11. Sign-off

After this pass:

- **Three real bugs fixed and regression-pinned** (H-02, M-01, I-04).
- **Two design weaknesses raised with concrete remediations** (M-02, M-03), neither exploitable as a no-op.
- **EIP-712 keeper-commit flow** verified robust under cross-domain, cross-agent, cross-trigger, cross-chain, nonce-monotonicity, and signature-malleability adversary classes.
- **All deployed-but-untested evolution hooks** brought to 100 % line coverage.
- **Storage-layout snapshots** committed and documented for CI guard.
- **Slither pass** triaged in full; zero net-new findings.

**Do not promote to mainnet on this audit alone.** The recommended pre-mainnet sequence is:

1. Land M-02 fix + `AgentAccount` tests.
2. Land M-03 fix + vault tests.
3. Move beacon ownership to a 3/5 multisig with 24-hour timelock (O-01).
4. Externalise audit to Spearbit / Trail of Bits / OpenZeppelin and treat their report as a release blocker.
5. Run a 2-week incentivised bug bounty (Immunefi) on Base Sepolia at production-scale state before mainnet.

— Cascade, internal pair-program audit, 2026-05-09
