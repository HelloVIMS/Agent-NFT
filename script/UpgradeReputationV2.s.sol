// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentReputationRegistry.sol";
import "../src/AgentX402Receiver.sol";

/**
 * @title  UpgradeReputationV2Script
 * @notice Reputation v2: owner eras, paid-only attestations, on-chain system
 *         reputation. Upgrades both proxies and wires them together:
 *
 *           1. new AgentReputationRegistry impl  → reputation.upgradeToAndCall
 *           2. new AgentX402Receiver impl        → receiver.upgradeToAndCall
 *           3. reputation.setSettlementRecorder(receiver, true)
 *           4. receiver.setReputationRegistry(reputation)
 *
 *         Storage: both upgrades only append state (checked by
 *         test/ReputationV2Upgrade.t.sol against the pre-upgrade layout).
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY       — owner of both proxies
 *   AGENT_REPUTATION_REGISTRY  — reputation proxy
 *   AGENT_X402_RECEIVER        — receiver proxy
 */
contract UpgradeReputationV2Script is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        AgentReputationRegistry reputation = AgentReputationRegistry(vm.envAddress("AGENT_REPUTATION_REGISTRY"));
        AgentX402Receiver receiver = AgentX402Receiver(vm.envAddress("AGENT_X402_RECEIVER"));
        address signer = vm.addr(pk);
        require(reputation.owner() == signer, "signer does not own the reputation proxy");
        require(receiver.owner() == signer, "signer does not own the receiver proxy");
        require(address(reputation.identityRegistry()) == address(receiver.identityRegistry()), "registries point at different identity registries");

        vm.startBroadcast(pk);
        AgentReputationRegistry repImpl = new AgentReputationRegistry();
        reputation.upgradeToAndCall(address(repImpl), "");
        AgentX402Receiver recvImpl = new AgentX402Receiver();
        receiver.upgradeToAndCall(address(recvImpl), "");
        reputation.setSettlementRecorder(address(receiver), true);
        receiver.setReputationRegistry(address(reputation));
        vm.stopBroadcast();

        require(reputation.settlementRecorders(address(receiver)), "recorder not set");
        require(address(receiver.reputationRegistry()) == address(reputation), "registry not set");
        console.log("AgentReputationRegistry impl (v2):", address(repImpl));
        console.log("AgentX402Receiver impl (v2):      ", address(recvImpl));
    }
}
