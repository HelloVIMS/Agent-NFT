#!/usr/bin/env bash
# mint-test-avatar.sh
#
# End-to-end mint of a demo agent NFT that exercises every path in the
# avatar / animation architecture:
#
#   - Inline on-chain-style SVG identity (image_data)
#   - role:'mesh'      → a GLB with embedded animation clips
#                        (proves auto-play embedded GLB path)
#   - role:'animation' → a second GLB whose clips extend the idle pool
#                        (proves nftAnimationURIs -> VRMAvatar mixer)
#
# Both mesh + animation URIs point at Khronos' public glTF sample
# repository — no IPFS pinning required for the demo. The full
# metadata JSON is embedded into the tokenURI as a data: URI so we
# don't need a JSON host either.
#
# Usage:
#   DEPLOYER_PRIVATE_KEY=0x...  ./script/mint-test-avatar.sh
#
# Env overrides:
#   RPC_URL       — default: https://sepolia.base.org
#   REGISTRY      — default: 0xfE1ef66Ba95891d3cDf6FB83FE1444Bc3bB9FEeF
#                             (AgentIdentityRegistry on Base Sepolia)
#   AGENT_NAME    — default: "Avatar Demo #1"
#   ROYALTY_BPS   — default: 500  (5%)

set -euo pipefail

: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set}"

RPC_URL="${RPC_URL:-https://sepolia.base.org}"
REGISTRY="${REGISTRY:-0xfE1ef66Ba95891d3cDf6FB83FE1444Bc3bB9FEeF}"
AGENT_NAME="${AGENT_NAME:-Avatar Demo #1}"
ROYALTY_BPS="${ROYALTY_BPS:-500}"

# ── 1. Inline identity SVG ────────────────────────────────────────
# Small enough to keep the data-URI tokenURI under 10 KB. Kept as a
# heredoc so the shape is inspectable in the script itself.
SVG=$(cat <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#7c3aed"/><stop offset="1" stop-color="#22d3ee"/></linearGradient></defs><rect width="200" height="200" rx="20" fill="url(#g)"/><circle cx="100" cy="86" r="42" fill="#0c0c10"/><rect x="72" y="130" width="56" height="40" rx="10" fill="#0c0c10"/><circle cx="86" cy="82" r="6" fill="#22d3ee"/><circle cx="114" cy="82" r="6" fill="#22d3ee"/><rect x="88" y="100" width="24" height="4" rx="2" fill="#22d3ee"/></svg>
EOF
)

# ── 2. Build the ERC-8004 metadata JSON ──────────────────────────
# `avatars[]` shape matches AgentAvatarModel (Go) / NFTAvatarModel (TS).
# CesiumMan carries a walking clip inside the GLB — the marketplace
# WebGPUAvatarViewer + meeting VRMAvatar plain-GLB path both detect
# and play `gltf.animations[0]` on loop.
# BrainStem carries several skeletal clips; we declare it as
# role:'animation' so VRMAvatar's nftAnimationURIs pool loads it
# separately and slots it into the idle rotation.
MESH_URI="https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/CesiumMan/glTF-Binary/CesiumMan.glb"
ANIM_URI="https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/BrainStem/glTF-Binary/BrainStem.glb"

# Hash each remote file so the metadata carries integrity fingerprints
# (matches what the mint UI / update panel emit for user uploads).
hash_url() {
    curl -sL "$1" | sha256sum | awk '{print $1}'
}
echo "Hashing $MESH_URI..."
MESH_SHA=$(hash_url "$MESH_URI")
MESH_SIZE=$(curl -sIL "$MESH_URI" | awk '/[Cc]ontent-[Ll]ength:/ {v=$2} END {gsub(/[^0-9]/,"",v); print v}')
echo "Hashing $ANIM_URI..."
ANIM_SHA=$(hash_url "$ANIM_URI")
ANIM_SIZE=$(curl -sIL "$ANIM_URI" | awk '/[Cc]ontent-[Ll]ength:/ {v=$2} END {gsub(/[^0-9]/,"",v); print v}')

# Build JSON with jq so escaping is bulletproof.
METADATA_JSON=$(jq -n \
    --arg name "$AGENT_NAME" \
    --arg desc "Demo agent NFT: inline SVG identity + role-tagged 3D avatar with mesh clips + companion animation clips." \
    --arg svg "$SVG" \
    --arg mesh_uri "$MESH_URI" \
    --arg mesh_sha "$MESH_SHA" \
    --argjson mesh_size "${MESH_SIZE:-0}" \
    --arg anim_uri "$ANIM_URI" \
    --arg anim_sha "$ANIM_SHA" \
    --argjson anim_size "${ANIM_SIZE:-0}" \
    '{
       name: $name,
       description: $desc,
       image_data: $svg,
       attributes: [
         { trait_type: "protocol", value: "agent.vims v0.9.2" },
         { trait_type: "demo",     value: "avatar+animation" }
       ],
       avatars: [
         {
           format: "glb",
           uri: $mesh_uri,
           sha256: $mesh_sha,
           size: $mesh_size,
           lod: "med"
         },
         {
           format: "glb",
           uri: $anim_uri,
           sha256: $anim_sha,
           size: $anim_size,
           role: "animation"
         }
       ]
     }')

# ── 3. Encode as a data: tokenURI ─────────────────────────────────
# Base64 keeps the URI free of quoting / newline pitfalls when we
# ship it through `cast send`.
JSON_B64=$(printf '%s' "$METADATA_JSON" | base64 -w 0)
TOKEN_URI="data:application/json;base64,${JSON_B64}"

# Guard: uint256 tokenURI length isn't limited on-chain, but a runaway
# JSON here almost always means something went wrong upstream.
echo "tokenURI length: ${#TOKEN_URI} bytes"
if [ "${#TOKEN_URI}" -gt 32768 ]; then
    echo "ERROR: tokenURI exceeds 32 KB, refusing to send." >&2
    exit 1
fi

# ── 4. Mint via AgentIdentityRegistry.registerAgent ──────────────
# Signature: registerAgent(string name, string agentURI, uint256 royaltyBps, address reputationAnchor)
# reputationAnchor = 0x0 means "no external anchor, use msg.sender".
echo "Minting to $REGISTRY on $RPC_URL..."
TX_HASH=$(cast send \
    --private-key "$DEPLOYER_PRIVATE_KEY" \
    --rpc-url "$RPC_URL" \
    --json \
    "$REGISTRY" \
    "registerAgent(string,string,uint256,address)" \
    "$AGENT_NAME" \
    "$TOKEN_URI" \
    "$ROYALTY_BPS" \
    "0x0000000000000000000000000000000000000000" | jq -r '.transactionHash')

echo "tx: $TX_HASH"
echo "explorer: https://sepolia.basescan.org/tx/$TX_HASH"

# ── 5. Resolve the minted tokenId from the AgentRegistered event ─
RECEIPT=$(cast receipt --rpc-url "$RPC_URL" --json "$TX_HASH")
# event AgentRegistered(uint256 indexed agentId, address indexed owner, string name, string agentURI)
# topic0 = keccak256("AgentRegistered(uint256,address,string,string)")
TOPIC0=$(cast keccak "AgentRegistered(uint256,address,string,string)")
TOKEN_ID=$(echo "$RECEIPT" | jq -r --arg t "$TOPIC0" '.logs[] | select(.topics[0] == $t) | .topics[1]' | head -1)
if [ -n "$TOKEN_ID" ]; then
    TOKEN_ID_DEC=$(cast to-dec "$TOKEN_ID")
    echo "minted tokenId: $TOKEN_ID_DEC"
    echo "detail: https://agent.vims.com/agent/$TOKEN_ID_DEC"
fi
