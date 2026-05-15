// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentTBARegistry.sol";
import "../src/AgentReputationRegistry.sol";
import "../src/AgentPaymentRouter.sol";
import "../src/AgentContextRegistry.sol";
import "../src/AgentMemory.sol";
import "../src/AgentX402Receiver.sol";

contract DeployAgentScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Deploy Identity Registry Implementation
        AgentIdentityRegistry identityImpl = new AgentIdentityRegistry();
        console.log("AgentIdentityRegistry impl:", address(identityImpl));
        
        // Deploy Proxy for Identity Registry
        ERC1967Proxy identityProxy = new ERC1967Proxy(
            address(identityImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        AgentIdentityRegistry identityRegistry = AgentIdentityRegistry(address(identityProxy));
        console.log("AgentIdentityRegistry proxy:", address(identityRegistry));
        
        // 2. Deploy TBA Registry (not upgradeable - it's a factory)
        // V2: Now linked to identity registry for validation
        // V3: Added ERC-4337 EntryPoint (Base Sepolia v0.7)
        address ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
        AgentTBARegistry tbaRegistry = new AgentTBARegistry(address(identityRegistry), ENTRY_POINT);
        console.log("AgentTBARegistry:", address(tbaRegistry));
        console.log("  -> TBA Implementation:", tbaRegistry.implementation());
        
        // 3. Deploy Reputation Registry Implementation
        AgentReputationRegistry reputationImpl = new AgentReputationRegistry();
        console.log("AgentReputationRegistry impl:", address(reputationImpl));
        
        // Deploy Proxy for Reputation Registry
        ERC1967Proxy reputationProxy = new ERC1967Proxy(
            address(reputationImpl),
            abi.encodeCall(AgentReputationRegistry.initialize, (address(identityRegistry)))
        );
        AgentReputationRegistry reputationRegistry = AgentReputationRegistry(address(reputationProxy));
        console.log("AgentReputationRegistry proxy:", address(reputationRegistry));
        
        // 4. Deploy Payment Router (not upgradeable - stateless payment processor)
        // Base Sepolia USDC address
        address USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        // AEyeOS Treasury - receives 0.5% system royalty on all payments
        address TREASURY = msg.sender; // Default to deployer, can be updated via setAeyeosTreasury()
        AgentPaymentRouter paymentRouter = new AgentPaymentRouter(address(identityRegistry), USDC, TREASURY);
        console.log("AgentPaymentRouter:", address(paymentRouter));
        
        // 5. Deploy Context Registry (UUPS) — typed context files (md/json/yaml)
        AgentContextRegistry ctxImpl = new AgentContextRegistry();
        console.log("AgentContextRegistry impl:", address(ctxImpl));

        ERC1967Proxy ctxProxy = new ERC1967Proxy(
            address(ctxImpl),
            abi.encodeCall(AgentContextRegistry.initialize, (address(identityRegistry)))
        );
        AgentContextRegistry contextRegistry = AgentContextRegistry(address(ctxProxy));
        console.log("AgentContextRegistry proxy:", address(contextRegistry));

        // 6. Deploy Agent Memory (UUPS) — Pixelog .pixe capsule memory
        AgentMemory memImpl = new AgentMemory();
        console.log("AgentMemory impl:", address(memImpl));

        ERC1967Proxy memProxy = new ERC1967Proxy(
            address(memImpl),
            abi.encodeCall(AgentMemory.initialize, (address(identityRegistry)))
        );
        AgentMemory agentMemory = AgentMemory(address(memProxy));
        console.log("AgentMemory proxy:", address(agentMemory));

        // 7. Deploy x402 Receiver (UUPS) — atomic ERC-3009 settler with splits.
        AgentX402Receiver x402Impl = new AgentX402Receiver();
        console.log("AgentX402Receiver impl:", address(x402Impl));

        ERC1967Proxy x402Proxy = new ERC1967Proxy(
            address(x402Impl),
            abi.encodeCall(
                AgentX402Receiver.initialize,
                (address(identityRegistry), TREASURY, 50) // 0.5% system fee
            )
        );
        AgentX402Receiver x402Receiver = AgentX402Receiver(address(x402Proxy));
        console.log("AgentX402Receiver proxy:", address(x402Receiver));

        // Seed token allowlist (audit L-3): USDC on Base Sepolia at deploy time.
        x402Receiver.setTokenAllowed(USDC, true);
        console.log("AgentX402Receiver: USDC allowlisted");

        vm.stopBroadcast();
        
        // Output for configuration
        console.log("\n=== AGENT DEPLOYMENT COMPLETE (UPGRADEABLE) ===");
        console.log("Add these PROXY addresses to your frontend config:");
        console.log("");
        console.log("AGENT_IDENTITY_REGISTRY=", address(identityRegistry));
        console.log("AGENT_TBA_REGISTRY=", address(tbaRegistry));
        console.log("AGENT_TBA_IMPLEMENTATION=", tbaRegistry.implementation());
        console.log("AGENT_REPUTATION_REGISTRY=", address(reputationRegistry));
        console.log("AGENT_PAYMENT_ROUTER=", address(paymentRouter));
        console.log("AGENT_CONTEXT_REGISTRY=", address(contextRegistry));
        console.log("AGENT_MEMORY=", address(agentMemory));
        console.log("AGENT_X402_RECEIVER=", address(x402Receiver));
        console.log("");
        console.log("Implementation addresses (for reference):");
        console.log("IDENTITY_IMPL=", address(identityImpl));
        console.log("REPUTATION_IMPL=", address(reputationImpl));
        console.log("CONTEXT_IMPL=", address(ctxImpl));
        console.log("MEMORY_IMPL=", address(memImpl));
        console.log("X402_IMPL=", address(x402Impl));
    }
}
