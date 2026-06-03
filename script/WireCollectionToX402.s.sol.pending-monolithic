// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentX402Receiver.sol";

/**
 * @title  WireCollectionToX402
 * @notice One-shot CLI helper that wires a freshly-deployed
 *         {AgentCollectionImpl} proxy as an x402 NFT source on
 *         {AgentX402Receiver} via the permissionless `selfRegisterCollection`
 *         entrypoint. Must be run by the collection's `collectionCreator` —
 *         the receiver-owner admin path no longer exists.
 *
 *         Sets two pieces of state in one tx:
 *           1. nftAdapters[collection]         = collection
 *           2. trustedRegistrarFor[collection] = collection
 *
 *         Required env:
 *           DEPLOYER_PRIVATE_KEY  (must equal collection.collectionCreator())
 *           AGENT_X402_RECEIVER   default: 0xd180DC89270Df505F5d4B7B36e83318f330014A7
 *           COLLECTION            address of the collection proxy
 */
contract WireCollectionToX402Script is Script {
    function run() external {
        uint256 pk         = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address receiverAddr = vm.envOr("AGENT_X402_RECEIVER", 0xd180DC89270Df505F5d4B7B36e83318f330014A7);
        address collection = vm.envAddress("COLLECTION");

        AgentX402Receiver receiver = AgentX402Receiver(receiverAddr);

        console.log("Receiver  :", receiverAddr);
        console.log("Collection:", collection);
        console.log("Caller    :", vm.addr(pk));

        vm.startBroadcast(pk);
        receiver.selfRegisterCollection(collection);
        vm.stopBroadcast();

        require(address(receiver.nftAdapters(collection)) == collection, "adapter not set");
        require(receiver.trustedRegistrarFor(collection) == collection, "registrar not set");
        console.log("Wired OK");
    }
}
