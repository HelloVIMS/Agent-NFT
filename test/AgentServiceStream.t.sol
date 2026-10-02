// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgentIdentityRegistry} from "../src/AgentIdentityRegistry.sol";
import {AgentX402Receiver} from "../src/AgentX402Receiver.sol";
import {AgentServiceStream} from "../src/AgentServiceStream.sol";
import {MockUSDC3009} from "./audit/AgentX402Receiver.fuzz.t.sol";

/// Shared deployment: an identity agent with a 30-day streamed service.
abstract contract StreamFixture is Test {
    AgentIdentityRegistry registry;
    AgentX402Receiver x402;
    AgentServiceStream stream;
    MockUSDC3009 usdc;

    address owner = address(0xA11CE);
    address treasury = address(0x7E2A);
    address creator = makeAddr("creator");
    uint256 payerPk = 0xBA5E;
    address payer;
    uint256 agentId;
    bytes32 constant SID = keccak256("kb-access-30d");
    uint256 constant PRICE = 30e6;
    uint32 constant TERM = 30 days;
    uint32 constant MIN_COMMIT = 1 days;

    function _deploy() internal {
        payer = vm.addr(payerPk);
        vm.startPrank(owner);
        registry = AgentIdentityRegistry(address(new ERC1967Proxy(address(new AgentIdentityRegistry()), abi.encodeCall(AgentIdentityRegistry.initialize, ()))));
        x402 = AgentX402Receiver(address(new ERC1967Proxy(address(new AgentX402Receiver()), abi.encodeCall(AgentX402Receiver.initialize, (address(registry), treasury, 50)))));
        stream = AgentServiceStream(address(new ERC1967Proxy(address(new AgentServiceStream()), abi.encodeCall(AgentServiceStream.initialize, (address(x402))))));
        x402.setServiceStream(address(stream));
        vm.stopPrank();
        usdc = new MockUSDC3009();
        vm.prank(owner);
        x402.setTokenAllowed(address(usdc), true);
        vm.startPrank(creator);
        agentId = registry.registerAgent("Streamer", "ipfs://x", 1_000, address(0));
        x402.registerService(agentId, SID, address(usdc), PRICE);
        stream.setTerms(address(registry), agentId, SID, TERM, MIN_COMMIT);
        vm.stopPrank();
        usdc.mint(payer, 1_000_000e6);
    }

    function _open(bytes32 nonce) internal {
        bytes32 digest = x402.hashPaymentCommitment(agentId, SID, address(usdc), PRICE, nonce, type(uint256).max);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(payerPk, digest);
        x402.payForServiceStreamed(address(registry), agentId, SID, payer, 0, type(uint256).max, nonce, 0, 0, 0, cv, cr, cs);
    }

    function _withdrawn(bytes32 id) internal view returns (uint256) {
        return stream.streamOf(id).withdrawn;
    }

    /// What the seller side took in: the creator is the owner here and the
    /// agent has no TBA, so everything not refunded lands with creator or treasury.
    function _sellerTake() internal view returns (uint256) {
        return usdc.balanceOf(creator) + usdc.balanceOf(treasury);
    }
}

contract AgentServiceStreamTest is StreamFixture {
    function setUp() public { _deploy(); }

    function test_vestsPerSecondAndWithdrawsThroughTheSplit() public {
        bytes32 id = keccak256("s1");
        _open(id);
        assertEq(usdc.balanceOf(address(stream)), PRICE, "held");
        vm.warp(block.timestamp + 10 days);
        assertEq(stream.vested(id), PRICE / 3);
        assertEq(_withdrawn(id), 0);
        uint256 paid = stream.withdraw(id);
        assertEq(paid, PRICE / 3);
        assertEq(usdc.balanceOf(treasury), paid * 50 / 10_000, "system fee taken on payout");
        assertEq(usdc.balanceOf(creator), paid - paid * 50 / 10_000);
        vm.expectRevert(AgentServiceStream.NothingToWithdraw.selector);
        stream.withdraw(id);
        vm.warp(block.timestamp + 1);
        assertGt(stream.withdrawable(id), 0, "a second later, more has vested");
    }

    function test_fullTermPaysExactlyTheAmount() public {
        bytes32 id = keccak256("s2");
        _open(id);
        vm.warp(block.timestamp + 7 days + 13);
        stream.withdraw(id);
        vm.warp(block.timestamp + TERM);
        stream.withdraw(id);
        assertEq(_sellerTake(), PRICE);
        assertEq(usdc.balanceOf(address(stream)), 0);
        vm.expectRevert(AgentServiceStream.Expired.selector);
        vm.prank(payer);
        stream.cancel(id);
    }

    function test_buyerCancelRefundsTheUnvestedPart() public {
        bytes32 id = keccak256("s3");
        _open(id);
        vm.warp(block.timestamp + 3 days);
        uint256 before = usdc.balanceOf(payer);
        vm.prank(payer);
        stream.cancel(id);
        assertEq(usdc.balanceOf(payer) - before, PRICE - PRICE / 10, "27 of 30 days back");
        assertEq(_sellerTake(), PRICE / 10, "seller paid the 3 days in the same tx");
        assertEq(usdc.balanceOf(address(stream)), 0);
        vm.prank(payer);
        vm.expectRevert(AgentServiceStream.AlreadyStopped.selector);
        stream.cancel(id);
        vm.warp(block.timestamp + 5 days);
        vm.expectRevert(AgentServiceStream.NothingToWithdraw.selector);
        stream.withdraw(id);
    }

    function test_buyerCancelInsideTheMinimumCommitmentPaysIt() public {
        bytes32 id = keccak256("s4");
        _open(id);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(payer);
        stream.cancel(id);
        assertEq(_sellerTake(), PRICE / 30, "one day: the minimum commitment");
        assertEq(usdc.balanceOf(address(stream)), 0);
    }

    function test_sellerCancelStopsNowWithoutTheMinimum() public {
        bytes32 id = keccak256("s5");
        _open(id);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(creator);
        stream.cancel(id);
        assertEq(_sellerTake(), PRICE / 720, "one hour, no minimum");
        assertEq(usdc.balanceOf(payer), 1_000_000e6 - PRICE / 720);
    }

    function test_onlyThePartiesCancel() public {
        bytes32 id = keccak256("s6");
        _open(id);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(AgentServiceStream.NotParty.selector);
        stream.cancel(id);
    }

    function test_cancelBySigIsTheBuyersCancel() public {
        bytes32 id = keccak256("s7");
        _open(id);
        vm.warp(block.timestamp + 2 days);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, stream.cancelDigest(id, deadline));
        // A guardian submits; the refund still goes to the buyer.
        address guardian = makeAddr("guardian");
        uint256 before = usdc.balanceOf(payer);
        vm.prank(guardian);
        stream.cancelBySig(id, deadline, abi.encodePacked(r, s, v));
        assertEq(usdc.balanceOf(payer) - before, PRICE - PRICE * 2 / 30);
        assertEq(usdc.balanceOf(guardian), 0);
    }

    function test_cancelBySigRejectsForgeriesExpiryAndOtherStreams() public {
        bytes32 id = keccak256("s8");
        bytes32 other = keccak256("s9");
        _open(id);
        _open(other);
        // vm.getBlockTimestamp: under via_ir a block.timestamp local is re-read after vm.warp.
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, stream.cancelDigest(id, deadline));
        vm.expectRevert(AgentServiceStream.InvalidSignature.selector);
        stream.cancelBySig(id, deadline, abi.encodePacked(r, s, v));
        (v, r, s) = vm.sign(payerPk, stream.cancelDigest(other, deadline));
        vm.expectRevert(AgentServiceStream.InvalidSignature.selector);
        stream.cancelBySig(id, deadline, abi.encodePacked(r, s, v));
        (v, r, s) = vm.sign(payerPk, stream.cancelDigest(id, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(AgentServiceStream.Expired.selector);
        stream.cancelBySig(id, deadline, abi.encodePacked(r, s, v));
    }

    function test_termsAreTheOwnersFixedAndBounded() public {
        bytes32 sid2 = keccak256("other");
        vm.prank(payer);
        vm.expectRevert(AgentServiceStream.NotAgentOwner.selector);
        stream.setTerms(address(registry), agentId, sid2, TERM, 0);
        vm.startPrank(creator);
        vm.expectRevert(AgentServiceStream.TermsAlreadySet.selector);
        stream.setTerms(address(registry), agentId, SID, 1 hours, 0);
        vm.expectRevert(AgentServiceStream.InvalidTerms.selector);
        stream.setTerms(address(registry), agentId, sid2, 59 minutes, 0);            // under an hour
        vm.expectRevert(AgentServiceStream.InvalidTerms.selector);
        stream.setTerms(address(registry), agentId, sid2, 2 hours, 13 minutes);      // over a tenth
        vm.expectRevert(AgentServiceStream.InvalidTerms.selector);
        stream.setTerms(address(registry), agentId, sid2, 365 days, 2 days);         // over a day
        stream.setTerms(address(registry), agentId, sid2, 1 hours, 6 minutes);
        vm.stopPrank();
    }

    function test_onlyTheReceiverOpensAndOnlyWithTerms() public {
        vm.expectRevert(AgentServiceStream.NotReceiver.selector);
        stream.open(keccak256("x"), payer, address(registry), agentId, SID, address(usdc), 1);
        bytes32 sid2 = keccak256("no-terms");
        vm.prank(creator);
        x402.registerService(agentId, sid2, address(usdc), PRICE);
        bytes32 digest = x402.hashPaymentCommitment(agentId, sid2, address(usdc), PRICE, keccak256("n"), type(uint256).max);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(payerPk, digest);
        vm.expectRevert(AgentServiceStream.NoTerms.selector);
        x402.payForServiceStreamed(address(registry), agentId, sid2, payer, 0, type(uint256).max, keccak256("n"), 0, 0, 0, cv, cr, cs);
        vm.expectRevert(AgentX402Receiver.NotStream.selector);
        x402.distributeFromStream(address(usdc), 1, address(registry), agentId, SID);
    }

    // Whatever mix of withdrawals and a cancel by either side, at any times,
    // every unit is paid to the seller or refunded to the buyer, once.
    function testFuzz_conserved(uint32 t1, uint32 t2, uint8 action) public {
        bytes32 id = keccak256(abi.encode(t1, t2, action));
        _open(id);
        uint256 start = block.timestamp;
        uint256 payerBefore = usdc.balanceOf(payer);
        vm.warp(start + bound(t1, 0, TERM + 10 days));
        try stream.withdraw(id) {} catch {}
        vm.warp(block.timestamp + bound(t2, 0, TERM));
        if (action % 3 == 1) { vm.prank(payer); try stream.cancel(id) {} catch {} }
        if (action % 3 == 2) { vm.prank(creator); try stream.cancel(id) {} catch {} }
        try stream.withdraw(id) {} catch {}
        vm.warp(start + TERM + 1);
        try stream.withdraw(id) {} catch {}
        uint256 refunded = usdc.balanceOf(payer) - payerBefore;
        assertEq(_sellerTake() + refunded, PRICE, "paid + refunded == amount");
        assertEq(usdc.balanceOf(address(stream)), 0, "nothing stuck after the term");
        assertEq(_withdrawn(id), _sellerTake());
    }

    // The seller is never paid ahead of time: at any moment withdrawn ≤ elapsed share.
    function testFuzz_neverPaidAhead(uint32 at) public {
        bytes32 id = keccak256(abi.encode("ahead", at));
        _open(id);
        uint256 start = block.timestamp;
        uint256 elapsed = bound(at, 0, TERM);
        vm.warp(start + elapsed);
        try stream.withdraw(id) {} catch {}
        assertLe(_withdrawn(id), PRICE * elapsed / TERM);
    }
}

/// Stateful: many streams, random opens, withdrawals, cancels and time.
contract StreamHandler is Test {
    AgentServiceStream stream;
    AgentX402Receiver x402;
    MockUSDC3009 usdc;
    address registry;
    uint256 agentId;
    bytes32 sid;
    uint256 payerPk;
    address creator;
    uint256 price;
    bytes32[] public ids;
    uint256 public opened;

    constructor(AgentServiceStream s, AgentX402Receiver x, MockUSDC3009 u, address reg, uint256 id, bytes32 service, uint256 pk, address c, uint256 p) {
        (stream, x402, usdc, registry, agentId, sid, payerPk, creator, price) = (s, x, u, reg, id, service, pk, c, p);
    }

    function open(uint256 salt) external {
        bytes32 nonce = keccak256(abi.encode(salt, ids.length));
        bytes32 digest = x402.hashPaymentCommitment(agentId, sid, address(usdc), price, nonce, type(uint256).max);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(payerPk, digest);
        x402.payForServiceStreamed(registry, agentId, sid, vm.addr(payerPk), 0, type(uint256).max, nonce, 0, 0, 0, cv, cr, cs);
        ids.push(nonce);
        opened += price;
    }

    function withdraw(uint256 i) external {
        if (ids.length == 0) return;
        try stream.withdraw(ids[i % ids.length]) {} catch {}
    }

    function cancel(uint256 i, bool bySeller) external {
        if (ids.length == 0) return;
        vm.prank(bySeller ? creator : vm.addr(payerPk));
        try stream.cancel(ids[i % ids.length]) {} catch {}
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 5 days));
    }

    function count() external view returns (uint256) { return ids.length; }
}

contract AgentServiceStreamInvariant is StreamFixture {
    StreamHandler handler;
    uint256 payerStart;

    function setUp() public {
        _deploy();
        handler = new StreamHandler(stream, x402, usdc, address(registry), agentId, SID, payerPk, creator, PRICE);
        payerStart = usdc.balanceOf(payer);
        targetContract(address(handler));
    }

    /// Held + paid to the seller side + refunded == everything ever streamed.
    function invariant_fundsConserved() public view {
        uint256 refundedOrUnspent = usdc.balanceOf(payer);
        // Net out of the buyer == still held + paid to the seller side.
        assertEq(payerStart - refundedOrUnspent, usdc.balanceOf(address(stream)) + _sellerTake(), "conservation");
        assertLe(payerStart - refundedOrUnspent, handler.opened(), "never more out than was streamed");
    }

    /// The stream never holds more than what is still unvested-or-unwithdrawn.
    function invariant_holdsExactlyWhatIsOwed() public view {
        uint256 owed;
        for (uint256 i = 0; i < handler.count(); i++) {
            bytes32 id = handler.ids(i);
            AgentServiceStream.Stream memory s = stream.streamOf(id);
            if (s.stoppedAt != 0) continue; // settled at cancel
            owed += s.amount - s.withdrawn;
        }
        assertEq(usdc.balanceOf(address(stream)), owed);
    }
}
