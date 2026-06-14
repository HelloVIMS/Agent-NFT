# Protocol Invariants — vimsbot v0.9.1 → v1.0

Each invariant is asserted by ≥1 forge test in `test/` or `test/audit/`.
The reference is given as `path::testName`. Auditors should add to this
file any invariant they consider load-bearing that isn't already
covered.

---

## A. Identity (AgentIdentityRegistry)

- **A.1 — Sequential agent IDs.** `_nextAgentId` is monotonically
  increasing; no caller can provide an ID.
  → `test/AgentIdentityRegistry.t.sol::test_RegisterAgent_AssignsSequential`

- **A.2 — Royalty bps is bounded at registration time** (`0 ≤ bps ≤ 8000`).
  → `test/AgentIdentityRegistry.t.sol::test_RegisterAgent_RoyaltyOutOfRange`

- **A.3 — `ownerOf(agentId)` reverts for inactive / never-minted IDs.**
  → unit

- **A.4 — Only the owner can `setTBAAddress` for an agent.**
  → unit

- **A.5 — UUPS implementation cannot be re-initialized.**
  Constructor calls `_disableInitializers()`.
  → `test/AgentIdentityRegistry.t.sol::test_Initialize_Revert_AlreadyInitialized`

## B. Bytecode size (EIP-170)

- **B.1 — Every deployed contract's runtime bytecode ≤ 24,576 B.**
  → `test/audit/BytecodeSize.audit.t.sol::test_*`

- **B.2 — Critical contracts (`AgentCollectionImpl`, `AgentIdentityRegistry`)
  emit a warning when within 1 KB of the ceiling.**
  → same suite, console-only warning
  - **Current margins:** `AgentCollectionImpl` **680 B** (after Pixelog
    extraction + per-token metadata-mode lock + shared `_commitAgent`
    helper; mode lock cost ~570 B from the 1,250 B post-Pixelog margin),
    `AgentIdentityRegistry` 348 B. Tracked in `MAINNET_READINESS.md`.

## C. Payment routing (AgentPaymentRouter)

- **C.1 — Conservation (ETH).** `amount = systemCut + creatorCut + recipientCut`.
  No funds locked in router, no "leakage" from the input.
  → `test/audit/AgentPaymentRouter.fuzz.t.sol::testFuzz_PayAgentETH_Conservation` (256 runs)

- **C.2 — Conservation (USDC).** Same property over the ERC-20 path.
  → `testFuzz_PayAgentUSDC_Conservation`

- **C.3 — Cross-rail parity.** ETH and USDC of equal nominal split into
  identical per-leg slices.
  → `testFuzz_EthUsdcRailParity`

- **C.4 — System fee invariant.** `systemCut == floor(amount * 50 / 10_000)`,
  hard-coded `SYSTEM_ROYALTY_BPS = 50`.
  → `testFuzz_PayAgentETH_Conservation`

- **C.5 — Creator royalty bound.** `creatorCut ≤ floor((amount - systemCut) * royaltyBps / 10_000)`
  for any `royaltyBps ∈ [0, 5000]`.
  → `testFuzz_CreatorRoyaltyBounded`

- **C.6 — Exempt path delivers 100% to recipient.** No system fee, no
  creator royalty taken when sender is whitelisted.
  → `testFuzz_ExemptPath_NoRoyalty`

- **C.7 — Exempt strictly better than standard rail.** For positive
  amounts, exempt recipient-gain > standard recipient-gain.
  → `testFuzz_ExemptStrictlyBetterForRecipient`

- **C.8 — `payAgentTo[USDC]` rejects non-permissioned subaccounts.**
  → unit

- **C.9 — `pendingSystemRoyalties[token]` is monotonically non-decreasing
  except via owner-driven withdraw.** No path other than the owner
  withdraw can reduce it. (Add explicit invariant test before launch.)
  → **TODO** for v1.0 audit prep

## D. Royalty splitter (AgentRoyaltySplitter, AgentRoyaltyVault)

- **D.1 — Sum of payee shares == total released.** No rounding loss > 0.
  → `test/audit/AgentRoyaltySplitter.fuzz.t.sol::testFuzz_ReleaseAll_NoRoundingLoss`

- **D.2 — `release()` is non-reentrant.**
  → unit

- **D.3 — `recoverETH` / `recoverToken` are owner-only.**
  → unit

- **D.4 — Vault address is deterministic per agent (`CREATE2(salt = bytes32(agentId))`).**
  → `test/AgentRoyaltyVault.t.sol`

## E. x402 settlement (AgentX402Receiver)

- **E.1 — Same nonce twice → revert** regardless of caller.
  → `test/audit/AgentX402Receiver.fuzz.t.sol::testFuzz_ReplaySameNonceReverts`

- **E.2 — Tampered (agentId|serviceId|amount|nonce|validBefore) → `InvalidCommitment`.**
  → `testFuzz_TamperAgentIdReverts`, `testFuzz_TamperServiceIdReverts`,
    `testFuzz_TamperValidBeforeReverts`, `testFuzz_TamperNonceReverts`

- **E.3 — Wrong signer → `InvalidCommitment`.**
  → `testFuzz_WrongSignerReverts`

- **E.4 — Random sig → revert** (either `ECDSAInvalidSignature` or `InvalidCommitment`).
  → `testFuzz_RandomSigReverts`

- **E.5 — Cross-service replay on same agent → `InvalidCommitment`.**
  → `testFuzz_CrossServiceReplayReverts`

- **E.6 — Atomic split.** A successful `payForService` always pays
  `systemCut + creatorCut + agentCut == gross`. No funds held by the
  receiver post-call.
  → `test/AgentX402Receiver.t.sol::test_PayForService_SplitsAtomically_NoTBA`

- **E.7 — Disallowed token reverts before any state.**
  → unit

## F. Collection (AgentCollectionImpl)

- **F.1 — `tokenURI(id)` resolves to `${baseURI}${id}.json` when
  `collectionBaseURI` is set.**
  → unit

- **F.2 — `tokenURI` falls back to on-chain SVG renderer when no baseURI.**
  → unit

- **F.3 — Mint is `nonReentrant`.**
  → unit

- **F.4 — `setRoyaltyReceiverOnce` is one-shot.** Second call reverts.
  → unit

- **F.5 — Allowlist proof binds `(msg.sender, agentId)`.**
  → unit

## G. SDK ↔ Contracts coherence

- **G.1 — Every ABI consumed by the SDK is byte-identical to the
  artifact under `vimsbot-contracts/out/`.**
  → `vimsbot-sdk/tests/unit/abi-coherence.test.ts` (96 tests)

- **G.2 — Every ABI consumed by the marketplace matches the SDK.**
  → `vimsbot-marketplace/tests/unit/abi-parity-sdk.test.ts` (68 tests)

- **G.3 — Every address in `deployments/<chain>.json` is EIP-55 checksummed
  and unique within its slot family.**
  → `vimsbot-sdk/tests/unit/deployments-sanity.test.ts` (16 tests)

- **G.4 — `getContracts(chainId)` throws `ContractsNotDeployedError` for
  any chain whose contracts are zero-address placeholders.**
  → `vimsbot-sdk/tests/unit/tba.test.ts`

## H. Evolution hooks

- **H.1 — Permission bitset matches `getPermissions()` on the deployed
  contract.**
  → `test/audit/DeployedHooks.audit.t.sol`

- **H.2 — Hooks are per-collection.** A hook installed on collection A
  cannot mutate collection B's state.
  → unit

- **H.3 — `OracleHook` reverts on stale Chainlink data
  (`updatedAt + maxAge < block.timestamp`).**
  → unit

- **H.4 — `SoulboundHook` blocks transfer when `block.timestamp < unlocksAt`.**
  → unit

## I. Reputation

- **I.1 — Feedback aggregator only accepts ECDSA-signed scores from the
  registered validator.**
  → unit

- **I.2 — Score range bounded** (`-1, 0, 1` for marketplace; full int128
  for advanced flows).
  → unit

## J. Versioning

- **J.1 — `_vimsContractName()` is unique per contract** (provenance
  fingerprint).
  → `VimsProvenance.sol` enforced at compile time

- **J.2 — Storage layouts are stable across UUPS upgrades.**
  → `docs/storage-layouts/*.json` snapshots; reviewed before every
    `_authorizeUpgrade`

---

## Invariants the audit should prove (currently best-effort)

The following are documented but NOT yet enforced by an automated test.
Auditors should treat these as proof obligations and either supply a
counterexample or confirm.

1. **No path other than `withdrawSystemRoyalties` decreases
   `pendingSystemRoyalties[token]`.** (C.9)
2. **`AgentX402Receiver.payForService` is total atomic**: either all
   four state changes (USDC pull, system credit, creator pay, agent
   pay) succeed, or the call reverts and no state is mutated.
3. **No two collections share the same beacon-proxy storage slot.**
4. **`AgentRoyaltyVault.releaseToken` cannot be tricked into paying out
   more than `IERC20(token).balanceOf(vault)`.**
5. **A creator cannot whitelist themselves into another agent's
   exempt-pay list** (cross-creator isolation).
6. **`AgentAccount` session keys honour `validUntil` deadlines under
   replay scenarios** (relevant after EntryPoint v0.7 simulation).
