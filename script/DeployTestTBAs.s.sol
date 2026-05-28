// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentTBARegistry.sol";

/**
 * @notice Deploy TBAs for test agents on base-sepolia.
 * @dev Run with:
 *      BASE_SEPOLIA_RPC_URL=<rpc> DEPLOYER_PRIVATE_KEY=<pk> \
 *        AGENT_TBA_REGISTRY=0x1383FA459907ce08f7A6c4619C40f672C0cA7D5e \
 *        forge script script/DeployTestTBAs.s.sol --rpc-url base_sepolia --broadcast
 */
contract DeployTestTBAsScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tbaRegistryAddr = vm.envAddress("AGENT_TBA_REGISTRY");
        AgentTBARegistry tbaRegistry = AgentTBARegistry(tbaRegistryAddr);

        // agentIds 9-19 minted on base-sepolia
        uint256[] memory agentIds = new uint256[](11);
        agentIds[0] = 9; agentIds[1] = 10; agentIds[2] = 11; agentIds[3] = 12;
        agentIds[4] = 13; agentIds[5] = 14; agentIds[6] = 15; agentIds[7] = 16;
        agentIds[8] = 17; agentIds[9] = 18; agentIds[10] = 19;

        vm.startBroadcast(pk);

        for (uint256 i = 0; i < agentIds.length; i++) {
            uint256 agentId = agentIds[i];
            bytes32 salt = bytes32(0);

            try tbaRegistry.createAccount(agentId, salt) returns (address account) {
                console.log("TBA deployed for agentId:", agentId);
                console.log("  account:", uint256(uint160(account)));
            } catch {
                console.log("TBA failed for agentId:", agentId);
            }
        }

        vm.stopBroadcast();
    }
}
