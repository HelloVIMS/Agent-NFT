// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";

/**
 * @title UpgradeCollectionImpl
 * @notice Upgrades the Agent Collection Implementation via beacon
 */
contract UpgradeCollectionImplScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address factoryAddress = 0x3A28C84fB5C06845d22Fccd0776341bF2e90A9EB;
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Deploy new implementation
        AgentCollectionImpl newImpl = new AgentCollectionImpl();
        console.log("New AgentCollectionImpl:", address(newImpl));
        
        // 2. Upgrade beacon via factory
        AgentCollectionFactory factory = AgentCollectionFactory(factoryAddress);
        factory.upgradeImplementation(address(newImpl));
        console.log("Beacon upgraded to new implementation");
        console.log("  -> New impl:", factory.implementation());
        
        vm.stopBroadcast();
    }
}
