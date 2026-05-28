// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentCollectionFactory.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentX402Receiver.sol";

/**
 * @title  E2EMintCollectionFullStack
 * @notice On-testnet validation of the V3 atomic-mint flow.
 *
 *         Steps in one broadcast:
 *           1. {AgentCollectionFactory.createCollection}
 *           2. Wire collection on receiver via `selfRegisterCollection`
 *              (permissionless; gated by collectionCreator()).
 *           3. Call {AgentCollectionImpl.mintAgentWithFullStack}.
 *           4. Read back: ownerOf(1), tbaOf(1),
 *              receiver.getServiceForNFT(collection, 1, sid),
 *              collection.serviceRoyaltyOf(1).
 *
 *         Required env:
 *           DEPLOYER_PRIVATE_KEY  — must be receiver owner + sender
 *           USDC                  — payment token (Base Sepolia: 0x036C...)
 *
 *         Run:
 *           forge script script/E2EMintCollectionFullStack.s.sol \
 *             --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --skip-simulation
 */
contract E2EMintCollectionFullStackScript is Script {
    address constant FACTORY  = 0x6B182188269208533Ed95B7C2b83240f21fA7f12;
    address constant RECEIVER = 0xd180DC89270Df505F5d4B7B36e83318f330014A7;

    function run() external {
        uint256 pk     = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address usdc   = vm.envAddress("USDC");
        address sender = vm.addr(pk);

        AgentCollectionFactory factory  = AgentCollectionFactory(FACTORY);
        AgentX402Receiver      receiver = AgentX402Receiver(RECEIVER);

        bytes32 sid = keccak256("api/chat/v1");
        uint256 price = 100_000; // 0.1 USDC at 6 decimals

        vm.startBroadcast(pk);

        (, address coll) = factory.createCollection(
            "E2E V3 Coll", "E2E", 5, 1000, 1000, "v3 atomic mint smoke"
        );
        console.log("Collection:", coll);

        receiver.selfRegisterCollection(coll);

        AgentCollectionImpl c = AgentCollectionImpl(coll);
        (uint256 agentId, address tba) = c.mintAgentWithFullStack(
            "E2E Agent #1", "ipfs://e2e/1.json", bytes32(0), sid, usdc, price
        );
        console.log("agentId:", agentId);
        console.log("tba    :", tba);

        vm.stopBroadcast();

        require(c.ownerOf(agentId) == sender, "owner mismatch");
        require(c.tbaOf(agentId) == tba, "tba mismatch");

        AgentX402Receiver.Service memory svc = receiver.getServiceForNFT(coll, agentId, sid);
        require(svc.token == usdc,  "service token mismatch");
        require(svc.price == price, "service price mismatch");
        require(svc.active,         "service inactive");

        (address royaltyTo, uint256 bps) = c.serviceRoyaltyOf(agentId);
        require(royaltyTo == sender, "royalty recipient should be collection creator");
        require(bps == 1000,         "royalty bps mismatch");

        console.log("E2E OK");
    }
}
