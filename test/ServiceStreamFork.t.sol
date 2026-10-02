// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgentX402Receiver} from "../src/AgentX402Receiver.sol";
import {AgentServiceStream} from "../src/AgentServiceStream.sol";
import {AgentCollectionFactory} from "../src/AgentCollectionFactory.sol";
import {AgentCollectionImpl} from "../src/AgentCollectionImpl.sol";

interface IUSDCStream { function balanceOf(address) external view returns (uint256); }
interface IIdentityStream { function getAgent(uint256) external view returns (string memory, address, uint256, bool, address, address); }

/**
 * The stream rollout against live Base Sepolia, with real USDC:
 *   BASE_SEPOLIA_RPC=https://sepolia.base.org forge test --match-contract ServiceStreamFork -vv
 * - the receiver upgrade keeps immediate payments exactly as quoted;
 * - a streamed service of a collection agent vests, pays out through the
 *   split, and a guardian's signed cancel refunds the buyer the rest.
 */
contract ServiceStreamFork is Test {
    AgentX402Receiver constant RECV = AgentX402Receiver(0xd180DC89270Df505F5d4B7B36e83318f330014A7);
    AgentCollectionFactory constant FACTORY = AgentCollectionFactory(0x6B182188269208533Ed95B7C2b83240f21fA7f12);
    address constant IDENTITY = 0xfE1ef66Ba95891d3cDf6FB83FE1444Bc3bB9FEeF;
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint256 constant BUYER_PK = uint256(keccak256("stream-fork-buyer"));

    function test_rollout() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        address owner = RECV.owner();
        address treasury = RECV.treasury();

        vm.startPrank(owner);
        RECV.upgradeToAndCall(address(new AgentX402Receiver()), "");
        AgentServiceStream stream = AgentServiceStream(address(new ERC1967Proxy(address(new AgentServiceStream()),
            abi.encodeCall(AgentServiceStream.initialize, (address(RECV))))));
        RECV.setServiceStream(address(stream));
        vm.stopPrank();
        address buyer = vm.addr(BUYER_PK);

        // 1. Immediate payment on #241's live service, split as quoted.
        bytes32 sid241 = keccak256("vims-e2e-reason");
        AgentX402Receiver.Service memory svc = RECV.getService(241, sid241);
        require(svc.active, "#241 service inactive on chain");
        deal(USDC, buyer, svc.price);
        (, uint256 sysQ,, uint256 agentQ) = RECV.quoteSplit(241, sid241);
        (, address tba241,,,,) = IIdentityStream(IDENTITY).getAgent(241);
        uint256 tbaBefore = IUSDCStream(USDC).balanceOf(tba241);
        uint256 treasuryBefore = IUSDCStream(USDC).balanceOf(treasury);
        uint256 vb = block.timestamp + 1 hours;
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(BUYER_PK, RECV.hashPaymentCommitment(241, sid241, USDC, svc.price, keccak256("immediate"), vb));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BUYER_PK, _authDigest(buyer, svc.price, vb, keccak256("immediate")));
        RECV.payForService(241, sid241, buyer, 0, vb, keccak256("immediate"), v, r, s, cv, cr, cs);
        assertEq(IUSDCStream(USDC).balanceOf(tba241) - tbaBefore, agentQ, "agent cut as quoted");
        assertEq(IUSDCStream(USDC).balanceOf(treasury) - treasuryBefore, sysQ, "system cut as quoted");

        // 2. A 10-day streamed service of a new collection agent.
        address creator = makeAddr("stream-creator");
        vm.startPrank(creator);
        (, address col) = FACTORY.createCollection("Str", "STR", 5, 500, 500, "");
        uint256 id = AgentCollectionImpl(col).mintAgentWithSVG("Str", "<svg/>", "");
        RECV.selfRegisterCollection(col);
        bytes32 sid = keccak256("access-10d");
        RECV.registerServiceForNFT(col, id, sid, USDC, 1_000_000);
        stream.setTerms(col, id, sid, 10 days, 1 days);
        vm.stopPrank();

        deal(USDC, buyer, 1_000_000);
        bytes32 streamId = keccak256("streamed");
        vb = block.timestamp + 1 hours;
        (cv, cr, cs) = vm.sign(BUYER_PK, RECV.hashPaymentCommitmentForNFT(col, id, sid, USDC, 1_000_000, streamId, vb));
        (v, r, s) = vm.sign(BUYER_PK, _authDigest(buyer, 1_000_000, vb, streamId));
        RECV.payForServiceStreamed(col, id, sid, buyer, 0, vb, streamId, v, r, s, cv, cr, cs);
        assertEq(IUSDCStream(USDC).balanceOf(address(stream)), 1_000_000, "held");

        // 4 days in: the seller withdraws 40%; a guardian cancels for the buyer.
        vm.warp(block.timestamp + 4 days);
        assertEq(stream.withdraw(streamId), 400_000);
        vm.warp(block.timestamp + 1 days);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (v, r, s) = vm.sign(BUYER_PK, stream.cancelDigest(streamId, deadline));
        vm.prank(makeAddr("guardian"));
        stream.cancelBySig(streamId, deadline, abi.encodePacked(r, s, v));
        assertEq(IUSDCStream(USDC).balanceOf(buyer), 500_000, "5 unvested days back");
        assertEq(IUSDCStream(USDC).balanceOf(address(stream)), 0);
    }

    function _authDigest(address from, uint256 value, uint256 validBefore, bytes32 nonce) internal view returns (bytes32) {
        (bool ok, bytes memory out) = USDC.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        require(ok, "domain");
        bytes32 typehash = keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");
        bytes32 structHash = keccak256(abi.encode(typehash, from, address(RECV), value, uint256(0), validBefore, nonce));
        return keccak256(abi.encodePacked("\x19\x01", abi.decode(out, (bytes32)), structHash));
    }
}
