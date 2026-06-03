// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {TimeOfDayHook}     from "../../src/hooks/TimeOfDayHook.sol";
import {RevenueLevelHook}  from "../../src/hooks/RevenueLevelHook.sol";
import {OracleHook}        from "../../src/hooks/OracleHook.sol";
import {EvolutionTypes}    from "../../src/hooks/EvolutionTypes.sol";

/// @dev Mock Chainlink-style aggregator we control completely from tests.
contract MockPriceFeed {
    int256  public answer;
    uint256 public updatedAt;
    uint8   public dec = 8;

    function setAnswer(int256 a, uint256 t) external { answer = a; updatedAt = t; }
    function decimals() external view returns (uint8) { return dec; }
    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) { return (1, answer, updatedAt, updatedAt, 1); }
}

contract DeployedHooksAudit is Test {
    bytes32 internal constant TRIG_TIME    = keccak256("time.tick");
    bytes32 internal constant TRIG_X402    = keccak256("service.x402");
    bytes32 internal constant TRIG_ORACLE  = keccak256("oracle.update");
    bytes32 internal constant TRIG_CUSTOM  = keccak256("custom");

    // ─────────────────────────────────────────────────────────────────────
    // TimeOfDayHook
    // ─────────────────────────────────────────────────────────────────────

    function test_AUDIT_TimeOfDay_allFourPhasesReachable() public {
        TimeOfDayHook h = new TimeOfDayHook();

        // 03:00 UTC → Night
        vm.warp(3 hours);
        assertEq(uint256(h.currentPhase()), uint256(TimeOfDayHook.Phase.Night));
        // 08:00 UTC → Dawn
        vm.warp(8 hours);
        assertEq(uint256(h.currentPhase()), uint256(TimeOfDayHook.Phase.Dawn));
        // 14:00 UTC → Noon
        vm.warp(14 hours);
        assertEq(uint256(h.currentPhase()), uint256(TimeOfDayHook.Phase.Noon));
        // 19:00 UTC → Dusk
        vm.warp(19 hours);
        assertEq(uint256(h.currentPhase()), uint256(TimeOfDayHook.Phase.Dusk));
        // 22:00 UTC → Night again
        vm.warp(22 hours);
        assertEq(uint256(h.currentPhase()), uint256(TimeOfDayHook.Phase.Night));
    }

    function testFuzz_AUDIT_TimeOfDay_phaseBoundaries(uint32 ts) public {
        TimeOfDayHook h = new TimeOfDayHook();
        vm.warp(ts);
        TimeOfDayHook.Phase p = h.currentPhase();
        // No invalid enum values
        assertLt(uint256(p), 4);
    }

    function test_AUDIT_TimeOfDay_unsupportedTriggerIsNoop() public {
        TimeOfDayHook h = new TimeOfDayHook();
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_X402, "");
        assertFalse(r.svgChanged);
        assertEq(r.newSvgInline.length, 0);
    }

    function test_AUDIT_TimeOfDay_correctTriggerEmitsAndChangesSvg() public {
        TimeOfDayHook h = new TimeOfDayHook();
        vm.warp(14 hours);
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_TIME, "");
        assertTrue(r.svgChanged);
        assertGt(r.newSvgInline.length, 100);
        assertTrue(r.newStateHash != bytes32(0));
    }

    // ─────────────────────────────────────────────────────────────────────
    // RevenueLevelHook
    // ─────────────────────────────────────────────────────────────────────

    function _newRevenueHook(address recorder) internal returns (RevenueLevelHook h) {
        uint256[] memory th = new uint256[](4);
        th[0] = 1 ether;
        th[1] = 5 ether;
        th[2] = 10 ether;
        th[3] = 50 ether;
        h = new RevenueLevelHook(recorder, th);
    }

    function test_AUDIT_RevenueLevel_recorderOnlyAuth() public {
        address recorder = address(0xAAA1);
        RevenueLevelHook h = _newRevenueHook(recorder);

        // Random caller cannot record.
        vm.expectRevert(RevenueLevelHook.NotRevenueRecorder.selector);
        h.recordRevenue(1, 1 ether);

        // Authorised caller works.
        vm.prank(recorder);
        h.recordRevenue(1, 1 ether);
        assertEq(h.cumulativeRevenue(1), 1 ether);
        assertEq(h.level(1), 1);
    }

    function test_AUDIT_RevenueLevel_singleCallSpansMultipleLevels() public {
        // Adversarial: a single big inflow should advance through ALL crossed
        // thresholds atomically, not just one level.
        address recorder = address(0xAAA1);
        RevenueLevelHook h = _newRevenueHook(recorder);

        vm.prank(recorder);
        h.recordRevenue(7, 12 ether); // crosses thresholds 0, 1, 2 in one shot

        assertEq(h.level(7), 3); // levels 1, 2, 3 unlocked
    }

    function test_AUDIT_RevenueLevel_levelCappedAtThresholdsLength() public {
        address recorder = address(0xAAA1);
        RevenueLevelHook h = _newRevenueHook(recorder);

        vm.prank(recorder);
        h.recordRevenue(1, 1_000 ether); // way past all thresholds

        assertEq(h.level(1), 4); // == thresholds.length
    }

    function testFuzz_AUDIT_RevenueLevel_monotonicLevel(uint8 calls) public {
        // Level must be monotonically non-decreasing across any sequence
        // of recordRevenue calls.
        address recorder = address(0xAAA1);
        RevenueLevelHook h = _newRevenueHook(recorder);

        uint256 c = uint256(bound(calls, 1, 16));
        uint8 lastLvl;
        for (uint256 i; i < c; ++i) {
            vm.prank(recorder);
            h.recordRevenue(1, 0.5 ether);
            uint8 lvl = h.level(1);
            assertGe(lvl, lastLvl);
            lastLvl = lvl;
        }
    }

    function test_AUDIT_RevenueLevel_unsupportedTriggerIsNoop() public {
        RevenueLevelHook h = _newRevenueHook(address(0xAAA1));
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_TIME, "");
        assertFalse(r.svgChanged);
    }

    function test_AUDIT_RevenueLevel_correctTriggerSvgChanges() public {
        address recorder = address(0xAAA1);
        RevenueLevelHook h = _newRevenueHook(recorder);
        vm.prank(recorder);
        h.recordRevenue(1, 6 ether);

        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_X402, "");
        assertTrue(r.svgChanged);
        assertGt(r.newSvgInline.length, 100);
    }

    // ─────────────────────────────────────────────────────────────────────
    // OracleHook
    // ─────────────────────────────────────────────────────────────────────

    function _newOracle() internal returns (OracleHook h, MockPriceFeed feed) {
        feed = new MockPriceFeed();
        h = new OracleHook(address(feed), 2_000_00000000, 3_500_00000000); // bear<2k, bull>=3.5k (8 decimals)
    }

    function test_AUDIT_Oracle_revertsOnStalePrice() public {
        // Warp forward so we can set a stale `updatedAt` without underflow.
        vm.warp(10 days);
        (OracleHook h, MockPriceFeed feed) = _newOracle();
        feed.setAnswer(2_500_00000000, block.timestamp - 2 hours);
        vm.expectRevert(OracleHook.StalePrice.selector);
        h.readBand();
    }

    /// @dev FINDING I-04 (FIXED): a future-dated `updatedAt` (e.g.,
    ///      misconfigured feed or replay across forks) used to cause an
    ///      arithmetic underflow panic instead of a clean `StalePrice` revert.
    ///      Fix: `if (updatedAt > block.timestamp) revert StalePrice();`
    ///      before the subtraction.
    function test_AUDIT_I04_futureDatedRoundClean() public {
        vm.warp(10 days);
        (OracleHook h, MockPriceFeed feed) = _newOracle();
        feed.setAnswer(2_500_00000000, block.timestamp + 1 hours); // future
        vm.expectRevert(OracleHook.StalePrice.selector);
        h.readBand();
    }

    function test_AUDIT_Oracle_revertsOnZeroOrNegativePrice() public {
        (OracleHook h, MockPriceFeed feed) = _newOracle();
        feed.setAnswer(0, block.timestamp);
        vm.expectRevert(OracleHook.InvalidPrice.selector);
        h.readBand();

        feed.setAnswer(-1, block.timestamp);
        vm.expectRevert(OracleHook.InvalidPrice.selector);
        h.readBand();
    }

    function test_AUDIT_Oracle_allThreeBandsReachable() public {
        (OracleHook h, MockPriceFeed feed) = _newOracle();
        // Bear
        feed.setAnswer(1_500_00000000, block.timestamp);
        (OracleHook.Band b,) = h.readBand();
        assertEq(uint256(b), uint256(OracleHook.Band.Bear));
        // Neutral
        feed.setAnswer(2_500_00000000, block.timestamp);
        (b,) = h.readBand();
        assertEq(uint256(b), uint256(OracleHook.Band.Neutral));
        // Bull (boundary: >= bullThreshold)
        feed.setAnswer(3_500_00000000, block.timestamp);
        (b,) = h.readBand();
        assertEq(uint256(b), uint256(OracleHook.Band.Bull));
    }

    function test_AUDIT_Oracle_thresholdBoundaryExactness() public {
        (OracleHook h, MockPriceFeed feed) = _newOracle();
        // bearThreshold = 2_000 ; price < 2_000 → Bear, price == 2_000 → Neutral
        feed.setAnswer(2_000_00000000 - 1, block.timestamp);
        (OracleHook.Band b,) = h.readBand();
        assertEq(uint256(b), uint256(OracleHook.Band.Bear));

        feed.setAnswer(2_000_00000000, block.timestamp);
        (b,) = h.readBand();
        assertEq(uint256(b), uint256(OracleHook.Band.Neutral));
    }

    function testFuzz_AUDIT_Oracle_priceAlwaysMapsToValidBand(int256 p) public {
        // Constrain to non-stale, positive prices; assert always-valid band.
        p = int256(bound(p, 1, type(int128).max));
        (OracleHook h, MockPriceFeed feed) = _newOracle();
        feed.setAnswer(p, block.timestamp);
        (OracleHook.Band b,) = h.readBand();
        assertLt(uint256(b), 3);
    }

    function test_AUDIT_Oracle_unsupportedTriggerIsNoop() public {
        (OracleHook h, MockPriceFeed feed) = _newOracle();
        feed.setAnswer(2_500_00000000, block.timestamp);
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_TIME, "");
        assertFalse(r.svgChanged);
    }

    function test_AUDIT_Oracle_correctTriggerEmitsBucketed() public {
        (OracleHook h, MockPriceFeed feed) = _newOracle();
        feed.setAnswer(4_000_00000000, block.timestamp);

        vm.recordLogs();
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(42, TRIG_ORACLE, "");
        assertTrue(r.svgChanged);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawBucketed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("Bucketed(uint256,int256,uint8)")) {
                sawBucketed = true;
                break;
            }
        }
        assertTrue(sawBucketed, "Bucketed event must fire on oracle trigger");
    }
}
