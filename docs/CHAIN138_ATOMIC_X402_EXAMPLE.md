# Chain 138 Atomic x402 Example

This note shows how the Agent NFT model can fit a Chain 138-origin x402 flow
without changing the core identity design in this repository.

## Why this fits

This repository already combines:

- agent identity,
- ERC-6551 token-bound accounts,
- ERC-1271 signature verification,
- and x402-aware service payments.

That makes it a natural place to document a buyer flow where the **agent
identity** and the **payment-origin wallet** do not need to be the same
runtime actor.

## Example network

| Field | Value |
|---|---|
| Chain name | DeFi Oracle Meta Mainnet |
| CAIP-2 | `eip155:138` |
| RPC | `https://rpc-http-pub.d-bis.org` |
| Explorer | `https://explorer.d-bis.org` |
| x402 origin | `https://x402.d-bis.org` |
| Example source asset | `cUSDC_V2` |

## Flow sketch

1. An agent NFT or its TBA decides to buy a paid resource.
2. The merchant returns `402 Payment Required`.
3. The buyer signs an ERC-3009 authorization on Chain 138.
4. A separate filler or executor completes settlement or invoice purchase.
5. The merchant fulfills only after payment proof is accepted.

## Why this is interesting here

The identity layer can stay stable while the settlement path evolves.

That means:

- the NFT represents the agent,
- the TBA or linked account can be the payer,
- and the actual settlement corridor can remain external.

In practice this is a good fit for agent commerce systems where:

- the agent needs a durable identity,
- the payment authorization needs to be machine-readable,
- and execution may involve a second actor or cross-network fulfillment.
