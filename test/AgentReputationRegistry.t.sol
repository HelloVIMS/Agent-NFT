// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentReputationRegistry.sol";

/// Reputation v2: (agent, owner) eras, paid-only attestations, on-chain
/// system reputation. `recorder` stands in for AgentX402Receiver; the
/// receiver → registry path is covered in BuyerSellerAgentEconomy.t.sol.
contract AgentReputationRegistryTest is Test {
    AgentIdentityRegistry public identityRegistry;
    AgentReputationRegistry public reputationRegistry;

    address public owner = address(0x1);
    address public agentOwner = address(0x2);
    address public client1 = address(0x3);
    address public client2 = address(0x4);
    address public newOwner = address(0x5);
    address public recorder = address(0x6);
    address public escrow = address(0x7);
    bytes32 constant SVC = keccak256("code-review");

    uint256 public agentId;

    event FeedbackGiven(uint256 indexed agentId, address indexed client, bytes32 indexed subject, int128 value, string tag1, string feedbackURI);
    event EraStarted(uint256 indexed agentId, uint256 indexed era, address indexed owner, bytes32 subject);
    event SettlementRecorded(uint256 indexed agentId, uint256 indexed era, address indexed client, bytes32 serviceId, uint256 amount, bool counted);

    function setUp() public {
        vm.startPrank(owner);
        AgentIdentityRegistry identityImpl = new AgentIdentityRegistry();
        identityRegistry = AgentIdentityRegistry(address(new ERC1967Proxy(address(identityImpl), abi.encodeCall(AgentIdentityRegistry.initialize, ()))));
        AgentReputationRegistry reputationImpl = new AgentReputationRegistry();
        reputationRegistry = AgentReputationRegistry(address(new ERC1967Proxy(
            address(reputationImpl), abi.encodeCall(AgentReputationRegistry.initialize, (address(identityRegistry)))
        )));
        reputationRegistry.setSettlementRecorder(recorder, true);
        reputationRegistry.setDisputeRecorder(escrow, true);
        vm.stopPrank();

        vm.prank(agentOwner);
        agentId = identityRegistry.registerAgent("TestBot", "uri", 1000, address(0));
    }

    function _pay(address client, uint256 amount) internal {
        vm.prank(recorder);
        reputationRegistry.recordSettlement(agentId, client, SVC, amount);
    }

    function _transfer(address to) internal {
        address from = identityRegistry.ownerOf(agentId);
        vm.prank(from);
        identityRegistry.transferFrom(from, to, agentId);
    }

    // ── paid-only attestations ───────────────────────────────────────

    function test_OnlyPayingClientsCanAttest() public {
        vm.prank(client1);
        vm.expectRevert(AgentReputationRegistry.NotAPayingClient.selector);
        reputationRegistry.giveFeedback(agentId, 1, 0, "x402", "code-review", "");

        _pay(client1, 250_000);
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 1, 0, "x402", "code-review", "eip155:84532:0xabc");
        (uint256 n, int256 avg, uint256 ts) = reputationRegistry.getReputationSummary(agentId);
        assertEq(n, 1);
        assertEq(avg, 1);
        assertEq(ts, block.timestamp);
    }

    function test_ScoreIsTriState() public {
        _pay(client1, 1);
        vm.startPrank(client1);
        vm.expectRevert(AgentReputationRegistry.ScoreOutOfRange.selector);
        reputationRegistry.giveFeedback(agentId, 2, 0, "", "", "");
        vm.expectRevert(AgentReputationRegistry.ScoreOutOfRange.selector);
        reputationRegistry.giveFeedback(agentId, -2, 0, "", "", "");
        vm.expectRevert(AgentReputationRegistry.ScoreOutOfRange.selector);
        reputationRegistry.giveFeedback(agentId, 1, 2, "", "", "");
        reputationRegistry.giveFeedback(agentId, -1, 0, "", "", "");
        vm.stopPrank();
    }

    function test_OneActiveAttestationPerClient_RevokeAndResubmit() public {
        _pay(client1, 1);
        vm.startPrank(client1);
        reputationRegistry.giveFeedback(agentId, -1, 0, "x402", "", "");
        vm.expectRevert("Already gave feedback");
        reputationRegistry.giveFeedback(agentId, 1, 0, "x402", "", "");
        reputationRegistry.revokeFeedback(agentId);
        reputationRegistry.giveFeedback(agentId, 1, 0, "x402", "", "");
        vm.stopPrank();
        (uint256 n, int256 avg,) = reputationRegistry.getReputationSummary(agentId);
        assertEq(n, 1);
        assertEq(avg, 1);
        assertEq(reputationRegistry.getFeedbackCount(agentId), 2); // revoked entry stays as history
        (int256 tagAvg, uint256 tagN) = reputationRegistry.getTagScore(agentId, "x402");
        assertEq(tagN, 1);
        assertEq(tagAvg, 1);
    }

    function test_OwnerCannotAttest_EvenAfterPayingSelf() public {
        _pay(agentOwner, 1_000_000);
        AgentReputationRegistry.EraStats memory st = reputationRegistry.eraStats(agentId, 0);
        assertEq(st.settlements, 0, "self-payment is not a sale");
        assertEq(st.volume, 0);
        vm.prank(agentOwner);
        vm.expectRevert("Cannot review own agent");
        reputationRegistry.giveFeedback(agentId, 1, 0, "", "", "");
    }

    function test_SummaryAverages() public {
        _pay(client1, 1);
        _pay(client2, 1);
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 1, 0, "", "", "");
        vm.prank(client2);
        reputationRegistry.giveFeedback(agentId, -1, 0, "", "", "");
        (uint256 n, int256 avg,) = reputationRegistry.getReputationSummary(agentId);
        assertEq(n, 2);
        assertEq(avg, 0);
        AgentReputationRegistry.EraStats memory st = reputationRegistry.eraStats(agentId, 0);
        assertEq(st.feedbackSum, 0);
        assertEq(st.feedbackCount, 2);
    }

    // ── system reputation ────────────────────────────────────────────

    function test_SettlementsAndVolume() public {
        vm.expectEmit(true, true, true, true);
        emit SettlementRecorded(agentId, 0, client1, SVC, 250_000, true);
        _pay(client1, 250_000);
        _pay(client1, 100_000);
        _pay(client2, 50_000);
        AgentReputationRegistry.EraStats memory st = reputationRegistry.eraStats(agentId, 0);
        assertEq(st.settlements, 3);
        assertEq(st.volume, 400_000);
        assertEq(st.lastSettlementAt, block.timestamp);
        bytes32 subject = reputationRegistry.reputationSubjectOf(agentId);
        assertEq(reputationRegistry.paidSettlements(subject, client1), 2);
    }

    function test_OnlyRecordersRecord() public {
        vm.prank(client1);
        vm.expectRevert(AgentReputationRegistry.NotSettlementRecorder.selector);
        reputationRegistry.recordSettlement(agentId, client1, SVC, 1);

        vm.prank(recorder);
        vm.expectRevert(AgentReputationRegistry.NotDisputeRecorder.selector);
        reputationRegistry.recordDispute(agentId, client1, bytes32("case-1"));

        vm.prank(escrow);
        reputationRegistry.recordDispute(agentId, client1, bytes32("case-1"));
        assertEq(reputationRegistry.eraStats(agentId, 0).disputes, 1);

        vm.prank(client1);
        vm.expectRevert();
        reputationRegistry.setSettlementRecorder(client1, true);

        vm.prank(owner);
        reputationRegistry.setSettlementRecorder(recorder, false);
        vm.prank(recorder);
        vm.expectRevert(AgentReputationRegistry.NotSettlementRecorder.selector);
        reputationRegistry.recordSettlement(agentId, client1, SVC, 1);
    }

    function test_SettlementForMissingAgentReverts() public {
        vm.prank(recorder);
        vm.expectRevert();
        reputationRegistry.recordSettlement(999, client1, SVC, 1);
    }

    // ── eras: a transfer starts a new history ────────────────────────

    function test_TransferStartsNewEra_OldEraIsAnArtifact() public {
        _pay(client1, 300_000);
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, 1, 0, "x402", "", "ipfs://era0");
        assertEq(reputationRegistry.eraCount(agentId), 1);

        vm.warp(block.timestamp + 1 days);
        _transfer(newOwner);

        // Immediately after the transfer the new owner's era is current and empty.
        assertEq(reputationRegistry.currentEra(agentId), 1);
        assertEq(reputationRegistry.eraCount(agentId), 2);
        (uint256 n,,) = reputationRegistry.getReputationSummary(agentId);
        assertEq(n, 0, "reputation does not follow the NFT");
        assertEq(reputationRegistry.getFeedbackCount(agentId), 0);
        (address o1,,, bool cur1) = reputationRegistry.eraInfo(agentId, 1);
        assertEq(o1, newOwner);
        assertTrue(cur1);

        // Era 0 stays readable, closed.
        (address o0, uint64 start0,, bool cur0) = reputationRegistry.eraInfo(agentId, 0);
        assertEq(o0, agentOwner);
        assertGt(start0, 0);
        assertFalse(cur0);
        assertEq(reputationRegistry.eraStats(agentId, 0).settlements, 1);
        assertEq(reputationRegistry.eraFeedbackCount(agentId, 0), 1);
        (address c,,,,, string memory uri,,) = reputationRegistry.eraFeedbackAt(agentId, 0, 0);
        assertEq(c, client1);
        assertEq(uri, "ipfs://era0");

        // Paying the previous owner's era doesn't entitle attesting in this one.
        vm.prank(client1);
        vm.expectRevert(AgentReputationRegistry.NotAPayingClient.selector);
        reputationRegistry.giveFeedback(agentId, 1, 0, "", "", "");

        // The first write materialises era 1 and closes era 0.
        vm.expectEmit(true, true, true, false);
        emit EraStarted(agentId, 1, newOwner, bytes32(0));
        _pay(client2, 10);
        (,, uint64 end0,) = reputationRegistry.eraInfo(agentId, 0);
        assertEq(end0, block.timestamp);
        vm.prank(client2);
        reputationRegistry.giveFeedback(agentId, -1, 0, "", "", "");
        (uint256 n1, int256 avg1,) = reputationRegistry.getReputationSummary(agentId);
        assertEq(n1, 1);
        assertEq(avg1, -1);
    }

    function test_ClosedErasCantBeChanged() public {
        _pay(client1, 1);
        vm.prank(client1);
        reputationRegistry.giveFeedback(agentId, -1, 0, "", "", "");
        _transfer(newOwner);
        vm.prank(client1);
        vm.expectRevert("No feedback to revoke");
        reputationRegistry.revokeFeedback(agentId);
        assertEq(reputationRegistry.eraStats(agentId, 0).feedbackCount, 1);
    }

    function test_TransferBackIsStillANewEra() public {
        _pay(client1, 1);
        _transfer(newOwner);
        _pay(client2, 1);
        _transfer(agentOwner);
        _pay(client2, 1);
        assertEq(reputationRegistry.eraCount(agentId), 3);
        (address o2,,,) = reputationRegistry.eraInfo(agentId, 2);
        assertEq(o2, agentOwner);
        assertEq(reputationRegistry.eraStats(agentId, 2).settlements, 1);
        assertEq(reputationRegistry.eraStats(agentId, 0).settlements, 1);
    }

    function test_EraInfoRejectsFutureEra() public {
        vm.expectRevert(AgentReputationRegistry.NoSuchEra.selector);
        reputationRegistry.eraInfo(agentId, 1);
    }

    function test_MissingAgentReverts() public {
        vm.prank(client1);
        vm.expectRevert();
        reputationRegistry.giveFeedback(999, 1, 0, "", "", "");
    }

    // ── fuzz ─────────────────────────────────────────────────────────

    function testFuzz_VolumeAndSettlementsAddUp(uint96[8] memory amounts) public {
        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            _pay(address(uint160(0x1000 + i)), amounts[i]);
            total += amounts[i];
        }
        AgentReputationRegistry.EraStats memory st = reputationRegistry.eraStats(agentId, 0);
        assertEq(st.settlements, amounts.length);
        assertEq(st.volume, total);
    }

    function testFuzz_OnlyTriStateAccepted(int128 value) public {
        _pay(client1, 1);
        vm.prank(client1);
        if (value < -1 || value > 1) {
            vm.expectRevert(AgentReputationRegistry.ScoreOutOfRange.selector);
        }
        reputationRegistry.giveFeedback(agentId, value, 0, "", "", "");
    }
}

/// Invariants over random interleavings of payments, attestations,
/// revocations and transfers: the running totals always equal what the
/// stored attestations say, and closed eras never change.
contract AgentReputationInvariantTest is Test {
    AgentIdentityRegistry identityRegistry;
    AgentReputationRegistry reputation;
    ReputationHandler handler;

    function setUp() public {
        address admin = address(0xA11CE);
        vm.startPrank(admin);
        identityRegistry = AgentIdentityRegistry(address(new ERC1967Proxy(address(new AgentIdentityRegistry()), abi.encodeCall(AgentIdentityRegistry.initialize, ()))));
        reputation = AgentReputationRegistry(address(new ERC1967Proxy(
            address(new AgentReputationRegistry()), abi.encodeCall(AgentReputationRegistry.initialize, (address(identityRegistry)))
        )));
        vm.stopPrank();
        handler = new ReputationHandler(identityRegistry, reputation);
        vm.prank(admin);
        reputation.setSettlementRecorder(address(handler), true);
        targetContract(address(handler));
    }

    function invariant_TotalsMatchStoredAttestations() public view {
        uint256 agentId = handler.agentId();
        uint256 eras = reputation.eraCount(agentId);
        for (uint256 e = 0; e < eras; e++) {
            AgentReputationRegistry.EraStats memory st = reputation.eraStats(agentId, e);
            uint256 n = reputation.eraFeedbackCount(agentId, e);
            uint256 active;
            int256 sum;
            for (uint256 i = 0; i < n; i++) {
                (, int128 v,,,,,, bool revoked) = reputation.eraFeedbackAt(agentId, e, i);
                if (!revoked) { active++; sum += v; }
            }
            assertEq(st.feedbackCount, active, "feedbackCount");
            assertEq(int256(st.feedbackSum), sum, "feedbackSum");
            assertEq(st.volume, handler.volumeOf(e), "volume");
        }
    }

    function invariant_ClosedErasAreFrozen() public view {
        uint256 agentId = handler.agentId();
        uint256 cur = reputation.currentEra(agentId);
        for (uint256 e = 0; e < cur; e++) {
            assertEq(reputation.eraFeedbackCount(agentId, e), handler.frozenFeedbackCount(e), "closed era changed");
        }
    }
}

contract ReputationHandler is Test {
    AgentIdentityRegistry identityRegistry;
    AgentReputationRegistry reputation;
    uint256 public agentId;
    address[] owners;
    address[] clients;
    mapping(uint256 => uint256) public volumeOf;           // era => expected volume
    mapping(uint256 => uint256) public frozenFeedbackCount; // closed era => count at close

    constructor(AgentIdentityRegistry id, AgentReputationRegistry rep) {
        identityRegistry = id;
        reputation = rep;
        for (uint160 i = 0; i < 3; i++) owners.push(address(0xB000 + i));
        for (uint160 i = 0; i < 4; i++) clients.push(address(0xC000 + i));
        vm.prank(owners[0]);
        agentId = id.registerAgent("Inv", "uri", 0, address(0));
    }

    function pay(uint8 c, uint64 amount) external {
        address client = clients[c % clients.length];
        uint256 era = reputation.currentEra(agentId);
        reputation.recordSettlement(agentId, client, bytes32("svc"), amount);
        volumeOf[era] += amount;
    }

    function attest(uint8 c, int8 v) external {
        address client = clients[c % clients.length];
        int128 value = int128(int256(v % 2));
        vm.prank(client);
        try reputation.giveFeedback(agentId, value, 0, "t", "", "") {} catch {}
    }

    function revoke(uint8 c) external {
        vm.prank(clients[c % clients.length]);
        try reputation.revokeFeedback(agentId) {} catch {}
    }

    function transfer(uint8 o) external {
        address from = identityRegistry.ownerOf(agentId);
        address to = owners[o % owners.length];
        if (to == from) return;
        uint256 closing = reputation.currentEra(agentId);
        frozenFeedbackCount[closing] = reputation.eraFeedbackCount(agentId, closing);
        vm.prank(from);
        identityRegistry.transferFrom(from, to, agentId);
    }
}
