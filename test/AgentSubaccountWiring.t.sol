// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentReputationRegistry.sol";
import "../src/AgentPaymentRouter.sol";

contract WiringMockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { _mint(msg.sender, 1_000_000 * 10**6); }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @title AgentSubaccountWiringTest
/// @notice Verifies cross-contract subaccount wiring:
///   - PERM_REPUTATION canonicalises bound subaccount callers in AgentReputationRegistry.
///   - PERM_PAY gates the new payAgentTo / payAgentToUSDC routes in AgentPaymentRouter.
///   - Pre-existing payAgent / giveFeedback flows are unchanged for non-bound callers.
contract AgentSubaccountWiringTest is Test {
    AgentIdentityRegistry      public identity;
    AgentReputationRegistry    public reputation;
    AgentPaymentRouter         public router;
    WiringMockUSDC             public usdc;

    address public deployer  = address(0xD);
    address public creator   = address(0xC);
    address public payer     = address(0xBEEFCAFE);
    address public clientEoa = address(0xC11E);
    address public clientPrimaryTba = address(0xCAFEC11E);
    address public clientSubacct    = address(0xBEEFC11E);
    address public agentSubacct     = address(0x5BACC7);
    address public treasury  = address(0x7);

    uint256 public targetAgentId;
    uint256 public clientAgentId;

    function setUp() public {
        vm.startPrank(deployer);

        AgentIdentityRegistry idImpl = new AgentIdentityRegistry();
        identity = AgentIdentityRegistry(address(new ERC1967Proxy(
            address(idImpl), abi.encodeCall(AgentIdentityRegistry.initialize, ())
        )));

        AgentReputationRegistry repImpl = new AgentReputationRegistry();
        reputation = AgentReputationRegistry(address(new ERC1967Proxy(
            address(repImpl), abi.encodeCall(AgentReputationRegistry.initialize, (address(identity)))
        )));

        usdc = new WiringMockUSDC();
        router = new AgentPaymentRouter(address(identity), address(usdc), treasury);

        vm.stopPrank();

        // target agent (subject of the review / payment recipient)
        vm.prank(creator);
        targetAgentId = identity.registerAgent("Target", "ipfs://t", 1000, address(0));

        // client agent (the reviewer / x402 caller)
        vm.prank(clientEoa);
        clientAgentId = identity.registerAgent("Client", "ipfs://c", 1000, address(0));
    }

    // ============ ReputationRegistry · PERM_REPUTATION ============

    function test_Reputation_NonBoundCaller_UnchangedBehavior() public {
        vm.prank(payer);
        reputation.giveFeedback(targetAgentId, 90, 0, "quality", "speed", "ipfs://r1");
        assertEq(reputation.getFeedbackCount(targetAgentId), 1);
    }

    function test_Reputation_SubaccountWithoutPerm_Reverts() public {
        // Bind a subaccount with PAY (NOT REPUTATION).
        uint96 permPay = identity.PERM_PAY();
        vm.prank(clientEoa);
        identity.registerSubaccount(clientAgentId, clientSubacct, bytes32(0), permPay);

        vm.prank(clientSubacct);
        vm.expectRevert(bytes("Subaccount lacks PERM_REPUTATION"));
        reputation.giveFeedback(targetAgentId, 90, 0, "q", "s", "ipfs://x");
    }

    function test_Reputation_SubaccountWithPerm_CanonicalisesAndDedups() public {
        // Bind a subaccount WITH PERM_REPUTATION.
        uint96 permRep = identity.PERM_REPUTATION();
        vm.prank(clientEoa);
        identity.registerSubaccount(clientAgentId, clientSubacct, bytes32(0), permRep);

        // Subaccount writes feedback. Canonical client should be clientEoa.
        vm.prank(clientSubacct);
        reputation.giveFeedback(targetAgentId, 88, 0, "quality", "", "ipfs://r1");
        assertTrue(reputation.clientHasFeedback(reputation.reputationSubjectOf(targetAgentId), clientEoa));
        assertFalse(reputation.clientHasFeedback(reputation.reputationSubjectOf(targetAgentId), clientSubacct));

        // A second subaccount also bound with PERM_REPUTATION must NOT be
        // able to bypass dedup — same canonical client.
        address sub2 = address(0xBEEFC11F);
        vm.prank(clientEoa);
        identity.registerSubaccount(clientAgentId, sub2, bytes32(0), permRep);

        vm.prank(sub2);
        vm.expectRevert(bytes("Already gave feedback"));
        reputation.giveFeedback(targetAgentId, 50, 0, "q", "", "ipfs://r2");

        // The original subaccount can revoke even though the canonical
        // client (clientEoa) was who recorded the feedback.
        vm.prank(clientSubacct);
        reputation.revokeFeedback(targetAgentId);
        assertFalse(reputation.clientHasFeedback(reputation.reputationSubjectOf(targetAgentId), clientEoa));
    }

    function test_Reputation_PrimaryTBA_AlsoCanonicalises() public {
        vm.prank(clientEoa);
        identity.setTBAAddress(clientAgentId, clientPrimaryTba);

        vm.prank(clientPrimaryTba);
        reputation.giveFeedback(targetAgentId, 70, 0, "quality", "", "ipfs://r3");
        assertTrue(reputation.clientHasFeedback(reputation.reputationSubjectOf(targetAgentId), clientEoa));
    }

    function test_Reputation_CannotReviewOwnAgent_ViaSubaccount() public {
        // Bind a subaccount of the *target* agent's owner (creator).
        uint96 permRep = identity.PERM_REPUTATION();
        vm.prank(creator);
        identity.registerSubaccount(targetAgentId, agentSubacct, bytes32(0), permRep);

        vm.prank(agentSubacct);
        vm.expectRevert(bytes("Cannot review own agent"));
        reputation.giveFeedback(targetAgentId, 100, 0, "q", "", "ipfs://self");
    }

    // ============ PaymentRouter · PERM_PAY ============

    function test_PaymentRouter_payAgentTo_RoutesToSubaccount() public {
        uint96 permPay = identity.PERM_PAY();
        vm.prank(creator);
        identity.registerSubaccount(targetAgentId, agentSubacct, bytes32(0), permPay);

        vm.deal(payer, 10 ether);
        uint256 amount = 1 ether;
        uint256 systemCut = (amount * 50) / 10000;
        uint256 afterSystem = amount - systemCut;
        uint256 creatorCut = (afterSystem * 1000) / 10000;
        uint256 recipientCut = afterSystem - creatorCut;

        uint256 subBalBefore = agentSubacct.balance;

        vm.prank(payer);
        router.payAgentTo{value: amount}(targetAgentId, agentSubacct);

        // Recipient share went to the subaccount, not the (zero) primary TBA.
        assertEq(agentSubacct.balance - subBalBefore, recipientCut);
        assertEq(router.totalPaidToAgent(targetAgentId), amount);
        assertEq(router.totalCreatorEarnings(targetAgentId), creatorCut);
    }

    function test_PaymentRouter_payAgentTo_RevertsWhenSubaccountUnbound() public {
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert(AgentPaymentRouter.SubaccountNotPermitted.selector);
        router.payAgentTo{value: 1 ether}(targetAgentId, agentSubacct);
    }

    function test_PaymentRouter_payAgentTo_RevertsWhenSubaccountWrongAgent() public {
        // Bind subaccount to clientAgentId, then try to route as targetAgentId.
        uint96 permPay = identity.PERM_PAY();
        vm.prank(clientEoa);
        identity.registerSubaccount(clientAgentId, agentSubacct, bytes32(0), permPay);

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert(AgentPaymentRouter.SubaccountNotPermitted.selector);
        router.payAgentTo{value: 1 ether}(targetAgentId, agentSubacct);
    }

    function test_PaymentRouter_payAgentTo_RevertsWhenSubaccountLacksPermPay() public {
        // Bind with PERM_REPUTATION only.
        uint96 permRep = identity.PERM_REPUTATION();
        vm.prank(creator);
        identity.registerSubaccount(targetAgentId, agentSubacct, bytes32(0), permRep);

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert(AgentPaymentRouter.SubaccountNotPermitted.selector);
        router.payAgentTo{value: 1 ether}(targetAgentId, agentSubacct);
    }

    function test_PaymentRouter_payAgentToUSDC_RoutesToSubaccount() public {
        uint96 permPay = identity.PERM_PAY();
        vm.prank(creator);
        identity.registerSubaccount(targetAgentId, agentSubacct, bytes32(0), permPay);

        usdc.mint(payer, 100 * 10**6);
        vm.prank(payer);
        usdc.approve(address(router), type(uint256).max);

        uint256 amount = 100 * 10**6;
        uint256 systemCut = (amount * 50) / 10000;
        uint256 afterSystem = amount - systemCut;
        uint256 creatorCut = (afterSystem * 1000) / 10000;
        uint256 recipientCut = afterSystem - creatorCut;

        vm.prank(payer);
        router.payAgentToUSDC(targetAgentId, amount, agentSubacct);

        assertEq(usdc.balanceOf(agentSubacct), recipientCut);
        assertEq(router.totalCreatorEarnings(targetAgentId), creatorCut);
    }

    function test_PaymentRouter_payAgentTo_PrimaryTBA_AlsoWorks() public {
        // Primary TBA has PERM_ALL implicitly, so payAgentTo to the primary
        // TBA should be allowed (degenerate but valid path).
        vm.prank(creator);
        identity.setTBAAddress(targetAgentId, agentSubacct);

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        router.payAgentTo{value: 1 ether}(targetAgentId, agentSubacct);
        assertGt(agentSubacct.balance, 0);
    }
}
