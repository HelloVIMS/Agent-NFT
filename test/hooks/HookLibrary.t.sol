// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {EvolutionTypes}      from "../../src/hooks/EvolutionTypes.sol";
import {SoulboundHook}       from "../../src/hooks/SoulboundHook.sol";
import {GenerationHook}      from "../../src/hooks/GenerationHook.sol";
import {SeasonalHook}        from "../../src/hooks/SeasonalHook.sol";
import {HueRotateHook}       from "../../src/hooks/HueRotateHook.sol";
import {TipJarHook, ITipBeneficiary} from "../../src/hooks/TipJarHook.sol";
import {ReputationLevelHook, IERC8004Reputation} from "../../src/hooks/ReputationLevelHook.sol";
import {VoteGatedHook}       from "../../src/hooks/VoteGatedHook.sol";

/// @dev Mock TBA-style sink that tracks ETH received per-agent and refuses on a flag.
contract MockBeneficiary is ITipBeneficiary {
    mapping(uint256 => address payable) public sinks;
    function setSink(uint256 agentId, address payable s) external { sinks[agentId] = s; }
    function tipBeneficiary(uint256 agentId) external view returns (address) {
        return sinks[agentId];
    }
}

/// @dev Mock ERC-8004 Reputation Registry. Stores a single int128 summary
///      per (agentId, clientAddress, tag1, tag2) tuple and serves it via
///      `getSummary` aggregating across the requested clients.
contract MockERC8004Reputation is IERC8004Reputation {
    struct K { uint256 a; address c; bytes32 t1; bytes32 t2; }
    mapping(bytes32 => int128) public score;
    mapping(bytes32 => bool)   public has;
    uint8 public immutable dec;

    constructor(uint8 _dec) { dec = _dec; }

    function _k(uint256 a, address c, string memory t1, string memory t2) internal pure returns (bytes32) {
        return keccak256(abi.encode(a, c, keccak256(bytes(t1)), keccak256(bytes(t2))));
    }
    function setScore(uint256 a, address c, string memory t1, string memory t2, int128 v) external {
        bytes32 k = _k(a, c, t1, t2);
        score[k] = v;
        has[k]   = true;
    }
    function getSummary(uint256 a, address[] calldata clients, string calldata t1, string calldata t2)
        external view returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals)
    {
        int256 acc;
        uint64 hits;
        for (uint256 i; i < clients.length; ++i) {
            bytes32 k = _k(a, clients[i], t1, t2);
            if (has[k]) { acc += int256(score[k]); unchecked { hits++; } }
        }
        if (hits == 0) return (0, 0, dec);
        return (hits, int128(acc / int256(uint256(hits))), dec);
    }
}

/// @dev Reverting receiver for tip-jar transfer-failed test.
contract RevertingReceiver {
    receive() external payable { revert("nope"); }
}

contract HookLibraryTest is Test {
    bytes32 internal constant TRIG_TIME    = keccak256("time.tick");
    bytes32 internal constant TRIG_TRANSFER= keccak256("transfer");
    bytes32 internal constant TRIG_REP     = keccak256("reputation.update");
    bytes32 internal constant TRIG_CUSTOM  = keccak256("custom");

    // ─────────────────────────────────────────────────────────────────────
    // SoulboundHook
    // ─────────────────────────────────────────────────────────────────────

    function test_Soulbound_blocksOwnerToOwner() public {
        SoulboundHook h = new SoulboundHook(0); // forever
        vm.expectRevert(abi.encodeWithSelector(SoulboundHook.TransferLocked.selector, uint256(0)));
        h.beforeTransfer(1, address(0xA), address(0xB));
    }

    function test_Soulbound_allowsMintAndBurn() public {
        SoulboundHook h = new SoulboundHook(0);
        // Mint
        bytes4 sel = h.beforeTransfer(1, address(0), address(0xA));
        assertEq(sel, h.beforeTransfer.selector);
        // Burn
        sel = h.beforeTransfer(1, address(0xA), address(0));
        assertEq(sel, h.beforeTransfer.selector);
    }

    function test_Soulbound_unlocksAtTimestamp() public {
        uint256 unlockAt = block.timestamp + 7 days;
        SoulboundHook h = new SoulboundHook(unlockAt);

        vm.expectRevert(abi.encodeWithSelector(SoulboundHook.TransferLocked.selector, unlockAt));
        h.beforeTransfer(1, address(0xA), address(0xB));

        vm.warp(unlockAt);
        bytes4 sel = h.beforeTransfer(1, address(0xA), address(0xB));
        assertEq(sel, h.beforeTransfer.selector);
    }

    function testFuzz_Soulbound_anyOwnerToOwnerReverts(address from, address to) public {
        vm.assume(from != address(0) && to != address(0));
        SoulboundHook h = new SoulboundHook(0);
        vm.expectRevert();
        h.beforeTransfer(1, from, to);
    }

    // ─────────────────────────────────────────────────────────────────────
    // GenerationHook
    // ─────────────────────────────────────────────────────────────────────

    function test_Generation_incrementsOnOwnerToOwner() public {
        GenerationHook h = new GenerationHook();
        h.afterTransfer(1, address(0xA), address(0xB));
        h.afterTransfer(1, address(0xB), address(0xC));
        assertEq(h.generation(1), 2);
    }

    function test_Generation_doesNotIncrementOnMintOrBurn() public {
        GenerationHook h = new GenerationHook();
        h.afterTransfer(1, address(0),  address(0xA)); // mint
        h.afterTransfer(1, address(0xA), address(0));  // burn
        assertEq(h.generation(1), 0);
    }

    function test_Generation_perAgentIsolation() public {
        GenerationHook h = new GenerationHook();
        h.afterTransfer(1, address(0xA), address(0xB));
        h.afterTransfer(2, address(0xC), address(0xD));
        h.afterTransfer(2, address(0xD), address(0xE));
        assertEq(h.generation(1), 1);
        assertEq(h.generation(2), 2);
    }

    function test_Generation_triggerRendersWithCount() public {
        GenerationHook h = new GenerationHook();
        h.afterTransfer(7, address(0xA), address(0xB));
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(7, TRIG_TRANSFER, "");
        assertTrue(r.svgChanged);
        assertGt(r.newSvgInline.length, 50);
    }

    function test_Generation_unsupportedTriggerNoop() public {
        GenerationHook h = new GenerationHook();
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_CUSTOM, "");
        assertFalse(r.svgChanged);
    }

    // ─────────────────────────────────────────────────────────────────────
    // SeasonalHook
    // ─────────────────────────────────────────────────────────────────────

    function test_Seasonal_correctMonthMapping() public {
        SeasonalHook h = new SeasonalHook();

        // 2024-01-15 (Winter)
        vm.warp(1705320000);
        (SeasonalHook.Season s, uint16 y, uint8 m) = h.currentSeason();
        assertEq(uint256(s), uint256(SeasonalHook.Season.Winter));
        assertEq(y, 2024); assertEq(m, 1);

        // 2024-04-15 (Spring)
        vm.warp(1713170000);
        (s, y, m) = h.currentSeason();
        assertEq(uint256(s), uint256(SeasonalHook.Season.Spring));
        assertEq(m, 4);

        // 2024-07-15 (Summer)
        vm.warp(1721044000);
        (s, y, m) = h.currentSeason();
        assertEq(uint256(s), uint256(SeasonalHook.Season.Summer));
        assertEq(m, 7);

        // 2024-10-15 (Autumn)
        vm.warp(1728994000);
        (s, y, m) = h.currentSeason();
        assertEq(uint256(s), uint256(SeasonalHook.Season.Autumn));
        assertEq(m, 10);
    }

    function testFuzz_Seasonal_alwaysValidEnum(uint32 ts) public {
        SeasonalHook h = new SeasonalHook();
        vm.warp(uint256(ts) + 86400); // avoid ts=0 epoch edge
        (SeasonalHook.Season s,,) = h.currentSeason();
        assertLt(uint256(s), 4);
    }

    function test_Seasonal_emitsSeasonChangedOnTimeTick() public {
        SeasonalHook h = new SeasonalHook();
        vm.warp(1721044000); // summer
        vm.recordLogs();
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_TIME, "");
        assertTrue(r.svgChanged);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(logs.length, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // HueRotateHook
    // ─────────────────────────────────────────────────────────────────────

    function test_HueRotate_zeroStepReverts() public {
        vm.expectRevert(HueRotateHook.InvalidStep.selector);
        new HueRotateHook(0);
    }

    function test_HueRotate_hueAdvancesEachStep() public {
        HueRotateHook h = new HueRotateHook(60); // 1 deg per minute
        vm.warp(0);
        assertEq(h.currentHue(), 0);
        vm.warp(60);
        assertEq(h.currentHue(), 1);
        vm.warp(60 * 359);
        assertEq(h.currentHue(), 359);
        vm.warp(60 * 360);
        assertEq(h.currentHue(), 0); // wraps
    }

    function testFuzz_HueRotate_alwaysWithin360(uint64 ts, uint16 step) public {
        step = uint16(bound(step, 1, 86400));
        HueRotateHook h = new HueRotateHook(step);
        vm.warp(uint256(ts));
        assertLt(h.currentHue(), 360);
    }

    function test_HueRotate_renderOnTimeTick() public {
        HueRotateHook h = new HueRotateHook(60);
        vm.warp(1000);
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_TIME, "");
        assertTrue(r.svgChanged);
        assertGt(r.newSvgInline.length, 80);
    }

    // ─────────────────────────────────────────────────────────────────────
    // TipJarHook
    // ─────────────────────────────────────────────────────────────────────

    function test_TipJar_zeroResolverReverts() public {
        vm.expectRevert(TipJarHook.ZeroBeneficiary.selector);
        new TipJarHook(address(0));
    }

    function test_TipJar_zeroAmountReverts() public {
        MockBeneficiary mb = new MockBeneficiary();
        TipJarHook h = new TipJarHook(address(mb));
        vm.expectRevert(TipJarHook.ZeroAmount.selector);
        h.tip(1);
    }

    function test_TipJar_unsetBeneficiaryReverts() public {
        MockBeneficiary mb = new MockBeneficiary();
        TipJarHook h = new TipJarHook(address(mb));
        vm.deal(address(this), 1 ether);
        vm.expectRevert(TipJarHook.ZeroBeneficiary.selector);
        h.tip{value: 1 ether}(1);
    }

    function test_TipJar_forwardsToBeneficiary() public {
        MockBeneficiary mb = new MockBeneficiary();
        TipJarHook h = new TipJarHook(address(mb));
        address payable sink = payable(address(uint160(uint256(keccak256("sink")))));
        mb.setSink(1, sink);

        vm.deal(address(this), 5 ether);
        h.tip{value: 1 ether}(1);
        h.tip{value: 0.5 ether}(1);

        assertEq(sink.balance, 1.5 ether);
        assertEq(h.tipped(1), 1.5 ether);
        assertEq(h.lastTip(1), 0.5 ether);
        assertEq(h.tipCount(1), 2);
        assertEq(address(h).balance, 0); // hook holds nothing
    }

    function test_TipJar_revertingBeneficiaryRevertsOuter() public {
        MockBeneficiary mb = new MockBeneficiary();
        TipJarHook h = new TipJarHook(address(mb));
        RevertingReceiver rr = new RevertingReceiver();
        mb.setSink(1, payable(address(rr)));

        vm.deal(address(this), 1 ether);
        vm.expectRevert(TipJarHook.TransferFailed.selector);
        h.tip{value: 1 ether}(1);
    }

    function test_TipJar_renderOnTipTrigger() public {
        MockBeneficiary mb = new MockBeneficiary();
        TipJarHook h = new TipJarHook(address(mb));
        address payable sink = payable(address(0x1234));
        mb.setSink(1, sink);
        vm.deal(address(this), 5 ether);
        h.tip{value: 2 ether}(1);

        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, h.TRIG_TIP_JAR(), "");
        assertTrue(r.svgChanged);
        assertGt(r.newSvgInline.length, 100);
    }

    // ─────────────────────────────────────────────────────────────────────
    // ReputationLevelHook
    // ─────────────────────────────────────────────────────────────────────

    address internal constant ATTESTOR_A = address(0xAA1);
    address internal constant ATTESTOR_B = address(0xAA2);

    function _newRepHook() internal returns (ReputationLevelHook h, MockERC8004Reputation o) {
        o = new MockERC8004Reputation(0);
        int128[] memory th = new int128[](4);
        th[0] = 25; th[1] = 50; th[2] = 75; th[3] = 90;
        address[] memory att = new address[](2);
        att[0] = ATTESTOR_A; att[1] = ATTESTOR_B;
        h = new ReputationLevelHook(address(o), att, th, "", "");
    }

    function test_ReputationLevel_zeroOracleReverts() public {
        int128[] memory th = new int128[](1); th[0] = 1;
        address[] memory att = new address[](1); att[0] = ATTESTOR_A;
        vm.expectRevert(ReputationLevelHook.ZeroOracle.selector);
        new ReputationLevelHook(address(0), att, th, "", "");
    }

    function test_ReputationLevel_nonIncreasingThresholdsRevert() public {
        MockERC8004Reputation o = new MockERC8004Reputation(0);
        int128[] memory th = new int128[](3); th[0] = 100; th[1] = 100; th[2] = 200;
        address[] memory att = new address[](1); att[0] = ATTESTOR_A;
        vm.expectRevert(ReputationLevelHook.ThresholdsNotIncreasing.selector);
        new ReputationLevelHook(address(o), att, th, "", "");
    }

    function test_ReputationLevel_zeroFeedbackIsTierZero() public {
        (ReputationLevelHook h,) = _newRepHook();
        (uint8 tier, int128 v, uint64 c) = h.tierOf(1);
        assertEq(tier, 0); assertEq(v, int128(0)); assertEq(c, 0);
    }

    function test_ReputationLevel_tierMapping() public {
        (ReputationLevelHook h, MockERC8004Reputation o) = _newRepHook();
        // Single attestor, score 30 → tier 1 (>=25, <50)
        o.setScore(1, ATTESTOR_A, "", "", 30);
        (uint8 t,,) = h.tierOf(1); assertEq(t, 1);
        // Two attestors, average 75 → tier 3
        o.setScore(1, ATTESTOR_B, "", "", 120); // avg = (30+120)/2 = 75
        (t,,) = h.tierOf(1); assertEq(t, 3);
        // Drop A's contribution by overwriting with -50, avg = (-50+120)/2 = 35 → tier 1
        o.setScore(1, ATTESTOR_A, "", "", -50);
        (t,,) = h.tierOf(1); assertEq(t, 1);
    }

    function test_ReputationLevel_unknownAttestorIgnored() public {
        (ReputationLevelHook h, MockERC8004Reputation o) = _newRepHook();
        // Score from a non-trusted address — must not affect tier.
        o.setScore(1, address(0xBADBADBA), "", "", 99);
        (uint8 t,, uint64 c) = h.tierOf(1);
        assertEq(t, 0); assertEq(c, 0);
    }

    function testFuzz_ReputationLevel_tierMonotoneInValue(int64 lo, int64 hi) public {
        if (lo > hi) (lo, hi) = (hi, lo);
        (ReputationLevelHook h, MockERC8004Reputation o) = _newRepHook();
        o.setScore(1, ATTESTOR_A, "", "", int128(lo));
        (uint8 ta,,) = h.tierOf(1);
        o.setScore(1, ATTESTOR_A, "", "", int128(hi));
        (uint8 tb,,) = h.tierOf(1);
        assertGe(tb, ta);
    }

    function test_ReputationLevel_emitsTierObserved() public {
        (ReputationLevelHook h, MockERC8004Reputation o) = _newRepHook();
        o.setScore(1, ATTESTOR_A, "", "", 80);
        vm.recordLogs();
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_REP, "");
        assertTrue(r.svgChanged);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(logs.length, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // VoteGatedHook
    // ─────────────────────────────────────────────────────────────────────

    function test_VoteGated_zeroGovernorReverts() public {
        vm.expectRevert(VoteGatedHook.ZeroGovernor.selector);
        new VoteGatedHook(address(0), 5);
    }

    function test_VoteGated_onlyGovernorAdvances() public {
        address gov = address(0xC0DE);
        VoteGatedHook h = new VoteGatedHook(gov, 5);

        vm.expectRevert(VoteGatedHook.NotGovernor.selector);
        h.setStage(1, 1);

        vm.prank(gov);
        h.setStage(1, 1);
        assertEq(h.stage(1), 1);
    }

    function test_VoteGated_strictlyIncreasing() public {
        address gov = address(0xC0DE);
        VoteGatedHook h = new VoteGatedHook(gov, 5);

        vm.startPrank(gov);
        h.setStage(1, 2);
        vm.expectRevert(VoteGatedHook.StageNotIncreasing.selector);
        h.setStage(1, 2); // equal
        vm.expectRevert(VoteGatedHook.StageNotIncreasing.selector);
        h.setStage(1, 1); // older
        vm.stopPrank();
    }

    function test_VoteGated_cannotExceedMaxStage() public {
        address gov = address(0xC0DE);
        VoteGatedHook h = new VoteGatedHook(gov, 3);

        vm.prank(gov);
        vm.expectRevert(VoteGatedHook.StageNotIncreasing.selector);
        h.setStage(1, 4);
    }

    function test_VoteGated_renderOnCustomTrigger() public {
        address gov = address(0xC0DE);
        VoteGatedHook h = new VoteGatedHook(gov, 5);
        vm.prank(gov);
        h.setStage(1, 3);
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, h.TRIG_VOTE_GATED(), "");
        assertTrue(r.svgChanged);
        assertGt(r.newSvgInline.length, 50);
    }
}
