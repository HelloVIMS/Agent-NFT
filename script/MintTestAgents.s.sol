// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentIdentityRegistry.sol";

/**
 * @notice Mint 10 test agents on base-sepolia and set their on-chain SVGs.
 * @dev Run with:
 *      BASE_SEPOLIA_RPC_URL=<rpc> DEPLOYER_PRIVATE_KEY=<pk> \
 *        AGENT_IDENTITY_REGISTRY=0xfE1ef66Ba95891d3cDf6FB83FE1444Bc3bB9FEeF \
 *        forge script script/MintTestAgents.s.sol --rpc-url base_sepolia --broadcast --verify
 */
contract MintTestAgentsScript is Script {
    struct AgentConfig {
        string name;
        string svgPath;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxy = vm.envAddress("AGENT_IDENTITY_REGISTRY");
        AgentIdentityRegistry registry = AgentIdentityRegistry(proxy);

        AgentConfig[] memory cfg = new AgentConfig[](10);
        cfg[0] = AgentConfig("Nebula",     "test-assets/svgs/agent_00_nebula.svg");
        cfg[1] = AgentConfig("Circuit",    "test-assets/svgs/agent_01_circuit.svg");
        cfg[2] = AgentConfig("Crystal",    "test-assets/svgs/agent_02_crystal.svg");
        cfg[3] = AgentConfig("Oracle",     "test-assets/svgs/agent_03_oracle.svg");
        cfg[4] = AgentConfig("Flux",       "test-assets/svgs/agent_04_flux.svg");
        cfg[5] = AgentConfig("Prism",      "test-assets/svgs/agent_05_prism.svg");
        cfg[6] = AgentConfig("Nexus",      "test-assets/svgs/agent_06_nexus.svg");
        cfg[7] = AgentConfig("Vertex",     "test-assets/svgs/agent_07_vertex.svg");
        cfg[8] = AgentConfig("Tide",       "test-assets/svgs/agent_08_tide.svg");
        cfg[9] = AgentConfig("Singularity","test-assets/svgs/agent_09_singularity.svg");

        vm.startBroadcast(pk);

        for (uint256 i = 0; i < cfg.length; i++) {
            string memory svg = vm.readFile(cfg[i].svgPath);
            uint256 svgLen = bytes(svg).length;
            require(svgLen > 0 && svgLen <= registry.MAX_SVG_SIZE(), "SVG size invalid");

            uint256 agentId = registry.registerAgent(
                cfg[i].name,
                string.concat("ipfs://test-agent/", cfg[i].name), // placeholder URI
                0,          // royaltyBps
                address(0)  // transferable reputation
            );

            // SVG set separately due to gas limits
            console.log("agentId:", agentId);
            console.log("svgLen:", svgLen);
        }

        vm.stopBroadcast();
    }
}
