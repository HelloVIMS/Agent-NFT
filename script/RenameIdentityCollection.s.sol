// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentIdentityRegistry.sol";

/**
 * @notice Deploys a fresh AgentIdentityRegistry implementation containing the
 *         V8 reinitializer (`initializeV8`) and atomically:
 *         1) points the existing UUPS proxy at the new impl, and
 *         2) executes initializeV8(name, symbol) to overwrite the legacy
 *            ERC-721 name/symbol pair.
 *
 * Usage:
 *   AGENT_IDENTITY_REGISTRY=0x2dc303B780fEe371cD649337F3f9eB034719C643 \
 *   COLLECTION_NAME=Agent \
 *   COLLECTION_SYMBOL=AGENT \
 *   forge script script/RenameIdentityCollection.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
 */
contract RenameIdentityCollectionScript is Script {
    function run() external {
        uint256 pk           = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxyAddr    = vm.envAddress("AGENT_IDENTITY_REGISTRY");
        string memory name_  = vm.envString("COLLECTION_NAME");
        string memory symbol_= vm.envString("COLLECTION_SYMBOL");

        require(bytes(name_).length   > 0, "COLLECTION_NAME empty");
        require(bytes(symbol_).length > 0, "COLLECTION_SYMBOL empty");

        bytes memory initCall = abi.encodeCall(
            AgentIdentityRegistry.initializeV8,
            (name_, symbol_)
        );

        vm.startBroadcast(pk);
        AgentIdentityRegistry newImpl = new AgentIdentityRegistry();
        AgentIdentityRegistry(proxyAddr).upgradeToAndCall(address(newImpl), initCall);
        vm.stopBroadcast();

        AgentIdentityRegistry proxy = AgentIdentityRegistry(proxyAddr);
        console.log("New impl :", address(newImpl));
        console.log("Proxy    :", proxyAddr);
        console.log("New name :", proxy.name());
        console.log("New sym  :", proxy.symbol());
    }
}
