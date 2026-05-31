// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentIdentityRegistry.sol";

contract MintRemaining3Script is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxy = vm.envAddress("AGENT_IDENTITY_REGISTRY");
        AgentIdentityRegistry registry = AgentIdentityRegistry(proxy);

        string[3] memory names = ["Nexus-2", "Vertex-2", "Tide-2"];
        string[3] memory uris = [
            "ipfs://test-agent/Nexus-2",
            "ipfs://test-agent/Vertex-2",
            "ipfs://test-agent/Tide-2"
        ];

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < 3; i++) {
            uint256 agentId = registry.registerAgent(names[i], uris[i], 0, address(0));
            console.log("minted agentId:", agentId);
        }
        vm.stopBroadcast();
    }
}
