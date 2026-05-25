// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentContextRegistry.sol";

contract AgentContextRegistryTest is Test {
    AgentIdentityRegistry public registry;
    AgentContextRegistry  public ctx;

    address public owner = address(0xA11CE);
    address public alice = address(0xA11);
    address public bob   = address(0xB0B);

    // Cached enum constants (avoid external calls that consume vm.prank)
    uint8 internal F_MD;
    uint8 internal F_JSON;
    uint8 internal F_YAML;
    uint8 internal MAX_F;
    uint8 internal C_SKILL;
    uint8 internal C_PERSONALITY;
    uint8 internal C_INSTR;
    uint8 internal C_PROMPT;
    uint8 internal MAX_C;

    bytes32 internal constant H1 = keccak256("file v1");
    bytes32 internal constant H2 = keccak256("file v2");

    function setUp() public {
        vm.startPrank(owner);

        AgentIdentityRegistry regImpl = new AgentIdentityRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        registry = AgentIdentityRegistry(address(regProxy));

        AgentContextRegistry ctxImpl = new AgentContextRegistry();
        ERC1967Proxy ctxProxy = new ERC1967Proxy(
            address(ctxImpl),
            abi.encodeCall(AgentContextRegistry.initialize, (address(registry)))
        );
        ctx = AgentContextRegistry(address(ctxProxy));

        vm.stopPrank();

        F_MD          = ctx.FILE_MD();
        F_JSON        = ctx.FILE_JSON();
        F_YAML        = ctx.FILE_YAML();
        MAX_F         = ctx.MAX_FILE_TYPE();
        C_SKILL       = ctx.CAT_SKILL();
        C_PERSONALITY = ctx.CAT_PERSONALITY();
        C_INSTR       = ctx.CAT_INSTRUCTION();
        C_PROMPT      = ctx.CAT_PROMPT();
        MAX_C         = ctx.MAX_CATEGORY();
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _mintAgent(address to) internal returns (uint256 agentId) {
        vm.prank(to);
        agentId = registry.registerAgent("Agent", "ipfs://meta", 1000, address(0));
    }

    // ─── happy paths ─────────────────────────────────────────────────────────

    function test_Init_BindsRegistryAndOwner() public view {
        assertEq(address(ctx.identityRegistry()), address(registry));
        assertEq(ctx.owner(), owner);
    }

    function test_AddFile_MarkdownSkill() public {
        uint256 id = _mintAgent(alice);
        vm.prank(alice);
        uint256 idx = ctx.addFile(id, "code-review", "ipfs://baf-review", H1, F_MD, C_SKILL, "review code");
        assertEq(idx, 0);
        assertEq(ctx.fileCount(id), 1);

        AgentContextRegistry.ContextFile memory f = ctx.getFile(id, "code-review");
        assertEq(f.name, "code-review");
        assertEq(f.contentHash, H1);
        assertEq(f.fileType, F_MD);
        assertEq(f.category, C_SKILL);
        assertTrue(f.enabled);
    }

    function test_AddFile_JsonPersonality() public {
        uint256 id = _mintAgent(alice);
        vm.prank(alice);
        ctx.addFile(id, "personality", "ar://abc", H1, F_JSON, C_PERSONALITY, "");
        AgentContextRegistry.ContextFile memory f = ctx.getFile(id, "personality");
        assertEq(f.fileType, F_JSON);
        assertEq(f.category, C_PERSONALITY);
    }

    function test_AddFile_YamlInstructions() public {
        uint256 id = _mintAgent(alice);
        vm.prank(alice);
        ctx.addFile(id, "rules", "https://example.com/rules.yaml", H1, F_YAML, C_INSTR, "");
        assertTrue(ctx.hasFile(id, "rules"));
    }

    function test_UpdateFile_OverwritesUriAndHash() public {
        uint256 id = _mintAgent(alice);
        vm.startPrank(alice);
        ctx.addFile(id, "skill", "ipfs://v1", H1, F_MD, C_SKILL, "v1");
        ctx.updateFile(id, "skill", "ipfs://v2", H2, "v2");
        vm.stopPrank();

        AgentContextRegistry.ContextFile memory f = ctx.getFile(id, "skill");
        assertEq(f.storageURI, "ipfs://v2");
        assertEq(f.contentHash, H2);
        assertEq(f.description, "v2");
        // immutable fields preserved
        assertEq(f.fileType, F_MD);
        assertEq(f.category, C_SKILL);
    }

    function test_SetEnabled_TogglesActive() public {
        uint256 id = _mintAgent(alice);
        vm.startPrank(alice);
        ctx.addFile(id, "skill", "ipfs://x", H1, F_MD, C_SKILL, "");
        assertTrue(ctx.hasFile(id, "skill"));
        ctx.setEnabled(id, "skill", false);
        assertFalse(ctx.hasFile(id, "skill"));
        ctx.setEnabled(id, "skill", true);
        assertTrue(ctx.hasFile(id, "skill"));
        vm.stopPrank();
    }

    function test_FilesByCategory_PartitionsCorrectly() public {
        uint256 id = _mintAgent(alice);
        vm.startPrank(alice);
        ctx.addFile(id, "code-review", "ipfs://1", H1, F_MD,   C_SKILL,       "");
        ctx.addFile(id, "tone",        "ipfs://2", H1, F_JSON, C_PERSONALITY, "");
        ctx.addFile(id, "refactor",    "ipfs://3", H1, F_MD,   C_SKILL,       "");
        ctx.addFile(id, "system",      "ipfs://4", H1, F_MD,   C_PROMPT,      "");
        vm.stopPrank();

        uint256[] memory skills = ctx.filesByCategory(id, C_SKILL);
        assertEq(skills.length, 2);
        assertEq(skills[0], 0);
        assertEq(skills[1], 2);

        uint256[] memory pers = ctx.filesByCategory(id, C_PERSONALITY);
        assertEq(pers.length, 1);
        assertEq(pers[0], 1);

        uint256[] memory prompts = ctx.filesByCategory(id, C_PROMPT);
        assertEq(prompts.length, 1);
        assertEq(prompts[0], 3);
    }

    function test_GetAllFiles_ReturnsAllInOrder() public {
        uint256 id = _mintAgent(alice);
        vm.startPrank(alice);
        ctx.addFile(id, "a", "ipfs://1", H1, F_MD, C_SKILL, "");
        ctx.addFile(id, "b", "ipfs://2", H2, F_JSON, C_INSTR, "");
        vm.stopPrank();
        AgentContextRegistry.ContextFile[] memory all = ctx.getAllFiles(id);
        assertEq(all.length, 2);
        assertEq(all[0].name, "a");
        assertEq(all[1].name, "b");
    }

    function test_GetFileAt_ReturnsByIndex() public {
        uint256 id = _mintAgent(alice);
        vm.prank(alice);
        ctx.addFile(id, "skill", "ipfs://x", H1, F_MD, C_SKILL, "");
        AgentContextRegistry.ContextFile memory f = ctx.getFileAt(id, 0);
        assertEq(f.name, "skill");
    }

    // ─── access control ──────────────────────────────────────────────────────

    function test_RevertWhen_NonOwner_AddFile() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentContextRegistry.NotOwner.selector);
        vm.prank(bob);
        ctx.addFile(id, "x", "ipfs://x", H1, F_MD, C_SKILL, "");
    }

    function test_RevertWhen_NonOwner_UpdateFile() public {
        uint256 id = _mintAgent(alice);
        vm.prank(alice);
        ctx.addFile(id, "x", "ipfs://x", H1, F_MD, C_SKILL, "");
        vm.expectRevert(AgentContextRegistry.NotOwner.selector);
        vm.prank(bob);
        ctx.updateFile(id, "x", "ipfs://y", H2, "");
    }

    function test_RevertWhen_NonOwner_SetEnabled() public {
        uint256 id = _mintAgent(alice);
        vm.prank(alice);
        ctx.addFile(id, "x", "ipfs://x", H1, F_MD, C_SKILL, "");
        vm.expectRevert(AgentContextRegistry.NotOwner.selector);
        vm.prank(bob);
        ctx.setEnabled(id, "x", false);
    }

    function test_SetIdentityRegistry_OwnerOnly() public {
        address newReg = address(0xBEEF);
        vm.expectRevert();
        vm.prank(bob);
        ctx.setIdentityRegistry(newReg);

        vm.prank(owner);
        ctx.setIdentityRegistry(newReg);
        assertEq(address(ctx.identityRegistry()), newReg);
    }

    // ─── input validation ────────────────────────────────────────────────────

    function test_RevertWhen_DuplicateName() public {
        uint256 id = _mintAgent(alice);
        vm.prank(alice);
        ctx.addFile(id, "x", "ipfs://1", H1, F_MD, C_SKILL, "");
        vm.expectRevert(AgentContextRegistry.AlreadyExists.selector);
        vm.prank(alice);
        ctx.addFile(id, "x", "ipfs://2", H2, F_JSON, C_INSTR, "");
    }

    function test_RevertWhen_Name_Empty() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentContextRegistry.EmptyInput.selector);
        vm.prank(alice);
        ctx.addFile(id, "", "ipfs://x", H1, F_MD, C_SKILL, "");
    }

    function test_RevertWhen_StorageURI_Empty() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentContextRegistry.EmptyInput.selector);
        vm.prank(alice);
        ctx.addFile(id, "x", "", H1, F_MD, C_SKILL, "");
    }

    function test_RevertWhen_ContentHash_Zero() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentContextRegistry.EmptyInput.selector);
        vm.prank(alice);
        ctx.addFile(id, "x", "ipfs://x", bytes32(0), F_MD, C_SKILL, "");
    }

    function test_RevertWhen_FileType_OutOfRange() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentContextRegistry.InvalidFileType.selector);
        vm.prank(alice);
        ctx.addFile(id, "x", "ipfs://x", H1, 5, C_SKILL, "");
    }

    function test_RevertWhen_Category_OutOfRange() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentContextRegistry.InvalidCategory.selector);
        vm.prank(alice);
        ctx.addFile(id, "x", "ipfs://x", H1, F_MD, 7, "");
    }

    function test_RevertWhen_Update_NotExists() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentContextRegistry.NotExists.selector);
        vm.prank(alice);
        ctx.updateFile(id, "missing", "ipfs://y", H2, "");
    }

    function test_RevertWhen_GetFile_NotExists() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentContextRegistry.NotExists.selector);
        ctx.getFile(id, "missing");
    }

    function test_RevertWhen_GetFileAt_OutOfRange() public {
        uint256 id = _mintAgent(alice);
        vm.expectRevert(AgentContextRegistry.NotExists.selector);
        ctx.getFileAt(id, 0);
    }

    // ─── fuzz ────────────────────────────────────────────────────────────────

    function testFuzz_AddFile_AcceptsValidEnumCombinations(uint8 ft, uint8 c) public {
        ft = uint8(bound(ft, 0, MAX_F));
        c  = uint8(bound(c,  0, MAX_C));
        uint256 id = _mintAgent(alice);
        vm.prank(alice);
        ctx.addFile(id, "x", "ipfs://x", H1, ft, c, "");
        AgentContextRegistry.ContextFile memory f = ctx.getFile(id, "x");
        assertEq(f.fileType, ft);
        assertEq(f.category, c);
    }
}
