// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {EvolutionTypes}      from "../../src/hooks/EvolutionTypes.sol";
import {EvolutionStagesHook} from "../../src/hooks/EvolutionStagesHook.sol";
import {OracleHook}          from "../../src/hooks/OracleHook.sol";
import {TimeOfDayHook}       from "../../src/hooks/TimeOfDayHook.sol";
import {RevenueLevelHook}    from "../../src/hooks/RevenueLevelHook.sol";
import {TransferRecolorHook} from "../../src/hooks/TransferRecolorHook.sol";

/// @dev Mock Chainlink-style oracle for OracleHook.
contract OracleMock {
    int256 public answer;
    function setAnswer(int256 a) external { answer = a; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

/**
 * @title HookCoverageSweepTest
 * @notice Drives the trigger-mismatch and view-getter paths across the
 *         remaining hooks: EvolutionStagesHook, OracleHook, TimeOfDayHook,
 *         RevenueLevelHook, TransferRecolorHook.
 */
contract HookCoverageSweepTest is Test {
    bytes32 internal constant TRIG_TIME    = EvolutionTypes.TRIGGER_TIME_TICK;
    bytes32 internal constant TRIG_TRANSFER= EvolutionTypes.TRIGGER_TRANSFER;
    bytes32 internal constant TRIG_ORACLE  = EvolutionTypes.TRIGGER_ORACLE_UPDATE;
    bytes32 internal constant TRIG_SERVICE = EvolutionTypes.TRIGGER_SERVICE_X402;
    bytes32 internal constant TRIG_OTHER   = bytes32("other");

    // ─── EvolutionStagesHook ──────────────────────────────────────────────

    function _makeStagesHook() internal returns (EvolutionStagesHook h) {
        bytes[] memory stages = new bytes[](3);
        stages[0] = bytes('<svg id="0"/>');
        stages[1] = bytes('<svg id="1"/>');
        stages[2] = bytes('<svg id="2"/>');
        h = new EvolutionStagesHook(stages);
    }

    function test_stages_totalStages() public {
        EvolutionStagesHook h = _makeStagesHook();
        assertEq(h.totalStages(), 3);
    }

    function test_stages_stageSvg_returnsExact() public {
        EvolutionStagesHook h = _makeStagesHook();
        assertEq(h.stageSvg(0), bytes('<svg id="0"/>'));
        assertEq(h.stageSvg(2), bytes('<svg id="2"/>'));
    }

    function test_stages_stageSvg_revertsForOutOfRange() public {
        EvolutionStagesHook h = _makeStagesHook();
        vm.expectRevert(EvolutionStagesHook.BadStageIndex.selector);
        h.stageSvg(3);
    }

    // ─── OracleHook ───────────────────────────────────────────────────────

    function test_oracle_onTrigger_otherTriggerNoOp() public {
        OracleMock om = new OracleMock();
        om.setAnswer(50_000 * 1e8);
        OracleHook h = new OracleHook(address(om), 40_000 * 1e8, 60_000 * 1e8);

        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_OTHER, "");
        assertFalse(r.svgChanged);
        assertEq(r.newSvgInline.length, 0);
    }

    function test_oracle_onTrigger_oracleTriggerRendersBand() public {
        OracleMock om = new OracleMock();
        om.setAnswer(70_000 * 1e8); // > upper → Bull
        OracleHook h = new OracleHook(address(om), 40_000 * 1e8, 60_000 * 1e8);

        EvolutionTypes.EvolutionResult memory r = h.onTrigger(7, TRIG_ORACLE, "");
        assertTrue(r.svgChanged);
        assertGt(r.newSvgInline.length, 50);
    }

    function test_oracle_onTrigger_rendersAllThreeBands() public {
        OracleMock om = new OracleMock();
        OracleHook h = new OracleHook(address(om), 40_000 * 1e8, 60_000 * 1e8);

        om.setAnswer(30_000 * 1e8); // Bear → down arrow
        EvolutionTypes.EvolutionResult memory rBear = h.onTrigger(1, TRIG_ORACLE, "");
        assertTrue(rBear.svgChanged);

        om.setAnswer(50_000 * 1e8); // Neutral → bar
        EvolutionTypes.EvolutionResult memory rNeutral = h.onTrigger(1, TRIG_ORACLE, "");
        assertTrue(rNeutral.svgChanged);

        om.setAnswer(70_000 * 1e8); // Bull → up arrow
        EvolutionTypes.EvolutionResult memory rBull = h.onTrigger(1, TRIG_ORACLE, "");
        assertTrue(rBull.svgChanged);

        // Distinct SVG outputs.
        assertTrue(keccak256(rBear.newSvgInline) != keccak256(rNeutral.newSvgInline));
        assertTrue(keccak256(rNeutral.newSvgInline) != keccak256(rBull.newSvgInline));
    }

    function test_oracle_readBand_bearAndNeutralAndBull() public {
        OracleMock om = new OracleMock();
        OracleHook h = new OracleHook(address(om), 40_000 * 1e8, 60_000 * 1e8);

        om.setAnswer(30_000 * 1e8);
        (OracleHook.Band band1,) = h.readBand();
        assertEq(uint256(band1), uint256(OracleHook.Band.Bear));

        om.setAnswer(50_000 * 1e8);
        (OracleHook.Band band2,) = h.readBand();
        assertEq(uint256(band2), uint256(OracleHook.Band.Neutral));

        om.setAnswer(70_000 * 1e8);
        (OracleHook.Band band3,) = h.readBand();
        assertEq(uint256(band3), uint256(OracleHook.Band.Bull));
    }

    // ─── TimeOfDayHook ────────────────────────────────────────────────────

    function test_timeOfDay_otherTriggerNoOp() public {
        TimeOfDayHook h = new TimeOfDayHook();
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_OTHER, "");
        assertFalse(r.svgChanged);
    }

    function test_timeOfDay_renderEachPhase() public {
        TimeOfDayHook h = new TimeOfDayHook();
        // Cycle through the four phases to render distinct SVGs.
        uint256 baseTs = 1_700_000_000;
        for (uint256 i = 0; i < 4; ++i) {
            vm.warp(baseTs + i * 6 hours);
            EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_TIME, "");
            assertTrue(r.svgChanged);
            assertGt(r.newSvgInline.length, 50);
        }
    }

    // ─── RevenueLevelHook ─────────────────────────────────────────────────

    function _makeRevenueHook() internal returns (RevenueLevelHook h, address recorder) {
        recorder = address(this);
        uint256[] memory thresholds = new uint256[](3);
        thresholds[0] = 0.1 ether;
        thresholds[1] = 0.5 ether;
        thresholds[2] = 1 ether;
        h = new RevenueLevelHook(recorder, thresholds);
    }

    function test_revenueLevel_otherTriggerNoOp() public {
        (RevenueLevelHook h, ) = _makeRevenueHook();
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_OTHER, "");
        assertFalse(r.svgChanged);
    }

    function test_revenueLevel_serviceTriggerRendersBadge() public {
        (RevenueLevelHook h, address recorder) = _makeRevenueHook();
        // Bump cumulative revenue past first threshold via the recorder.
        vm.prank(recorder);
        h.recordRevenue(1, 0.6 ether);
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_SERVICE, "");
        assertTrue(r.svgChanged);
        assertGt(r.newSvgInline.length, 50);
    }

    // ─── TransferRecolorHook ──────────────────────────────────────────────

    function test_recolor_otherTriggerNoOp() public {
        TransferRecolorHook h = new TransferRecolorHook();
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_OTHER, "");
        assertFalse(r.svgChanged);
    }

    function test_recolor_transferTriggerRecolors() public {
        TransferRecolorHook h = new TransferRecolorHook();
        // First call afterTransfer to bump the counter.
        h.afterTransfer(1, address(0xA), address(0xB));
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_TRANSFER, "");
        assertTrue(r.svgChanged);
        assertGt(r.newSvgInline.length, 50);
    }

    function test_recolor_afterTransfer_returnsSelector() public {
        TransferRecolorHook h = new TransferRecolorHook();
        bytes4 sel = h.afterTransfer(1, address(0xA), address(0xB));
        assertEq(sel, h.afterTransfer.selector);
        assertEq(h.transferCount(1), 1);
    }
}
