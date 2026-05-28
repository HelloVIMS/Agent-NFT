// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentX402Receiver.sol";

/**
 * @notice Register x402 services for test agents on base-sepolia.
 * @dev Run with:
 *      BASE_SEPOLIA_RPC_URL=<rpc> DEPLOYER_PRIVATE_KEY=<pk> \
 *        AGENT_X402_RECEIVER=0xd180DC89270Df505F5d4B7B36e83318f330014A7 \
 *        forge script script/RegisterX402Services.s.sol --rpc-url base_sepolia --broadcast
 */
contract RegisterX402ServicesScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address receiverAddr = vm.envAddress("AGENT_X402_RECEIVER");
        AgentX402Receiver receiver = AgentX402Receiver(receiverAddr);

        // USDC on base-sepolia
        address usdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

        // agentIds 9-19 minted on base-sepolia
        uint256[] memory agentIds = new uint256[](11);
        agentIds[0] = 9; agentIds[1] = 10; agentIds[2] = 11; agentIds[3] = 12;
        agentIds[4] = 13; agentIds[5] = 14; agentIds[6] = 15; agentIds[7] = 16;
        agentIds[8] = 17; agentIds[9] = 18; agentIds[10] = 19;

        vm.startBroadcast(pk);

        for (uint256 i = 0; i < agentIds.length; i++) {
            uint256 agentId = agentIds[i];
            bytes32 serviceId = keccak256(abi.encodePacked("test-service/", vm.toString(agentId)));
            uint256 price = 0.1e6; // 0.1 USDC (6 decimals)

            try receiver.registerService(agentId, serviceId, usdc, price) {
                console.log("Registered service for agentId:", agentId);
            } catch {
                console.log("Failed for agentId:", agentId);
            }
        }

        vm.stopBroadcast();
    }
}
