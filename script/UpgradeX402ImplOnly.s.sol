// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentX402Receiver.sol";

contract UpgradeX402ImplOnlyScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxy = vm.envAddress("AGENT_X402_RECEIVER");
        vm.startBroadcast(pk);
        AgentX402Receiver newImpl = new AgentX402Receiver();
        AgentX402Receiver(proxy).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();
        console.log("New x402 impl:", address(newImpl));
    }
}
