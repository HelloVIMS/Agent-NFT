// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentIdentityRegistry.sol";

/**
 * @notice Set a single SVG for one agent.
 * @dev Run with:
 *      BASE_SEPOLIA_RPC_URL=<rpc> DEPLOYER_PRIVATE_KEY=<pk> \
 *        AGENT_IDENTITY_REGISTRY=0xfE1ef66Ba95891d3cDf6FB83FE1444Bc3bB9FEeF \
 *        AGENT_ID=<id> SVG_PATH=<path> \
 *        forge script script/SetSingleSVG.s.sol --rpc-url base_sepolia --broadcast
 */
contract SetSingleSVGScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxy = vm.envAddress("AGENT_IDENTITY_REGISTRY");
        uint256 agentId = vm.envUint("AGENT_ID");
        string memory svgPath = vm.envString("SVG_PATH");

        AgentIdentityRegistry registry = AgentIdentityRegistry(proxy);
        string memory svg = vm.readFile(svgPath);
        uint256 svgLen = bytes(svg).length;
        require(svgLen > 0 && svgLen <= registry.MAX_SVG_SIZE(), "SVG size invalid");

        vm.startBroadcast(pk);
        registry.setSVGImage(agentId, svg);
        vm.stopBroadcast();

        console.log("SVG set for agentId:", agentId);
        console.log("svgLen:", svgLen);
    }
}
