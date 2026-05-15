# ClawBot Cross-Contract Coherence - L33T LOOP 6

**Audit Date:** February 7, 2026  
**Loop:** 6 of 13.37  

---

## Interface Coherence Matrix

### IClawBotIdentityRegistry Interface

| Function | Defined | Used By | Signature Match |
|----------|---------|---------|-----------------|
| `ownerOf(uint256)` | IdentityRegistry | TBARegistry, PaymentRouter | ✅ |
| `agents(uint256)` | IdentityRegistry | PaymentRouter | ✅ |
| `getCreatorRoyalty(uint256)` | IdentityRegistry | PaymentRouter | ✅ |
| `setTBAAddress(uint256, address)` | IdentityRegistry | TBARegistry | ✅ |

### Data Flow Verification

```
┌─────────────────────────────────────────────────────────────────┐
│ COHERENCE CHECK: Payment Flow                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  PaymentRouter.payAgent(agentId)                                │
│       │                                                          │
│       ├─► identityRegistry.ownerOf(agentId)                     │
│       │   Returns: address owner ✅ VERIFIED                    │
│       │                                                          │
│       ├─► identityRegistry.agents(agentId)                      │
│       │   Returns: (name, tbaAddress, createdAt, active) ✅     │
│       │                                                          │
│       ├─► identityRegistry.getCreatorRoyalty(agentId)           │
│       │   Returns: (creator, royaltyBps) ✅ VERIFIED            │
│       │                                                          │
│       └─► Transfer to tbaAddress OR owner ✅ CORRECT LOGIC      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

```
┌─────────────────────────────────────────────────────────────────┐
│ COHERENCE CHECK: TBA Creation Flow                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  TBARegistry.createAccount(tokenId, salt)                       │
│       │                                                          │
│       ├─► identityRegistry.ownerOf(tokenId)                     │
│       │   Validates token exists ✅ VERIFIED                    │
│       │                                                          │
│       ├─► CREATE2 deploy ClawBotAccount                         │
│       │   Deterministic address ✅ VERIFIED                     │
│       │                                                          │
│       └─► identityRegistry.setTBAAddress(tokenId, account)      │
│           Auto-registers TBA ✅ VERIFIED                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

```
┌─────────────────────────────────────────────────────────────────┐
│ COHERENCE CHECK: TBA Ownership Derivation                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ClawBotAccount.owner()                                          │
│       │                                                          │
│       ├─► token() - extracts from bytecode footer               │
│       │   Returns: (chainId, tokenContract, tokenId) ✅         │
│       │                                                          │
│       ├─► chainId check                                         │
│       │   Prevents cross-chain attacks ✅ VERIFIED              │
│       │                                                          │
│       └─► IERC721(tokenContract).ownerOf(tokenId)               │
│           Returns NFT owner ✅ VERIFIED                         │
│                                                                  │
│  Note: tokenContract = identityRegistry address ✅ COHERENT     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## State Consistency Checks

### Agent State

| State | Source of Truth | Consumers | Sync Method |
|-------|-----------------|-----------|-------------|
| `owner` | IdentityRegistry (ERC721) | All | Live query |
| `tbaAddress` | IdentityRegistry.agents | PaymentRouter | Live query |
| `active` | IdentityRegistry.agents | PaymentRouter | Live query |
| `creator` | IdentityRegistry._agentCreator | PaymentRouter | Live query |
| `royaltyBps` | IdentityRegistry._creatorRoyaltyBps | PaymentRouter | Live query |

### No Stale State Risk
- All queries are live (no caching)
- No cross-contract storage writes that could desync
- ✅ **COHERENT**

---

## Version Compatibility

| Contract | Solidity | OZ Version | Compatible |
|----------|----------|------------|------------|
| IdentityRegistry | ^0.8.20 | 5.x Upgradeable | ✅ |
| TBARegistry | ^0.8.20 | 5.x | ✅ |
| Account | ^0.8.20 | 5.x | ✅ |
| PaymentRouter | ^0.8.20 | 5.x | ✅ |
| ReputationRegistry | ^0.8.20 | 5.x Upgradeable | ✅ |

---

## Deployment Order Dependency

```
1. ClawBotIdentityRegistry (proxy)
   └─► No dependencies
   
2. ClawBotTBARegistry
   └─► Requires: IdentityRegistry address
   
3. ClawBotReputationRegistry (proxy)
   └─► Requires: IdentityRegistry address
   
4. ClawBotPaymentRouter
   └─► Requires: IdentityRegistry address, USDC address
```

✅ **Deployment order is correct and documented**

---

## Cross-Contract Attack Surface

| Attack Vector | Contracts Involved | Status |
|---------------|-------------------|--------|
| Fake IdentityRegistry | TBA, Router | ✅ Immutable in constructor |
| Fake TBA address | Registry, Router | ✅ setTBAAddress is one-time |
| Ownership race | TBA, Registry | ✅ Live query prevents |
| Upgrade manipulation | Registry | ✅ Owner-only UUPS |

---

## Conclusion

**Cross-Contract Coherence: VERIFIED ✅**

All contracts properly:
- Share consistent interfaces
- Query live state (no caching issues)
- Have correct deployment dependencies
- Resist cross-contract attack vectors
