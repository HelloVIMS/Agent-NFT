// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentAvatarExtension.sol";

/**
 * Ship a new AgentAvatarExtension implementation behind the existing proxy.
 *
 * The deployed implementation authorises writes with
 * `ownerOf(tokenId) != msg.sender`, which passes for an unminted token
 * called from address(0) — both sides are zero. Unreachable through the
 * canonical registry, which reverts on an unminted id, but the guard now
 * raises NotExists itself instead of relying on a collaborator to do it.
 *
 * Storage layout is unchanged (the fix lives inside a modifier), and
 * test_upgrade_preservesManifestsAndVersions asserts manifests, versions,
 * ownership and the registry handle survive an upgrade.
 *
 * Usage:
 *   DEPLOYER_PRIVATE_KEY=0x… \
 *   AGENT_AVATAR_EXTENSION=0x132A0d33aC8040A81E5a3A865Ca2D5238D2Bdbc1 \
 *   forge script script/UpgradeAvatarExtensionImplOnly.s.sol \
 *     --rpc-url "$BASE_SEPOLIA_RPC_URL" --broadcast
 *
 * The signer must be the proxy owner: _authorizeUpgrade is onlyOwner, so a
 * wrong key reverts having spent nothing but gas.
 */
contract UpgradeAvatarExtensionImplOnlyScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxy = vm.envAddress("AGENT_AVATAR_EXTENSION");

        // Read through the proxy first, so a wrong address fails here
        // rather than after a new implementation has been paid for, and so
        // the log records what the upgrade was applied to.
        address ownerBefore = AgentAvatarExtension(proxy).owner();
        address registryBefore = address(AgentAvatarExtension(proxy).identityRegistry());
        console.log("Proxy:           ", proxy);
        console.log("Owner before:    ", ownerBefore);
        console.log("Registry before: ", registryBefore);

        vm.startBroadcast(pk);
        AgentAvatarExtension newImpl = new AgentAvatarExtension();
        AgentAvatarExtension(proxy).upgradeToAndCall(address(newImpl), "");
        vm.stopBroadcast();

        // An upgrade that silently detached the proxy from its registry
        // would leave every write reverting, so assert rather than trust.
        require(AgentAvatarExtension(proxy).owner() == ownerBefore, "owner changed");
        require(
            address(AgentAvatarExtension(proxy).identityRegistry()) == registryBefore,
            "registry changed"
        );

        console.log("New impl:        ", address(newImpl));
    }
}
