// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {AgentCollectionFactory} from "../src/AgentCollectionFactory.sol";
import {AgentCurveMarket} from "../src/AgentCurveMarket.sol";
import {AgentCollectionImpl} from "../src/AgentCollectionImpl.sol";

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
        require(block.chainid == 84532, "Base Sepolia only");
        require(vm.addr(pk) == vm.envOr("EXPECTED_DEPLOYER", address(0xE48840eD6678218Bd21dF2671b98bCF23de661b9)), "unexpected deployer");
        address sample = factory.allCollections(0);
        address previous = vm.envOr("PREVIOUS_CURVE_MARKET", address(0x12515d4615DE573536EE3EcdE87bAa64C94d36c9));
        vm.startBroadcast(pk);
        AgentCollectionImpl implementation = new AgentCollectionImpl();
        AgentCurveMarket market = new AgentCurveMarket(usdc, sample, address(implementation), previous);
        vm.stopBroadcast();
        require(AgentCollectionFactory(market.collectionFactory()).owner() == address(0), "factory must be immutable");
        console.log("AgentCurveMarket:", address(market));
        console.log("Reserve collection factory:", market.collectionFactory());
        console.log("Reserve collection implementation:", address(implementation));
        console.logBytes32(market.collectionCodehash());
    }
}
