// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentX402Receiver.sol";

/**
 * @title  UpgradeX402ReceiverScript
 * @notice Upgrades the AgentX402Receiver proxy to the current source and
 *         checks that wiring and configuration survived: identity registry,
 *         reputation registry, treasury and fee. The receiver only appends
 *         storage between versions (test/ReputationV2Upgrade.t.sol re-runs the
 *         upgrade against live state and settles a real hire through it).
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY  — owner of the receiver proxy
 *   AGENT_X402_RECEIVER   — receiver proxy
 */
contract UpgradeX402ReceiverScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        AgentX402Receiver receiver = AgentX402Receiver(vm.envAddress("AGENT_X402_RECEIVER"));
        require(receiver.owner() == vm.addr(pk), "signer does not own the receiver proxy");
        address identity = address(receiver.identityRegistry());
        address reputation = address(receiver.reputationRegistry());
        address treasury = receiver.treasury();
        uint256 feeBps = receiver.systemFeeBps();

        vm.startBroadcast(pk);
        AgentX402Receiver impl = new AgentX402Receiver();
        receiver.upgradeToAndCall(address(impl), "");
        vm.stopBroadcast();

        require(address(receiver.identityRegistry()) == identity, "identity registry changed");
        require(address(receiver.reputationRegistry()) == reputation, "reputation registry changed");
        require(receiver.treasury() == treasury, "treasury changed");
        require(receiver.systemFeeBps() == feeBps, "fee changed");
        console.log("AgentX402Receiver impl:", address(impl));
    }
}
