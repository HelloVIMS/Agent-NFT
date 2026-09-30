// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC721}          from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AgentStatusHook} from "../../src/hooks/AgentStatusHook.sol";
import {EvolutionTypes}  from "../../src/hooks/EvolutionTypes.sol";

contract StatusCollection is ERC721 {
    constructor() ERC721("Status", "ST") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

contract AgentStatusHookTest is Test {
    AgentStatusHook hook;
    StatusCollection a;
    StatusCollection b;

    address constant ALICE = address(0xA11CE);
    address constant BOB   = address(0xB0B);
    address constant OP    = address(0x0B);

    bytes32 constant TRIG = keccak256("status.change");

    function setUp() public {
        hook = new AgentStatusHook();
        a = new StatusCollection();
        b = new StatusCollection();
        a.mint(ALICE, 1);
        b.mint(BOB, 1);
    }

    function _status(StatusCollection c, uint256 id) internal view returns (AgentStatusHook.Status s) {
        (s,) = hook.getStatus(address(c), id);
    }

    function test_ownerSetsStatus() public {
        vm.warp(1000);
        vm.prank(ALICE);
        hook.setStatus(address(a), 1, AgentStatusHook.Status.Running);
        (AgentStatusHook.Status s, uint64 at) = hook.getStatus(address(a), 1);
        assertEq(uint8(s), uint8(AgentStatusHook.Status.Running));
        assertEq(at, 1000);
    }

    function test_strangerCantSetStatus() public {
        vm.prank(BOB);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        hook.setStatus(address(a), 1, AgentStatusHook.Status.Running);
    }

    function test_unknownTokenOrNonCollectionRefused() public {
        vm.prank(ALICE);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        hook.setStatus(address(a), 99, AgentStatusHook.Status.Running);
        vm.prank(ALICE);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        hook.setStatus(address(0xEEEE), 1, AgentStatusHook.Status.Running);
    }

    /// Token 1 exists in both collections with different owners.
    function test_statusIsPerCollection() public {
        vm.prank(ALICE);
        hook.setStatus(address(a), 1, AgentStatusHook.Status.Running);
        assertEq(uint8(_status(b, 1)), uint8(AgentStatusHook.Status.Offline));
        vm.prank(ALICE);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        hook.setStatus(address(b), 1, AgentStatusHook.Status.Running);
    }

    function test_operatorCanSetStatus() public {
        vm.prank(ALICE);
        hook.setOperator(address(a), 1, OP, true);
        vm.prank(OP);
        hook.setStatus(address(a), 1, AgentStatusHook.Status.Standby);
        assertEq(uint8(_status(a, 1)), uint8(AgentStatusHook.Status.Standby));
        vm.prank(ALICE);
        hook.setOperator(address(a), 1, OP, false);
        vm.prank(OP);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        hook.setStatus(address(a), 1, AgentStatusHook.Status.Running);
    }

    function test_onlyOwnerAppointsOperators() public {
        vm.prank(OP);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        hook.setOperator(address(a), 1, OP, true);
    }

    /// A sale drops the previous owner's operators, and the previous owner.
    function test_saleDropsPreviousOwnersOperators() public {
        vm.prank(ALICE);
        hook.setOperator(address(a), 1, OP, true);
        vm.prank(ALICE);
        a.transferFrom(ALICE, BOB, 1);
        vm.prank(OP);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        hook.setStatus(address(a), 1, AgentStatusHook.Status.Running);
        vm.prank(ALICE);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        hook.setStatus(address(a), 1, AgentStatusHook.Status.Running);
        vm.prank(BOB);
        hook.setStatus(address(a), 1, AgentStatusHook.Status.Running);
        // Appointing the same operator again is the new owner's choice.
        assertFalse(hook.isAuthorised(address(a), 1, OP));
    }

    function test_sameStatusIsANoop() public {
        vm.warp(1000);
        vm.prank(ALICE);
        hook.setStatus(address(a), 1, AgentStatusHook.Status.Running);
        vm.warp(2000);
        vm.recordLogs();
        vm.prank(ALICE);
        hook.setStatus(address(a), 1, AgentStatusHook.Status.Running);
        assertEq(vm.getRecordedLogs().length, 0);
        (, uint64 at) = hook.getStatus(address(a), 1);
        assertEq(at, 1000);
    }

    function test_firstSetToOfflineIsRecorded() public {
        vm.warp(1000);
        vm.prank(ALICE);
        hook.setStatus(address(a), 1, AgentStatusHook.Status.Offline);
        (, uint64 at) = hook.getStatus(address(a), 1);
        assertEq(at, 1000);
    }

    function test_triggerRendersTheCallingCollectionsStatus() public {
        vm.prank(ALICE);
        hook.setStatus(address(a), 1, AgentStatusHook.Status.Running);
        vm.prank(address(a));
        EvolutionTypes.EvolutionResult memory ra = hook.onTrigger(1, TRIG, "");
        vm.prank(address(b));
        EvolutionTypes.EvolutionResult memory rb = hook.onTrigger(1, TRIG, "");
        assertTrue(ra.svgChanged && rb.svgChanged);
        assertTrue(keccak256(ra.newSvgInline) != keccak256(rb.newSvgInline));
        assertFalse(hook.onTrigger(1, keccak256("custom"), "").svgChanged);
    }

    function test_permissionsAreOnTriggerOnly() public view {
        assertEq(hook.permissions(), EvolutionTypes.FLAG_ON_TRIGGER);
    }
}
