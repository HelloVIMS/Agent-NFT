// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentReputationRegistry} from "../src/AgentReputationRegistry.sol";
import {AgentX402Receiver} from "../src/AgentX402Receiver.sol";
import {AgentCollectionFactory} from "../src/AgentCollectionFactory.sol";
import {AgentCollectionImpl} from "../src/AgentCollectionImpl.sol";

interface IUSDCFork { function balanceOf(address) external view returns (uint256); }

/**
 * Upgrades the live reputation registry and receiver in a fork: agent #241's
 * reputation reads back identically, then a new collection agent is hired
 * with real USDC through the NFT path and its buyer rates it.
 *   BASE_SEPOLIA_RPC=https://sepolia.base.org forge test --match-contract ReputationV3UpgradeFork -vv
 */
contract ReputationV3UpgradeFork is Test {
    AgentReputationRegistry constant REP = AgentReputationRegistry(0x5563EE2939F6839CE82B3cA6E50AA285e8d1C316);
    AgentX402Receiver constant RECV = AgentX402Receiver(0xd180DC89270Df505F5d4B7B36e83318f330014A7);
    AgentCollectionFactory constant FACTORY = AgentCollectionFactory(0x6B182188269208533Ed95B7C2b83240f21fA7f12);
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    // Base Sepolia USDC's EIP-3009 domain is checked on-chain, so the buyer
    // signs for real: the deal() below funds that key's address.
    uint256 constant BUYER_PK = uint256(keccak256("rep-v3-fork-buyer"));

    function test_upgradeKeepsReputationAndRatesCollectionAgents() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        uint256 n = REP.eraCount(241);
        bytes memory before = _snapshot(n);

        address owner = REP.owner();
        AgentReputationRegistry repImpl = new AgentReputationRegistry();
        AgentX402Receiver recvImpl = new AgentX402Receiver();
        vm.startPrank(owner);
        REP.upgradeToAndCall(address(repImpl), "");
        RECV.upgradeToAndCall(address(recvImpl), "");
        vm.stopPrank();
        assertEq(keccak256(_snapshot(n)), keccak256(before), "#241 unchanged");

        // A new collection agent with a priced service.
        address creator = makeAddr("fork-creator");
        vm.startPrank(creator);
        (, address col) = FACTORY.createCollection("Fork", "FRK", 5, 500, 500, "");
        uint256 id = AgentCollectionImpl(col).mintAgentWithSVG("Fork", "<svg/>", "");
        RECV.selfRegisterCollection(col);
        bytes32 sid = keccak256("fork-read");
        RECV.registerServiceForNFT(col, id, sid, USDC, 10_000);
        vm.stopPrank();

        address buyer = vm.addr(BUYER_PK);
        deal(USDC, buyer, 10_000);
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("fork-nonce");
        bytes32 commit = RECV.hashPaymentCommitmentForNFT(col, id, sid, USDC, 10_000, nonce, validBefore);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(BUYER_PK, commit);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BUYER_PK, _authDigest(buyer, 10_000, validBefore, nonce));
        RECV.payForServiceForNFT(col, id, sid, buyer, 0, validBefore, nonce, v, r, s, cv, cr, cs);
        assertEq(IUSDCFork(USDC).balanceOf(buyer), 0, "paid");

        uint256 ref = REP.refOf(col, id);
        assertEq(REP.eraStats(ref, 0).settlements, 1, "collection hire recorded");
        vm.prank(buyer);
        REP.giveFeedback(ref, 1, 0, "x402", "fork-read", "");
        assertEq(REP.eraStats(ref, 0).feedbackCount, 1, "buyer rated");
    }

    function _snapshot(uint256 n) internal view returns (bytes memory) {
        (uint256 total, int256 avg, uint256 recent) = REP.getReputationSummary(241);
        return abi.encode(REP.eraCount(241), REP.currentEra(241), REP.eraStats(241, n - 1), total, avg, recent);
    }

    function _authDigest(address from, uint256 value, uint256 validBefore, bytes32 nonce) internal view returns (bytes32) {
        (bool ok, bytes memory out) = USDC.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        require(ok, "domain");
        bytes32 typehash = keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");
        bytes32 structHash = keccak256(abi.encode(typehash, from, address(RECV), value, uint256(0), validBefore, nonce));
        return keccak256(abi.encodePacked("\x19\x01", abi.decode(out, (bytes32)), structHash));
    }
}
