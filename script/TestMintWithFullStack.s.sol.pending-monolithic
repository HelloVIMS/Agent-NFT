// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentX402Receiver.sol";

/// @notice End-to-end verification of atomic mint + TBA + x402 service in ONE tx.
contract TestMintWithFullStackScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        AgentIdentityRegistry registry = AgentIdentityRegistry(vm.envAddress("AGENT_IDENTITY_REGISTRY"));
        AgentX402Receiver     x402     = AgentX402Receiver(vm.envAddress("AGENT_X402_RECEIVER"));
        address               usdc     = vm.envAddress("USDC");

        bytes32 serviceId = keccak256("fullstack-test/api/chat");

        vm.startBroadcast(pk);
        (uint256 agentId, address tba) = registry.mintWithFullStack(
            "FullStackAgent",
            "ipfs://test/fullstack",
            500,            // 5% creator royalty
            address(0),
            keccak256("full-1"),
            serviceId,
            usdc,
            100_000         // 0.1 USDC
        );
        vm.stopBroadcast();

        console.log("agentId:", agentId);
        console.log("tba:    ", tba);

        // Verify identity + TBA binding
        (, address bound,,,) = registry.agents(agentId);
        require(bound == tba, "TBA binding failed");

        // Verify x402 service registration
        AgentX402Receiver.Service memory svc = x402.getService(agentId, serviceId);
        require(svc.token == usdc, "service token mismatch");
        require(svc.price == 100_000, "service price mismatch");
        require(svc.active, "service inactive");
        console.log("service.token: ", svc.token);
        console.log("service.price: ", svc.price);
        console.log("service.active:", svc.active);
        console.log("serviceId:");
        console.logBytes32(serviceId);
    }
}
