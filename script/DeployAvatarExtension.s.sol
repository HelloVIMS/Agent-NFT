// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentAvatarExtension.sol";

/**
 * @notice Fresh deployment of {AgentAvatarExtension} (UUPS).
 *
 *         Required env:
 *           - DEPLOYER_PRIVATE_KEY        — funding key with broadcast rights
 *           - AGENT_IDENTITY_REGISTRY     — proxy address of the identity registry
 *                                           whose `ownerOf()` gates manifest writes
 *
 *         The extension stores a per-token `{manifestURI, contentHash,
 *         updatedAt, fileCount, version}` record that points at an off-chain
 *         JSON of the shape `{version, avatars: [...]}`. Meeting brokers +
 *         browse cards call {getAvatarPointer} to discover the latest
 *         manifest without walking every token's inline `avatars[]`.
 *
 *         Network-scoped — deploy once per chain you want post-mint avatar
 *         updates to work on. Wire the resulting proxy address into
 *         `vimsbot-marketplace/src/lib/contracts.ts` under the matching
 *         chain entry's `agentAvatarExtension` field, AND expose the same
 *         address to the Go daemon via the `AGENT_AVATAR_EXTENSION` env
 *         (see `cmd/server/avatar_bundle.go`'s `AvatarExtensionAddress()`).
 */
contract DeployAvatarExtensionScript is Script {
    function run() external returns (address proxy) {
        uint256 pk            = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address identityProxy = vm.envAddress("AGENT_IDENTITY_REGISTRY");

        vm.startBroadcast(pk);

        // Impl. Constructor `_disableInitializers()` keeps the impl
        // itself uncallable — every path must go through the proxy.
        AgentAvatarExtension impl = new AgentAvatarExtension();
        console.log("AgentAvatarExtension impl:", address(impl));

        ERC1967Proxy p = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AgentAvatarExtension.initialize, (identityProxy))
        );
        proxy = address(p);

        vm.stopBroadcast();

        console.log("AgentAvatarExtension proxy:", proxy);
        console.log("Bound IdentityRegistry:",    identityProxy);
        console.log(
            "Wire: (1) CONTRACTS.agentAvatarExtension in vimsbot-marketplace/src/lib/contracts.ts"
        );
        console.log(
            "Wire: (2) AGENT_AVATAR_EXTENSION env for the Go daemon (cmd/server)"
        );
    }
}
