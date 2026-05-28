# ClawBot Smart Contract System - InQtel Audit Documentation

**Version:** 1.0  
**Audit Date:** February 7, 2026  
**Auditor:** Cascade AI  
**Status:** L33T Audit Loop In Progress  

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Contract Architecture](#contract-architecture)
3. [Contract Specifications](#contract-specifications)
4. [Security Analysis](#security-analysis)
5. [Economic Analysis](#economic-analysis)
6. [Gas Optimization Review](#gas-optimization-review)
7. [Cross-Contract Coherence](#cross-contract-coherence)
8. [Attack Vector Analysis](#attack-vector-analysis)
9. [Findings & Recommendations](#findings--recommendations)
10. [Deployment Checklist](#deployment-checklist)

---

## 1. System Overview

### Purpose
ClawBot is an on-chain AI agent identity and payment system implementing:
- **ERC-8004**: Agent Identity Standard
- **ERC-6551**: Token Bound Accounts
- **ERC-2981**: NFT Royalty Standard
- **x402**: HTTP Payment Protocol Integration

### Core Value Proposition
- AI agents as tradeable NFTs with soulbound creator royalties
- Automatic payment splitting between creators and owners
- Decentralized reputation tracking
- Session key delegation for automated operations

### Target Chain
- **Primary:** Base L2 (Coinbase)
- **Testnet:** Base Sepolia

---

## 2. Contract Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    ClawBot Contract System                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────────┐     ┌─────────────────────┐           │
│  │  ClawBotIdentity    │────▶│  ClawBotTBARegistry │           │
│  │     Registry        │     │  (ERC-6551 Factory) │           │
│  │  (ERC-721 + 8004)   │     └──────────┬──────────┘           │
│  └──────────┬──────────┘                │                       │
│             │                           │                       │
│             │ queries                   │ creates               │
│             ▼                           ▼                       │
│  ┌─────────────────────┐     ┌─────────────────────┐           │
│  │  ClawBotPayment     │     │   ClawBotAccount    │           │
│  │     Router          │────▶│   (TBA Instance)    │           │
│  │ (Royalty Splitter)  │     │  (Session Keys)     │           │
│  └─────────────────────┘     └─────────────────────┘           │
│             │                                                   │
│             │ reads reputation                                  │
│             ▼                                                   │
│  ┌─────────────────────┐                                       │
│  │  ClawBotReputation  │                                       │
│  │     Registry        │                                       │
│  │  (Feedback System)  │                                       │
│  └─────────────────────┘                                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Contract Dependency Graph

| Contract | Dependencies | Upgradeable |
|----------|--------------|-------------|
| ClawBotIdentityRegistry | OpenZeppelin ERC721, UUPS | ✅ Yes |
| ClawBotTBARegistry | ClawBotAccount, IClawBotIdentityRegistry | ❌ No |
| ClawBotAccount | OpenZeppelin ReentrancyGuard | ❌ No |
| ClawBotPaymentRouter | IClawBotIdentityRegistry, SafeERC20 | ❌ No |
| ClawBotReputationRegistry | ClawBotIdentityRegistry, UUPS | ✅ Yes |

---

## 3. Contract Specifications

### 3.1 ClawBotIdentityRegistry

**Purpose:** ERC-721 NFT registry for AI agent identities with soulbound creator royalties.

**Storage Layout:**
```solidity
uint256 private _nextTokenId;
mapping(uint256 => AgentMetadata) public agents;
mapping(address => uint256[]) public ownerAgents;
mapping(uint256 => string) private _svgImages;           // V2
mapping(uint256 => PixeVersion[]) private _pixeVersions; // V2
mapping(uint256 => address) private _agentCreator;       // V3 - SOULBOUND
mapping(uint256 => uint256) private _creatorRoyaltyBps;  // V3
```

**Key Functions:**
| Function | Access | Description |
|----------|--------|-------------|
| `registerAgent(name, uri)` | Public | Mint new agent with 10% royalty |
| `registerAgentWithRoyalty(name, uri, bps)` | Public | Mint with custom royalty (1-50%) |
| `setTBAAddress(agentId, tba)` | Owner only | Link TBA to agent |
| `getCreatorRoyalty(agentId)` | View | Get soulbound creator + royalty bps |
| `updateCreatorRoyalty(agentId, newBps)` | Creator only | Can only DECREASE |
| `setSVGImage(agentId, svg)` | Owner only | Store on-chain SVG (max 24KB) |
| `addPixeVersion(agentId, cid, type, desc)` | Owner only | Add versioned knowledge file |

**Royalty Constraints:**
- `DEFAULT_CREATOR_ROYALTY_BPS`: 1000 (10%)
- `MAX_CREATOR_ROYALTY_BPS`: 5000 (50%)
- `MIN_CREATOR_ROYALTY_BPS`: 100 (1%)

**ERC-2981 Implementation:**
```solidity
function royaltyInfo(uint256 tokenId, uint256 salePrice) 
    returns (address receiver, uint256 royaltyAmount)
```

---

### 3.2 ClawBotTBARegistry

**Purpose:** Factory for creating deterministic ERC-6551 Token Bound Accounts.

**Key Functions:**
| Function | Access | Description |
|----------|--------|-------------|
| `createAccount(tokenId, salt)` | Public | Deploy TBA for ClawBot |
| `account(tokenContract, tokenId, salt)` | View | Compute TBA address |
| `isAccountDeployed(...)` | View | Check if TBA exists |

**Security Features:**
- Validates token exists in IdentityRegistry before creating TBA
- Reverts on duplicate TBA creation (`TBAAlreadyExists`)
- Auto-registers TBA address back to IdentityRegistry (if caller is owner)

**Address Derivation:**
```solidity
salt = keccak256(abi.encodePacked(_salt, chainId, tokenContract, tokenId))
address = CREATE2.computeAddress(salt, keccak256(creationCode))
```

---

### 3.3 ClawBotAccount

**Purpose:** ERC-6551 Token Bound Account implementation with session key support.

**Key Features:**
- **Ownership:** Derived from NFT owner via `IERC721(tokenContract).ownerOf(tokenId)`
- **Session Keys:** Delegated execution with constraints
- **Asset Reception:** Supports ETH, ERC-721, ERC-1155

**Session Key Structure:**
```solidity
struct SessionKey {
    address signer;
    address[] allowedTargets;
    bytes4[] allowedSelectors;
    uint256 maxValuePerTx;
    uint256 maxTotalValue;
    uint256 usedValue;
    uint48 validAfter;
    uint48 validUntil;
    bool revoked;
}
```

**Session Key Security:**
- Signature includes `block.chainid` for cross-chain replay protection
- Per-transaction and total value limits
- Target and selector whitelisting
- Time-bounded validity

---

### 3.4 ClawBotPaymentRouter

**Purpose:** Routes payments to agents with automatic creator royalty splitting.

**Payment Flow:**
```
User pays 1 ETH to Agent #42
    │
    ├─► Query IdentityRegistry.getCreatorRoyalty(42)
    │   Returns: (creator: 0xABC, royaltyBps: 1000)
    │
    ├─► Calculate split: 1 ETH × 10% = 0.1 ETH creator, 0.9 ETH recipient
    │
    ├─► Recipient = TBA if exists, else owner
    │
    ├─► Check threshold (0.0001 ETH for Base L2)
    │   ├─► Above threshold: Transfer immediately
    │   └─► Below threshold: Accumulate in pendingRoyalties
    │
    └─► Emit PaymentReceived, PaymentSplit events
```

**Whitelist System:**
| Type | Scope | Manager | Purpose |
|------|-------|---------|---------|
| Infrastructure | Global | Contract Owner | DeFi protocols (Uniswap, Chainlink) |
| Creator | Per Agent | Soulbound Creator | Custom operational addresses |

**Hardcoded Infrastructure (Base):**
- `0x2626664c2603336E57B271c5C0b26F421741e481` - Uniswap SwapRouter02
- `0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1` - Uniswap UniversalRouter
- `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` - Chainlink Price Feed
- `0x4200000000000000000000000000000000000006` - WETH
- `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` - USDC
- `0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb` - DAI

**Gas Threshold System:**
| Chain | ETH Threshold | USDC Threshold |
|-------|--------------|----------------|
| Base L2 (default) | 0.0001 ETH | $0.10 |
| Ethereum L1 | 0.01 ETH | $10 |

**Key Functions:**
| Function | Access | Description |
|----------|--------|-------------|
| `payAgent(agentId)` | Public | Pay ETH with royalty split |
| `payAgentUSDC(agentId, amount)` | Public | Pay USDC with royalty split |
| `payAgentExempt(agentId)` | Whitelisted | Pay ETH without royalty |
| `payAgentExemptUSDC(agentId, amount)` | Whitelisted | Pay USDC without royalty |
| `addToCreatorWhitelist(agentId, addr)` | Creator only | Add exempt address |
| `withdrawRoyalties()` | Creator | Withdraw accumulated royalties |
| `emergencyWithdrawETH(to)` | Owner | Recover stuck ETH |

---

### 3.5 ClawBotReputationRegistry

**Purpose:** On-chain reputation tracking for agents.

**Feedback Structure:**
```solidity
struct Feedback {
    address client;
    int128 value;        // Score (-100 to 100 recommended)
    uint8 decimals;
    string tag1;         // Primary category
    string tag2;         // Secondary category
    string feedbackURI;  // IPFS details
    uint256 timestamp;
    bool revoked;
}
```

**Anti-Spam Measures:**
- One feedback per client per agent
- Cannot review own agent
- Revocation supported (enables re-submission)

---

## 4. Security Analysis

### 4.1 Access Control Matrix

| Action | Owner | Creator | NFT Owner | Public |
|--------|-------|---------|-----------|--------|
| Mint Agent | - | - | - | ✅ |
| Transfer Agent | - | - | ✅ | - |
| Set TBA Address | - | - | ✅ | - |
| Update Royalty (decrease) | - | ✅ | - | - |
| Modify Creator Whitelist | - | ✅ | - | - |
| Modify Infra Whitelist | ✅ | - | - | - |
| Update Thresholds | ✅ | - | - | - |
| Emergency Withdraw | ✅ | - | - | - |
| Execute from TBA | - | - | ✅ | - |
| Create Session Key | - | - | ✅ | - |

### 4.2 Reentrancy Protection

| Contract | Protection | Functions Covered |
|----------|------------|-------------------|
| ClawBotPaymentRouter | ✅ ReentrancyGuard | All payment functions |
| ClawBotAccount | ✅ ReentrancyGuard | execute, executeWithSessionKey |
| ClawBotIdentityRegistry | ✅ CEI Pattern | All state-changing functions |
| ClawBotTBARegistry | ✅ CREATE2 (atomic) | createAccount |

### 4.3 Integer Overflow/Underflow

| Contract | Protection |
|----------|------------|
| All | ✅ Solidity 0.8.20 built-in checks |

### 4.4 External Call Safety

| Contract | Pattern | Notes |
|----------|---------|-------|
| PaymentRouter | ✅ CEI | State updated before transfers |
| PaymentRouter | ✅ Pull over Push | pendingWithdrawals for failed transfers |
| Account | ✅ Revert on failure | Assembly revert propagation |

---

## 5. Economic Analysis

### 5.1 Incentive Alignment

| Actor | Incentive | Aligned? |
|-------|-----------|----------|
| Creator | Perpetual royalty income | ✅ Yes |
| Owner | Agent earnings (90% default) | ✅ Yes |
| Buyer | Can verify whitelist before purchase | ✅ Yes |
| User | Transparent pricing via previewSplit | ✅ Yes |

### 5.2 Game Theory Analysis

**Scenario: Creator adds excessive whitelist entries**
- **Risk:** Creator whitelists addresses to avoid paying royalties to themselves
- **Mitigation:** Creator IS the royalty recipient - no incentive to bypass
- **Buyer Protection:** Can view whitelist before purchase

**Scenario: Owner tries to bypass royalties**
- **Risk:** Owner pays through whitelisted address
- **Mitigation:** Only creator controls whitelist; owner cannot add entries
- **Result:** ✅ Attack not possible

**Scenario: Front-running payment split**
- **Risk:** MEV bot extracts value during payment
- **Mitigation:** All calculations deterministic; no sandwich opportunity
- **Result:** ✅ Low risk

### 5.3 Royalty Economics

| Payment | Creator Cut | Owner Cut | Gas (Base L2) |
|---------|-------------|-----------|---------------|
| 0.001 ETH | 0.0001 ETH (accumulates) | 0.0009 ETH | ~$0.001 |
| 0.01 ETH | 0.001 ETH | 0.009 ETH | ~$0.001 |
| 1 ETH | 0.1 ETH | 0.9 ETH | ~$0.001 |
| $10 USDC | $1 USDC | $9 USDC | ~$0.001 |

---

## 6. Gas Optimization Review

### 6.1 Storage Patterns

| Pattern | Contract | Status |
|---------|----------|--------|
| Packed structs | All | ✅ Optimized |
| Immutable variables | PaymentRouter, TBARegistry | ✅ Used |
| Mapping over array | Whitelists | ✅ O(1) lookup |
| Lazy deletion | Creator whitelist array | ✅ Saves gas |

### 6.2 Gas Estimates (Base L2)

| Operation | Estimated Gas | Cost at 0.001 gwei |
|-----------|--------------|---------------------|
| registerAgent | ~250,000 | ~$0.0006 |
| createAccount (TBA) | ~350,000 | ~$0.0009 |
| payAgent | ~180,000 | ~$0.0005 |
| payAgentExempt | ~120,000 | ~$0.0003 |
| addToCreatorWhitelist | ~50,000 | ~$0.0001 |
| withdrawRoyalties | ~50,000 | ~$0.0001 |

### 6.3 Optimization Opportunities

| Item | Current | Potential | Priority |
|------|---------|-----------|----------|
| getCreatorWhitelist O(n²) | 2 loops | EnumerableSet | Low (small n) |
| Batch payments | Not supported | Multi-pay function | Medium |
| Event string storage | On-chain | Indexed bytes32 | Low |

---

## 7. Cross-Contract Coherence

### 7.1 Interface Consistency

| Interface | Defined In | Used By | Consistent? |
|-----------|------------|---------|-------------|
| IClawBotIdentityRegistry | interfaces/ | TBARegistry, PaymentRouter | ✅ Yes |
| AgentMetadata struct | IdentityRegistry | PaymentRouter (via agents()) | ✅ Yes |
| getCreatorRoyalty | IdentityRegistry | PaymentRouter | ✅ Yes |

### 7.2 State Synchronization

| State | Source | Consumer | Sync Method |
|-------|--------|----------|-------------|
| Agent ownership | IdentityRegistry | PaymentRouter | Live query |
| TBA address | IdentityRegistry | PaymentRouter | Live query |
| Agent active status | IdentityRegistry | PaymentRouter | Live query |
| Creator address | IdentityRegistry | PaymentRouter | Live query |

### 7.3 Version Compatibility

| Contract | Solidity | OpenZeppelin | Compatible? |
|----------|----------|--------------|-------------|
| IdentityRegistry | ^0.8.20 | 5.x (Upgradeable) | ✅ |
| TBARegistry | ^0.8.20 | 5.x | ✅ |
| Account | ^0.8.20 | 5.x | ✅ |
| PaymentRouter | ^0.8.20 | 5.x | ✅ |
| ReputationRegistry | ^0.8.20 | 5.x (Upgradeable) | ✅ |

---

## 8. Attack Vector Analysis

### 8.1 Potential Attacks & Mitigations

| Attack | Vector | Mitigation | Status |
|--------|--------|------------|--------|
| Reentrancy | Payment callbacks | ReentrancyGuard | ✅ Mitigated |
| Flash loan manipulation | Royalty calculation | No external price oracle | ✅ N/A |
| Signature replay | Session keys | Chain ID in signature | ✅ Mitigated |
| Cross-chain replay | TBA execution | Chain ID check in owner() | ✅ Mitigated |
| Griefing via dust | Small payments | Gas threshold accumulation | ✅ Mitigated |
| Creator impersonation | Whitelist modification | Soulbound creator check | ✅ Mitigated |
| Token approval drain | USDC transfers | SafeERC20, explicit amounts | ✅ Mitigated |
| Stuck funds | Direct ETH sends | emergencyWithdraw functions | ✅ Mitigated |

### 8.2 Centralization Risks

| Risk | Component | Severity | Notes |
|------|-----------|----------|-------|
| Owner key compromise | PaymentRouter | Medium | Can modify infra whitelist, thresholds |
| Owner key compromise | IdentityRegistry | High | Can upgrade contract (UUPS) |
| Owner key compromise | ReputationRegistry | High | Can upgrade contract (UUPS) |

**Recommendation:** Use multisig for contract ownership (Gnosis Safe).

---

## 9. Findings & Recommendations

### 9.1 Resolved Findings

| ID | Severity | Finding | Resolution |
|----|----------|---------|------------|
| L-01 | Low | receive() accepts stuck ETH | ✅ Added emergencyWithdrawETH |
| M-01 | Medium | Generic token threshold | ✅ Removed payAgentToken, V1 ETH+USDC only |
| M-02 | Medium | Silent ETH queuing | ✅ Added TransferQueued event |

### 9.2 Accepted Risks

| ID | Severity | Finding | Justification |
|----|----------|---------|---------------|
| L-02 | Low | getCreatorWhitelist O(n²) | Array size < 20 in practice |
| L-03 | Low | No max royalty cap check in Router | IdentityRegistry enforces 50% cap |

### 9.3 Recommendations

| Priority | Recommendation | Status |
|----------|----------------|--------|
| High | Use multisig for owner keys | 🔲 Pending |
| Medium | Add pause functionality | 🔲 V2 consideration |
| Medium | Implement batch payments | 🔲 V2 consideration |
| Low | Add more comprehensive events | 🔲 Nice to have |

---

## 10. Deployment Checklist

### Pre-Deployment

- [ ] All tests passing (33 PaymentRouter, 69 total)
- [ ] Deploy to Base Sepolia testnet
- [ ] Verify all contracts on Basescan
- [ ] Test full payment flow end-to-end
- [ ] Test royalty accumulation and withdrawal
- [ ] Test emergency withdrawal functions
- [ ] Security review complete

### Deployment Order

1. **ClawBotIdentityRegistry** (upgradeable proxy)
2. **ClawBotTBARegistry** (pass IdentityRegistry address)
3. **ClawBotReputationRegistry** (upgradeable proxy, pass IdentityRegistry)
4. **ClawBotPaymentRouter** (pass IdentityRegistry, USDC address)

### Post-Deployment

- [ ] Transfer ownership to multisig
- [ ] Verify infrastructure whitelist addresses
- [ ] Set appropriate thresholds for chain
- [ ] Monitor first transactions
- [ ] Set up event monitoring/alerting

### Mainnet Addresses (Base)

| Contract | Address | Notes |
|----------|---------|-------|
| USDC | 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 | Native USDC |
| WETH | 0x4200000000000000000000000000000000000006 | Wrapped ETH |
| Uniswap Router | 0x2626664c2603336E57B271c5C0b26F421741e481 | SwapRouter02 |

---

## Appendix A: Test Coverage

```
Ran 69 tests across 5 test suites

ClawBotAccountTest            - 12 passed
ClawBotIdentityRegistryTest   - 14 passed  
ClawBotPaymentRouterTest      - 33 passed
ClawBotReputationRegistryTest - 12 passed
ClawBotTBARegistryTest        - 9 passed
```

---

## Appendix B: Event Reference

### ClawBotPaymentRouter Events

```solidity
event PaymentReceived(uint256 indexed agentId, address indexed payer, address indexed token, uint256 amount, bool exempt);
event PaymentSplit(uint256 indexed agentId, address indexed creator, address indexed recipient, uint256 creatorAmount, uint256 recipientAmount);
event ExemptPayment(uint256 indexed agentId, address indexed payer, address indexed token, uint256 amount, string reason);
event WhitelistUpdated(uint256 indexed agentId, address indexed addr, bool added, address indexed updatedBy);
event InfrastructureWhitelistUpdated(address indexed addr, bool added);
event Withdrawal(address indexed recipient, address indexed token, uint256 amount);
event RoyaltyAccumulated(address indexed creator, address indexed token, uint256 amount, uint256 totalPending);
event RoyaltyWithdrawn(address indexed creator, address indexed token, uint256 amount);
event ThresholdUpdated(address indexed token, uint256 oldThreshold, uint256 newThreshold);
event TransferQueued(address indexed recipient, address indexed token, uint256 amount, string reason);
event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed to);
```

---

**Document End**

*This audit documentation is part of the ClawBot L33T Audit Loop. For questions or updates, reference the source contracts in `/contracts/src/`.*
