// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentX402Receiver.sol";
import "../src/AgentServiceStream.sol";

/**
 * Upgrades AgentX402Receiver (streamed payments) and deploys
 * AgentServiceStream behind it, replacing the retired escrow in the same
 * slot.
 *
 *   DEPLOYER_PRIVATE_KEY, AGENT_X402_RECEIVER
 */
contract DeployServiceStream is Script {
    function run() external returns (AgentServiceStream stream) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        AgentX402Receiver receiver = AgentX402Receiver(vm.envAddress("AGENT_X402_RECEIVER"));
        require(receiver.owner() == vm.addr(pk), "signer does not own the receiver proxy");
        address identity = address(receiver.identityRegistry());
        address reputation = address(receiver.reputationRegistry());
        address treasury = receiver.treasury();
        uint256 feeBps = receiver.systemFeeBps();

        vm.startBroadcast(pk);
        receiver.upgradeToAndCall(address(new AgentX402Receiver()), "");
        stream = AgentServiceStream(address(new ERC1967Proxy(
            address(new AgentServiceStream()), abi.encodeCall(AgentServiceStream.initialize, (address(receiver)))
        )));
        receiver.setServiceStream(address(stream));
        vm.stopBroadcast();

        require(address(receiver.identityRegistry()) == identity, "identity registry changed");
        require(address(receiver.reputationRegistry()) == reputation, "reputation registry changed");
        require(receiver.treasury() == treasury && receiver.systemFeeBps() == feeBps, "fee config changed");
        require(address(receiver.serviceStream()) == address(stream), "stream not wired");
        console.log("AgentServiceStream:", address(stream));
    }
}
