#!/usr/bin/env bash
# Regenerate vimsbot-marketplace/src/lib/hook-artifacts.ts from the latest
# foundry build outputs. Required after any change to a hook constructor.
set -euo pipefail
cd "$(dirname "$0")/.."

forge build >/dev/null

python3 <<'PY'
import json, os
hooks = [
  ("transfer-recolor", "TransferRecolorHook.sol/TransferRecolorHook.json"),
  ("generation",       "GenerationHook.sol/GenerationHook.json"),
  ("soulbound",        "SoulboundHook.sol/SoulboundHook.json"),
  ("time-of-day",      "TimeOfDayHook.sol/TimeOfDayHook.json"),
  ("seasonal",         "SeasonalHook.sol/SeasonalHook.json"),
  ("hue-rotate",       "HueRotateHook.sol/HueRotateHook.json"),
  ("revenue-level",    "RevenueLevelHook.sol/RevenueLevelHook.json"),
  ("tip-jar",          "TipJarHook.sol/TipJarHook.json"),
  ("oracle",           "OracleHook.sol/OracleHook.json"),
  ("reputation-level", "ReputationLevelHook.sol/ReputationLevelHook.json"),
  ("evolution-stages", "EvolutionStagesHook.sol/EvolutionStagesHook.json"),
  ("vote-gated",       "VoteGatedHook.sol/VoteGatedHook.json"),
]
arts = {}
for hid, p in hooks:
  with open(os.path.join("out", p)) as f:
    a = json.load(f)
  ctor = next((e for e in a["abi"] if e.get("type")=="constructor"), {"inputs":[]})
  arts[hid] = {"bytecode": a["bytecode"]["object"], "ctorAbi": ctor}

out_path = "../vimsbot-marketplace/src/lib/hook-artifacts.ts"
with open(out_path, "w") as f:
  f.write("// AUTO-GENERATED — do not edit by hand.\n")
  f.write("// Source: vimsbot-contracts/out/<Hook>.sol/<Hook>.json (foundry artifact).\n")
  f.write("// Regenerate by running tools/generate-hook-artifacts.sh after `forge build`.\n")
  f.write("//\n")
  f.write("// Each entry is the CREATE bytecode + the constructor ABI fragment used by\n")
  f.write("// EvolutionHooksCard's \"Customize & deploy\" flow to broadcast a fresh hook\n")
  f.write("// from the user's wallet via viem's `walletClient.deployContract`.\n")
  f.write("import type { Abi } from 'viem'\n\n")
  f.write("export interface HookArtifact {\n")
  f.write("  bytecode: `0x${string}`\n")
  f.write("  ctorAbi:  Abi[number]\n")
  f.write("}\n\n")
  f.write("export const HOOK_ARTIFACTS: Record<string, HookArtifact> = {\n")
  for hid, a in arts.items():
    f.write(f'  {json.dumps(hid)}: {{\n')
    f.write(f'    bytecode: {json.dumps(a["bytecode"])} as `0x${{string}}`,\n')
    f.write(f'    ctorAbi:  {json.dumps(a["ctorAbi"])} as unknown as Abi[number],\n')
    f.write(f'  }},\n')
  f.write("}\n")
print("wrote", out_path)
PY
