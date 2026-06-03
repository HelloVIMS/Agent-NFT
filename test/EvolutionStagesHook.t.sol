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
        stages = new EvolutionStagesHook(sv);

        vm.prank(creator);
        collection.setCollectionHook(address(stages));
    }

    function test_constructor_rejectsEmptyStages() public {
        bytes[] memory empty = new bytes[](0);
        vm.expectRevert(EvolutionStagesHook.NoStages.selector);
        new EvolutionStagesHook(empty);
    }

    function test_firstTrigger_seedsStageZero() public {
        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        assertEq(stages.stage(id), 0);
        assertFalse(stages.seeded(id));

        collection.triggerEvolve(id, EvolutionTypes.TRIGGER_TRANSFER, "");

        assertTrue(stages.seeded(id));
        assertEq(stages.stage(id), 0);
        assertEq(collection.getSVGImage(id), string(SVG_EGG));
    }

    function test_subsequentTriggers_advanceStage() public {
        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        // seed
        collection.triggerEvolve(id, EvolutionTypes.TRIGGER_TRANSFER, "");
        assertEq(collection.getSVGImage(id), string(SVG_EGG));

        // advance to BABY
        collection.triggerEvolve(id, EvolutionTypes.TRIGGER_TRANSFER, "");
        assertEq(stages.stage(id), 1);
        assertEq(collection.getSVGImage(id), string(SVG_BABY));

        // advance to ADULT
        collection.triggerEvolve(id, EvolutionTypes.TRIGGER_TRANSFER, "");
        assertEq(stages.stage(id), 2);
        assertEq(collection.getSVGImage(id), string(SVG_ADULT));

        // advance to ELDER (final)
        collection.triggerEvolve(id, EvolutionTypes.TRIGGER_TRANSFER, "");
        assertEq(stages.stage(id), 3);
        assertEq(collection.getSVGImage(id), string(SVG_ELDER));
    }

    function test_finalStage_isSticky() public {
        vm.prank(minter);
        uint256 id = collection.registerAgent("A", "uri");

        // Max out the stages
        for (uint256 i = 0; i < 4; i++) {
            collection.triggerEvolve(id, EvolutionTypes.TRIGGER_TRANSFER, "");
        }
        assertEq(stages.stage(id), 3);
        bytes32 beforeHash = collection.evolutionStateHash(id);

        // Further triggers are no-ops (svgChanged=false)
        collection.triggerEvolve(id, EvolutionTypes.TRIGGER_TRANSFER, "");
        assertEq(stages.stage(id), 3);
        assertEq(collection.getSVGImage(id), string(SVG_ELDER));
        // State hash unchanged for no-op result.
        assertEq(collection.evolutionStateHash(id), beforeHash);
    }

    function test_stagesArePerAgent() public {
        vm.prank(minter);
        uint256 a = collection.registerAgent("A", "uri");
        vm.prank(minter);
        uint256 b = collection.registerAgent("B", "uri");

        // a: seed + advance once → stage 1
        collection.triggerEvolve(a, EvolutionTypes.TRIGGER_TRANSFER, "");
        collection.triggerEvolve(a, EvolutionTypes.TRIGGER_TRANSFER, "");
        // b: seed only → stage 0
        collection.triggerEvolve(b, EvolutionTypes.TRIGGER_TRANSFER, "");

        assertEq(stages.stage(a), 1);
        assertEq(stages.stage(b), 0);
        assertEq(collection.getSVGImage(a), string(SVG_BABY));
        assertEq(collection.getSVGImage(b), string(SVG_EGG));
    }

    function test_stageSvg_outOfBoundsReverts() public {
        vm.expectRevert(EvolutionStagesHook.BadStageIndex.selector);
        stages.stageSvg(4);
    }
}
