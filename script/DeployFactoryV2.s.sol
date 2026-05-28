// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";

/**
 * @title  DeployFactoryV2Script
 * @notice Re-deploys {AgentCollectionFactory} pointing at the existing
 *         {AgentCollectionImpl} so the new {createCollectionWithSplits}
 *         entrypoint and the embedded {AgentRoyaltySplitterFactory} are
 *         available without touching beacon implementation state.
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY       — broadcasting key
 *   COLLECTION_IMPLEMENTATION  — existing impl address (used by old beacon)
 *   PROTOCOL_FEE_RECIPIENT     — treasury for 2% primary / 0.5% secondary
 */
contract DeployFactoryV2Script is Script {
    function run() external {
        uint256 pk           = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address impl         = vm.envAddress("COLLECTION_IMPLEMENTATION");
        address feeRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");

        vm.startBroadcast(pk);
        AgentCollectionFactory factory = new AgentCollectionFactory(impl, feeRecipient);
        vm.stopBroadcast();

        console.log("AgentCollectionFactory(v2):  ", address(factory));
        console.log("  beacon:                    ", address(factory.beacon()));
        console.log("  implementation:            ", factory.implementation());
        console.log("  splitterFactory:           ", address(factory.splitterFactory()));
        console.log("  protocolFeeRecipient:      ", factory.protocolFeeRecipient());
    }
}
