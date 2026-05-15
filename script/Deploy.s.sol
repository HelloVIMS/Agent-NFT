// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AgentRegistry.sol";
import "../src/ReputationRegistry.sol";
import "../src/ValidationRegistry.sol";

contract DeployScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy Agent Registry first
        AgentRegistry agentRegistry = new AgentRegistry();
        console.log("AgentRegistry deployed to:", address(agentRegistry));
        
        // Deploy Reputation Registry with Agent Registry reference
        ReputationRegistry reputationRegistry = new ReputationRegistry(address(agentRegistry));
        console.log("ReputationRegistry deployed to:", address(reputationRegistry));
        
        // Deploy Validation Registry with Agent Registry reference
        ValidationRegistry validationRegistry = new ValidationRegistry(address(agentRegistry));
        console.log("ValidationRegistry deployed to:", address(validationRegistry));
        
        vm.stopBroadcast();
        
        // Output for easy copying
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Add these to your .env or erc8004.go:");
        console.log("AGENT_REGISTRY=", address(agentRegistry));
        console.log("REPUTATION_REGISTRY=", address(reputationRegistry));
        console.log("VALIDATION_REGISTRY=", address(validationRegistry));
    }
}
