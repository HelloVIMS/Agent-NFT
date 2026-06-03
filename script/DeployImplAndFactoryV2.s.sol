// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";

/**
 * @title  DeployImplAndFactoryV2Script
 * @notice One-shot deploy: AgentCollectionImpl (with royaltyReceiver slot) +
 *         AgentCollectionFactory (with createCollectionWithSplits + embedded
 *         AgentRoyaltySplitterFactory).
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY   — broadcasting key
 *   PROTOCOL_FEE_RECIPIENT — treasury for 2% primary / 0.5% secondary
 */
contract DeployImplAndFactoryV2Script is Script {
    function run() external {
        uint256 pk           = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address feeRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");

        vm.startBroadcast(pk);
        AgentCollectionImpl    impl    = new AgentCollectionImpl();
        AgentCollectionFactory factory = new AgentCollectionFactory(address(impl), feeRecipient);
        vm.stopBroadcast();

        console.log("AgentCollectionImpl(v2):     ", address(impl));
        console.log("AgentCollectionFactory(v2):  ", address(factory));
        console.log("  beacon:                    ", address(factory.beacon()));
        console.log("  splitterFactory:           ", address(factory.splitterFactory()));
    }
}
