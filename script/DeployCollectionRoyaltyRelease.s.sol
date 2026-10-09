// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {AgentCollectionImpl} from "../src/AgentCollectionImpl.sol";
import {AgentCollectionFactory} from "../src/AgentCollectionFactory.sol";
import {AgentCurveMarket} from "../src/AgentCurveMarket.sol";

/**
 * @title  DeployCollectionRoyaltyReleaseScript
 * @notice Collections whose secondary sales pay the protocol fee (per-token
 *         AgentCollectionRoyaltyVault): a new collection factory, its
 *         reference collection, and a new AgentCurveMarket (which deploys its
 *         own frozen reserve factory). The previous factory's collections are
 *         left as they are — their royaltyInfo would call a factory without
 *         the vault view — so the market starts without a previous market.
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY
 *   PROTOCOL_FEE_RECIPIENT (default: the Base Sepolia owner / treasury)
 *   USDC                   (default: Base Sepolia USDC)
 */
contract DeployCollectionRoyaltyReleaseScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(block.chainid == 84532, "Base Sepolia only");
        address owner = vm.envOr("EXPECTED_DEPLOYER", address(0xE48840eD6678218Bd21dF2671b98bCF23de661b9));
        require(vm.addr(pk) == owner, "unexpected deployer");
        address feeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", owner);
        address usdc = vm.envOr("USDC", address(0x036CbD53842c5426634e7929541eC2318f3dCF7e));

        vm.startBroadcast(pk);
        AgentCollectionImpl implementation = new AgentCollectionImpl();
        AgentCollectionFactory factory = new AgentCollectionFactory(address(implementation), feeRecipient);
        (, address refCollection) = factory.createCollection("VIMS reference", "VREF", 1, 0, 0, "Reference collection (code hash) for the curve market");
        AgentCollectionImpl reserveImplementation = new AgentCollectionImpl();
        AgentCurveMarket market = new AgentCurveMarket(usdc, refCollection, address(reserveImplementation), address(0));
        vm.stopBroadcast();

        require(market.legacyCollectionFactory() == address(factory), "market must recognise the new factory");
        require(AgentCollectionFactory(market.collectionFactory()).owner() == address(0), "reserve factory must be immutable");
        console.log("AgentCollectionImpl:", address(implementation));
        console.log("AgentCollectionFactory:", address(factory));
        console.log("  beacon:", address(factory.beacon()));
        console.log("  reference collection:", refCollection);
        console.log("AgentCurveMarket:", address(market));
        console.log("  reserve factory:", market.collectionFactory());
        console.log("  reserve implementation:", address(reserveImplementation));
        console.log("  collection codehash:");
        console.logBytes32(market.collectionCodehash());
    }
}
