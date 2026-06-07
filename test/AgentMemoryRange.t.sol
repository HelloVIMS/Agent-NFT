// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentMemory.sol";

/**
 * @title AgentMemoryRangeTest
 * @notice Drives the paginated range readers and pause/unpause paths that
 *         the original AgentMemory.t.sol doesn't cover.
 */
contract AgentMemoryRangeTest is Test {
    AgentIdentityRegistry public registry;
    AgentMemory           public pixe;

    address public owner = address(0xA11CE);
    address public alice = address(0xA11);

    uint8 internal T_CAPSULE;
    uint8 internal T_DELTA;
    uint8 internal C_FACT;
    uint8 internal C_EVENT;
    uint8 internal L0;
    uint8 internal L1;
    uint8 internal L2;
    uint8 internal MAX_C;
    uint8 internal MAX_L;

    uint256 internal agentId;

    function setUp() public {
        vm.startPrank(owner);
        AgentIdentityRegistry regImpl = new AgentIdentityRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl), abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        registry = AgentIdentityRegistry(address(regProxy));

        AgentMemory pixeImpl = new AgentMemory();
        ERC1967Proxy pixeProxy = new ERC1967Proxy(
            address(pixeImpl), abi.encodeCall(AgentMemory.initialize, (address(registry)))
        );
        pixe = AgentMemory(address(pixeProxy));
        vm.stopPrank();

        T_CAPSULE = pixe.TYPE_CAPSULE();
        T_DELTA   = pixe.TYPE_DELTA();
        C_FACT    = pixe.CATEGORY_FACT();
        C_EVENT   = pixe.CATEGORY_EVENT();
        L0        = pixe.TIER_L0();
        L1        = pixe.TIER_L1();
        L2        = pixe.TIER_L2();
        MAX_C     = pixe.MAX_CATEGORY();
        MAX_L     = pixe.MAX_TIER();

        vm.prank(alice);
        agentId = registry.registerAgent("Agent", "ipfs://meta", 1000, address(0));

        // Seed 5 versions: v1 (capsule, FACT, L2), v2-v5 (deltas, alternating cat/tier)
        vm.startPrank(alice);
        pixe.addVersion(agentId, "pixe://v1", keccak256("v1"), T_CAPSULE, C_FACT, L2, 0, "");
        pixe.addVersion(agentId, "pixe://v2", keccak256("v2"), T_DELTA,   C_FACT, L2, 0, "");
        pixe.addVersion(agentId, "pixe://v3", keccak256("v3"), T_DELTA,   C_EVENT, L1, 1, "");
        pixe.addVersion(agentId, "pixe://v4", keccak256("v4"), T_DELTA,   C_FACT, L2, 2, "");
        pixe.addVersion(agentId, "pixe://v5", keccak256("v5"), T_DELTA,   C_EVENT, L0, 3, "");
        vm.stopPrank();
    }

    // ─── versionsByCategoryRange ──────────────────────────────────────────

    function test_versionsByCategoryRange_pageWithinBounds() public view {
        // C_FACT versions: indexes [0, 1, 3]. start=0 count=2 → [0,1].
        uint256[] memory page = pixe.versionsByCategoryRange(agentId, C_FACT, 0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], 0);
        assertEq(page[1], 1);
    }

    function test_versionsByCategoryRange_pageOverhangClamped() public view {
        // C_EVENT has versions [2, 4]. start=0 count=10 → [2,4] (clamped).
        uint256[] memory page = pixe.versionsByCategoryRange(agentId, C_EVENT, 0, 10);
        assertEq(page.length, 2);
        assertEq(page[0], 2);
        assertEq(page[1], 4);
    }

    function test_versionsByCategoryRange_startAtOrPastEndReturnsEmpty() public view {
        // C_FACT count is 3.
        uint256[] memory atEnd = pixe.versionsByCategoryRange(agentId, C_FACT, 3, 5);
        assertEq(atEnd.length, 0);

        uint256[] memory pastEnd = pixe.versionsByCategoryRange(agentId, C_FACT, 100, 5);
        assertEq(pastEnd.length, 0);
    }

    function test_versionsByCategoryRange_revertsForInvalidCategory() public {
        vm.expectRevert(AgentMemory.InvalidCategory.selector);
        pixe.versionsByCategoryRange(agentId, MAX_C + 1, 0, 5);
    }

    // ─── versionsByTierRange ──────────────────────────────────────────────

    function test_versionsByTierRange_pageWithinBounds() public view {
        // L2 versions: [0, 1, 3]. start=1 count=2 → [1, 3].
        uint256[] memory page = pixe.versionsByTierRange(agentId, L2, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], 1);
        assertEq(page[1], 3);
    }

    function test_versionsByTierRange_pageOverhangClamped() public view {
        // L0 has version [4] only.
        uint256[] memory page = pixe.versionsByTierRange(agentId, L0, 0, 100);
        assertEq(page.length, 1);
        assertEq(page[0], 4);
    }

    function test_versionsByTierRange_startAtOrPastEndReturnsEmpty() public view {
        uint256[] memory empty = pixe.versionsByTierRange(agentId, L1, 5, 5);
        assertEq(empty.length, 0);
    }

    function test_versionsByTierRange_revertsForInvalidTier() public {
        vm.expectRevert(AgentMemory.InvalidTier.selector);
        pixe.versionsByTierRange(agentId, MAX_L + 1, 0, 5);
    }

    // ─── hasConsolidations ────────────────────────────────────────────────

    function test_hasConsolidations_falseUntilConsolidate() public view {
        assertFalse(pixe.hasConsolidations(agentId));
    }

    function test_hasConsolidations_trueAfterConsolidate() public {
        vm.prank(alice);
        pixe.consolidate(
            agentId,
            "ipfs://consolidated",
            keccak256("c1"),
            keccak256("merkle"),
            uint16(0), uint16(4),
            C_FACT, L2,
            "first consolidation"
        );
        assertTrue(pixe.hasConsolidations(agentId));
    }

    // ─── pause / unpause ──────────────────────────────────────────────────

    function test_pause_blocksWrites() public {
        vm.prank(owner);
        pixe.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pixe.addVersion(agentId, "pixe://x", keccak256("x"), T_DELTA, C_FACT, L2, 4, "");
    }

    function test_unpause_resumesWrites() public {
        vm.prank(owner);
        pixe.pause();
        vm.prank(owner);
        pixe.unpause();

        vm.prank(alice);
        uint256 v = pixe.addVersion(agentId, "pixe://x", keccak256("x"), T_DELTA, C_FACT, L2, 4, "");
        assertEq(v, 5);
    }

    function test_pause_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        pixe.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(owner);
        pixe.pause();
        vm.prank(alice);
        vm.expectRevert();
        pixe.unpause();
    }

    // ─── pause + view functions still work ────────────────────────────────

    function test_pause_doesNotBlockReads() public {
        vm.prank(owner);
        pixe.pause();

        // Reads must still succeed.
        uint256[] memory page = pixe.versionsByCategoryRange(agentId, C_FACT, 0, 10);
        assertGt(page.length, 0);
    }
}
