// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {AgentCollectionFactory} from "../src/AgentCollectionFactory.sol";
import {AgentCollectionImpl}    from "../src/AgentCollectionImpl.sol";

/**
 * @title  UpgradeCollectionImplScript
 * @notice Points the factory's beacon — and so every collection — at the
 *         current AgentCollectionImpl. New state only ever goes at the end of
 *         the layout; test/CollectionBeaconUpgradeFork.t.sol rehearses this
 *         against every live collection first.
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY  — owner of the factory
 *   COLLECTION_FACTORY    — factory (default: Base Sepolia)
 */
contract UpgradeCollectionImplScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        AgentCollectionFactory factory = AgentCollectionFactory(vm.envOr("COLLECTION_FACTORY", address(0x6B182188269208533Ed95B7C2b83240f21fA7f12)));
        require(factory.owner() == vm.addr(pk), "signer does not own the factory");

        vm.startBroadcast(pk);
        AgentCollectionImpl impl = new AgentCollectionImpl();
        factory.upgradeImplementation(address(impl));
        vm.stopBroadcast();

        console.log("AgentCollectionImpl:", address(impl));
    }
}
