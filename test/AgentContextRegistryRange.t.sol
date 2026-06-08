// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentContextRegistry.sol";

/**
 * @title AgentContextRegistryRangeTest
 * @notice Drives the paginated range readers (`getFilesRange`,
 *         `filesByCategoryRange`) and pause/unpause paths that the original
 *         AgentContextRegistry.t.sol doesn't cover.
 */
contract AgentContextRegistryRangeTest is Test {
    AgentIdentityRegistry public registry;
    AgentContextRegistry  public ctx;

    address public owner = address(0xA11CE);
    address public alice = address(0xA11);

    uint8 internal F_MD;
    uint8 internal F_JSON;
    uint8 internal F_YAML;
    uint8 internal C_SKILL;
    uint8 internal C_PERSONALITY;
    uint8 internal C_INSTR;
    uint8 internal MAX_C;

    bytes32 internal constant H = keccak256("file");

    uint256 internal agentId;

    function setUp() public {
        vm.startPrank(owner);
        AgentIdentityRegistry regImpl = new AgentIdentityRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl), abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        registry = AgentIdentityRegistry(address(regProxy));

        AgentContextRegistry ctxImpl = new AgentContextRegistry();
        ERC1967Proxy ctxProxy = new ERC1967Proxy(
            address(ctxImpl), abi.encodeCall(AgentContextRegistry.initialize, (address(registry)))
        );
        ctx = AgentContextRegistry(address(ctxProxy));
        vm.stopPrank();

        F_MD          = ctx.FILE_MD();
        F_JSON        = ctx.FILE_JSON();
        F_YAML        = ctx.FILE_YAML();
        C_SKILL       = ctx.CAT_SKILL();
        C_PERSONALITY = ctx.CAT_PERSONALITY();
        C_INSTR       = ctx.CAT_INSTRUCTION();
        MAX_C         = ctx.MAX_CATEGORY();

        vm.prank(alice);
        agentId = registry.registerAgent("Agent", "ipfs://meta", 1000, address(0));

        // 5 files: indices 0..4. Categories alternate SKILL/PERSONALITY.
        vm.startPrank(alice);
        ctx.addFile(agentId, "skill1",  "ipfs://1", H, F_MD,   C_SKILL,       "");
        ctx.addFile(agentId, "pers1",   "ipfs://2", H, F_JSON, C_PERSONALITY, "");
        ctx.addFile(agentId, "skill2",  "ipfs://3", H, F_MD,   C_SKILL,       "");
        ctx.addFile(agentId, "instr1",  "ipfs://4", H, F_YAML, C_INSTR,       "");
        ctx.addFile(agentId, "skill3",  "ipfs://5", H, F_MD,   C_SKILL,       "");
        vm.stopPrank();
    }

    // ─── getFilesRange ────────────────────────────────────────────────────

    function test_getFilesRange_pageWithinBounds() public view {
        AgentContextRegistry.ContextFile[] memory page = ctx.getFilesRange(agentId, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0].name, "pers1");
        assertEq(page[1].name, "skill2");
    }

    function test_getFilesRange_pageOverhangClamped() public view {
        AgentContextRegistry.ContextFile[] memory page = ctx.getFilesRange(agentId, 3, 100);
        assertEq(page.length, 2);
        assertEq(page[0].name, "instr1");
        assertEq(page[1].name, "skill3");
    }

    function test_getFilesRange_startAtOrPastEndReturnsEmpty() public view {
        AgentContextRegistry.ContextFile[] memory atEnd = ctx.getFilesRange(agentId, 5, 5);
        assertEq(atEnd.length, 0);
        AgentContextRegistry.ContextFile[] memory past = ctx.getFilesRange(agentId, 100, 5);
        assertEq(past.length, 0);
    }

    // ─── filesByCategoryRange ─────────────────────────────────────────────

    function test_filesByCategoryRange_pageWithinBounds() public view {
        // C_SKILL indices: [0, 2, 4]. start=1 count=2 → [2,4].
        uint256[] memory page = ctx.filesByCategoryRange(agentId, C_SKILL, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], 2);
        assertEq(page[1], 4);
    }

    function test_filesByCategoryRange_pageOverhangClamped() public view {
        // C_PERSONALITY has [1] only.
        uint256[] memory page = ctx.filesByCategoryRange(agentId, C_PERSONALITY, 0, 100);
        assertEq(page.length, 1);
        assertEq(page[0], 1);
    }

    function test_filesByCategoryRange_startAtOrPastEndReturnsEmpty() public view {
        uint256[] memory empty = ctx.filesByCategoryRange(agentId, C_SKILL, 3, 5);
        assertEq(empty.length, 0);
    }

    function test_filesByCategoryRange_revertsForInvalidCategory() public {
        vm.expectRevert(AgentContextRegistry.InvalidCategory.selector);
        ctx.filesByCategoryRange(agentId, MAX_C + 1, 0, 5);
    }

    // ─── pause / unpause ──────────────────────────────────────────────────

    function test_pause_blocksWrites() public {
        vm.prank(owner);
        ctx.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ctx.addFile(agentId, "x", "ipfs://x", H, F_MD, C_SKILL, "");
    }

    function test_unpause_resumesWrites() public {
        vm.prank(owner);
        ctx.pause();
        vm.prank(owner);
        ctx.unpause();

        vm.prank(alice);
        ctx.addFile(agentId, "x", "ipfs://x", H, F_MD, C_SKILL, "");
        assertEq(ctx.getFilesRange(agentId, 0, 100).length, 6);
    }

    function test_pause_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        ctx.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(owner);
        ctx.pause();
        vm.prank(alice);
        vm.expectRevert();
        ctx.unpause();
    }

    function test_pause_doesNotBlockReads() public {
        vm.prank(owner);
        ctx.pause();

        AgentContextRegistry.ContextFile[] memory page = ctx.getFilesRange(agentId, 0, 100);
        assertEq(page.length, 5);
    }
}
