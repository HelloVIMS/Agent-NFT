// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";

/**
 * @title  UpgradeCollectionImplPatternB
 * @notice Deploys a new {AgentCollectionImpl} that supports the Pattern B
 *         generative drop flow (collectionBaseURI + permissionless public/
 *         allowlist mint resolving `tokenURI` to `${baseURI}${id}.json`)
 *         and points the BeaconProxy at it via the factory.
 *
 * @dev    Library deployment + linking is handled automatically by Foundry
 *         when broadcasting `new AgentCollectionImpl()` — the new
 *         {AgentCollectionPaymentLib} and updated {AgentCollectionEIP712}
 *         are deployed and linked transparently as part of this run.
 *
 *         Run with:
 *           forge script script/UpgradeCollectionImplPatternB.s.sol \
 *             --rpc-url $BASE_SEPOLIA_RPC_URL \
 *             --broadcast --verify
 *
 *         Required env:
 *           DEPLOYER_PRIVATE_KEY   — must equal current factory.owner()
 *
 *         Existing collections automatically inherit the new logic on the
 *         next call (beacon proxy pattern). New storage slots
 *         (`royaltyReceiver`, `collectionBaseURI`) are appended to the end
 *         of layout, so all currently-deployed proxies stay safe.
 */
contract UpgradeCollectionImplPatternBScript is Script {
    // Base Sepolia AgentCollectionFactory (v3, beacon owner).
    address public constant FACTORY = 0x6B182188269208533Ed95B7C2b83240f21fA7f12;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        AgentCollectionFactory factory = AgentCollectionFactory(FACTORY);
        address oldImpl = factory.implementation();
        console.log("Factory:           ", FACTORY);
        console.log("Beacon owner:      ", factory.owner());
        console.log("Old implementation:", oldImpl);

        vm.startBroadcast(pk);

        // Foundry auto-deploys + links the external libraries
        // (AgentCollectionRenderer, AgentCollectionEIP712,
        // AgentCollectionPaymentLib) referenced by this contract.
        AgentCollectionImpl newImpl = new AgentCollectionImpl();
        console.log("New implementation:", address(newImpl));

        factory.upgradeImplementation(address(newImpl));
        console.log("Beacon upgraded   :", factory.implementation());

        vm.stopBroadcast();

        require(
            factory.implementation() == address(newImpl),
            "beacon implementation mismatch post-upgrade"
        );
    }
}
