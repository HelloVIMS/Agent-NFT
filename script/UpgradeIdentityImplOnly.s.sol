// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentIdentityRegistry.sol";

/**
 * @notice Deploys a fresh AgentIdentityRegistry implementation and points
 *         the existing UUPS proxy at it. No reinitializer call (V7 storage
 *         is already seeded). Use this for follow-up impl-only fixes.
 */
contract UpgradeIdentityImplOnlyScript is Script {
    function run() external {
        uint256 pk        = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxyAddr = vm.envAddress("AGENT_IDENTITY_REGISTRY");

        vm.startBroadcast(pk);
        AgentIdentityRegistry newImpl = new AgentIdentityRegistry();
        AgentIdentityRegistry(proxyAddr).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        console.log("New impl:", address(newImpl));
        console.log("Proxy:   ", proxyAddr);
        console.log("MIN_CREATOR_ROYALTY_BPS:", AgentIdentityRegistry(proxyAddr).MIN_CREATOR_ROYALTY_BPS());
    }
}
