// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {AgentIdentityKeyExtension} from "../src/AgentIdentityKeyExtension.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * Deploy {AgentIdentityKeyExtension} — the on-chain home for an agent's
 * off-chain identity keys (Nostr npub today), on the same 1:many model as
 * Token-Bound Accounts: one primary registered with the mint, more added
 * later.
 *
 * Kept out of {AgentIdentityRegistry} because that contract holds ~958
 * bytes under the EIP-170 ceiling and BytecodeSizeAudit guards the margin.
 *
 * Network-scoped — deploy once per chain. Wire the resulting proxy into
 * the daemon so the mint flow can register a primary key immediately after
 * reading the token id from the AgentRegistered log (the id does not exist
 * until the mint call returns, so registration is necessarily a second
 * transaction in the same flow).
 *
 * Usage:
 *   DEPLOYER_PRIVATE_KEY=0x… \
 *   AGENT_IDENTITY_REGISTRY=$(jq -r .proxies.AgentIdentityRegistry deployments/base-sepolia.json) \
 *   forge script script/DeployIdentityKeyExtension.s.sol \
 *     --rpc-url "$BASE_SEPOLIA_RPC_URL" --broadcast
 */
contract DeployIdentityKeyExtensionScript is Script {
    function run() external returns (address proxy) {
        uint256 pk            = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address identityProxy = vm.envAddress("AGENT_IDENTITY_REGISTRY");

        vm.startBroadcast(pk);

        // Constructor calls _disableInitializers(), so the implementation
        // itself is uncallable — every path goes through the proxy.
        AgentIdentityKeyExtension impl = new AgentIdentityKeyExtension();
        console.log("AgentIdentityKeyExtension impl: ", address(impl));

        ERC1967Proxy p = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AgentIdentityKeyExtension.initialize, (identityProxy))
        );
        proxy = address(p);

        vm.stopBroadcast();

        // Prove the proxy came up wired, rather than reporting an address
        // that reverts on first use.
        require(
            address(AgentIdentityKeyExtension(proxy).identityRegistry()) == identityProxy,
            "registry not wired"
        );

        console.log("AgentIdentityKeyExtension proxy:", proxy);
        console.log("Bound IdentityRegistry:         ", identityProxy);
        console.log("Owner:                          ", AgentIdentityKeyExtension(proxy).owner());
        console.log("Wire: AGENT_IDENTITY_KEY_EXTENSION env for the Go daemon (cmd/server)");
    }
}
