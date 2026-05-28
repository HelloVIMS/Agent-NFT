// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentMemory.sol";

/// @notice V5 Pixe-memory tests. Pixelog-aligned schema:
///         storageURI / category / tier / versionType / merkle-rooted consolidations.
contract AgentMemoryTest is Test {
    AgentIdentityRegistry public registry;
    AgentMemory       public pixe;

    address public owner = address(0xA11CE);
    address public alice = address(0xA11);
    address public bob   = address(0xB0B);

    // Cached constants (avoid external calls that consume vm.prank)
    uint8 internal T_DELTA;
    uint8 internal T_CONSOLIDATED;
    uint8 internal T_CAPSULE;
    uint8 internal T_MEMORY;
    uint8 internal MAX_T;
    uint8 internal C_MIXED;
    uint8 internal C_PREF;
    uint8 internal C_FACT;
    uint8 internal C_EVENT;
    uint8 internal MAX_C;
    uint8 internal L0;
    uint8 internal L1;
    uint8 internal L2;
    uint8 internal MAX_L;

    bytes32 internal constant H1 = keccak256("pixe v1");
    bytes32 internal constant H2 = keccak256("pixe v2 delta");
    bytes32 internal constant H3 = keccak256("pixe v3 delta");
    bytes32 internal constant HC = keccak256("consolidated");
    bytes32 internal constant MR = keccak256("merkle root v0..v2");

    string internal constant URI_PIXE_V1 = "pixe://capsule/0xv1";
    string internal constant URI_IPFS_V2 = "ipfs://bafyv2";
    string internal constant URI_AR_V3   = "ar://txid-v3";
    string internal constant URI_HTTPS_C = "https://gateway.example/consolidated";

    function setUp() public {
        vm.startPrank(owner);

        AgentIdentityRegistry regImpl = new AgentIdentityRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        registry = AgentIdentityRegistry(address(regProxy));

        AgentMemory pixeImpl = new AgentMemory();
        ERC1967Proxy pixeProxy = new ERC1967Proxy(
            address(pixeImpl),
            abi.encodeCall(AgentMemory.initialize, (address(registry)))
        );
        pixe = AgentMemory(address(pixeProxy));

        vm.stopPrank();

        // Cache constants once to avoid external calls consuming vm.prank in tests
        T_DELTA        = pixe.TYPE_DELTA();
        T_CONSOLIDATED = pixe.TYPE_CONSOLIDATED();
        T_CAPSULE      = pixe.TYPE_CAPSULE();
        T_MEMORY       = pixe.TYPE_MEMORY();
        MAX_T          = pixe.MAX_TYPE();
        C_MIXED        = pixe.CATEGORY_MIXED();
        C_PREF         = pixe.CATEGORY_PREFERENCE();
        C_FACT         = pixe.CATEGORY_FACT();
        C_EVENT        = pixe.CATEGORY_EVENT();
        MAX_C          = pixe.MAX_CATEGORY();
        L0             = pixe.TIER_L0();
        L1             = pixe.TIER_L1();
        L2             = pixe.TIER_L2();
        MAX_L          = pixe.MAX_TIER();
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _mintAgent(address to) internal returns (uint256 agentId) {
        vm.prank(to);
        agentId = registry.registerAgent("Agent", "ipfs://meta", 1000, address(0));
    }

    function _addV1(uint256 agentId, address as_) internal returns (uint256) {
        vm.prank(as_);
        return pixe.addVersion(
            agentId,
            URI_PIXE_V1,
            H1,
            T_CAPSULE,
            C_FACT,
            L2,
            0,
            "initial capsule"
        );
    }

    // ─── happy paths ─────────────────────────────────────────────────────────

    function test_Init_BindsRegistryAndOwner() public view {
        assertEq(address(pixe.identityRegistry()), address(registry));
        assertEq(pixe.owner(), owner);
    }

    function test_AddFirstVersion_Capsule() public {
        uint256 id = _mintAgent(alice);
        uint256 v = _addV1(id, alice);
        assertEq(v, 0);
        assertEq(pixe.versionCount(id), 1);

        AgentMemory.PixeVersion memory pv = pixe.getVersion(id, 0);
        assertEq(pv.storageURI, URI_PIXE_V1);
        assertEq(pv.contentHash, H1);
        assertEq(pv.versionType, T_CAPSULE);
        assertEq(pv.category,    C_FACT);
        assertEq(pv.tier,        L2);
        assertEq(uint256(pv.timestamp), block.timestamp);
    }

    function test_AddDelta_BuildsOnPriorVersion() public {
        uint256 id = _mintAgent(alice);
        _addV1(id, alice);

        vm.prank(alice);
        uint256 v2 = pixe.addVersion(
            id, URI_IPFS_V2, H2,
            T_DELTA, C_PREF, L1,
            0, "preference delta"
        );
        assertEq(v2, 1);
        AgentMemory.PixeVersion memory pv = pixe.getVersion(id, v2);
        assertEq(pv.versionType, T_DELTA);
    }

    function test_GetLatest_ReturnsHead() public {
        uint256 id = _mintAgent(alice);
        _addV1(id, alice);
        vm.prank(alice);
        pixe.addVersion(id, URI_AR_V3, H3, T_DELTA, C_EVENT, L0, 0, "");
        (uint256 v, AgentMemory.PixeVersion memory pv) = pixe.getLatest(id);
        assertEq(v, 1);
        assertEq(pv.contentHash, H3);
    }

    function test_Consolidate_RecordsMerkleRoot() public {
        uint256 id = _mintAgent(alice);
        _addV1(id, alice);
        vm.startPrank(alice);
        pixe.addVersion(id, URI_IPFS_V2, H2, T_DELTA, C_FACT, L2, 0, "");
        pixe.addVersion(id, URI_AR_V3,   H3, T_DELTA, C_FACT, L2, 1, "");
        uint256 cv = pixe.consolidate(id, URI_HTTPS_C, HC, MR, 0, 2, C_FACT, L1, "snapshot");
        vm.stopPrank();

        assertEq(cv, 3);
        assertEq(uint256(pixe.latestConsolidatedVersion(id)), 3);
        assertEq(pixe.consolidationCount(id), 1);
        AgentMemory.ConsolidationRecord memory cr = pixe.getConsolidation(id, 0);
        assertEq(cr.fromVersion,   0);
        assertEq(cr.toVersion,     2);
        assertEq(cr.resultVersion, 3);
        assertEq(cr.merkleRoot,    MR);
    }

    function test_GetLatestConsolidated_TracksHead() public {
        uint256 id = _mintAgent(alice);
        _addV1(id, alice);
        vm.startPrank(alice);
        pixe.addVersion(id, URI_IPFS_V2, H2, T_DELTA, C_FACT, L2, 0, "");
        pixe.consolidate(id, URI_HTTPS_C, HC, MR, 0, 1, C_FACT, L1, "");
        vm.stopPrank();
        (uint256 v, AgentMemory.PixeVersion memory pv) = pixe.getLatestConsolidated(id);
        assertEq(v, 2);
        assertEq(pv.versionType, T_CONSOLIDATED);
    }

    // ─── partitioned retrieval ───────────────────────────────────────────────

    function test_VersionsByCategory_PartitionsCorrectly() public {
        uint256 id = _mintAgent(alice);
        _addV1(id, alice); // FACT@L2 → idx 0
        vm.startPrank(alice);
        pixe.addVersion(id, URI_IPFS_V2, H2, T_DELTA, C_PREF, L1, 0, "");
        pixe.addVersion(id, URI_AR_V3,   H3, T_DELTA, C_FACT,       L2, 1, "");
        vm.stopPrank();

        uint256[] memory facts = pixe.versionsByCategory(id, C_FACT);
        assertEq(facts.length, 2);
        assertEq(facts[0], 0);
        assertEq(facts[1], 2);

        uint256[] memory prefs = pixe.versionsByCategory(id, C_PREF);
        assertEq(prefs.length, 1);
        assertEq(prefs[0], 1);
    }

    function test_VersionsByTier_PartitionsCorrectly() public {
        uint256 id = _mintAgent(alice);
        _addV1(id, alice);
        vm.startPrank(alice);
        pixe.addVersion(id, URI_IPFS_V2, H2, T_DELTA, C_FACT, L0, 0, "summary");
        pixe.addVersion(id, URI_AR_V3,   H3, T_DELTA, C_FACT, L1, 0, "overview");
        vm.stopPrank();

        assertEq(pixe.versionsByTier(id, L0).length, 1);
        assertEq(pixe.versionsByTier(id, L1).length, 1);
        assertEq(pixe.versionsByTier(id, L2).length, 1);
    }

    function test_GetVersionsRange_Pagination() public {
        uint256 id = _mintAgent(alice);
        _addV1(id, alice);
        vm.startPrank(alice);
        for (uint256 i = 0; i < 4; ++i) {
            pixe.addVersion(id, URI_IPFS_V2, keccak256(abi.encode(i)), T_DELTA, C_FACT, L2, 0, "");
        }
        vm.stopPrank();
        AgentMemory.PixeVersion[] memory page = pixe.getVersionsRange(id, 1, 2);
        assertEq(page.length, 2);

        page = pixe.getVersionsRange(id, 4, 100);
        assertEq(page.length, 1);

        page = pixe.getVersionsRange(id, 99, 5);
        assertEq(page.length, 0);
    }

    // ─── access control ──────────────────────────────────────────────────────

    function test_RevertWhen_NonOwner_Adds() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentMemory.NotOwner.selector);
        vm.prank(bob);
        pixe.addVersion(id, URI_PIXE_V1, H1, T_CAPSULE, C_FACT, L2, 0, "");
    }

    function test_RevertWhen_NonOwner_Consolidates() public {
        uint256 id = _mintAgent(alice);
        _addV1(id, alice);
        vm.expectRevert(AgentMemory.NotOwner.selector);
        vm.prank(bob);
        pixe.consolidate(id, URI_HTTPS_C, HC, MR, 0, 0, C_FACT, L1, "");
    }

    function test_SetIdentityRegistry_OwnerOnly() public {
        address newReg = address(0xBEEF);
        vm.expectRevert();
        vm.prank(bob);
        pixe.setIdentityRegistry(newReg);

        vm.prank(owner);
        pixe.setIdentityRegistry(newReg);
        assertEq(address(pixe.identityRegistry()), newReg);
    }

    // ─── input validation ────────────────────────────────────────────────────

    function test_RevertWhen_StorageURI_Empty() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentMemory.EmptyInput.selector);
        vm.prank(alice);
        pixe.addVersion(id, "", H1, T_CAPSULE, C_FACT, L2, 0, "");
    }

    function test_RevertWhen_StorageURI_TooLong() public {
        uint256 id = _mintAgent(alice);
        bytes memory big = new bytes(513);
        for (uint256 i; i < 513; ++i) big[i] = "a";
        vm.expectRevert(AgentMemory.TooLarge.selector);
        vm.prank(alice);
        pixe.addVersion(id, string(big), H1, T_CAPSULE, C_FACT, L2, 0, "");
    }

    function test_RevertWhen_ContentHash_Zero() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentMemory.EmptyInput.selector);
        vm.prank(alice);
        pixe.addVersion(id, URI_PIXE_V1, bytes32(0), T_CAPSULE, C_FACT, L2, 0, "");
    }

    function test_RevertWhen_VersionType_OutOfRange() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentMemory.InvalidVersionType.selector);
        vm.prank(alice);
        pixe.addVersion(id, URI_PIXE_V1, H1, 4, C_FACT, L2, 0, "");
    }

    function test_RevertWhen_Category_OutOfRange() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentMemory.InvalidCategory.selector);
        vm.prank(alice);
        pixe.addVersion(id, URI_PIXE_V1, H1, T_CAPSULE, 7, L2, 0, "");
    }

    function test_RevertWhen_Tier_OutOfRange() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentMemory.InvalidTier.selector);
        vm.prank(alice);
        pixe.addVersion(id, URI_PIXE_V1, H1, T_CAPSULE, C_FACT, 3, 0, "");
    }

    function test_RevertWhen_DeltaBaseVersion_OutOfRange() public {
        uint256 id = _mintAgent(alice);
        _addV1(id, alice);
        vm.expectRevert(AgentMemory.InvalidRange.selector);
        vm.prank(alice);
        pixe.addVersion(id, URI_IPFS_V2, H2, T_DELTA, C_FACT, L2, 99, "");
    }

    function test_RevertWhen_Consolidate_NoPriorVersions() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentMemory.NotExists.selector);
        vm.prank(alice);
        pixe.consolidate(id, URI_HTTPS_C, HC, MR, 0, 0, C_FACT, L1, "");
    }

    function test_RevertWhen_Consolidate_RangeInverted() public {
        uint256 id = _mintAgent(alice);
        _addV1(id, alice);
        vm.prank(alice);
        pixe.addVersion(id, URI_IPFS_V2, H2, T_DELTA, C_FACT, L2, 0, "");
        vm.expectRevert(AgentMemory.InvalidRange.selector);
        vm.prank(alice);
        pixe.consolidate(id, URI_HTTPS_C, HC, MR, 1, 0, C_FACT, L1, "");
    }

    function test_RevertWhen_Consolidate_ToVersionOutOfRange() public {
        uint256 id = _mintAgent(alice);
        _addV1(id, alice);
        vm.expectRevert(AgentMemory.InvalidRange.selector);
        vm.prank(alice);
        pixe.consolidate(id, URI_HTTPS_C, HC, MR, 0, 5, C_FACT, L1, "");
    }

    function test_RevertWhen_Consolidate_MerkleRootZero() public {
        uint256 id = _mintAgent(alice);
        _addV1(id, alice);
        vm.expectRevert(AgentMemory.EmptyInput.selector);
        vm.prank(alice);
        pixe.consolidate(id, URI_HTTPS_C, HC, bytes32(0), 0, 0, C_FACT, L1, "");
    }

    function test_RevertWhen_GetVersion_OutOfRange() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentMemory.NotExists.selector);
        pixe.getVersion(id, 0);
    }

    function test_RevertWhen_GetLatest_NoVersions() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentMemory.NotExists.selector);
        pixe.getLatest(id);
    }

    // ─── fuzz ────────────────────────────────────────────────────────────────

    function testFuzz_AddVersion_AcceptsValidEnumValues(uint8 t, uint8 c, uint8 tier) public {
        t    = uint8(bound(t,    0, MAX_T));
        c    = uint8(bound(c,    0, MAX_C));
        tier = uint8(bound(tier, 0, MAX_L));
        uint256 id = _mintAgent(alice);

        if (t == T_DELTA) {
            _addV1(id, alice);
            vm.prank(alice);
            pixe.addVersion(id, URI_IPFS_V2, H2, t, c, tier, 0, "");
        } else if (t == T_CONSOLIDATED) {
            _addV1(id, alice);
            vm.prank(alice);
            pixe.consolidate(id, URI_HTTPS_C, HC, MR, 0, 0, c, tier, "");
        } else {
            vm.prank(alice);
            pixe.addVersion(id, URI_PIXE_V1, H1, t, c, tier, 0, "");
        }
    }
}
