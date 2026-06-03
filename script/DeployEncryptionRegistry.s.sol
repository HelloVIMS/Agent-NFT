// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentEncryptionRegistry.sol";

/**
 * @notice Fresh deployment of {AgentEncryptionRegistry} (UUPS).
 *
 *         Required env:
 *           - DEPLOYER_PRIVATE_KEY        — funding key with broadcast rights
 *           - AGENT_IDENTITY_REGISTRY     — proxy address of the identity registry
 *                                           used by `ownerOf()` ownership gating
 *
 *         The registry stores per-agent X25519 long-term encryption material
 *         (publishable pubkey + owner-wrapped privkey blob). It is read by the
 *         marketplace's {useAgentEncryption} hook and by every flow that needs
 *         to seal payloads to an agent's inbox.
 *
 *         Network-scoped — deploy once per chain you want sealed-uploads to
 *         work on. Wire the resulting proxy address into
 *         `vimsbot-marketplace/src/lib/contracts.ts` under the matching chain
 *         entry's `encryptionRegistry` field.
 */
contract DeployEncryptionRegistryScript is Script {
    function run() external returns (address proxy) {
        uint256 pk            = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address identityProxy = vm.envAddress("AGENT_IDENTITY_REGISTRY");

        vm.startBroadcast(pk);

        // Deploy the implementation; constructor is a no-op aside from
        // {_disableInitializers}, so the impl can never be initialised directly.
        AgentEncryptionRegistry impl = new AgentEncryptionRegistry();
        console.log("AgentEncryptionRegistry impl:", address(impl));

        ERC1967Proxy p = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AgentEncryptionRegistry.initialize, (identityProxy))
        );
        proxy = address(p);

        vm.stopBroadcast();

        console.log("AgentEncryptionRegistry proxy:", proxy);
        console.log("Bound IdentityRegistry:",       identityProxy);
        console.log(
            "Next step: set encryptionRegistry in vimsbot-marketplace/src/lib/contracts.ts"
        );
    }
}
