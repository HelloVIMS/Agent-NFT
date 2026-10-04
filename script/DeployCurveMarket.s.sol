// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {AgentCollectionFactory} from "../src/AgentCollectionFactory.sol";
import {AgentCurveMarket} from "../src/AgentCurveMarket.sol";

/**
 * @title  DeployCurveMarketScript
 * @notice Deploys AgentCurveMarket. It recognises the factory's collections
 *         by their proxy's runtime code, taken from the factory's first
 *         collection (every factory collection shares it).
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY
 *   COLLECTION_FACTORY  (default: Base Sepolia)
 *   USDC                (default: Base Sepolia USDC)
 */
contract DeployCurveMarketScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        AgentCollectionFactory factory = AgentCollectionFactory(vm.envOr("COLLECTION_FACTORY", address(0x6B182188269208533Ed95B7C2b83240f21fA7f12)));
        address usdc = vm.envOr("USDC", address(0x036CbD53842c5426634e7929541eC2318f3dCF7e));
        address sample = factory.allCollections(0);
        vm.startBroadcast(pk);
        AgentCurveMarket market = new AgentCurveMarket(usdc, sample);
        vm.stopBroadcast();
        console.log("AgentCurveMarket:", address(market));
        console.logBytes32(market.collectionCodehash());
    }
}
