// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC721}              from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {EvolutionTypes}      from "../../src/hooks/EvolutionTypes.sol";
import {SoulboundHook}       from "../../src/hooks/SoulboundHook.sol";
import {GenerationHook}      from "../../src/hooks/GenerationHook.sol";
import {TransferRecolorHook} from "../../src/hooks/TransferRecolorHook.sol";
import {SeasonalHook}        from "../../src/hooks/SeasonalHook.sol";
import {HueRotateHook}       from "../../src/hooks/HueRotateHook.sol";
import {TipJarHook}          from "../../src/hooks/TipJarHook.sol";
import {RevenueLevelHook}    from "../../src/hooks/RevenueLevelHook.sol";
import {ReputationLevelHook, IReputationEras} from "../../src/hooks/ReputationLevelHook.sol";
import {VoteGatedHook}       from "../../src/hooks/VoteGatedHook.sol";

/// @dev A minimal agent collection: an ERC-721 anyone can mint into.
contract MockCollection is ERC721 {
    constructor() ERC721("Mock", "M") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

/// @dev AgentX402Receiver's per-NFT stats surface, settable.
contract MockNFTStats {
    address public identityRegistry;
    mapping(address => mapping(uint256 => uint64)) public nftSettlements;
    mapping(address => mapping(uint256 => mapping(address => uint256))) public nftVolume;
    constructor(address identity) { identityRegistry = identity; }
    function set(address nft, uint256 id, uint64 hires, address token, uint256 volume) external {
        nftSettlements[nft][id] = hires;
        nftVolume[nft][id][token] = volume;
    }
}

/// @dev AgentReputationRegistry v2's era surface, settable.
contract MockEras {
    mapping(uint256 => uint256) public currentEra;
    mapping(uint256 => mapping(uint256 => IReputationEras.EraStats)) internal _stats;
    function set(uint256 id, uint256 era, uint64 hires, int128 ratingSum) external {
        currentEra[id] = era;
        _stats[id][era].settlements = hires;
        _stats[id][era].feedbackSum = ratingSum;
    }
    function eraStats(uint256 id, uint256 era) external view returns (IReputationEras.EraStats memory) {
        return _stats[id][era];
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
    bytes32 internal constant TRIG_X402    = keccak256("service.x402");
    bytes32 internal constant TRIG_CUSTOM  = keccak256("custom");

    address internal constant HOST_A = address(0xA0);
    address internal constant HOST_B = address(0xB0);
    address internal constant USDC   = address(0x05DC);

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
    // GenerationHook / TransferRecolorHook — counters per host collection
    // ─────────────────────────────────────────────────────────────────────

    function test_Generation_incrementsOnOwnerToOwner() public {
        GenerationHook h = new GenerationHook();
        vm.startPrank(HOST_A);
        h.afterTransfer(1, address(0xA), address(0xB));
        h.afterTransfer(1, address(0xB), address(0xC));
        vm.stopPrank();
        assertEq(h.generation(HOST_A, 1), 2);
    }

    function test_Generation_doesNotIncrementOnMintOrBurn() public {
        GenerationHook h = new GenerationHook();
        vm.startPrank(HOST_A);
        h.afterTransfer(1, address(0),  address(0xA));
        h.afterTransfer(1, address(0xA), address(0));
        vm.stopPrank();
        assertEq(h.generation(HOST_A, 1), 0);
    }

    /// Anyone can call afterTransfer; it only moves the caller's own counters,
    /// and the same token id in two collections never collides.
    function test_Generation_isolatedPerHost() public {
        GenerationHook h = new GenerationHook();
        vm.prank(HOST_A);
        h.afterTransfer(1, address(0xA), address(0xB));
        for (uint256 i; i < 5; i++) {
            vm.prank(address(0xBAD));
            h.afterTransfer(1, address(0xA), address(0xB));
        }
        assertEq(h.generation(HOST_A, 1), 1);
        assertEq(h.generation(HOST_B, 1), 0);
        assertEq(h.generation(address(0xBAD), 1), 5);
        vm.prank(HOST_A);
        EvolutionTypes.EvolutionResult memory ra = h.onTrigger(1, TRIG_TRANSFER, "");
        vm.prank(HOST_B);
        EvolutionTypes.EvolutionResult memory rb = h.onTrigger(1, TRIG_TRANSFER, "");
        assertTrue(ra.newStateHash != rb.newStateHash);
    }

    function test_Generation_unsupportedTriggerNoop() public {
        GenerationHook h = new GenerationHook();
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_CUSTOM, "");
        assertFalse(r.svgChanged);
    }

    function test_Recolor_countsOwnerMovesPerHost() public {
        TransferRecolorHook h = new TransferRecolorHook();
        vm.startPrank(HOST_A);
        h.afterTransfer(1, address(0), address(0xA));  // mint: not counted
        h.afterTransfer(1, address(0xA), address(0xB));
        h.afterTransfer(1, address(0xB), address(0xC));
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_TRANSFER, "");
        vm.stopPrank();
        assertEq(h.transferCount(HOST_A, 1), 2);
        assertEq(h.transferCount(HOST_B, 1), 0);
        assertTrue(r.svgChanged);
        assertGt(r.newSvgInline.length, 50);
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

    function test_Seasonal_rendersOnTimeTick() public {
        SeasonalHook h = new SeasonalHook();
        vm.warp(1721044000); // summer
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_TIME, "");
        assertTrue(r.svgChanged);
        assertGt(r.newSvgInline.length, 80);
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
    // TipJarHook — tips reach the owner of that exact token
    // ─────────────────────────────────────────────────────────────────────

    function test_TipJar_forwardsToTokenOwner() public {
        TipJarHook h = new TipJarHook();
        MockCollection c = new MockCollection();
        address owner = address(0xA11CE);
        c.mint(owner, 7);
        vm.deal(address(this), 1 ether);
        h.tip{value: 0.2 ether}(address(c), 7);
        h.tip{value: 0.3 ether}(address(c), 7);
        assertEq(owner.balance, 0.5 ether);
        assertEq(address(h).balance, 0);
        (uint256 total, uint256 last, uint32 count) = h.jars(address(c), 7);
        assertEq(total, 0.5 ether);
        assertEq(last, 0.3 ether);
        assertEq(count, 2);
    }

    /// The same token id in another collection belongs to someone else.
    function test_TipJar_collectionsDontCollide() public {
        TipJarHook h = new TipJarHook();
        MockCollection a = new MockCollection();
        MockCollection b = new MockCollection();
        a.mint(address(0xA11CE), 1);
        b.mint(address(0xB0B), 1);
        vm.deal(address(this), 1 ether);
        h.tip{value: 0.1 ether}(address(b), 1);
        assertEq(address(0xA11CE).balance, 0);
        assertEq(address(0xB0B).balance, 0.1 ether);
        (uint256 totalA,,) = h.jars(address(a), 1);
        assertEq(totalA, 0);
    }

    function test_TipJar_followsOwnershipAfterSale() public {
        TipJarHook h = new TipJarHook();
        MockCollection c = new MockCollection();
        c.mint(address(0xA11CE), 1);
        vm.prank(address(0xA11CE));
        c.transferFrom(address(0xA11CE), address(0xB0B), 1);
        vm.deal(address(this), 1 ether);
        h.tip{value: 0.1 ether}(address(c), 1);
        assertEq(address(0xB0B).balance, 0.1 ether);
        assertEq(address(0xA11CE).balance, 0);
    }

    function test_TipJar_refusesUnknownTokensZeroAmountsAndEOAHosts() public {
        TipJarHook h = new TipJarHook();
        MockCollection c = new MockCollection();
        vm.deal(address(this), 1 ether);
        vm.expectRevert(TipJarHook.NoSuchToken.selector);
        h.tip{value: 1}(address(c), 99);
        vm.expectRevert(TipJarHook.NoSuchToken.selector);
        h.tip{value: 1}(address(0xEEEE), 1);
        c.mint(address(0xA11CE), 1);
        vm.expectRevert(TipJarHook.ZeroAmount.selector);
        h.tip(address(c), 1);
    }

    function test_TipJar_revertsWhenOwnerRefusesETH() public {
        TipJarHook h = new TipJarHook();
        MockCollection c = new MockCollection();
        RevertingReceiver rr = new RevertingReceiver();
        c.mint(address(rr), 1);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(TipJarHook.TransferFailed.selector);
        h.tip{value: 1}(address(c), 1);
        (uint256 total,,) = h.jars(address(c), 1);
        assertEq(total, 0, "reverted tip leaves no trace");
    }

    function test_TipJar_rendersTotalsForTheCallingHost() public {
        TipJarHook h = new TipJarHook();
        MockCollection c = new MockCollection();
        c.mint(address(0xA11CE), 1);
        vm.deal(address(this), 1 ether);
        h.tip{value: 0.25 ether}(address(c), 1);
        bytes32 trig = h.TRIG_TIP_JAR();
        vm.prank(address(c));
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, trig, "");
        assertTrue(r.svgChanged);
        assertGt(r.newSvgInline.length, 100);
        vm.prank(HOST_B);
        EvolutionTypes.EvolutionResult memory other = h.onTrigger(1, trig, "");
        assertTrue(r.newStateHash != other.newStateHash);
    }

    // ─────────────────────────────────────────────────────────────────────
    // RevenueLevelHook — levels from what buyers paid (payment contract)
    // ─────────────────────────────────────────────────────────────────────

    function _revenueHook(MockNFTStats st) internal returns (RevenueLevelHook) {
        uint256[] memory th = new uint256[](3);
        th[0] = 1e6; th[1] = 10e6; th[2] = 100e6;
        return new RevenueLevelHook(address(st), USDC, th);
    }

    function test_RevenueLevel_levelsFromPaidVolume() public {
        MockNFTStats st = new MockNFTStats(address(0));
        RevenueLevelHook h = _revenueHook(st);
        (uint8 lvl,) = h.levelOf(HOST_A, 1);
        assertEq(lvl, 0);
        st.set(HOST_A, 1, 3, USDC, 10e6);
        (lvl,) = h.levelOf(HOST_A, 1);
        assertEq(lvl, 2);
        st.set(HOST_A, 1, 9, USDC, 500e6);
        (lvl,) = h.levelOf(HOST_A, 1);
        assertEq(lvl, 3, "capped at the last threshold");
        (lvl,) = h.levelOf(HOST_B, 1);
        assertEq(lvl, 0, "other collection");
        // Volume in another token doesn't count.
        st.set(HOST_B, 1, 1, address(0xDA1), 1000e6);
        (lvl,) = h.levelOf(HOST_B, 1);
        assertEq(lvl, 0);
    }

    function test_RevenueLevel_rendersForCallingHostOnX402Trigger() public {
        MockNFTStats st = new MockNFTStats(address(0));
        RevenueLevelHook h = _revenueHook(st);
        st.set(HOST_A, 1, 1, USDC, 2e6);
        vm.prank(HOST_A);
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_X402, "");
        assertTrue(r.svgChanged);
        assertFalse(h.onTrigger(1, TRIG_CUSTOM, "").svgChanged);
    }

    function test_RevenueLevel_constructorValidation() public {
        uint256[] memory bad = new uint256[](2);
        bad[0] = 10; bad[1] = 10;
        vm.expectRevert(RevenueLevelHook.ThresholdsNotIncreasing.selector);
        new RevenueLevelHook(address(1), USDC, bad);
        uint256[] memory ok = new uint256[](1);
        vm.expectRevert(RevenueLevelHook.ZeroAddress.selector);
        new RevenueLevelHook(address(0), USDC, ok);
        vm.expectRevert(RevenueLevelHook.ZeroAddress.selector);
        new RevenueLevelHook(address(1), address(0), ok);
    }

    // ─────────────────────────────────────────────────────────────────────
    // ReputationLevelHook — tiers from paid hires; identity agents per owner era
    // ─────────────────────────────────────────────────────────────────────

    address internal constant IDENTITY = address(0x1D);

    function _repHook(MockNFTStats st, MockEras eras) internal returns (ReputationLevelHook) {
        uint256[] memory th = new uint256[](3);
        th[0] = 1; th[1] = 5; th[2] = 25;
        return new ReputationLevelHook(address(st), address(eras), th);
    }

    function test_ReputationLevel_collectionAgentsTierByPaidHires() public {
        MockNFTStats st = new MockNFTStats(IDENTITY);
        ReputationLevelHook h = _repHook(st, new MockEras());
        st.set(HOST_A, 1, 5, USDC, 0);
        (uint8 tier, uint64 hires,) = h.tierOf(HOST_A, 1);
        assertEq(tier, 2);
        assertEq(hires, 5);
        (tier,,) = h.tierOf(HOST_B, 1);
        assertEq(tier, 0);
    }

    function test_ReputationLevel_identityAgentsUseCurrentOwnerEra() public {
        MockNFTStats st = new MockNFTStats(IDENTITY);
        MockEras eras = new MockEras();
        ReputationLevelHook h = _repHook(st, eras);
        // The payment contract's lifetime count is ignored for identity agents…
        st.set(IDENTITY, 9, 100, USDC, 0);
        // …the current owner's era is what counts: a new owner starts at 0.
        eras.set(9, 0, 30, 5);
        (uint8 tier,,) = h.tierOf(IDENTITY, 9);
        assertEq(tier, 3);
        eras.set(9, 1, 0, 0);
        (tier,,) = h.tierOf(IDENTITY, 9);
        assertEq(tier, 0, "sold: new era");
        eras.set(9, 1, 6, 0);
        (tier,,) = h.tierOf(IDENTITY, 9);
        assertEq(tier, 2);
    }

    function test_ReputationLevel_netNegativeRatingsDropToZero() public {
        MockNFTStats st = new MockNFTStats(IDENTITY);
        MockEras eras = new MockEras();
        ReputationLevelHook h = _repHook(st, eras);
        eras.set(9, 0, 30, -1);
        (uint8 tier, uint64 hires, int128 sum) = h.tierOf(IDENTITY, 9);
        assertEq(tier, 0);
        assertEq(hires, 30);
        assertEq(sum, -1);
    }

    function test_ReputationLevel_rendersOnReputationTrigger() public {
        MockNFTStats st = new MockNFTStats(IDENTITY);
        ReputationLevelHook h = _repHook(st, new MockEras());
        st.set(HOST_A, 1, 1, USDC, 0);
        vm.prank(HOST_A);
        EvolutionTypes.EvolutionResult memory r = h.onTrigger(1, TRIG_REP, "");
        assertTrue(r.svgChanged);
        assertFalse(h.onTrigger(1, TRIG_CUSTOM, "").svgChanged);
    }

    function test_ReputationLevel_constructorValidation() public {
        MockNFTStats st = new MockNFTStats(IDENTITY);
        uint256[] memory bad = new uint256[](2);
        bad[0] = 5; bad[1] = 1;
        vm.expectRevert(ReputationLevelHook.ThresholdsNotIncreasing.selector);
        new ReputationLevelHook(address(st), address(1), bad);
        uint256[] memory ok = new uint256[](1);
        vm.expectRevert(ReputationLevelHook.ZeroAddress.selector);
        new ReputationLevelHook(address(st), address(0), ok);
        ReputationLevelHook h = new ReputationLevelHook(address(st), address(1), ok);
        assertEq(h.identityRegistry(), IDENTITY);
    }

    // ─────────────────────────────────────────────────────────────────────
    // VoteGatedHook — governor names the collection
    // ─────────────────────────────────────────────────────────────────────

    function test_VoteGated_onlyGovernorAdvancesPerHost() public {
        address gov = address(0x60);
        VoteGatedHook h = new VoteGatedHook(gov, 4);
        vm.expectRevert(VoteGatedHook.NotGovernor.selector);
        h.setStage(HOST_A, 1, 1);
        vm.startPrank(gov);
        h.setStage(HOST_A, 1, 2);
        vm.expectRevert(VoteGatedHook.StageNotIncreasing.selector);
        h.setStage(HOST_A, 1, 2);
        vm.expectRevert(VoteGatedHook.StageNotIncreasing.selector);
        h.setStage(HOST_A, 1, 5);
        vm.stopPrank();
        assertEq(h.stage(HOST_A, 1), 2);
        assertEq(h.stage(HOST_B, 1), 0);
        bytes32 trig = h.TRIG_VOTE_GATED();
        vm.prank(HOST_A);
        EvolutionTypes.EvolutionResult memory a = h.onTrigger(1, trig, "");
        vm.prank(HOST_B);
        EvolutionTypes.EvolutionResult memory b = h.onTrigger(1, trig, "");
        assertTrue(a.svgChanged && b.svgChanged);
        assertTrue(a.newStateHash != b.newStateHash);
    }

    function test_VoteGated_zeroGovernorReverts() public {
        vm.expectRevert(VoteGatedHook.ZeroGovernor.selector);
        new VoteGatedHook(address(0), 4);
    }
}
