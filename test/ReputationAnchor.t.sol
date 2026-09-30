// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentReputationRegistry.sol";

/**
 * @title ReputationAnchorTest
 * @notice Tests the dynamic reputation anchor: reputation keyed to agentId
 *         when anchor=address(0) (transferable), and keyed to anchor address
 *         when anchor is non-zero (non-transferable).
 */
contract ReputationAnchorTest is Test {
    AgentIdentityRegistry public identityRegistry;
    AgentReputationRegistry public reputationRegistry;

    address public owner = address(0x1);
    address public creator = address(0x2);
    address public buyer = address(0x3);
    address public client1 = address(0x4);
    address public client2 = address(0x5);

    uint256 public anchoredAgentId;
    uint256 public transferableAgentId;

    function setUp() public {
        vm.startPrank(owner);

        AgentIdentityRegistry identityImpl = new AgentIdentityRegistry();
        ERC1967Proxy identityProxy = new ERC1967Proxy(
            address(identityImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identityRegistry = AgentIdentityRegistry(address(identityProxy));

        AgentReputationRegistry reputationImpl = new AgentReputationRegistry();
        ERC1967Proxy reputationProxy = new ERC1967Proxy(
            address(reputationImpl),
            abi.encodeCall(AgentReputationRegistry.initialize, (address(identityRegistry)))
        );
        reputationRegistry = AgentReputationRegistry(address(reputationProxy));
        // v2: this contract stands in for the payment contract.
        reputationRegistry.setSettlementRecorder(address(this), true);

        vm.stopPrank();

        // Mint agent with reputation anchor (creator's address)
        vm.prank(creator);
        anchoredAgentId = identityRegistry.registerAgent(
            "AnchoredBot",
            "ipfs://anchored",
            1000, // 10% royalty
            creator // reputation locked to creator
        );

        // Mint agent without anchor (default, transferable)
        vm.prank(creator);
        transferableAgentId = identityRegistry.registerAgent(
            "TransferableBot",
            "ipfs://transferable",
            1000,
            address(0) // transferable
        );
    }

    // ============ Identity Registry Tests ============

    function test_RegisterAgentWithAnchor() public {
        assertEq(identityRegistry.reputationAnchorOf(anchoredAgentId), creator);

        (
            string memory name,
            address tba,
            uint256 createdAt,
            bool active,
            address agentOwner,
            address reputationAnchor
        ) = identityRegistry.getAgent(anchoredAgentId);

        assertEq(name, "AnchoredBot");
        assertEq(reputationAnchor, creator);
        assertEq(agentOwner, creator);
        assertGt(createdAt, 0);
        assertTrue(active);
    }

    function test_RegisterAgent_DefaultsToTransferable() public {
        assertEq(identityRegistry.reputationAnchorOf(transferableAgentId), address(0));

        (
            ,
            ,
            ,
            ,
            address agentOwner,
            address reputationAnchor
        ) = identityRegistry.getAgent(transferableAgentId);

        assertEq(reputationAnchor, address(0));
        assertEq(agentOwner, creator);
    }

    function test_DefaultAnchor_IsTransferable() public {
        vm.prank(creator);
        uint256 agentId = identityRegistry.registerAgent("DefaultBot", "ipfs://default", 500, address(0));

        assertEq(identityRegistry.reputationAnchorOf(agentId), address(0));
        (,,,,, address anchor) = identityRegistry.getAgent(agentId);
        assertEq(anchor, address(0));
    }

    function test_ReputationAnchorOf_RevertNonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(AgentIdentityRegistry.NotExists.selector));
        identityRegistry.reputationAnchorOf(999);
    }

    // ============ Transferable Reputation Tests ============

    // Reputation v2: reputation belongs to an (agent, owner) era. A sale
    // starts the buyer's era with an empty history — whether or not the
    // agent was minted with a reputation anchor — and the seller's era stays
    // readable. Anchors remain an identity-registry fact (who minted, the
    // reverse index); they no longer pool or carry reputation.

    function _paid(uint256 agentId, address client) internal {
        reputationRegistry.recordSettlement(agentId, client, bytes32("svc"), 1);
    }

    function test_Sale_StartsNewEra_ForTransferableAgent() public {
        _paid(transferableAgentId, client1);
        vm.prank(client1);
        reputationRegistry.giveFeedback(transferableAgentId, 1, 0, "quality", "", "");

        vm.prank(creator);
        identityRegistry.transferFrom(creator, buyer, transferableAgentId);

        (uint256 count,,) = reputationRegistry.getReputationSummary(transferableAgentId);
        assertEq(count, 0, "the buyer does not inherit the seller's reputation");
        assertEq(reputationRegistry.eraStats(transferableAgentId, 0).feedbackCount, 1, "seller's era kept");
    }

    function test_Sale_BuyersClientsBuildTheNewEra() public {
        _paid(transferableAgentId, client1);
        vm.prank(client1);
        reputationRegistry.giveFeedback(transferableAgentId, -1, 0, "quality", "", "");

        vm.prank(creator);
        identityRegistry.transferFrom(creator, buyer, transferableAgentId);

        _paid(transferableAgentId, client2);
        vm.prank(client2);
        reputationRegistry.giveFeedback(transferableAgentId, 1, 0, "quality", "", "");

        (uint256 count, int256 avg,) = reputationRegistry.getReputationSummary(transferableAgentId);
        assertEq(count, 1);
        assertEq(avg, 1, "only the new era's attestation counts");
    }

    function test_AnchoredAgent_SaleStillStartsNewEra() public {
        _paid(anchoredAgentId, client1);
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 1, 0, "quality", "", "");

        vm.prank(creator);
        identityRegistry.transferFrom(creator, buyer, anchoredAgentId);

        (uint256 count,,) = reputationRegistry.getReputationSummary(anchoredAgentId);
        assertEq(count, 0, "an anchor does not carry reputation to a new owner");
        (address eraOwner,,,) = reputationRegistry.eraInfo(anchoredAgentId, 0);
        assertEq(eraOwner, creator);
    }

    function test_AgentsWithTheSameAnchor_HaveSeparateHistories() public {
        vm.prank(creator);
        uint256 agent2Id = identityRegistry.registerAgent("AnchoredBot2", "ipfs://anchored2", 1000, creator);

        _paid(anchoredAgentId, client1);
        _paid(agent2Id, client2);
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 1, 0, "quality", "", "");
        vm.prank(client2);
        reputationRegistry.giveFeedback(agent2Id, -1, 0, "quality", "", "");

        (uint256 c1, int256 a1,) = reputationRegistry.getReputationSummary(anchoredAgentId);
        (uint256 c2, int256 a2,) = reputationRegistry.getReputationSummary(agent2Id);
        assertEq(c1, 1);
        assertEq(a1, 1);
        assertEq(c2, 1);
        assertEq(a2, -1);
    }

    function test_TagScores_ArePerEra() public {
        _paid(anchoredAgentId, client1);
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 1, 0, "quality", "speed", "");
        (int256 q, uint256 qn) = reputationRegistry.getTagScore(anchoredAgentId, "quality");
        assertEq(q, 1);
        assertEq(qn, 1);

        vm.prank(creator);
        identityRegistry.transferFrom(creator, buyer, anchoredAgentId);
        (, uint256 qnAfter) = reputationRegistry.getTagScore(anchoredAgentId, "quality");
        assertEq(qnAfter, 0);
    }

    function test_ClosedEra_RevocationsAndAttestationsAreFrozen() public {
        _paid(anchoredAgentId, client1);
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 1, 0, "quality", "", "");

        vm.prank(creator);
        identityRegistry.transferFrom(creator, buyer, anchoredAgentId);

        vm.prank(client1);
        vm.expectRevert("No feedback to revoke");
        reputationRegistry.revokeFeedback(anchoredAgentId);
        vm.prank(client1);
        vm.expectRevert(AgentReputationRegistry.NotAPayingClient.selector);
        reputationRegistry.giveFeedback(anchoredAgentId, -1, 0, "quality", "", "");
    }

    // ============ Audit regression tests ============

    /// CRITICAL-1 (v2 form): subjects are domain-separated keccak(ERA, agentId,
    /// era) — an anchor whose uint160 equals an agentId can't merge pools, and
    /// the legacy anchor/agent subjects stay separate too.
    function test_AUDIT_NoSubjectCollisionBetweenAnchorAndAgentId() public {
        address collidingAnchor = address(uint160(transferableAgentId));
        vm.prank(collidingAnchor);
        uint256 collidingAgent = identityRegistry.registerAgent("Collider", "ipfs://collide", 0, collidingAnchor);

        _paid(collidingAgent, client1);
        vm.prank(client1);
        reputationRegistry.giveFeedback(collidingAgent, -1, 0, "evil", "", "");

        (uint256 nCount,,) = reputationRegistry.getReputationSummary(transferableAgentId);
        assertEq(nCount, 0, "transferable agent leaked from another subject");
        (uint256 aCount, int256 aAvg,) = reputationRegistry.getReputationSummary(collidingAgent);
        assertEq(aCount, 1);
        assertEq(aAvg, -1);
        assertTrue(reputationRegistry.reputationSubjectOf(collidingAgent) != reputationRegistry.reputationSubjectOf(transferableAgentId));
    }

    /**
     * @dev HIGH-3 regression: minter MUST NOT be able to set a foreign
     *      reputationAnchor (would enable reputation poisoning).
     */
    function test_AUDIT_RegisterRevertsOnForeignAnchor() public {
        address victim = address(0xDEADBEEF);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AgentIdentityRegistry.InvalidValue.selector));
        identityRegistry.registerAgent("Evil", "ipfs://evil", 0, victim);
    }

    function test_AUDIT_GetFeedbackCount_ResolvesCurrentEra() public {
        _paid(anchoredAgentId, client1);
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 1, 0, "quality", "", "");
        assertEq(reputationRegistry.getFeedbackCount(anchoredAgentId), 1);
    }

    /// MEDIUM-4 (v2 form): the current subject is keccak(ERA, agentId, era).
    function test_AUDIT_ReputationSubjectIsDomainSeparated() public view {
        assertEq(reputationRegistry.reputationSubjectOf(transferableAgentId), keccak256(abi.encode(keccak256("ERA"), transferableAgentId, uint256(0))));
        assertTrue(reputationRegistry.reputationSubjectOf(anchoredAgentId) != reputationRegistry.reputationSubjectOf(transferableAgentId));
    }

    function test_AUDIT_GetFeedbackAt_ResolvesCurrentEra() public {
        _paid(anchoredAgentId, client1);
        vm.prank(client1);
        reputationRegistry.giveFeedback(anchoredAgentId, 1, 0, "quality", "speed", "ipfs://x");

        (address fbClient, int128 fbValue,, string memory fbTag1,,,, bool fbRevoked) = reputationRegistry.getFeedbackAt(anchoredAgentId, 0);
        assertEq(fbClient, client1);
        assertEq(fbValue, 1);
        assertEq(keccak256(bytes(fbTag1)), keccak256(bytes("quality")));
        assertFalse(fbRevoked);
    }
}
