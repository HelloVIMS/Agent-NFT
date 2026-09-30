// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";
import {EvolutionTypes} from "../src/hooks/EvolutionTypes.sol";
import {EvolutionStagesHook} from "../src/hooks/EvolutionStagesHook.sol";

contract EvolutionStagesHookTest is Test {
    AgentCollectionFactory factory;
    AgentCollectionImpl    impl;
    AgentCollectionImpl    collection;
    EvolutionStagesHook    stages;

    address owner   = address(0x1);
    address creator = address(0x3);
    address minter  = address(0x4);

    uint256 constant INTERVAL = 1 hours;

    bytes constant SVG_EGG    = bytes("<svg><circle r='10' fill='#fff'/></svg>");
    bytes constant SVG_BABY   = bytes("<svg><circle r='20' fill='#9ae'/></svg>");
    bytes constant SVG_ADULT  = bytes("<svg><circle r='40' fill='#5a3'/></svg>");
    bytes constant SVG_ELDER  = bytes("<svg><circle r='60' fill='#a33'/></svg>");

    function setUp() public {
        vm.startPrank(owner);
        impl = new AgentCollectionImpl();
        factory = new AgentCollectionFactory(address(impl), address(0x2));
        vm.stopPrank();

        vm.prank(creator);
        (, address addr) = factory.createCollection("Stages", "STG", 100, 1000, 500, "");
        collection = AgentCollectionImpl(addr);

        bytes[] memory sv = new bytes[](4);
        sv[0] = SVG_EGG;
        sv[1] = SVG_BABY;
        sv[2] = SVG_ADULT;
        sv[3] = SVG_ELDER;
        stages = new EvolutionStagesHook(sv, INTERVAL);

        vm.prank(creator);
        collection.setCollectionHook(address(stages));
        vm.warp(1_000_000);
    }

    function _stage(uint256 id) internal view returns (uint8 s) {
        (s,,) = stages.progress(address(collection), id);
    }

    function _seeded(uint256 id) internal view returns (bool seeded) {
        (, seeded,) = stages.progress(address(collection), id);
    }

    uint256 internal t = 1_000_000;

    /// Explicit clock: with via-IR a test's timestamp reads can be cached
    /// across vm.warp.
    function _advance(uint256 dt) internal {
        t += dt;
        vm.warp(t);
    }

    function _trigger(uint256 id) internal {
        collection.triggerEvolve(id, EvolutionTypes.TRIGGER_TRANSFER, "");
    }

    function test_constructor_rejectsEmptyStages() public {
        bytes[] memory empty = new bytes[](0);
        vm.expectRevert(EvolutionStagesHook.NoStages.selector);
        new EvolutionStagesHook(empty, INTERVAL);
    }

    function test_firstTrigger_seedsStageZero() public {
        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");
        assertFalse(_seeded(id));
        _trigger(id);
        assertTrue(_seeded(id));
        assertEq(_stage(id), 0);
        assertEq(collection.getSVGImage(id), string(SVG_EGG));
    }

    function test_advancesOncePerInterval() public {
        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");
        _trigger(id);
        bytes[4] memory want = [SVG_EGG, SVG_BABY, SVG_ADULT, SVG_ELDER];
        for (uint8 i = 1; i < 4; i++) {
            _advance(INTERVAL);
            _trigger(id);
            assertEq(_stage(id), i);
            assertEq(collection.getSVGImage(id), string(want[i]));
        }
    }

    /// Anyone may call triggerEvolve: without the interval a stranger could
    /// fast-forward an agent to its last stage in a few calls.
    function test_strangerCannotFastForward() public {
        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");
        _trigger(id);
        vm.startPrank(address(0xBAD));
        for (uint256 i; i < 10; i++) _trigger(id);
        vm.stopPrank();
        assertEq(_stage(id), 0);
        assertEq(stages.nextAdvanceAt(address(collection), id), t + INTERVAL);
        _advance(INTERVAL - 1);
        _trigger(id);
        assertEq(_stage(id), 0);
        _advance(1);
        _trigger(id);
        assertEq(_stage(id), 1);
    }

    /// Calling the hook directly only touches the caller's own namespace.
    function test_directHookCallsDontMoveACollection() public {
        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");
        _trigger(id);
        vm.startPrank(address(0xBAD));
        for (uint256 i; i < 5; i++) {
            _advance(INTERVAL);
            stages.onTrigger(id, EvolutionTypes.TRIGGER_TRANSFER, "");
        }
        vm.stopPrank();
        assertEq(_stage(id), 0);
        (uint8 attackerStage,,) = stages.progress(address(0xBAD), id);
        assertEq(attackerStage, 3);
    }

    function test_finalStage_isSticky() public {
        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");
        _trigger(id);
        for (uint256 i = 0; i < 3; i++) {
            _advance(INTERVAL);
            _trigger(id);
        }
        assertEq(_stage(id), 3);
        assertEq(stages.nextAdvanceAt(address(collection), id), 0);
        bytes32 beforeHash = collection.evolutionStateHash(id);
        _advance(INTERVAL);
        _trigger(id);
        assertEq(_stage(id), 3);
        assertEq(collection.getSVGImage(id), string(SVG_ELDER));
        assertEq(collection.evolutionStateHash(id), beforeHash);
    }

    function test_stagesArePerAgentAndPerCollection() public {
        vm.prank(minter);
        uint256 a = collection.registerAgent("A", "uri");
        vm.prank(minter);
        uint256 b = collection.registerAgent("B", "uri");
        vm.prank(creator);
        (, address addr2) = factory.createCollection("Stages2", "ST2", 100, 1000, 500, "");
        AgentCollectionImpl other = AgentCollectionImpl(addr2);
        vm.prank(creator);
        other.setCollectionHook(address(stages));
        vm.prank(minter);
        uint256 a2 = other.registerAgent("A2", "uri");
        assertEq(a2, a, "same token id in another collection");

        _trigger(a);
        _advance(INTERVAL);
        _trigger(a);
        _trigger(b);
        other.triggerEvolve(a2, EvolutionTypes.TRIGGER_TRANSFER, "");

        assertEq(_stage(a), 1);
        assertEq(_stage(b), 0);
        (uint8 otherStage,,) = stages.progress(address(other), a2);
        assertEq(otherStage, 0);
        assertEq(other.getSVGImage(a2), string(SVG_EGG));
    }

    function test_stageSvg_outOfBoundsReverts() public {
        vm.expectRevert(EvolutionStagesHook.BadStageIndex.selector);
        stages.stageSvg(4);
    }
}
