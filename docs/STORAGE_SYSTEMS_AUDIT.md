# ClawBot Storage Systems Deep Audit - L33T LOOPS 14-19

**Audit Date:** February 7, 2026  
**Focus:** .pixe Versioned Storage, On-chain SVG, Memory Architecture  

---

## 1. On-Chain SVG Storage System

### 1.1 Implementation Analysis

```solidity
// Storage
mapping(uint256 => string) private _svgImages;

// Functions
setSVGImage(uint256 agentId, string calldata svg)
getSVGImage(uint256 agentId) → string
hasSVGImage(uint256 agentId) → bool
```

### 1.2 Security Audit

| Check | Status | Notes |
|-------|--------|-------|
| Access Control | ✅ PASS | Owner only can set |
| Size Limit | ✅ PASS | 24KB max enforced |
| Empty Check | ✅ PASS | Rejects empty SVG |
| Existence Check | ✅ PASS | Validates agent exists |

### 1.3 Findings

#### ⚠️ FINDING SVG-01: No SVG Update/Delete Capability
**Severity:** Low  
**Issue:** Once set, SVG can be overwritten but not deleted  
**Impact:** Owner can update but not remove image  
**Recommendation:** Add `clearSVGImage(agentId)` function  
**Status:** 🔶 ENHANCEMENT NEEDED

#### ⚠️ FINDING SVG-02: XSS/Script Injection Risk
**Severity:** Medium (off-chain)  
**Issue:** SVG can contain `<script>` tags, event handlers, external references  
**Impact:** Malicious SVG could execute JS in browsers  
**On-chain Impact:** NONE - Solidity doesn't execute JS  
**Off-chain Impact:** Frontend must sanitize before rendering  
**Recommendation:** 
1. Document XSS risk prominently
2. Frontend MUST use DOMPurify or similar
3. Consider on-chain sanitization (expensive)
**Status:** 🔴 DOCUMENTATION REQUIRED

#### ⚠️ FINDING SVG-03: No Content-Type Validation
**Severity:** Low  
**Issue:** No validation that content is actually SVG  
**Impact:** Could store arbitrary text as "SVG"  
**Recommendation:** Basic `<svg` prefix check  
**Status:** 🔶 ENHANCEMENT NEEDED

#### 📊 FINDING SVG-04: Gas Cost Analysis
**24KB SVG Storage Cost:**
```
Base cost: 20,000 gas per 32-byte slot
24KB = 24,576 bytes = 768 slots
Storage: 768 × 20,000 = 15,360,000 gas
At 0.001 gwei on Base: ~$0.04

VERDICT: Acceptable for Base L2, expensive on L1
```
**Status:** ✅ ACCEPTABLE FOR BASE

### 1.4 SVG tokenURI Integration

```solidity
function tokenURI(uint256 tokenId) public view override returns (string memory) {
    if (bytes(_svgImages[tokenId]).length == 0) {
        return super.tokenURI(tokenId);  // Fallback to stored URI
    }
    return _buildTokenURI(tokenId);  // Embed SVG in JSON
}
```

**Audit:**
- ✅ Graceful fallback if no SVG
- ✅ Base64 encoding for data URI
- ✅ Proper JSON structure with attributes
- ⚠️ Large SVGs may exceed RPC response limits

---

## 2. Versioned .pixe Knowledge Storage System

### 2.1 Implementation Analysis

```solidity
struct PixeVersion {
    string cid;           // IPFS CID or Arweave TX ID
    string storageType;   // "ipfs" or "arweave"
    uint256 timestamp;
    string description;   // Optional description
}

mapping(uint256 => PixeVersion[]) private _pixeVersions;

// Functions
addPixeVersion(agentId, cid, storageType, description) → version
getPixeVersion(agentId, version) → PixeVersion
getLatestPixe(agentId) → PixeVersion + version
getPixeVersionCount(agentId) → uint256
getAllPixeVersions(agentId) → PixeVersion[]
getPixeURL(agentId, version) → string
```

### 2.2 Security Audit

| Check | Status | Notes |
|-------|--------|-------|
| Access Control | ✅ PASS | Owner only can add versions |
| CID Validation | ⚠️ PARTIAL | Non-empty check only |
| Storage Type | ✅ PASS | Validates ipfs/arweave |
| Version Bounds | ✅ PASS | Checks version exists |

### 2.3 Findings

#### ⚠️ FINDING PIXE-01: No Version Limit
**Severity:** Medium  
**Issue:** Unbounded array of versions per agent  
**Impact:** Could grow indefinitely, `getAllPixeVersions` could OOG  
**Recommendation:** 
1. Add `MAX_PIXE_VERSIONS` constant (e.g., 100)
2. Or paginate `getAllPixeVersions`
**Status:** 🔴 NEEDS FIX

#### ⚠️ FINDING PIXE-02: No CID Format Validation
**Severity:** Low  
**Issue:** Accepts any non-empty string as CID  
**Valid IPFS CID:** `QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG`
**Valid Arweave:** `bNbA3TEQVL60xlgCcqdz4ZPHFZ711cZ3hmkpGttDt_U`
**Impact:** Could store invalid references  
**Recommendation:** Basic length/prefix validation  
**Status:** 🔶 ENHANCEMENT NEEDED

#### ⚠️ FINDING PIXE-03: No Version Deletion
**Severity:** Low  
**Issue:** Cannot delete/deprecate old versions  
**Impact:** Storage bloat over time  
**Recommendation:** Add `deprecatePixeVersion` with soft delete flag  
**Status:** 🔶 ENHANCEMENT NEEDED

#### ⚠️ FINDING PIXE-04: Timestamp Manipulation
**Severity:** Informational  
**Issue:** Uses `block.timestamp` which miners can manipulate ±15s  
**Impact:** Minor - just for display, not security-critical  
**Status:** ✅ ACCEPTABLE

#### 📊 FINDING PIXE-05: Gas Cost Analysis
**Per Version Storage:**
```
cid: ~46 bytes (IPFS) = 2 slots = 40,000 gas
storageType: ~5 bytes = 1 slot = 20,000 gas  
timestamp: 32 bytes = 1 slot = 20,000 gas
description: variable, assume 100 bytes = 4 slots = 80,000 gas

Total per version: ~160,000 gas = ~$0.0004 on Base
```
**Status:** ✅ ACCEPTABLE

### 2.4 .pixe Content Architecture

**.pixe File Format (Off-chain):**
```json
{
  "version": "1.0",
  "agent_id": 42,
  "knowledge": {
    "capabilities": ["task1", "task2"],
    "personality": "...",
    "trained_data": "...",
    "fine_tuning": {...}
  },
  "metadata": {
    "created_at": "2026-02-07T00:00:00Z",
    "author": "0x...",
    "hash": "sha256:..."
  }
}
```

**Content Integrity:**
- ⚠️ No on-chain hash verification
- Content at CID is mutable for IPFS (if CID is directory)
- Arweave is immutable by design

**Recommendation:** Store content hash on-chain for verification
```solidity
struct PixeVersion {
    string cid;
    string storageType;
    bytes32 contentHash;  // ADD THIS
    uint256 timestamp;
    string description;
}
```
**Status:** 🔶 V2 ENHANCEMENT

---

## 3. Memory/Knowledge Architecture Review

### 3.1 Current Architecture

```
┌─────────────────────────────────────────────────────────┐
│                 ClawBot Memory Architecture              │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ON-CHAIN (Permanent)                                   │
│  ├── Agent Identity (ERC-721)                           │
│  ├── Agent Metadata (name, TBA, active status)          │
│  ├── Creator Royalties (soulbound)                      │
│  ├── SVG Image (up to 24KB)                             │
│  └── .pixe Version References (CID pointers)            │
│                                                          │
│  OFF-CHAIN (Decentralized)                              │
│  ├── IPFS: .pixe knowledge files                        │
│  ├── Arweave: .pixe knowledge files (permanent)         │
│  └── Agent URI: Full metadata JSON                      │
│                                                          │
│  OFF-CHAIN (Centralized - optional)                     │
│  ├── HOL Registry: Agent discovery                      │
│  └── Backend DB: Operational cache                      │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### 3.2 Data Flow Analysis

```
Agent Learning Flow:
1. Agent performs tasks, gains knowledge
2. Knowledge packaged into .pixe JSON
3. .pixe uploaded to IPFS/Arweave
4. CID recorded on-chain via addPixeVersion()
5. Future queries get latest via getLatestPixe()

Agent Identity Flow:
1. Creator registers agent (registerAgent)
2. Creator sets SVG (setSVGImage)
3. Creator/Owner adds .pixe versions
4. Marketplaces query tokenURI for metadata
5. Services query .pixe for capabilities
```

### 3.3 Architectural Findings

#### ⚠️ FINDING ARCH-01: No .pixe Schema Validation
**Severity:** Medium  
**Issue:** No standard enforced for .pixe content structure  
**Impact:** Incompatible .pixe files across ecosystem  
**Recommendation:** Define and document .pixe JSON schema  
**Status:** 🔴 NEEDS SPECIFICATION

#### ⚠️ FINDING ARCH-02: IPFS Pinning Not Enforced
**Severity:** Medium  
**Issue:** IPFS content unpinned will be garbage collected  
**Impact:** .pixe files could become unavailable  
**Recommendation:** 
1. Document pinning requirement
2. Consider Filecoin integration for guaranteed persistence
3. Arweave recommended for critical knowledge
**Status:** 🔴 DOCUMENTATION REQUIRED

#### ⚠️ FINDING ARCH-03: No Version Migration Path
**Severity:** Low  
**Issue:** If .pixe schema changes, old versions break  
**Impact:** Backwards compatibility issues  
**Recommendation:** Include schema version in .pixe format  
**Status:** 🔶 ENHANCEMENT NEEDED

#### ✅ FINDING ARCH-04: Decentralization Analysis
**Strengths:**
- SVG fully on-chain (permanent)
- Version history on-chain (permanent)
- IPFS/Arweave for large files (decentralized)
- No single point of failure

**Weaknesses:**
- IPFS requires pinning infrastructure
- Content availability not guaranteed

**Status:** ✅ ACCEPTABLE for V1

---

## 4. Gas Optimization Analysis

### 4.1 Storage Costs Summary

| Operation | Gas Cost | USD (Base L2) |
|-----------|----------|---------------|
| setSVGImage (24KB) | ~15,360,000 | ~$0.04 |
| setSVGImage (5KB) | ~3,200,000 | ~$0.008 |
| addPixeVersion | ~160,000 | ~$0.0004 |
| getLatestPixe | ~50,000 | ~$0.0001 |

### 4.2 Optimization Opportunities

#### OPT-01: Compressed SVG Storage
```solidity
// Current: Store raw SVG
_svgImages[agentId] = svg;

// Optimized: Store gzip compressed (off-chain compression)
// Saves ~70% storage for typical SVGs
// Requires frontend decompression
```
**Savings:** ~70% gas on SVG storage  
**Tradeoff:** Frontend complexity  
**Status:** 🔶 V2 CONSIDERATION

#### OPT-02: Packed PixeVersion Struct
```solidity
// Current (unoptimized)
struct PixeVersion {
    string cid;           // dynamic
    string storageType;   // dynamic (wastes gas)
    uint256 timestamp;    // 32 bytes
    string description;   // dynamic
}

// Optimized
struct PixeVersion {
    string cid;
    uint8 storageType;    // 0=ipfs, 1=arweave (1 byte)
    uint48 timestamp;     // fits until year 8.9M (6 bytes)
    string description;
}
```
**Savings:** ~20,000 gas per version  
**Status:** 🔶 V2 CONSIDERATION

---

## 5. Recommended Fixes

### Critical (Must Fix Before Deploy)

| ID | Issue | Fix |
|----|-------|-----|
| PIXE-01 | Unbounded versions | Add MAX_PIXE_VERSIONS = 1000 |

### High (Fix Soon)

| ID | Issue | Fix |
|----|-------|-----|
| SVG-02 | XSS documentation | Add security warning to docs |
| ARCH-01 | No .pixe schema | Define JSON schema spec |
| ARCH-02 | IPFS pinning | Document requirement |

### Medium (V2)

| ID | Issue | Fix |
|----|-------|-----|
| SVG-01 | No SVG delete | Add clearSVGImage() |
| PIXE-02 | CID validation | Add format checks |
| PIXE-03 | No version delete | Add deprecation flag |

---

## 6. Implementation Fixes

### Fix PIXE-01: Add Version Limit

```solidity
uint256 public constant MAX_PIXE_VERSIONS = 1000;

function addPixeVersion(...) external returns (uint256 version) {
    require(ownerOf(agentId) == msg.sender, "Not agent owner");
    require(bytes(cid).length > 0, "Empty CID");
    require(_pixeVersions[agentId].length < MAX_PIXE_VERSIONS, "Max versions reached");
    // ... rest of function
}
```

---

## 7. Conclusion

### Storage Systems Rating: B+

| System | Rating | Notes |
|--------|--------|-------|
| SVG Storage | B+ | Works, needs XSS docs |
| .pixe Storage | B | Needs version limit |
| Architecture | B+ | Solid design, needs schema |

### Action Items

1. **IMMEDIATE:** Add MAX_PIXE_VERSIONS limit
2. **IMMEDIATE:** Document XSS risks for SVG
3. **BEFORE LAUNCH:** Define .pixe JSON schema
4. **V2:** Add content hash verification
5. **V2:** Struct packing optimizations

---

**Document End - L33T LOOPS 14-19 Complete**
