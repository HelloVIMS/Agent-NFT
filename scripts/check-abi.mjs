#!/usr/bin/env node
/**
 * check-abi.mjs — verify that committed dist/abi matches a fresh forge build.
 *
 * Usage (in CI, after `forge build`):
 *   node scripts/check-abi.mjs
 *
 * Exits non-zero if any ABI JSON differs from what `export-abi.mjs` would emit.
 * This is the drift gate for consumer repos (sdk + marketplace) — if this is
 * green, their pinned ABIs are guaranteed coherent against the current source.
 */

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const DIST = join(ROOT, 'dist', 'abi');
const CHECKSUMS = join(DIST, 'CHECKSUMS.txt');

if (!existsSync(CHECKSUMS)) {
  console.error('[check-abi] dist/abi/CHECKSUMS.txt missing — run `pnpm abi:export` first.');
  process.exit(1);
}

// Rebuild ABIs to a scratch location and compare checksums line-by-line.
execFileSync(process.execPath, [join(ROOT, 'scripts', 'export-abi.mjs')], { stdio: 'inherit' });

const fresh = readFileSync(CHECKSUMS, 'utf8');

// Re-read git-tracked CHECKSUMS via git show to compare with the just-generated one
// (the in-place rewrite means we need git as the reference).
let committed;
try {
  committed = execFileSync('git', ['show', 'HEAD:dist/abi/CHECKSUMS.txt'], {
    cwd: ROOT,
    encoding: 'utf8',
  });
} catch {
  console.warn('[check-abi] no committed CHECKSUMS.txt yet — treating fresh export as baseline.');
  process.exit(0);
}

if (fresh.trim() === committed.trim()) {
  console.log('[check-abi] OK — committed ABIs match forge build.');
  process.exit(0);
}

console.error('[check-abi] DRIFT DETECTED');
console.error('--- committed (HEAD:dist/abi/CHECKSUMS.txt)');
console.error(committed);
console.error('--- fresh (just-exported)');
console.error(fresh);
process.exit(1);
