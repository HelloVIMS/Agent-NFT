// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";

/**
 * @title DeployCollectionFactory
 * @notice Deploys the Agent Collection Factory with Beacon Proxy pattern
 * @dev Each collection created via factory gets its own OpenSea collection page
 */
contract DeployCollectionFactoryScript is Script {
    // Protocol fee recipient - receives 2% primary, 0.5% secondary
    address constant PROTOCOL_FEE_RECIPIENT = 0x1234567890123456789012345678901234567890; // TODO: Set your treasury address
    
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address protocolFeeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", PROTOCOL_FEE_RECIPIENT);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Deploy Collection Implementation (used by all beacon proxies)
        AgentCollectionImpl collectionImpl = new AgentCollectionImpl();
        console.log("AgentCollectionImpl:", address(collectionImpl));
        
        // 2. Deploy Collection Factory (creates beacon internally)
        // Protocol fees: 2% primary sales, 0.5% secondary sales
        AgentCollectionFactory factory = new AgentCollectionFactory(
            address(collectionImpl),
            protocolFeeRecipient
        );
        console.log("AgentCollectionFactory:", address(factory));
        console.log("  -> Protocol Fee Recipient:", protocolFeeRecipient);
        console.log("  -> Beacon:", address(factory.beacon()));
        console.log("  -> Implementation:", factory.implementation());
        
        vm.stopBroadcast();
        
        // Output for configuration
        console.log("\n=== AGENT COLLECTION FACTORY DEPLOYED ===");
        console.log("Add these addresses to your frontend config:");
        console.log("");
        console.log("AGENT_COLLECTION_FACTORY=", address(factory));
        console.log("AGENT_COLLECTION_IMPL=", address(collectionImpl));
        console.log("");
        console.log("Usage:");
        console.log("  - 1-off agents: mint via AgentIdentityRegistry (shared 'Agent Agents' OS collection)");
        console.log("  - New collections: create via factory (each gets separate OS collection)");
    }
}
