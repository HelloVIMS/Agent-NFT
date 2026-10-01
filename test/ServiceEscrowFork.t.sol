// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgentX402Receiver} from "../src/AgentX402Receiver.sol";
import {AgentServiceEscrow} from "../src/AgentServiceEscrow.sol";
import {AgentCollectionFactory} from "../src/AgentCollectionFactory.sol";
import {AgentCollectionImpl} from "../src/AgentCollectionImpl.sol";

interface IUSDCEsc { function balanceOf(address) external view returns (uint256); }
interface IIdentityEsc { function getAgent(uint256) external view returns (string memory, address, uint256, bool, address, address); }

/**
 * The escrow rollout against live Base Sepolia, with real USDC:
 *   BASE_SEPOLIA_RPC=https://sepolia.base.org forge test --match-contract ServiceEscrowFork -vv
 * - the receiver upgrade keeps immediate payments working (#241's live
 *   service settles exactly as before, split included);
 * - an escrowed access service of a collection agent is paid, released by
 *   a 2-of-3 watcher quorum, and its downtime refunded at close.
 */
contract ServiceEscrowFork is Test {
    AgentX402Receiver constant RECV = AgentX402Receiver(0xd180DC89270Df505F5d4B7B36e83318f330014A7);
    AgentCollectionFactory constant FACTORY = AgentCollectionFactory(0x6B182188269208533Ed95B7C2b83240f21fA7f12);
    address constant IDENTITY = 0xfE1ef66Ba95891d3cDf6FB83FE1444Bc3bB9FEeF;
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint256 constant BUYER_PK = uint256(keccak256("escrow-fork-buyer"));
    uint256[3] W = [uint256(keccak256("w1")), uint256(keccak256("w2")), uint256(keccak256("w3"))];

    function test_rollout() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        address owner = RECV.owner();
        address treasury = RECV.treasury();

        vm.startPrank(owner);
        RECV.upgradeToAndCall(address(new AgentX402Receiver()), "");
        AgentServiceEscrow escrow = AgentServiceEscrow(address(new ERC1967Proxy(address(new AgentServiceEscrow()),
            abi.encodeCall(AgentServiceEscrow.initialize, (address(RECV), 48 hours)))));
        RECV.setServiceEscrow(address(escrow));
        address[] memory ws = new address[](3);
        for (uint256 i = 0; i < 3; i++) ws[i] = vm.addr(W[i]);
        escrow.addWatcherSet(ws, 2);
        vm.stopPrank();

        address buyer = vm.addr(BUYER_PK);

        // 1. Immediate payment on #241's live service, through the refactored split.
        bytes32 sid241 = keccak256("vims-e2e-reason");
        AgentX402Receiver.Service memory svc = RECV.getService(241, sid241);
        require(svc.active, "#241 service inactive on chain");
        deal(USDC, buyer, svc.price);
        (uint256 sysQ,,uint256 agentQ,address recipient) = _quote(241, sid241);
        uint256 recipientBefore = IUSDCEsc(USDC).balanceOf(recipient);
        uint256 treasuryBefore = IUSDCEsc(USDC).balanceOf(treasury);
        _payIdentity(241, sid241, svc.price, keccak256("immediate"));
        assertEq(IUSDCEsc(USDC).balanceOf(recipient) - recipientBefore, agentQ, "agent cut as quoted");
        assertEq(IUSDCEsc(USDC).balanceOf(treasury) - treasuryBefore, sysQ, "system cut as quoted");

        // 2. Escrowed access service of a new collection agent: 24 hourly epochs.
        address creator = makeAddr("escrow-creator");
        vm.startPrank(creator);
        (, address col) = FACTORY.createCollection("Esc", "ESC", 5, 500, 500, "");
        uint256 id = AgentCollectionImpl(col).mintAgentWithSVG("Esc", "<svg/>", "");
        RECV.selfRegisterCollection(col);
        bytes32 sid = keccak256("access-24h");
        RECV.registerServiceForNFT(col, id, sid, USDC, 240_000);
        escrow.setTerms(col, id, sid, 24, 1 hours, 100);
        vm.stopPrank();

        deal(USDC, buyer, 240_000);
        bytes32 escrowId = keccak256("escrowed");
        uint256 validBefore = block.timestamp + 1 hours;
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(BUYER_PK, RECV.hashPaymentCommitmentForNFT(col, id, sid, USDC, 240_000, escrowId, validBefore));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BUYER_PK, _authDigest(buyer, 240_000, validBefore, escrowId));
        RECV.payForServiceEscrowed(col, id, sid, buyer, 0, validBefore, escrowId, v, r, s, cv, cr, cs);
        assertEq(IUSDCEsc(USDC).balanceOf(address(escrow)), 240_000, "held");

        // Up 20 of 24 hours by a 2-of-3 quorum; the third watcher disagrees.
        vm.warp(block.timestamp + 24 hours);
        uint256 up = ((1 << 24) - 1) & ~uint256(0xF0); // hours 4-7 down
        uint256[] memory bits = new uint256[](2);
        bits[0] = up; bits[1] = up;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _report(W[0], escrow, escrowId, up);
        sigs[1] = _report(W[2], escrow, escrowId, up);
        uint256 released = escrow.claim(escrowId, 0, 24, bits, sigs);
        assertEq(released, 20 * 10_000);

        vm.warp(block.timestamp + 48 hours + 1);
        uint256 refunded = escrow.close(escrowId);
        assertEq(refunded, 4 * 10_000, "SLA 1% of 24 floors to 0 epochs: all 4 down hours refunded");
        assertEq(IUSDCEsc(USDC).balanceOf(buyer), refunded);
        assertEq(IUSDCEsc(USDC).balanceOf(address(escrow)), 0);
    }

    function _quote(uint256 agentId, bytes32 sid) internal view returns (uint256 sys, uint256 cre, uint256 agent, address recipient) {
        (, sys, cre, agent) = RECV.quoteSplit(agentId, sid);
        (, recipient,,,,) = IIdentityEsc(IDENTITY).getAgent(agentId); // #241 has a TBA
    }

    function _payIdentity(uint256 agentId, bytes32 sid, uint256 price, bytes32 nonce) internal {
        address buyer = vm.addr(BUYER_PK);
        uint256 validBefore = block.timestamp + 1 hours;
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(BUYER_PK, RECV.hashPaymentCommitment(agentId, sid, USDC, price, nonce, validBefore));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BUYER_PK, _authDigest(buyer, price, validBefore, nonce));
        RECV.payForService(agentId, sid, buyer, 0, validBefore, nonce, v, r, s, cv, cr, cs);
    }

    function _report(uint256 pk, AgentServiceEscrow escrow, bytes32 id, uint256 bitmap) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, escrow.uptimeDigest(id, 0, 24, bitmap));
        return abi.encodePacked(r, s, v);
    }

    function _authDigest(address from, uint256 value, uint256 validBefore, bytes32 nonce) internal view returns (bytes32) {
        (bool ok, bytes memory out) = USDC.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        require(ok, "domain");
        bytes32 typehash = keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");
        bytes32 structHash = keccak256(abi.encode(typehash, from, address(RECV), value, uint256(0), validBefore, nonce));
        return keccak256(abi.encodePacked("\x19\x01", abi.decode(out, (bytes32)), structHash));
    }
}
