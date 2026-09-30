// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {AgentReputationRegistry} from "../src/AgentReputationRegistry.sol";
import {AgentX402Receiver} from "../src/AgentX402Receiver.sol";

/**
 * @title  UpgradeReputationV3Script
 * @notice Reputation for every agent NFT: AgentReputationRegistry v3
 *         (collection agents through refOf) and the receiver that records
 *         their settlements. Storage appended only; rehearsed by
 *         test/ReputationV3UpgradeFork.t.sol against live state.
 *
 * Env: DEPLOYER_PRIVATE_KEY (owner of both proxies)
 */
contract UpgradeReputationV3Script is Script {
    AgentReputationRegistry constant REPUTATION = AgentReputationRegistry(0x5563EE2939F6839CE82B3cA6E50AA285e8d1C316);
    AgentX402Receiver constant RECEIVER = AgentX402Receiver(0xd180DC89270Df505F5d4B7B36e83318f330014A7);

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(REPUTATION.owner() == vm.addr(pk) && RECEIVER.owner() == vm.addr(pk), "signer does not own the proxies");
        vm.startBroadcast(pk);
        AgentReputationRegistry rep = new AgentReputationRegistry();
        REPUTATION.upgradeToAndCall(address(rep), "");
        AgentX402Receiver recv = new AgentX402Receiver();
        RECEIVER.upgradeToAndCall(address(recv), "");
        vm.stopBroadcast();
        console.log("AgentReputationRegistry impl:", address(rep));
        console.log("AgentX402Receiver impl:", address(recv));
    }
}
