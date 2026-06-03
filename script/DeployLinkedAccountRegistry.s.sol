// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentLinkedAccountRegistry.sol";

/**
 * @notice Fresh deployment of AgentLinkedAccountRegistry (Option B: external
 *         and cross-chain accounts attested to an agent NFT). UUPS proxy.
 *
 *         Required env: DEPLOYER_PRIVATE_KEY, AGENT_IDENTITY_REGISTRY.
 *
 *         The registry is independent from AgentIdentityRegistry — links are
 *         advisory metadata consumed by off-chain routers (Bookkeeper,
 *         x402, ChangeNOW). They do NOT change on-chain payment routing in
 *         AgentPaymentRouter (use subaccounts + `payAgentTo` for that).
 */
contract DeployLinkedAccountRegistryScript is Script {
    function run() external returns (address proxy) {
        uint256 pk             = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address identityProxy  = vm.envAddress("AGENT_IDENTITY_REGISTRY");

        vm.startBroadcast(pk);

        AgentLinkedAccountRegistry impl = new AgentLinkedAccountRegistry();
        console.log("Impl:", address(impl));

        ERC1967Proxy p = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AgentLinkedAccountRegistry.initialize, (identityProxy))
        );
        proxy = address(p);

        vm.stopBroadcast();

        console.log("AgentLinkedAccountRegistry proxy:", proxy);
        console.log("Bound IdentityRegistry:",           identityProxy);
    }
}
