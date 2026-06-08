// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentSkillsExtension} from "../src/AgentSkillsExtension.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @dev Minimal stub of {IAgentIdentityRegistry} that only honours `ownerOf`,
 *      which is the single function the SkillsExtension calls. Avoids
 *      pulling the whole identity-registry deployment graph into a unit
 *      test for an extension contract.
 */
contract MockIdentityRegistry {
    mapping(uint256 => address) public owners;

    function setOwner(uint256 id, address who) external {
        owners[id] = who;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return owners[id];
    }
}

contract AgentSkillsExtensionTest is Test {
    AgentSkillsExtension internal ext;
    MockIdentityRegistry internal idReg;

    address internal owner   = makeAddr("owner");
    address internal agentEoa = makeAddr("agent-owner");
    address internal stranger = makeAddr("stranger");
    uint256 internal constant AGENT = 1;

    bytes32 internal constant HASH_A = keccak256("skill-content-a");
    bytes32 internal constant HASH_B = keccak256("skill-content-b");

    function setUp() public {
        idReg = new MockIdentityRegistry();
        idReg.setOwner(AGENT, agentEoa);

        // UUPS pattern: deploy impl + proxy, then initialise the proxy.
        AgentSkillsExtension impl = new AgentSkillsExtension();
        bytes memory init = abi.encodeCall(AgentSkillsExtension.initialize, (address(idReg)));
        vm.prank(owner);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        ext = AgentSkillsExtension(address(proxy));
    }

    // ── Initialisation ─────────────────────────────────────────────────────

    function test_initialize_setsOwnerAndRegistry() public view {
        assertEq(ext.owner(), owner);
        assertEq(address(ext.identityRegistry()), address(idReg));
    }

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        ext.initialize(address(idReg));
    }

    // ── addSkill ───────────────────────────────────────────────────────────

    function test_addSkill_happyPath() public {
        vm.prank(agentEoa);
        uint256 idx = ext.addSkill(AGENT, "summarise", "ar-tx-1", HASH_A, "Summarise text");
        assertEq(idx, 0);
        assertTrue(ext.hasSkill(AGENT, "summarise"));
        assertEq(ext.getSkillCount(AGENT), 1);

        (string memory tx_, bytes32 hash_, uint256 ts, string memory desc, bool enabled) =
            ext.getSkill(AGENT, "summarise");
        assertEq(tx_, "ar-tx-1");
        assertEq(hash_, HASH_A);
        assertEq(desc, "Summarise text");
        assertTrue(enabled);
        assertGt(ts, 0);
    }

    function test_addSkill_revertsOnEmptyName() public {
        vm.prank(agentEoa);
        vm.expectRevert(AgentSkillsExtension.EmptyInput.selector);
        ext.addSkill(AGENT, "", "ar-tx", HASH_A, "");
    }

    function test_addSkill_revertsOnEmptyArweave() public {
        vm.prank(agentEoa);
        vm.expectRevert(AgentSkillsExtension.EmptyInput.selector);
        ext.addSkill(AGENT, "summarise", "", HASH_A, "");
    }

    function test_addSkill_revertsOnZeroHash() public {
        vm.prank(agentEoa);
        vm.expectRevert(AgentSkillsExtension.EmptyInput.selector);
        ext.addSkill(AGENT, "summarise", "ar-tx", bytes32(0), "");
    }

    function test_addSkill_revertsOnDuplicate() public {
        vm.startPrank(agentEoa);
        ext.addSkill(AGENT, "summarise", "ar-tx-1", HASH_A, "");
        vm.expectRevert(AgentSkillsExtension.AlreadySet.selector);
        ext.addSkill(AGENT, "summarise", "ar-tx-2", HASH_B, "");
        vm.stopPrank();
    }

    function test_addSkill_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(AgentSkillsExtension.NotOwner.selector);
        ext.addSkill(AGENT, "summarise", "ar-tx", HASH_A, "");
    }

    // ── updateSkill ────────────────────────────────────────────────────────

    function test_updateSkill_replacesArweaveAndHash() public {
        vm.startPrank(agentEoa);
        ext.addSkill(AGENT, "code-review", "ar-1", HASH_A, "v1");
        vm.warp(block.timestamp + 1 hours);
        ext.updateSkill(AGENT, "code-review", "ar-2", HASH_B, "v2");
        vm.stopPrank();

        (string memory tx_, bytes32 hash_,, string memory desc,) = ext.getSkill(AGENT, "code-review");
        assertEq(tx_, "ar-2");
        assertEq(hash_, HASH_B);
        assertEq(desc, "v2");
    }

    function test_updateSkill_revertsForUnknown() public {
        vm.prank(agentEoa);
        vm.expectRevert(AgentSkillsExtension.NotExists.selector);
        ext.updateSkill(AGENT, "ghost", "ar", HASH_A, "");
    }

    function test_updateSkill_revertsForNonOwner() public {
        vm.prank(agentEoa);
        ext.addSkill(AGENT, "x", "ar", HASH_A, "");
        vm.prank(stranger);
        vm.expectRevert(AgentSkillsExtension.NotOwner.selector);
        ext.updateSkill(AGENT, "x", "ar2", HASH_B, "");
    }

    // ── toggleSkill ────────────────────────────────────────────────────────

    function test_toggleSkill_disablesAndReEnables() public {
        vm.startPrank(agentEoa);
        ext.addSkill(AGENT, "x", "ar", HASH_A, "");
        ext.toggleSkill(AGENT, "x", false);
        assertFalse(ext.hasSkill(AGENT, "x"));
        ext.toggleSkill(AGENT, "x", true);
        assertTrue(ext.hasSkill(AGENT, "x"));
        vm.stopPrank();
    }

    function test_toggleSkill_revertsForUnknown() public {
        vm.prank(agentEoa);
        vm.expectRevert(AgentSkillsExtension.NotExists.selector);
        ext.toggleSkill(AGENT, "ghost", true);
    }

    // ── Read paths ─────────────────────────────────────────────────────────

    function test_hasSkill_falseWhenUnknown() public view {
        assertFalse(ext.hasSkill(AGENT, "anything"));
    }

    function test_getSkill_revertsForUnknown() public {
        vm.expectRevert(AgentSkillsExtension.NotExists.selector);
        ext.getSkill(AGENT, "ghost");
    }

    function test_getAllSkills_returnsInsertOrder() public {
        vm.startPrank(agentEoa);
        ext.addSkill(AGENT, "a", "ar-a", HASH_A, "");
        ext.addSkill(AGENT, "b", "ar-b", HASH_B, "");
        vm.stopPrank();
        AgentSkillsExtension.SkillVersion[] memory all = ext.getAllSkills(AGENT);
        assertEq(all.length, 2);
        assertEq(all[0].skillName, "a");
        assertEq(all[1].skillName, "b");
    }

    function test_getSkillURL_returnsArweaveURI() public {
        vm.prank(agentEoa);
        ext.addSkill(AGENT, "x", "tx-id-zzz", HASH_A, "");
        assertEq(ext.getSkillURL(AGENT, "x"), "ar://tx-id-zzz");
    }

    function test_getSkillURL_revertsForUnknown() public {
        vm.expectRevert(AgentSkillsExtension.NotExists.selector);
        ext.getSkillURL(AGENT, "ghost");
    }

    // ── Admin path ─────────────────────────────────────────────────────────

    function test_setIdentityRegistry_onlyOwner() public {
        MockIdentityRegistry idReg2 = new MockIdentityRegistry();
        vm.prank(stranger);
        vm.expectRevert();
        ext.setIdentityRegistry(address(idReg2));

        vm.prank(owner);
        ext.setIdentityRegistry(address(idReg2));
        assertEq(address(ext.identityRegistry()), address(idReg2));
    }

    // ── MAX_SKILL_VERSIONS limit ──────────────────────────────────────────

    function test_addSkill_revertsAfterMaxReached() public {
        // Filling 100 skills is 100 storage writes — keep names short and
        // just iterate.
        vm.startPrank(agentEoa);
        for (uint256 i = 0; i < 100; i++) {
            string memory name = string.concat("s", vm.toString(i));
            ext.addSkill(AGENT, name, "ar", HASH_A, "");
        }
        vm.expectRevert(AgentSkillsExtension.MaxReached.selector);
        ext.addSkill(AGENT, "overflow", "ar", HASH_A, "");
        vm.stopPrank();
    }
}
