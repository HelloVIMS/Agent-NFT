# Operational Runbook — vimsbot v1.0+

> Owner: protocol on-call rotation. Updates require a signed-off PR.
>
> Every command below is destructive or privilege-bearing. Read the
> entire entry before executing. Never paste a private key into a
> terminal that has shell history enabled.

---

## §1 Upgrade a UUPS proxy

**Pre-conditions:**
- Storage-layout diff (`docs/storage-layouts/<contract>.json`)
  reviewed by ≥ 2 engineers.
- New implementation deployed to mainnet and Etherscan-verified.
- Audit sign-off on the diff (or pre-audit if pre-1.0).

**Procedure:**

1. Deploy the new implementation:
   ```bash
   forge script script/UpgradeFooImpl.s.sol \
     --rpc-url $MAINNET_RPC --broadcast --verify
   ```
   Capture the printed `NEW_IMPL` address.
2. Schedule the upgrade through the timelock from the Safe UI:
   - Target: the proxy address (e.g. `AgentIdentityRegistry`).
   - Calldata: `upgradeToAndCall(NEW_IMPL, "")` (empty data unless the
     impl ships a re-init hook).
   - Delay: 48 h.
3. Wait the full timelock period. Communicate the upgrade window in
   the protocol announcements channel.
4. Execute the queued operation from the Safe.
5. Verify post-upgrade:
   ```bash
   cast call $PROXY 'proxiableUUID()(bytes32)'        # should match impl
   forge script script/PostUpgradeChecks.s.sol --rpc-url $MAINNET_RPC
   ```
6. Update `deployments/<chain>.json`:
   - Move the previous `implementation` into `implementationLegacy[]`
     with `replacedAt` timestamp.
   - Set `implementation` to the new address.
   - Append to `implementationHistory.<Contract>` array.
7. Run `pnpm sync-abi` from `vimsbot-sdk/` if the ABI changed.
8. Tag a release.

**If the upgrade fails:**
- The proxy is still on the old impl (UUPS atomicity).
- Cancel the timelock operation; investigate; re-deploy.
- Do NOT attempt a second upgrade in the same 48 h without explicit
  ack from the Safe owners.

---

## §2 Pause the protocol

**Use case:** active exploit detected, oracle gone bad, treasury misuse.

`AgentX402Receiver`, `AgentCollectionImpl`, `AgentPaymentRouter` (P1
roadmap) expose `pause()` callable by the owner (and Pause Guardian
once that role lands).

```bash
# From Safe — single-sig if Pause Guardian, multisig threshold otherwise
cast send $X402_RECEIVER 'pause()' --from $SAFE
cast send $COLLECTION_IMPL 'pause()' --from $SAFE
```

After pausing, communicate via the protocol's announcement channels
within 15 min. Triage with the on-call.

**Unpause:**
- Multisig threshold required regardless of who paused.
- Document the incident root cause in `audit/incidents/<date>.md`.

---

## §3 Withdraw `pendingSystemRoyalties`

`AgentPaymentRouter.pendingSystemRoyalties[token]` is the per-token
treasury accumulator. Withdrawal is owner-gated.

```bash
# ETH side
cast send $PAYMENT_ROUTER 'withdrawSystemRoyalties(address)' \
  0x0000000000000000000000000000000000000000 \
  --from $SAFE

# USDC side
cast send $PAYMENT_ROUTER 'withdrawSystemRoyalties(address)' \
  $USDC \
  --from $SAFE
```

**Cadence:** at minimum monthly, or whenever `pendingSystemRoyalties`
exceeds the alert threshold (configurable, e.g. 10 ETH equivalent).

**Verification:** after the withdraw, balance of the treasury Safe
should increase by exactly the amount that was pending. Treasury Safe
publishes signed proofs of receipt to the public dashboard.

---

## §4 Rotate the treasury address

**When:** Safe key compromise suspected, governance migration to a
new Safe, jurisdiction change.

```bash
# Old treasury (current Safe)
cast send $PAYMENT_ROUTER  'setAeyeosTreasury(address)' $NEW_SAFE --from $OLD_SAFE
cast send $X402_RECEIVER   'setTreasury(address)'       $NEW_SAFE --from $OLD_SAFE
```

Both calls go through the timelock. Update
`deployments/<chain>.json#treasury` afterwards.

---

## §5 Add a token to the x402 allowlist

```bash
cast send $X402_RECEIVER 'setTokenAllowed(address,bool)' $TOKEN true --from $SAFE
```

The token must implement EIP-3009 (`receiveWithAuthorization`) AND
be on a known issuer's whitelist. We do NOT allowlist arbitrary
ERC-20s.

To remove:
```bash
cast send $X402_RECEIVER 'setTokenAllowed(address,bool)' $TOKEN false --from $SAFE
```

Existing services priced in that token continue to render but new
payments revert with `TokenNotAllowed()`. Communicate before removal.

---

## §6 Deploy a hook upgrade

Hooks are stateless reference contracts. To upgrade a curated hook:

1. Deploy the new hook impl.
2. Update `deployments/<chain>.json#evolutionHooks.<HookName>` to the new address.
3. Update `vimsbot-sdk/src/v7/contracts.ts#HOOK_LIBRARY` to point at the
   new address; bump the SDK version.
4. Existing collections that pinned the old hook continue to use it.
   Creators can opt into the new hook via `setCollectionHook` per
   collection.

**Hooks are NOT upgradeable.** A "new version" is always a new
deployment + opt-in.

---

## §7 Recover stuck funds

Splitter / vault contracts include `recoverETH(address)` and
`recoverToken(address,address)` for **non-managed** assets that landed
at the contract by accident. They are owner-gated.

```bash
cast send $SPLITTER 'recoverETH(address)' $RESCUE_ADDR --from $SAFE
cast send $SPLITTER 'recoverToken(address,address)' $TOKEN $RESCUE_ADDR --from $SAFE
```

These functions are NOT a generic withdrawal — they specifically
exclude the splitter's tracked token. Audit them carefully before
each call.

---

## §8 Incident response

1. **Detect** — alert from Tenderly / Defender / on-chain monitor /
   user report.
2. **Triage** — confirm with `cast` queries and Etherscan.
3. **Contain** — invoke §2 (pause) if any money path is affected.
4. **Communicate** — pinned post in the announcements channel within
   15 min of containment. Status page updated within 30 min.
5. **Investigate** — root cause analysis. Forge fork test reproducing
   the bug.
6. **Patch** — UUPS upgrade per §1, or off-chain mitigation.
7. **Postmortem** — `audit/incidents/<date>.md` within 7 days. Public
   summary linked from the protocol blog.

**Severity classifications** (matches threat model §3):

| Level | Examples | Response time |
|---|---|---|
| Critical | Active fund-loss exploit | < 15 min pause |
| High | Royalty bypass discovered, sig replay vector | < 1 h |
| Medium | Stale oracle on a hook | < 24 h |
| Low | UI / docs | next sprint |

---

## §9 New chain deploy

Use the chain-parameterised entry point:

```bash
export DEPLOYER_PRIVATE_KEY=$(op read 'op://protocol/deployer/key')
export TREASURY=0x… # Safe on the target chain
forge script script/DeployMainnet.s.sol:DeployMainnetScript \
  --rpc-url $RPC_URL --broadcast --verify
```

Then:

1. Paste the JSON output into `deployments/<chain>.json`.
2. Run `pnpm sync-abi` in `vimsbot-sdk/`.
3. **Remove the chain from `PLACEHOLDER_CHAINS`** in
   `vimsbot-sdk/src/core/contracts.ts`. Otherwise the SDK refuses to
   serve real addresses (by design — see `MAINNET_READINESS.md` P0).
4. Etherscan-verify every deployed contract.
5. Run forge fork tests against the new RPC.
6. Tag SDK + marketplace releases.

---

## §10 Post-mortem template

Save to `audit/incidents/YYYY-MM-DD-<slug>.md`:

```
# Incident YYYY-MM-DD: <slug>
**Severity:** Critical | High | Medium | Low
**Status:** mitigated | resolved
**Detected at:** <ISO 8601>
**Resolved at:** <ISO 8601>

## Summary

## Timeline (UTC)

## Impact (funds, users, downtime)

## Root cause

## Fix

## Prevention (process, code, tests added)

## Lessons learned
```
