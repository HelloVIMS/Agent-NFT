// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";

/**
 * @title  DeployFactoryV3Script
 * @notice One-shot deploy: AgentCollectionImpl (slimmed via renderer +
 *         EIP-712 libraries; carries the `royaltyReceiver` slot) +
 *         AgentCollectionFactory (governance stays with deployer, splitter
 *         is wired in as financial recipient via `setRoyaltyReceiverOnce`).
 *
 *         Foundry auto-links the two external libraries
 *         (`AgentCollectionRenderer`, `AgentCollectionEIP712`) at compile
 *         time and broadcasts them in the same script.
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY   — broadcasting key
 *   PROTOCOL_FEE_RECIPIENT — treasury for 2% primary / 0.5% secondary
 */
contract DeployFactoryV3Script is Script {
    function run() external {
        uint256 pk           = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address feeRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");

        vm.startBroadcast(pk);
        AgentCollectionImpl    impl    = new AgentCollectionImpl();
        AgentCollectionFactory factory = new AgentCollectionFactory(address(impl), feeRecipient);
        vm.stopBroadcast();

        console.log("AgentCollectionImpl(v3):     ", address(impl));
        console.log("AgentCollectionFactory(v3):  ", address(factory));
        console.log("  beacon:                    ", address(factory.beacon()));
        console.log("  splitterFactory:           ", address(factory.splitterFactory()));
    }
}
