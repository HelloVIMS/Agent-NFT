// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {AgentIdentityKeyExtension} from "../src/AgentIdentityKeyExtension.sol";

/**
 * @title  UpgradeIdentityKeyExtensionScript
 * @notice Upgrades AgentIdentityKeyExtension to the version that binds keys
 *         to any agent NFT (collection agents), storage appended only.
 *         Rehearsed by test/IdentityKeyExtensionUpgradeFork.t.sol.
 *
 * Env: DEPLOYER_PRIVATE_KEY (proxy owner), IDENTITY_KEY_EXTENSION (default: Base Sepolia)
 */
contract UpgradeIdentityKeyExtensionScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        AgentIdentityKeyExtension proxy = AgentIdentityKeyExtension(vm.envOr("IDENTITY_KEY_EXTENSION", address(0xC6d25a28430eFfD9953250f5BDAC5Ab26228E974)));
        require(proxy.owner() == vm.addr(pk), "signer does not own the extension");
        vm.startBroadcast(pk);
        AgentIdentityKeyExtension impl = new AgentIdentityKeyExtension();
        proxy.upgradeToAndCall(address(impl), "");
        vm.stopBroadcast();
        console.log("AgentIdentityKeyExtension impl:", address(impl));
    }
}
