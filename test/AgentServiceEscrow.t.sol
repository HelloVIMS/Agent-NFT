// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgentIdentityRegistry} from "../src/AgentIdentityRegistry.sol";
import {AgentX402Receiver} from "../src/AgentX402Receiver.sol";
import {AgentServiceEscrow} from "../src/AgentServiceEscrow.sol";
import {MockUSDC3009} from "./audit/AgentX402Receiver.fuzz.t.sol";

/// Escrowed access services: paid through the receiver, released by
/// watcher quorum, refunded at close. claimed + refunded + held == funded.
contract AgentServiceEscrowTest is Test {
    AgentIdentityRegistry registry;
    AgentX402Receiver x402;
    AgentServiceEscrow escrow;
    MockUSDC3009 usdc;

    address owner = address(0xA11CE);
    address treasury = address(0x7E2A);
    address creator = makeAddr("creator");
    uint256 payerPk = 0xBA5E;
    address payer;
    uint256[3] watcherPks = [uint256(0x1001), 0x1002, 0x1003];
    address[] watchers;

    uint256 agentId;
    address tba;
    bytes32 constant SID = keccak256("kb-access");
    uint256 constant PRICE = 300e6;
    uint32 constant TERM = 30;        // epochs
    uint32 constant EPOCH = 1 hours;
    uint16 constant SLA = 500;        // 5%: 1 epoch of 30 forgiven
    uint64 constant WINDOW = 2 days;

    function setUp() public {
        payer = vm.addr(payerPk);
        for (uint256 i = 0; i < 3; i++) watchers.push(vm.addr(watcherPks[i]));
        vm.startPrank(owner);
        registry = AgentIdentityRegistry(address(new ERC1967Proxy(address(new AgentIdentityRegistry()), abi.encodeCall(AgentIdentityRegistry.initialize, ()))));
        x402 = AgentX402Receiver(address(new ERC1967Proxy(address(new AgentX402Receiver()), abi.encodeCall(AgentX402Receiver.initialize, (address(registry), treasury, 50)))));
        escrow = AgentServiceEscrow(address(new ERC1967Proxy(address(new AgentServiceEscrow()), abi.encodeCall(AgentServiceEscrow.initialize, (address(x402), WINDOW)))));
        x402.setServiceEscrow(address(escrow));
        escrow.addWatcherSet(watchers, 2);
        vm.stopPrank();
        usdc = new MockUSDC3009();
        vm.prank(owner);
        x402.setTokenAllowed(address(usdc), true);
        vm.startPrank(creator);
        agentId = registry.registerAgent("Access", "ipfs://x", 1_000, address(0));
        x402.registerService(agentId, SID, address(usdc), PRICE);
        escrow.setTerms(address(registry), agentId, SID, TERM, EPOCH, SLA);
        vm.stopPrank();
        usdc.mint(payer, 1_000_000e6);
    }

    function _pay(bytes32 nonce) internal {
        bytes32 digest = x402.hashPaymentCommitment(agentId, SID, address(usdc), PRICE, nonce, type(uint256).max);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(payerPk, digest);
        x402.payForServiceEscrowed(address(registry), agentId, SID, payer, 0, type(uint256).max, nonce, 0, 0, 0, cv, cr, cs);
    }

    function _report(uint256 pk, bytes32 id, uint32 from, uint32 count, uint256 bitmap) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, escrow.uptimeDigest(id, from, count, bitmap));
        return abi.encodePacked(r, s, v);
    }

    function _claim(bytes32 id, uint32 from, uint32 count, uint256[] memory bits, uint256[] memory pks) internal returns (uint256) {
        bytes[] memory sigs = new bytes[](bits.length);
        for (uint256 i = 0; i < bits.length; i++) sigs[i] = _report(pks[i], id, from, count, bits[i]);
        return escrow.claim(id, from, count, bits, sigs);
    }

    function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory x) { x = new uint256[](2); x[0] = a; x[1] = b; }

    function _sellerTake() internal view returns (uint256) {
        // The creator is also the owner here, and the agent has no TBA.
        return usdc.balanceOf(creator) + usdc.balanceOf(treasury);
    }

    function test_fullUptimeReleasesEverythingThroughTheSplit() public {
        bytes32 id = keccak256("job-1");
        _pay(id);
        assertEq(usdc.balanceOf(address(escrow)), PRICE, "held in escrow");
        vm.warp(block.timestamp + uint256(TERM) * EPOCH);
        uint256 all = (1 << TERM) - 1;
        uint256 released = _claim(id, 0, TERM, _two(all, all), _two(watcherPks[0], watcherPks[1]));
        assertEq(released, PRICE);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(treasury), PRICE * 50 / 10_000, "system fee");
        assertEq(usdc.balanceOf(creator), PRICE - PRICE * 50 / 10_000, "creator (owner, no TBA) gets royalty + agent share");
        vm.warp(block.timestamp + WINDOW + 1);
        assertEq(escrow.close(id), 0, "nothing to refund");
    }

    function test_downtimeIsRefundedLessTheSLA() public {
        bytes32 id = keccak256("job-2");
        _pay(id);
        vm.warp(block.timestamp + uint256(TERM) * EPOCH);
        // Up for 27 of 30 epochs (3 down: 6, 7, 8).
        uint256 up = ((1 << TERM) - 1) & ~uint256(0x1C0);
        _claim(id, 0, TERM, _two(up, up), _two(watcherPks[0], watcherPks[2]));
        uint256 base = PRICE / TERM;
        assertEq(escrow.escrowOf(id).released, 27 * base);
        vm.warp(block.timestamp + WINDOW + 1);
        uint256 before = usdc.balanceOf(payer);
        uint256 refunded = escrow.close(id);
        // SLA forgives 1 epoch (5% of 30, floored): 2 refunded.
        assertEq(refunded, 2 * base);
        assertEq(usdc.balanceOf(payer) - before, 2 * base);
        assertEq(escrow.escrowOf(id).released + refunded, PRICE, "conserved");
    }

    function test_epochNeedsAMajorityOfDistinctWatchers() public {
        bytes32 id = keccak256("job-3");
        _pay(id);
        vm.warp(block.timestamp + 2 * EPOCH);
        // Watcher 0 says both up, watcher 1 only epoch 0: epoch 1 lacks quorum.
        uint256 released = _claim(id, 0, 2, _two(3, 1), _two(watcherPks[0], watcherPks[1]));
        assertEq(released, PRICE / TERM);
        assertFalse(escrow.isClaimed(id, 1));
        // The same watcher twice doesn't make a quorum.
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _report(watcherPks[0], id, 1, 1, 1);
        sigs[1] = _report(watcherPks[0], id, 1, 1, 1);
        vm.expectRevert(AgentServiceEscrow.InvalidClaim.selector);
        escrow.claim(id, 1, 1, _two(1, 1), sigs);
        // Nor does an outsider.
        sigs[1] = _report(0xBAD, id, 1, 1, 1);
        vm.expectRevert(AgentServiceEscrow.InvalidClaim.selector);
        escrow.claim(id, 1, 1, _two(1, 1), sigs);
        // A report for another escrow doesn't verify here.
        sigs[1] = _report(watcherPks[1], keccak256("other"), 1, 1, 1);
        vm.expectRevert(AgentServiceEscrow.InvalidClaim.selector);
        escrow.claim(id, 1, 1, _two(1, 1), sigs);
    }

    function test_timing() public {
        bytes32 id = keccak256("job-4");
        _pay(id);
        uint256[] memory pks = _two(watcherPks[0], watcherPks[1]);
        // An epoch can't be claimed before it ends.
        vm.expectRevert(AgentServiceEscrow.TooEarly.selector);
        this.claimFor(id, 0, 1, pks);
        vm.warp(block.timestamp + EPOCH);
        this.claimFor(id, 0, 1, pks);
        // Claiming it again releases nothing.
        vm.expectRevert(AgentServiceEscrow.InvalidClaim.selector);
        this.claimFor(id, 0, 1, pks);
        // Close waits for the term plus the claim window.
        vm.expectRevert(AgentServiceEscrow.TooEarly.selector);
        escrow.close(id);
        vm.warp(block.timestamp + uint256(TERM) * EPOCH + WINDOW + 1);
        vm.expectRevert(AgentServiceEscrow.ClaimWindowOver.selector);
        this.claimFor(id, 1, 1, pks);
        escrow.close(id);
        vm.expectRevert(AgentServiceEscrow.AlreadyClosed.selector);
        escrow.close(id);
        vm.expectRevert(AgentServiceEscrow.AlreadyClosed.selector);
        this.claimFor(id, 2, 1, pks);
    }

    function claimFor(bytes32 id, uint32 from, uint32 count, uint256[] calldata pks) external returns (uint256) {
        uint256 all = (count == 256) ? type(uint256).max : (1 << count) - 1;
        return _claim(id, from, count, _two(all, all), pks);
    }

    function test_termsAreTheOwnersAndFixed() public {
        bytes32 sid2 = keccak256("other");
        vm.prank(payer);
        vm.expectRevert(AgentServiceEscrow.NotAgentOwner.selector);
        escrow.setTerms(address(registry), agentId, sid2, 10, EPOCH, 0);
        vm.prank(creator);
        vm.expectRevert(AgentServiceEscrow.TermsAlreadySet.selector);
        escrow.setTerms(address(registry), agentId, SID, 1, EPOCH, 0);
        vm.startPrank(creator);
        vm.expectRevert(AgentServiceEscrow.InvalidTerms.selector);
        escrow.setTerms(address(registry), agentId, sid2, 10, 60, 0); // epoch too short
        vm.expectRevert(AgentServiceEscrow.InvalidTerms.selector);
        escrow.setTerms(address(registry), agentId, sid2, 10, EPOCH, 501); // SLA above 5%
        vm.stopPrank();
    }

    function test_onlyTheReceiverOpensAndOnlyWithTerms() public {
        vm.expectRevert(AgentServiceEscrow.NotReceiver.selector);
        escrow.open(keccak256("x"), payer, address(registry), agentId, SID, address(usdc), 1);
        bytes32 sid2 = keccak256("no-terms");
        vm.prank(creator);
        x402.registerService(agentId, sid2, address(usdc), PRICE);
        bytes32 digest = x402.hashPaymentCommitment(agentId, sid2, address(usdc), PRICE, keccak256("n"), type(uint256).max);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(payerPk, digest);
        vm.expectRevert(AgentServiceEscrow.NoTerms.selector);
        x402.payForServiceEscrowed(address(registry), agentId, sid2, payer, 0, type(uint256).max, keccak256("n"), 0, 0, 0, cv, cr, cs);
        vm.expectRevert(AgentX402Receiver.NotEscrow.selector);
        x402.distributeFromEscrow(address(usdc), 1, address(registry), agentId, SID);
    }

    function test_watcherSetsNeedAStrictMajority() public {
        vm.startPrank(owner);
        vm.expectRevert(AgentServiceEscrow.InvalidWatcherSet.selector);
        escrow.addWatcherSet(watchers, 1); // 1 of 3
        address[] memory dup = new address[](2);
        dup[0] = watchers[0]; dup[1] = watchers[0];
        vm.expectRevert(AgentServiceEscrow.InvalidWatcherSet.selector);
        escrow.addWatcherSet(dup, 2);
        vm.stopPrank();
    }

    // Whatever mix of claims happens, every unit is released or refunded, once.
    function testFuzz_fundsConserved(uint256 upA, uint256 upB, uint8 claimAt) public {
        bytes32 id = keccak256(abi.encode(upA, upB));
        _pay(id);
        uint256 mask = (1 << TERM) - 1;
        upA &= mask; upB &= mask;
        uint32 count = uint32(bound(claimAt, 1, TERM));
        vm.warp(block.timestamp + uint256(TERM) * EPOCH);
        uint256 sellerBefore = _sellerTake();
        try this.claimWith(id, count, upA & ((1 << count) - 1), upB & ((1 << count) - 1)) {} catch {}
        vm.warp(block.timestamp + WINDOW + 1);
        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 refunded = escrow.close(id);
        AgentServiceEscrow.Escrow memory e = escrow.escrowOf(id);
        assertEq(e.released + refunded, PRICE, "released + refunded == funded");
        assertEq(usdc.balanceOf(payer) - payerBefore, refunded);
        assertEq(_sellerTake() - sellerBefore, e.released, "released went through the split");
        assertEq(usdc.balanceOf(address(escrow)), 0, "nothing stuck");
    }

    function claimWith(bytes32 id, uint32 count, uint256 a, uint256 b) external {
        _claim(id, 0, count, _two(a, b), _two(watcherPks[0], watcherPks[1]));
    }
}
