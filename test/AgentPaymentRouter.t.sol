// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentPaymentRouter.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1_000_000 * 10**6);
    }
    
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AgentPaymentRouterTest is Test {
    AgentIdentityRegistry public identityRegistry;
    AgentPaymentRouter public paymentRouter;
    MockUSDC public usdc;
    
    address public creator = address(0x1);
    address public owner = address(0x2);
    address public payer = address(0x3);
    address public operationalAddr = address(0x4);
    address public treasury = address(0x5);  // AEyeOS treasury
    
    uint256 public agentId;
    
    function setUp() public {
        // Deploy Identity Registry
        AgentIdentityRegistry impl = new AgentIdentityRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identityRegistry = AgentIdentityRegistry(address(proxy));
        
        // Deploy Mock USDC
        usdc = new MockUSDC();
        
        // Deploy Payment Router with treasury
        paymentRouter = new AgentPaymentRouter(address(identityRegistry), address(usdc), treasury);
        
        // Create an agent as creator
        vm.prank(creator);
        agentId = identityRegistry.registerAgent("TestBot", "ipfs://test", 1000, address(0)); // 10% royalty
        
        // Fund payer with ETH and USDC
        vm.deal(payer, 100 ether);
        usdc.mint(payer, 100_000 * 10**6);
        
        // Approve router for USDC
        vm.prank(payer);
        usdc.approve(address(paymentRouter), type(uint256).max);
    }
    
    // ============ BASIC PAYMENT TESTS ============
    
    function test_PayAgentETH() public {
        uint256 paymentAmount = 1 ether;
        // System takes 1% first, then creator takes 10% of remainder
        uint256 expectedSystemCut = paymentAmount * 100 / 10000; // 1%
        uint256 afterSystem = paymentAmount - expectedSystemCut;
        uint256 expectedCreatorCut = afterSystem * 1000 / 10000; // 10% of remainder
        uint256 expectedOwnerCut = afterSystem - expectedCreatorCut;
        
        uint256 creatorBalanceBefore = creator.balance;
        
        vm.prank(payer);
        paymentRouter.payAgent{value: paymentAmount}(agentId);
        
        // Creator should receive royalty + owner cut (creator is owner initially)
        assertEq(creator.balance - creatorBalanceBefore, expectedCreatorCut + expectedOwnerCut);
        
        // System royalty should be accumulated
        assertEq(paymentRouter.pendingSystemRoyalties(address(0)), expectedSystemCut);
        
        // Stats should be updated
        assertEq(paymentRouter.totalPaidToAgent(agentId), paymentAmount);
        assertEq(paymentRouter.totalCreatorEarnings(agentId), expectedCreatorCut);
        assertEq(paymentRouter.creatorLifetimeEarnings(creator), expectedCreatorCut);
        assertEq(paymentRouter.totalSystemRoyalties(), expectedSystemCut);
    }
    
    function test_PayAgentUSDC() public {
        uint256 paymentAmount = 100 * 10**6; // 100 USDC
        // System takes 1% first, then creator takes 10% of remainder
        uint256 expectedSystemCut = paymentAmount * 100 / 10000; // 1%
        uint256 afterSystem = paymentAmount - expectedSystemCut;
        uint256 expectedCreatorCut = afterSystem * 1000 / 10000; // 10% of remainder
        uint256 expectedOwnerCut = afterSystem - expectedCreatorCut;
        
        uint256 creatorBalanceBefore = usdc.balanceOf(creator);
        
        vm.prank(payer);
        paymentRouter.payAgentUSDC(agentId, paymentAmount);
        
        // Creator should receive royalty + owner cut (creator is owner initially)
        assertEq(usdc.balanceOf(creator) - creatorBalanceBefore, expectedCreatorCut + expectedOwnerCut);
        
        // System royalty should be accumulated
        assertEq(paymentRouter.pendingSystemRoyalties(address(usdc)), expectedSystemCut);
        
        // Stats should be updated
        assertEq(paymentRouter.totalPaidToAgent(agentId), paymentAmount);
    }
    
    function test_PreviewSplit() public {
        uint256 amount = 10000;  // Use 10000 for easier math
        
        // System takes 1% first = 50, then creator takes 10% of 9950 = 995
        (uint256 systemCut, address creatorAddr, uint256 creatorCut, address recipient, uint256 recipientCut) = 
            paymentRouter.previewSplit(agentId, amount);
        
        assertEq(systemCut, 100);  // 1% of 10000
        assertEq(creatorAddr, creator);
        assertEq(creatorCut, 990); // 10% of 9900
        assertEq(recipient, creator); // No TBA set, so owner (who is creator)
        assertEq(recipientCut, 8910); // 9900 - 990
    }
    
    // ============ CREATOR WHITELIST TESTS ============
    
    function test_AddToCreatorWhitelist() public {
        vm.prank(creator);
        paymentRouter.addToCreatorWhitelist(agentId, operationalAddr);
        
        assertTrue(paymentRouter.isExempt(agentId, operationalAddr));
        assertTrue(paymentRouter.creatorWhitelist(agentId, operationalAddr));
    }
    
    function test_AddToCreatorWhitelist_RevertNotCreator() public {
        vm.prank(payer);
        vm.expectRevert(AgentPaymentRouter.NotCreator.selector);
        paymentRouter.addToCreatorWhitelist(agentId, operationalAddr);
    }
    
    function test_AddToCreatorWhitelist_RevertAlreadyWhitelisted() public {
        vm.prank(creator);
        paymentRouter.addToCreatorWhitelist(agentId, operationalAddr);
        
        vm.prank(creator);
        vm.expectRevert(AgentPaymentRouter.AlreadyWhitelisted.selector);
        paymentRouter.addToCreatorWhitelist(agentId, operationalAddr);
    }
    
    function test_RemoveFromCreatorWhitelist() public {
        vm.prank(creator);
        paymentRouter.addToCreatorWhitelist(agentId, operationalAddr);
        assertTrue(paymentRouter.isExempt(agentId, operationalAddr));
        
        vm.prank(creator);
        paymentRouter.removeFromCreatorWhitelist(agentId, operationalAddr);
        assertFalse(paymentRouter.isExempt(agentId, operationalAddr));
    }
    
    function test_RemoveFromCreatorWhitelist_RevertNotWhitelisted() public {
        vm.prank(creator);
        vm.expectRevert(AgentPaymentRouter.NotWhitelisted.selector);
        paymentRouter.removeFromCreatorWhitelist(agentId, operationalAddr);
    }
    
    function test_GetCreatorWhitelist() public {
        address addr1 = address(0x10);
        address addr2 = address(0x11);
        address addr3 = address(0x12);
        
        vm.startPrank(creator);
        paymentRouter.addToCreatorWhitelist(agentId, addr1);
        paymentRouter.addToCreatorWhitelist(agentId, addr2);
        paymentRouter.addToCreatorWhitelist(agentId, addr3);
        paymentRouter.removeFromCreatorWhitelist(agentId, addr2);
        vm.stopPrank();
        
        address[] memory whitelist = paymentRouter.getCreatorWhitelist(agentId);
        assertEq(whitelist.length, 2);
        assertEq(whitelist[0], addr1);
        assertEq(whitelist[1], addr3);
    }
    
    // ============ EXEMPT PAYMENT TESTS ============
    
    function test_PayAgentExempt() public {
        // Whitelist the operational address
        vm.prank(creator);
        paymentRouter.addToCreatorWhitelist(agentId, operationalAddr);
        
        // Fund operational address
        vm.deal(operationalAddr, 10 ether);
        
        uint256 paymentAmount = 1 ether;
        uint256 creatorBalanceBefore = creator.balance;
        
        vm.prank(operationalAddr);
        paymentRouter.payAgentExempt{value: paymentAmount}(agentId);
        
        // Creator should receive FULL amount (no royalty split on exempt)
        assertEq(creator.balance - creatorBalanceBefore, paymentAmount);
        
        // Stats
        assertEq(paymentRouter.totalPaidToAgent(agentId), paymentAmount);
        assertEq(paymentRouter.totalExemptPayments(agentId), paymentAmount);
        assertEq(paymentRouter.totalCreatorEarnings(agentId), 0); // No creator earnings on exempt
    }
    
    function test_PayAgentExempt_RevertNotExempt() public {
        vm.deal(operationalAddr, 10 ether);
        
        vm.prank(operationalAddr);
        vm.expectRevert(AgentPaymentRouter.NotExempt.selector);
        paymentRouter.payAgentExempt{value: 1 ether}(agentId);
    }
    
    function test_PayAgentExemptUSDC() public {
        vm.prank(creator);
        paymentRouter.addToCreatorWhitelist(agentId, operationalAddr);
        
        usdc.mint(operationalAddr, 1000 * 10**6);
        vm.prank(operationalAddr);
        usdc.approve(address(paymentRouter), type(uint256).max);
        
        uint256 paymentAmount = 100 * 10**6;
        uint256 creatorBalanceBefore = usdc.balanceOf(creator);
        
        vm.prank(operationalAddr);
        paymentRouter.payAgentExemptUSDC(agentId, paymentAmount);
        
        assertEq(usdc.balanceOf(creator) - creatorBalanceBefore, paymentAmount);
        assertEq(paymentRouter.totalExemptPayments(agentId), paymentAmount);
    }
    
    // ============ INFRASTRUCTURE WHITELIST TESTS ============
    
    function test_InfrastructureWhitelist() public {
        // Uniswap SwapRouter02 should be whitelisted
        address uniswapRouter = 0x2626664c2603336E57B271c5C0b26F421741e481;
        assertTrue(paymentRouter.infrastructureWhitelist(uniswapRouter));
        assertTrue(paymentRouter.isExempt(agentId, uniswapRouter));
    }
    
    function test_AddInfrastructure() public {
        address newProtocol = address(0x999);
        
        paymentRouter.addInfrastructure(newProtocol);
        assertTrue(paymentRouter.infrastructureWhitelist(newProtocol));
    }
    
    function test_AddInfrastructure_RevertNotOwner() public {
        address newProtocol = address(0x999);
        
        vm.prank(payer);
        vm.expectRevert();
        paymentRouter.addInfrastructure(newProtocol);
    }
    
    function test_RemoveInfrastructure() public {
        address uniswapRouter = 0x2626664c2603336E57B271c5C0b26F421741e481;
        assertTrue(paymentRouter.infrastructureWhitelist(uniswapRouter));
        
        paymentRouter.removeInfrastructure(uniswapRouter);
        assertFalse(paymentRouter.infrastructureWhitelist(uniswapRouter));
    }
    
    // ============ EDGE CASES ============
    
    function test_PayAgent_RevertZeroPayment() public {
        vm.prank(payer);
        vm.expectRevert(AgentPaymentRouter.ZeroPayment.selector);
        paymentRouter.payAgent{value: 0}(agentId);
    }
    
    function test_PayAgent_RevertInvalidAgent() public {
        vm.prank(payer);
        vm.expectRevert(AgentPaymentRouter.InvalidAgent.selector);
        paymentRouter.payAgent{value: 1 ether}(999);
    }
    
    function test_PayAgent_RevertInactiveAgent() public {
        vm.prank(creator);
        identityRegistry.deactivateAgent(agentId);
        
        vm.prank(payer);
        vm.expectRevert(AgentPaymentRouter.InactiveAgent.selector);
        paymentRouter.payAgent{value: 1 ether}(agentId);
    }
    
    function test_GetAgentStats() public {
        vm.prank(payer);
        paymentRouter.payAgent{value: 1 ether}(agentId);
        
        // System takes 1% first = 0.005 ETH, then creator takes 10% of 0.995 ETH = 0.0995 ETH
        (uint256 totalReceived, uint256 creatorEarnings, address creatorAddr, uint256 royaltyBps) = 
            paymentRouter.getAgentStats(agentId);
        
        assertEq(totalReceived, 1 ether);
        assertEq(creatorEarnings, 0.099 ether); // 10% of (1 - 1%)
        assertEq(creatorAddr, creator);
        assertEq(royaltyBps, 1000);
    }
    
    // ============ TRANSFER OWNERSHIP SCENARIO ============
    
    function test_RoyaltiesAfterTransfer() public {
        // Transfer agent to new owner
        vm.prank(creator);
        identityRegistry.transferFrom(creator, owner, agentId);
        
        // Verify ownership changed
        assertEq(identityRegistry.ownerOf(agentId), owner);
        
        // Pay agent - system takes 0.5% first, then creator takes 10% of remainder
        uint256 paymentAmount = 1 ether;
        uint256 systemCut = paymentAmount * 100 / 10000; // 1%
        uint256 afterSystem = paymentAmount - systemCut;
        uint256 expectedCreatorCut = afterSystem * 1000 / 10000; // 10% of remainder
        uint256 expectedOwnerCut = afterSystem - expectedCreatorCut;
        
        uint256 creatorBalanceBefore = creator.balance;
        uint256 ownerBalanceBefore = owner.balance;
        
        vm.prank(payer);
        paymentRouter.payAgent{value: paymentAmount}(agentId);
        
        // Creator STILL gets royalty (soulbound)
        assertEq(creator.balance - creatorBalanceBefore, expectedCreatorCut);
        
        // New owner gets remainder
        assertEq(owner.balance - ownerBalanceBefore, expectedOwnerCut);
    }
    
    function test_CreatorWhitelistAfterTransfer() public {
        // Transfer agent to new owner
        vm.prank(creator);
        identityRegistry.transferFrom(creator, owner, agentId);
        
        // New owner cannot modify whitelist
        vm.prank(owner);
        vm.expectRevert(AgentPaymentRouter.NotCreator.selector);
        paymentRouter.addToCreatorWhitelist(agentId, operationalAddr);
        
        // Original creator CAN still modify whitelist
        vm.prank(creator);
        paymentRouter.addToCreatorWhitelist(agentId, operationalAddr);
        assertTrue(paymentRouter.isExempt(agentId, operationalAddr));
    }
    
    // ============ GAS THRESHOLD TESTS ============
    
    function test_SmallPaymentAccumulates() public {
        // Payment below threshold should accumulate
        // System takes 1% first, then creator takes 10% of remainder
        uint256 smallPayment = 0.0005 ether;
        uint256 systemCut = smallPayment * 100 / 10000; // 0.5%
        uint256 afterSystem = smallPayment - systemCut;
        uint256 expectedCreatorCut = afterSystem * 1000 / 10000; // 10% of remainder
        
        uint256 creatorBalanceBefore = creator.balance;
        
        vm.prank(payer);
        paymentRouter.payAgent{value: smallPayment}(agentId);
        
        // Creator should NOT receive royalty immediately (below threshold)
        // But recipient (also creator here) gets their cut
        uint256 recipientCut = afterSystem - expectedCreatorCut;
        assertEq(creator.balance - creatorBalanceBefore, recipientCut);
        
        // Royalty should be accumulated
        assertEq(paymentRouter.getPendingRoyalties(creator, address(0)), expectedCreatorCut);
    }
    
    function test_AccumulatedRoyaltiesTransferWhenThresholdMet() public {
        // Transfer agent to separate owner so we can isolate royalty payments
        vm.prank(creator);
        identityRegistry.transferFrom(creator, owner, agentId);
        
        // Make multiple small payments until threshold is met
        // System takes 1% first, then creator takes 10% of remainder
        // Use 0.0006 ETH so royalty = 0.0006 * 0.99 * 0.1 = 0.0000594 ETH per payment
        // Two payments = 0.0001188 ETH > 0.0001 ETH threshold
        uint256 smallPayment = 0.0006 ether;
        uint256 systemCut = smallPayment * 100 / 10000;
        uint256 afterSystem = smallPayment - systemCut;
        uint256 royaltyPerPayment = afterSystem * 1000 / 10000;
        
        // First payment should accumulate (below threshold)
        vm.prank(payer);
        paymentRouter.payAgent{value: smallPayment}(agentId);
        
        // First payment accumulates
        assertEq(paymentRouter.getPendingRoyalties(creator, address(0)), royaltyPerPayment);
        
        uint256 creatorBalanceBefore = creator.balance;
        
        // Second payment should trigger transfer of accumulated + current
        vm.prank(payer);
        paymentRouter.payAgent{value: smallPayment}(agentId);
        
        // Pending should be cleared (threshold met: 0.0000597 * 2 = 0.0001194 > 0.0001)
        assertEq(paymentRouter.getPendingRoyalties(creator, address(0)), 0);
        
        // Creator should receive both royalties (owner gets recipient cut separately)
        assertEq(creator.balance - creatorBalanceBefore, royaltyPerPayment * 2);
    }
    
    function test_WithdrawRoyalties() public {
        // Make small payment that accumulates (below 0.0001 ETH threshold)
        // System takes 1% first, then creator takes 10% of remainder
        uint256 smallPayment = 0.0005 ether;
        uint256 systemCut = smallPayment * 100 / 10000;
        uint256 afterSystem = smallPayment - systemCut;
        uint256 expectedCreatorCut = afterSystem * 1000 / 10000;
        
        vm.prank(payer);
        paymentRouter.payAgent{value: smallPayment}(agentId);
        
        // Verify accumulation
        assertEq(paymentRouter.getPendingRoyalties(creator, address(0)), expectedCreatorCut);
        
        uint256 creatorBalanceBefore = creator.balance;
        
        // Creator manually withdraws
        vm.prank(creator);
        paymentRouter.withdrawRoyalties();
        
        // Should receive accumulated royalty
        assertEq(creator.balance - creatorBalanceBefore, expectedCreatorCut);
        assertEq(paymentRouter.getPendingRoyalties(creator, address(0)), 0);
    }
    
    function test_WithdrawRoyalties_RevertNothingToWithdraw() public {
        vm.prank(creator);
        vm.expectRevert(AgentPaymentRouter.NothingToWithdraw.selector);
        paymentRouter.withdrawRoyalties();
    }
    
    function test_SetMinAutoTransferETH() public {
        uint256 newThreshold = 0.05 ether;
        
        paymentRouter.setMinAutoTransferETH(newThreshold);
        
        (uint256 ethThreshold,) = paymentRouter.getThresholds();
        assertEq(ethThreshold, newThreshold);
    }
    
    function test_SetMinAutoTransferETH_RevertNotOwner() public {
        vm.prank(payer);
        vm.expectRevert();
        paymentRouter.setMinAutoTransferETH(0.05 ether);
    }
    
    function test_SetMinAutoTransferETH_RevertZeroThreshold() public {
        vm.expectRevert(AgentPaymentRouter.InvalidThreshold.selector);
        paymentRouter.setMinAutoTransferETH(0);
    }
    
    function test_SetMinAutoTransferUSDC() public {
        uint256 newThreshold = 50 * 10**6; // $50
        
        paymentRouter.setMinAutoTransferUSDC(newThreshold);
        
        (, uint256 usdcThreshold) = paymentRouter.getThresholds();
        assertEq(usdcThreshold, newThreshold);
    }
    
    function test_GetThresholds() public {
        (uint256 ethThreshold, uint256 usdcThreshold) = paymentRouter.getThresholds();
        
        // Base L2 defaults - 100x lower than mainnet
        assertEq(ethThreshold, 0.0001 ether);
        assertEq(usdcThreshold, 100000); // $0.10 USDC
    }
    
    function test_LargePaymentTransfersImmediately() public {
        // Payment above threshold should transfer immediately
        // System takes 1% first, then creator takes 10% of remainder
        uint256 largePayment = 1 ether;
        uint256 systemCut = largePayment * 100 / 10000;
        uint256 afterSystem = largePayment - systemCut;
        uint256 expectedCreatorCut = afterSystem * 1000 / 10000;
        uint256 recipientCut = afterSystem - expectedCreatorCut;
        
        uint256 creatorBalanceBefore = creator.balance;
        
        vm.prank(payer);
        paymentRouter.payAgent{value: largePayment}(agentId);
        
        // Creator should receive royalty immediately (above threshold)
        // Plus recipient cut (creator is also owner)
        assertEq(creator.balance - creatorBalanceBefore, expectedCreatorCut + recipientCut);
        
        // No pending royalties
        assertEq(paymentRouter.getPendingRoyalties(creator, address(0)), 0);
    }
    
    function test_WithdrawRoyaltiesToken() public {
        // Set a high USDC threshold so payments accumulate
        paymentRouter.setMinAutoTransferUSDC(1000 * 10**6); // $1000
        
        // System takes 1% first, then creator takes 10% of remainder
        uint256 usdcPayment = 100 * 10**6; // $100
        uint256 systemCut = usdcPayment * 100 / 10000;
        uint256 afterSystem = usdcPayment - systemCut;
        uint256 expectedCreatorCut = afterSystem * 1000 / 10000;
        
        vm.prank(payer);
        paymentRouter.payAgentUSDC(agentId, usdcPayment);
        
        // Should accumulate
        assertEq(paymentRouter.getPendingRoyalties(creator, address(usdc)), expectedCreatorCut);
        
        uint256 creatorUsdcBefore = usdc.balanceOf(creator);
        
        // Creator manually withdraws
        vm.prank(creator);
        paymentRouter.withdrawRoyaltiesToken(address(usdc));
        
        assertEq(usdc.balanceOf(creator) - creatorUsdcBefore, expectedCreatorCut);
        assertEq(paymentRouter.getPendingRoyalties(creator, address(usdc)), 0);
    }
    
    // ============ SYSTEM ROYALTY TESTS ============
    
    function test_SystemRoyaltyAccumulates() public {
        uint256 paymentAmount = 1 ether;
        uint256 expectedSystemCut = paymentAmount * 100 / 10000; // 1%
        
        vm.prank(payer);
        paymentRouter.payAgent{value: paymentAmount}(agentId);
        
        assertEq(paymentRouter.pendingSystemRoyalties(address(0)), expectedSystemCut);
        assertEq(paymentRouter.totalSystemRoyalties(), expectedSystemCut);
    }
    
    function test_WithdrawSystemRoyalties() public {
        uint256 paymentAmount = 1 ether;
        uint256 expectedSystemCut = paymentAmount * 100 / 10000; // 1%
        
        vm.prank(payer);
        paymentRouter.payAgent{value: paymentAmount}(agentId);
        
        uint256 treasuryBalanceBefore = treasury.balance;
        
        vm.prank(treasury);
        paymentRouter.withdrawSystemRoyalties();
        
        assertEq(treasury.balance - treasuryBalanceBefore, expectedSystemCut);
        assertEq(paymentRouter.pendingSystemRoyalties(address(0)), 0);
    }
    
    function test_WithdrawSystemRoyalties_RevertNotTreasury() public {
        uint256 paymentAmount = 1 ether;
        
        vm.prank(payer);
        paymentRouter.payAgent{value: paymentAmount}(agentId);
        
        vm.prank(payer);
        vm.expectRevert("Not treasury");
        paymentRouter.withdrawSystemRoyalties();
    }
    
    function test_SetAeyeosTreasury() public {
        address newTreasury = address(0x999);
        
        paymentRouter.setAeyeosTreasury(newTreasury);
        
        assertEq(paymentRouter.aeyeosTreasury(), newTreasury);
    }
    
    function test_SetAeyeosTreasury_RevertNotOwner() public {
        vm.prank(payer);
        vm.expectRevert();
        paymentRouter.setAeyeosTreasury(address(0x999));
    }
    
    // ============ DYNAMIC ROYALTY TESTS ============
    
    // Creator royalty is committed at mint and immutable thereafter. The
    // legacy `updateCreatorRoyalty(uint256,uint256)` selector was removed
    // — every call (creator or not) falls through to the empty fallback
    // and returns false from the low-level call.
    function test_CreatorRoyalty_isImmutablePostMint() public {
        (, uint256 initial) = identityRegistry.getCreatorRoyalty(agentId);
        assertEq(initial, 1000); // committed at mint

        bytes memory call = abi.encodeWithSignature("updateCreatorRoyalty(uint256,uint256)", agentId, 2000);

        vm.prank(creator);
        (bool okCreator,) = address(identityRegistry).call(call);
        vm.prank(payer);
        (bool okStranger,) = address(identityRegistry).call(call);

        assertFalse(okCreator,  "selector should be removed for creator too");
        assertFalse(okStranger, "selector should be removed for non-creator");

        (, uint256 after_) = identityRegistry.getCreatorRoyalty(agentId);
        assertEq(after_, 1000);
    }
}
