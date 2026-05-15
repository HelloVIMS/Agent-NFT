// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentIdentityRegistry.sol";

/**
 * @notice Upgrades the deployed AgentIdentityRegistry proxy to V7
 *         (secondary-market royalty splitter) and calls initializeV7
 *         in the same upgradeToAndCall to seed treasury + system fee.
 *
 *         Required env: DEPLOYER_PRIVATE_KEY, AGENT_IDENTITY_REGISTRY,
 *         AGENT_SECONDARY_TREASURY (defaults to deployer if unset).
 */
contract UpgradeIdentityToV7Script is Script {
    function run() external {
        uint256 pk           = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxyAddr    = vm.envAddress("AGENT_IDENTITY_REGISTRY");
        address treasury     = vm.envOr("AGENT_SECONDARY_TREASURY", vm.addr(pk));

        vm.startBroadcast(pk);

        AgentIdentityRegistry newImpl = new AgentIdentityRegistry();
        console.log("New impl:", address(newImpl));

        bytes memory init = abi.encodeCall(
            AgentIdentityRegistry.initializeV7,
            (treasury)
        );
        AgentIdentityRegistry(proxyAddr).upgradeToAndCall(address(newImpl), init);

        vm.stopBroadcast();

        console.log("Upgraded proxy:", proxyAddr);
        console.log("Secondary treasury:", treasury);
        console.log("Secondary system fee bps:", AgentIdentityRegistry(proxyAddr).secondarySystemFeeBps());
    }
}
