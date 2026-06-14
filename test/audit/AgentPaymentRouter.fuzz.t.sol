// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AgentIdentityRegistry} from "../../src/AgentIdentityRegistry.sol";
import {AgentPaymentRouter}    from "../../src/AgentPaymentRouter.sol";

contract MockUSDC6 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @notice Fuzz/property tests for AgentPaymentRouter that cover:
///   * Conservation across all paid rails (ETH + USDC):
///       payment == systemCut + creatorCut + recipientCut
///       and the router holds zero net balance after the call.
///   * System-fee invariant: cut == floor(amount * 50 / 10_000).
///   * Creator-royalty invariant:
///       creatorCut == floor((amount - systemCut) * royaltyBps / 10_000)
///   * Cross-rail parity: ETH and USDC of the same nominal amount split
///       into the same per-leg slices.
///   * Exemption path: payAgentExempt routes 100% to the recipient and
///       collects ZERO system / creator royalty.
contract AgentPaymentRouterFuzz is Test {
    AgentIdentityRegistry internal identity;
    AgentPaymentRouter    internal router;
    MockUSDC6             internal usdc;

    address internal creator   = address(0xC1);
    address internal payer     = address(0xD1);
    address internal treasury  = address(0xE1);

    uint256 internal agentId;

    uint256 internal constant SYSTEM_BPS = 50; // 0.5%

    function setUp() public {
        AgentIdentityRegistry impl = new AgentIdentityRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identity = AgentIdentityRegistry(address(proxy));
        usdc     = new MockUSDC6();
        router   = new AgentPaymentRouter(address(identity), address(usdc), treasury);

        // Pin auto-transfer thresholds to 1 so creator royalty is forwarded
        // synchronously instead of accumulating in pendingRoyalties; this
        // matches the conservation property we want to fuzz.
        router.setMinAutoTransferETH(1);
        router.setMinAutoTransferUSDC(1);

        vm.prank(creator);
        agentId  = identity.registerAgent("FuzzBot", "ipfs://fuzz", 1_000, address(0));

        vm.deal(payer, 1_000_000 ether);
        usdc.mint(payer, 1_000_000_000 * 1e6);
        vm.prank(payer);
        usdc.approve(address(router), type(uint256).max);
    }

    function _splitMath(uint256 amount, uint256 royaltyBps)
        internal
        pure
        returns (uint256 systemCut, uint256 creatorCut, uint256 recipientCut)
    {
        systemCut    = (amount * SYSTEM_BPS) / 10_000;
        uint256 afterSystem = amount - systemCut;
        creatorCut   = (afterSystem * royaltyBps) / 10_000;
        recipientCut = afterSystem - creatorCut;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Conservation: ETH rail. The full amount must be partitioned with
    // zero locked in the router.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_PayAgentETH_Conservation(uint96 amount) public {
        amount = uint96(bound(uint256(amount), 1e6, 1_000 ether));

        (uint256 sysExp, uint256 creatorExp, uint256 recipExp) = _splitMath(amount, 1_000);

        // System royalty pools inside the router (treasury withdraws in
        // batches), so we audit `pendingSystemRoyalties[token]` and the
        // router's net balance, NOT the treasury EOA.
        uint256 sysPendingBefore = router.pendingSystemRoyalties(address(0));
        uint256 crBefore         = creator.balance;
        uint256 routerBefore     = address(router).balance;

        vm.prank(payer);
        router.payAgent{value: amount}(agentId);

        uint256 sysPending   = router.pendingSystemRoyalties(address(0)) - sysPendingBefore;
        uint256 creatorTotal = creator.balance - crBefore;
        uint256 routerAfter  = address(router).balance;

        assertEq(sysPending,   sysExp, "system cut drift");
        assertEq(creatorTotal, creatorExp + recipExp, "creator+recipient drift (same address)");
        assertEq(routerAfter - routerBefore, sysExp, "router net balance != pooled system cut");
        assertEq(sysPending + creatorTotal, uint256(amount), "leakage");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Conservation: USDC rail.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_PayAgentUSDC_Conservation(uint96 amount) public {
        amount = uint96(bound(uint256(amount), 1e3, 1_000_000 * 1e6));

        (uint256 sysExp, uint256 creatorExp, uint256 recipExp) = _splitMath(amount, 1_000);

        uint256 sysPendingBefore = router.pendingSystemRoyalties(address(usdc));
        uint256 crBefore         = usdc.balanceOf(creator);
        uint256 routerBefore     = usdc.balanceOf(address(router));

        vm.prank(payer);
        router.payAgentUSDC(agentId, amount);

        uint256 sysPending   = router.pendingSystemRoyalties(address(usdc)) - sysPendingBefore;
        uint256 creatorTotal = usdc.balanceOf(creator) - crBefore;
        uint256 routerAfter  = usdc.balanceOf(address(router));

        assertEq(sysPending,   sysExp, "USDC system cut drift");
        assertEq(creatorTotal, creatorExp + recipExp, "USDC creator+recipient drift");
        assertEq(routerAfter - routerBefore, sysExp, "router USDC pool != system cut");
        assertEq(sysPending + creatorTotal, uint256(amount), "USDC leakage");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Cross-rail parity: ETH and USDC of equal nominal value yield equal
    // per-leg slices (treasuries / creators do not see different math).
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_EthUsdcRailParity(uint96 amount) public {
        amount = uint96(bound(uint256(amount), 1e6, 1_000_000 * 1e6));

        // Snapshot baselines.
        uint256 ethSysBefore  = router.pendingSystemRoyalties(address(0));
        uint256 crEthBefore   = creator.balance;
        uint256 usdcSysBefore = router.pendingSystemRoyalties(address(usdc));
        uint256 crUsdcBefore  = usdc.balanceOf(creator);

        vm.prank(payer);
        router.payAgent{value: amount}(agentId);

        vm.prank(payer);
        router.payAgentUSDC(agentId, amount);

        uint256 ethSys           = router.pendingSystemRoyalties(address(0)) - ethSysBefore;
        uint256 usdcSys          = router.pendingSystemRoyalties(address(usdc)) - usdcSysBefore;
        uint256 ethCreatorTotal  = creator.balance - crEthBefore;
        uint256 usdcCreatorTotal = usdc.balanceOf(creator) - crUsdcBefore;

        assertEq(ethSys, usdcSys, "system cut differs across rails");
        assertEq(ethCreatorTotal, usdcCreatorTotal, "creator total differs across rails");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Royalty-bound invariant: creator cut never exceeds royaltyBps share
    // of the after-system remainder, regardless of bps in [0..5000].
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_CreatorRoyaltyBounded(uint16 royaltyBps, uint96 amount) public {
        // 0% to 50% is the legal range of registerAgent.
        royaltyBps = uint16(bound(royaltyBps, 0, 5_000));
        amount     = uint96(bound(uint256(amount), 1e6, 100 ether));

        // Register a fresh agent at the chosen bps.
        vm.prank(creator);
        uint256 id = identity.registerAgent("FuzzBot2", "ipfs://x", royaltyBps, address(0));

        (uint256 sysExp, uint256 creatorExp, uint256 recipExp) = _splitMath(amount, royaltyBps);

        uint256 sysBefore = router.pendingSystemRoyalties(address(0));
        uint256 crBefore  = creator.balance;

        vm.prank(payer);
        router.payAgent{value: amount}(id);

        assertEq(router.pendingSystemRoyalties(address(0)) - sysBefore, sysExp, "system");
        assertEq(creator.balance  - crBefore, creatorExp + recipExp, "creator+recipient");
        assertLe(creatorExp, (uint256(amount) - sysExp) * royaltyBps / 10_000, "creator > bps share");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Exemption path: a whitelisted operational sender pays 100% of the
    // amount to the recipient — no system cut, no creator royalty.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_ExemptPath_NoRoyalty(uint96 amount) public {
        amount = uint96(bound(uint256(amount), 1e6, 100 ether));

        address exemptPayer = address(0xEEEE);
        vm.prank(creator);
        router.addToCreatorWhitelist(agentId, exemptPayer);
        assertTrue(router.isExempt(agentId, exemptPayer));

        vm.deal(exemptPayer, uint256(amount));
        uint256 sysBefore = router.pendingSystemRoyalties(address(0));
        uint256 crBefore  = creator.balance;

        vm.prank(exemptPayer);
        router.payAgentExempt{value: amount}(agentId);

        assertEq(router.pendingSystemRoyalties(address(0)), sysBefore, "exempt path pooled system fee");
        assertEq(creator.balance - crBefore, uint256(amount), "exempt path did not pay full amount");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Differential: paying via the exempt rail vs the standard rail must
    // ALWAYS leave the recipient with strictly more (or equal in the
    // royaltyBps=0 + system=0 corner case, which can't happen here since
    // SYSTEM_BPS is hard-coded at 50).
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_ExemptStrictlyBetterForRecipient(uint96 amount) public {
        amount = uint96(bound(uint256(amount), 1e6, 100 ether));

        address exemptPayer = address(0xEEEE);
        vm.prank(creator);
        router.addToCreatorWhitelist(agentId, exemptPayer);

        // Standard rail.
        uint256 stdBefore = creator.balance;
        vm.prank(payer);
        router.payAgent{value: amount}(agentId);
        uint256 stdGain = creator.balance - stdBefore;

        // Exempt rail — same nominal.
        vm.deal(exemptPayer, uint256(amount));
        uint256 exBefore = creator.balance;
        vm.prank(exemptPayer);
        router.payAgentExempt{value: amount}(agentId);
        uint256 exGain = creator.balance - exBefore;

        assertGt(exGain, stdGain, "exempt rail did not beat standard rail");
        assertEq(exGain, uint256(amount), "exempt rail did not deliver 100%");
        assertEq(stdGain, uint256(amount) - (uint256(amount) * SYSTEM_BPS) / 10_000, "standard rail wrong");
    }
}
