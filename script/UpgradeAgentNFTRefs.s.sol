// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {AgentReputationRegistry} from "../src/AgentReputationRegistry.sol";
import {AgentIdentityKeyExtension} from "../src/AgentIdentityKeyExtension.sol";
import {AgentMemory} from "../src/AgentMemory.sol";
import {AgentAvatarExtension} from "../src/AgentAvatarExtension.sol";

/**
 * @title  UpgradeAgentNFTRefsScript
 * @notice Every agent NFT gets reputation, identity keys, memory and avatars:
 *         the four contracts share AgentNFTRefs (ERC-7201 storage, so no
 *         layout shifts). Rehearsed by test/AgentNFTRefsUpgradeFork.t.sol.
 *
 * Env: DEPLOYER_PRIVATE_KEY (owner of all four proxies)
 */
contract UpgradeAgentNFTRefsScript is Script {
    address constant REPUTATION = 0x5563EE2939F6839CE82B3cA6E50AA285e8d1C316;
    address constant KEYS       = 0xC6d25a28430eFfD9953250f5BDAC5Ab26228E974;
    address constant MEMORY     = 0x2eEc7cB85a127D2f2B49EE1957d87797C961a2D1;
    address constant AVATARS    = 0x132A0d33aC8040A81E5a3A865Ca2D5238D2Bdbc1;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        address rep = address(new AgentReputationRegistry());
        AgentReputationRegistry(REPUTATION).upgradeToAndCall(rep, "");
        address keys = address(new AgentIdentityKeyExtension());
        AgentIdentityKeyExtension(KEYS).upgradeToAndCall(keys, "");
        address mem = address(new AgentMemory());
        AgentMemory(MEMORY).upgradeToAndCall(mem, "");
        address av = address(new AgentAvatarExtension());
        AgentAvatarExtension(AVATARS).upgradeToAndCall(av, "");
        vm.stopBroadcast();
        console.log("AgentReputationRegistry impl:", rep);
        console.log("AgentIdentityKeyExtension impl:", keys);
        console.log("AgentMemory impl:", mem);
        console.log("AgentAvatarExtension impl:", av);
    }
}
