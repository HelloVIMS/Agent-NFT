// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentTBARegistry.sol";
import "../src/AgentX402Receiver.sol";

/// @notice Mint a fresh agent with 5% creator royalty, deploy TBA, register x402 service.
contract MintRoyaltyAgentScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        AgentIdentityRegistry registry = AgentIdentityRegistry(vm.envAddress("AGENT_IDENTITY_REGISTRY"));
        AgentTBARegistry tbaRegistry = AgentTBARegistry(vm.envAddress("AGENT_TBA_REGISTRY"));
        AgentX402Receiver receiver = AgentX402Receiver(vm.envAddress("AGENT_X402_RECEIVER"));

        address usdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

        vm.startBroadcast(pk);

        uint256 agentId = registry.registerAgent(
            "RoyaltyAgent",
            "ipfs://test-agent/RoyaltyAgent",
            500,           // 5% creator royalty
            address(0)
        );
        console.log("Royalty agent minted, id:", agentId);

        address tba = tbaRegistry.createAccount(agentId, bytes32(0));
        console.log("TBA deployed:", tba);

        bytes32 serviceId = keccak256(abi.encodePacked("royalty-service/", vm.toString(agentId)));
        receiver.registerService(agentId, serviceId, usdc, 0.1e6);
        console.log("Service registered with serviceId:");
        console.logBytes32(serviceId);

        vm.stopBroadcast();
    }
}
