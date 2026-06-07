// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentStatusHook} from "../../src/hooks/AgentStatusHook.sol";
import {EvolutionTypes} from "../../src/hooks/EvolutionTypes.sol";

/**
 * @dev Implements the same surface AgentStatusHook calls into. We
 *      deliberately omit `getAgentOwner` to exercise the catch path —
 *      a separate registry stub `MockRegistryAgentOwnerOnly` lets us
 *      flip the case where ownerOf is missing instead.
 */
contract MockRegistry {
    mapping(uint256 => address) public ownerByToken;

    function setOwner(uint256 id, address who) external {
        ownerByToken[id] = who;
    }

    function ownerOf(uint256 id) external view returns (address) {
        require(ownerByToken[id] != address(0), "no token");
        return ownerByToken[id];
    }

    function getAgentOwner(uint256 id) external view returns (address) {
        return ownerByToken[id];
    }
}

contract AgentStatusHookTest is Test {
    AgentStatusHook internal hook;
    MockRegistry    internal reg;

    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal eve      = makeAddr("eve");
    uint256 internal constant AGENT = 7;

    // Re-declare events so vm.expectEmit can match them.
    event StatusChanged(
        uint256 indexed agentId,
        AgentStatusHook.Status indexed previous,
        AgentStatusHook.Status indexed next,
        address by,
        uint64 at
    );
    event OperatorUpdated(uint256 indexed agentId, address indexed operator, bool allowed);

    function setUp() public {
        reg = new MockRegistry();
        reg.setOwner(AGENT, alice);
        hook = new AgentStatusHook(address(reg));
    }

    // ── Construction ────────────────────────────────────────────────────────

    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(AgentStatusHook.ZeroRegistry.selector);
        new AgentStatusHook(address(0));
    }

    function test_getPermissions_declaresOnTriggerOnly() public view {
        assertEq(hook.getPermissions(), EvolutionTypes.FLAG_ON_TRIGGER);
    }

    // ── setStatus authority model ──────────────────────────────────────────

    function test_setStatus_byOwnerSucceeds() public {
        vm.expectEmit(true, true, true, true, address(hook));
        emit StatusChanged(AGENT, AgentStatusHook.Status.Offline, AgentStatusHook.Status.Running, alice, uint64(block.timestamp));
        vm.prank(alice);
        hook.setStatus(AGENT, AgentStatusHook.Status.Running);

        (AgentStatusHook.Status s, uint64 ts) = hook.getStatus(AGENT);
        assertEq(uint256(s), uint256(AgentStatusHook.Status.Running));
        assertEq(ts, uint64(block.timestamp));
        assertTrue(hook.isRunning(AGENT));
    }

    function test_setStatus_byNonOwnerNonOperatorReverts() public {
        vm.prank(eve);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        hook.setStatus(AGENT, AgentStatusHook.Status.Running);
    }

    function test_setStatus_byApprovedOperatorSucceeds() public {
        vm.prank(alice);
        hook.setOperator(AGENT, bob, true);

        vm.prank(bob);
        hook.setStatus(AGENT, AgentStatusHook.Status.Standby);

        assertEq(uint256(_status()), uint256(AgentStatusHook.Status.Standby));
    }

    function test_setStatus_repeatedSameValueIsNoOp() public {
        vm.startPrank(alice);
        hook.setStatus(AGENT, AgentStatusHook.Status.Running);
        // Capture the lastUpdate before the redundant set…
        ( , uint64 ts1) = hook.getStatus(AGENT);
        vm.warp(block.timestamp + 1 days);
        // …redundant set must NOT update the timestamp (state-write-skipping).
        vm.recordLogs();
        hook.setStatus(AGENT, AgentStatusHook.Status.Running);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 0, "no-op set must not emit");
        ( , uint64 ts2) = hook.getStatus(AGENT);
        assertEq(ts1, ts2, "no-op must not bump timestamp");
        vm.stopPrank();
    }

    function test_setStatus_revertsOnUnknownEnumValue() public {
        // Status enum has 3 entries (Offline=0, Standby=1, Running=2). An
        // out-of-range cast triggers Solidity's panic(0x21) at calldata
        // decode — before the function body. Either way the call must not
        // succeed: hook state must not advance.
        bytes memory cd = abi.encodeWithSelector(hook.setStatus.selector, AGENT, uint8(99));
        vm.prank(alice);
        (bool ok, ) = address(hook).call(cd);
        assertFalse(ok, "out-of-range enum must not succeed");
        // State unchanged.
        (AgentStatusHook.Status s, ) = hook.getStatus(AGENT);
        assertEq(uint256(s), uint256(AgentStatusHook.Status.Offline));
    }

    // ── setOperator authority model ────────────────────────────────────────

    function test_setOperator_byOwnerSucceeds() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit OperatorUpdated(AGENT, bob, true);
        vm.prank(alice);
        hook.setOperator(AGENT, bob, true);
    }

    function test_setOperator_operatorCannotDelegate() public {
        // Authorise bob as an operator…
        vm.prank(alice);
        hook.setOperator(AGENT, bob, true);
        // …bob can call setStatus, but cannot create new operators.
        vm.prank(bob);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        hook.setOperator(AGENT, eve, true);
    }

    function test_setOperator_revoke() public {
        vm.startPrank(alice);
        hook.setOperator(AGENT, bob, true);
        hook.setOperator(AGENT, bob, false);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        hook.setStatus(AGENT, AgentStatusHook.Status.Running);
    }

    // ── onTrigger ──────────────────────────────────────────────────────────

    function test_onTrigger_statusChangeReturnsNewSvg() public {
        vm.prank(alice);
        hook.setStatus(AGENT, AgentStatusHook.Status.Running);

        EvolutionTypes.EvolutionResult memory r = hook.onTrigger(AGENT, EvolutionTypes.TRIGGER_STATUS_CHANGE, "");
        assertTrue(r.svgChanged, "svgChanged not flagged");
        assertGt(r.newSvgInline.length, 0, "empty SVG");
        assertTrue(_contains(r.newSvgInline, bytes("RUN")), "RUN label missing");
        assertTrue(_contains(r.newSvgInline, bytes("#22c55e")), "running color missing");
    }

    function test_onTrigger_offlineRendersGreyOFF() public {
        EvolutionTypes.EvolutionResult memory r = hook.onTrigger(AGENT, EvolutionTypes.TRIGGER_STATUS_CHANGE, "");
        assertTrue(_contains(r.newSvgInline, bytes("OFF")), "OFF label missing");
        assertTrue(_contains(r.newSvgInline, bytes("#6b7280")), "grey color missing");
    }

    function test_onTrigger_standbyRendersAmberSTBY() public {
        vm.prank(alice);
        hook.setStatus(AGENT, AgentStatusHook.Status.Standby);
        EvolutionTypes.EvolutionResult memory r = hook.onTrigger(AGENT, EvolutionTypes.TRIGGER_STATUS_CHANGE, "");
        assertTrue(_contains(r.newSvgInline, bytes("STBY")), "STBY label missing");
        assertTrue(_contains(r.newSvgInline, bytes("#f59e0b")), "amber color missing");
    }

    function test_onTrigger_unrelatedTriggerReturnsNoOp() public {
        EvolutionTypes.EvolutionResult memory r = hook.onTrigger(AGENT, EvolutionTypes.TRIGGER_TRANSFER, "");
        assertFalse(r.svgChanged);
        assertEq(r.newSvgInline.length, 0);
    }

    // ── helpers ────────────────────────────────────────────────────────────

    function _status() internal view returns (AgentStatusHook.Status s) {
        (s, ) = hook.getStatus(AGENT);
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || needle.length > haystack.length) return needle.length == 0;
        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) { match_ = false; break; }
            }
            if (match_) return true;
        }
        return false;
    }
}
