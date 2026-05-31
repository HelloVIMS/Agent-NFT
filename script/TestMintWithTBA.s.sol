// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentIdentityRegistry.sol";

/// @notice On-chain verification that the upgraded mintWithTBA flow auto-binds
///         the TBA in a single transaction (closes the prior gap where TBA
///         had to be bound manually after createAccount).
contract TestMintWithTBAScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        AgentIdentityRegistry registry = AgentIdentityRegistry(vm.envAddress("AGENT_IDENTITY_REGISTRY"));

        vm.startBroadcast(pk);
        (uint256 agentId, address tba) = registry.mintWithFullStack(
            "AtomicAgent",
            "ipfs://test/atomic",
            500,
            address(0),
            keccak256("atomic-test-1"),
            bytes32(0),
            address(0),
            0 // skip x402
        );
        vm.stopBroadcast();

        console.log("agentId:", agentId);
        console.log("tba:    ", tba);

        (, address bound,,,) = registry.agents(agentId);
        console.log("bound:  ", bound);
        require(bound == tba, "auto-bind failed");
    }
}
