#!/usr/bin/env node
/**
 * export-abi.mjs — emit a canonical ABI bundle from forge artifacts.
 *
 * Reads `out/<Contract>.sol/<Contract>.json`, extracts the `.abi` array, and
 * writes:
 *   dist/abi/<Contract>.json                  // pure ABI, no compiler junk
 *   dist/abi/<Contract>.abi.d.ts              // `export default [...] as const`
 *   dist/abi/index.ts                         // re-export aggregator
 *   dist/abi/manifest.json                    // { contract, sha256, bytes, src }
 *   dist/abi/CHECKSUMS.txt                    // human-readable sha256 list
 *
 * Consumed by `vimsbot-sdk` (and transitively, `vimsbot-marketplace`) via
 * `pnpm sync-abi`, which copies `dist/abi/*` into `src/abi/`. CI in all three
 * repos verifies the checksums match — that's the drift gate.
 *
 * Usage:
 *   forge build
 *   node scripts/export-abi.mjs
 *
 * No external dependencies; node 20+ standard library only.
 */

import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const OUT_DIR = join(ROOT, 'out');
const DIST_DIR = join(ROOT, 'dist', 'abi');

/**
 * Which contracts we publish. Anything in `src/**` not listed here is treated
 * as internal and skipped. Hooks are namespaced under `hooks/` in the output.
 *
 * Keep this list sorted; CI diffs it.
 */
const EXPORTS = [
  // ── Core registries ─────────────────────────────────────────────────
  'AgentIdentityRegistry',
  'AgentTBARegistry',
  'AgentLinkedAccountRegistry',
  'AgentEncryptionRegistry',
  'AgentReputationRegistry',
  'AgentContextRegistry',
  'AgentMemory',
  'AgentPaymentRouter',
  'AgentX402Receiver',
  // ── Marketplace ─────────────────────────────────────────────────────
  'AgentMarketplace',
  'AgentAuctionHouse',
  // ── Royalty + vault ─────────────────────────────────────────────────
  'AgentRoyaltyVault',
  'AgentRoyaltySplitter',
  'AgentRoyaltySplitterFactory',
  // ── Collections ─────────────────────────────────────────────────────
  'AgentCollectionFactory',
  'AgentCollectionImpl',
  // ── TBA + provenance ────────────────────────────────────────────────
  'AgentAccount',
  'VimsProvenance',
  // ── Token extensions ────────────────────────────────────────────────
  'AgentSkillsExtension',
  'AgentAvatarExtension',
  'AgentIdentityKeyExtension',
  // ── Hyperlane bridge ────────────────────────────────────────────────
  { contract: 'AgentBridge', namespace: 'hyperlane' },
  // ── Evolution hooks (interface + impls) ─────────────────────────────
  { contract: 'IAgentEvolutionHook',    namespace: 'hooks' },
  { contract: 'AgentStatusHook',        namespace: 'hooks' },
  { contract: 'EvolutionStagesHook',    namespace: 'hooks' },
  { contract: 'GenerationHook',         namespace: 'hooks' },
  { contract: 'HueRotateHook',          namespace: 'hooks' },
  { contract: 'OracleHook',             namespace: 'hooks' },
  { contract: 'ReputationLevelHook',    namespace: 'hooks' },
  { contract: 'RevenueLevelHook',       namespace: 'hooks' },
  { contract: 'SeasonalHook',           namespace: 'hooks' },
  { contract: 'SoulboundHook',          namespace: 'hooks' },
  { contract: 'TimeOfDayHook',          namespace: 'hooks' },
  { contract: 'TipJarHook',             namespace: 'hooks' },
  { contract: 'TransferRecolorHook',    namespace: 'hooks' },
  { contract: 'VoteGatedHook',          namespace: 'hooks' },
];

/**
 * Concrete contracts deliberately NOT published, each with the reason.
 *
 * This list is the other half of EXPORTS: together they must account for
 * every concrete contract in `src/**`, which assertEveryContractClassified
 * enforces. Without it, omission is silent — a new contract simply never
 * reaches consumers, `abi:check` stays green because it only compares the
 * ABIs already listed, and the gap surfaces as a client that cannot call a
 * contract that is deployed and working. That is exactly how
 * AgentAvatarExtension shipped to base-sepolia with no ABI.
 */
const INTERNAL = [
  // Called on-chain by TipJarHook to resolve the tip recipient. Deployed,
  // but no client-facing surface: consumers interact with the hook.
  'IdentityTipBeneficiaryResolver',
  // On-chain shim mapping legacy reputation calls onto the ERC-8004
  // registry. Callers use AgentReputationRegistry's ABI instead.
  'AgentReputationERC8004Adapter',
];

/**
 * Fail when a concrete contract in src/ is in neither EXPORTS nor INTERNAL.
 *
 * Adding a contract is the moment to decide whether consumers get its ABI,
 * and the only moment anybody is thinking about it. Interfaces, libraries
 * and abstract bases are skipped: they have no deployed instance to call.
 */
function assertEveryContractClassified() {
  const declared = new Set();
  const walk = dir => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(p);
      } else if (entry.name.endsWith('.sol')) {
        const src = readFileSync(p, 'utf8');
        // Concrete contracts only: `abstract contract`, `interface` and
        // `library` have no deployed instance for a client to call.
        for (const m of src.matchAll(/^\s*contract\s+([A-Za-z0-9_]+)/gm)) {
          declared.add(m[1]);
        }
      }
    }
  };
  walk(join(ROOT, 'src'));

  const classified = new Set([
    ...EXPORTS.map(s => (typeof s === 'string' ? s : s.contract)),
    ...INTERNAL,
  ]);
  const unclassified = [...declared].filter(c => !classified.has(c)).sort();
  if (unclassified.length) {
    console.error('[export-abi] contracts in src/ that are neither exported nor declared internal:');
    for (const c of unclassified) console.error(`  ${c}`);
    console.error('Add each to EXPORTS (consumers need the ABI) or to INTERNAL (with the reason).');
    process.exit(1);
  }
}

function locateArtifact(contract) {
  // Forge layout: out/<File>.sol/<Contract>.json. File usually matches contract.
  const direct = join(OUT_DIR, `${contract}.sol`, `${contract}.json`);
  if (existsSync(direct)) return direct;
  // Fallback: search out/*/<contract>.json (covers libs / nested cases).
  const dirs = readdirSync(OUT_DIR, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name);
  for (const d of dirs) {
    const p = join(OUT_DIR, d, `${contract}.json`);
    if (existsSync(p)) return p;
  }
  return null;
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function normaliseAbi(abi) {
  // Strip Solidity-only `internalType` so the ABI bundle is portable across
  // toolchains and stable across solc patch bumps that re-format struct names.
  return abi.map(entry => {
    const stripped = { ...entry };
    if (Array.isArray(stripped.inputs)) {
      stripped.inputs = stripped.inputs.map(stripInternal);
    }
    if (Array.isArray(stripped.outputs)) {
      stripped.outputs = stripped.outputs.map(stripInternal);
    }
    return stripped;
  });
}

function stripInternal(io) {
  const { internalType: _drop, components, ...rest } = io;
  if (Array.isArray(components)) {
    return { ...rest, components: components.map(stripInternal) };
  }
  return rest;
}

function asConstLiteral(abi) {
  return `// AUTO-GENERATED by scripts/export-abi.mjs — DO NOT EDIT.
// Source: out/<Contract>.sol/<Contract>.json
// Re-run \`forge build && node scripts/export-abi.mjs\` to regenerate.

const abi = ${JSON.stringify(abi, null, 2)} as const;
export default abi;
`;
}

function main() {
  if (!existsSync(OUT_DIR)) {
    console.error(`[export-abi] missing ${OUT_DIR} — run \`forge build\` first.`);
    process.exit(1);
  }

  assertEveryContractClassified();

  rmSync(DIST_DIR, { recursive: true, force: true });
  mkdirSync(DIST_DIR, { recursive: true });

  const manifest = [];
  const indexLines = ['// AUTO-GENERATED. Re-export aggregator for all published ABIs.', ''];

  for (const spec of EXPORTS) {
    const contract = typeof spec === 'string' ? spec : spec.contract;
    const namespace = typeof spec === 'string' ? null : spec.namespace ?? null;

    // Fatal, not a warning. A listed contract with no artifact after
    // `forge build` means a typo or a build failure, and skipping it drops
    // the ABI from the bundle while leaving the exit code clean — the same
    // silent omission this script now gates against.
    const artifact = locateArtifact(contract);
    if (!artifact) {
      console.error(`[export-abi] ${contract} is exported but has no artifact — run \`forge build\`, or fix the name in EXPORTS.`);
      process.exit(1);
    }
    const raw = JSON.parse(readFileSync(artifact, 'utf8'));
    const abi = normaliseAbi(raw.abi ?? []);
    if (!abi.length) {
      console.error(`[export-abi] ${contract} produced an empty ABI — it has no external surface, so exporting it publishes nothing.`);
      process.exit(1);
    }

    const relDir = namespace ? join(namespace) : '';
    const outDir = join(DIST_DIR, relDir);
    mkdirSync(outDir, { recursive: true });

    const jsonPath = join(outDir, `${contract}.json`);
    const tsPath   = join(outDir, `${contract}.ts`);
    const jsonBuf  = Buffer.from(JSON.stringify(abi, null, 2) + '\n', 'utf8');

    writeFileSync(jsonPath, jsonBuf);
    writeFileSync(tsPath, asConstLiteral(abi));

    const relSrc = `src/${namespace ? namespace + '/' : ''}${contract}.sol`;
    const checksum = sha256(jsonBuf);
    manifest.push({
      contract,
      namespace,
      src: relSrc,
      abi: `${namespace ? namespace + '/' : ''}${contract}.json`,
      sha256: checksum,
      bytes: jsonBuf.length,
      entries: abi.length,
    });

    const importPath = `./${namespace ? namespace + '/' : ''}${contract}`;
    indexLines.push(
      `export { default as ${contract}_ABI } from '${importPath}';`,
    );

    console.log(`[export-abi] ${contract.padEnd(36)} → ${jsonPath} (${abi.length} entries, ${checksum.slice(0, 12)}…)`);
  }

  writeFileSync(join(DIST_DIR, 'index.ts'), indexLines.join('\n') + '\n');
  writeFileSync(join(DIST_DIR, 'manifest.json'), JSON.stringify({
    generatedAt: new Date().toISOString(),
    generator: 'agent-nft/scripts/export-abi.mjs',
    contracts: manifest,
  }, null, 2) + '\n');

  const checksums = manifest
    .map(m => `${m.sha256}  ${m.abi}`)
    .sort()
    .join('\n') + '\n';
  writeFileSync(join(DIST_DIR, 'CHECKSUMS.txt'), checksums);

  console.log(`[export-abi] wrote ${manifest.length} ABIs to ${DIST_DIR}`);
}

main();
