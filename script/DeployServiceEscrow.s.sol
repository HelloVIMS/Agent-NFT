// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentX402Receiver.sol";
import "../src/AgentServiceEscrow.sol";

/**
 * Upgrades AgentX402Receiver (escrowed payments, shared split) and deploys
 * AgentServiceEscrow behind it. Watchers are added separately
 * (addWatcherSet) once their keys exist; until then escrowed payments
 * revert NoWatcherSet and nothing can be stuck.
 *
 *   DEPLOYER_PRIVATE_KEY, AGENT_X402_RECEIVER, CLAIM_WINDOW (seconds, default 48h)
 */
contract DeployServiceEscrow is Script {
    function run() external returns (AgentServiceEscrow escrow) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        AgentX402Receiver receiver = AgentX402Receiver(vm.envAddress("AGENT_X402_RECEIVER"));
        uint64 window = uint64(vm.envOr("CLAIM_WINDOW", uint256(48 hours)));
        require(receiver.owner() == vm.addr(pk), "signer does not own the receiver proxy");
        address identity = address(receiver.identityRegistry());
        address reputation = address(receiver.reputationRegistry());
        address treasury = receiver.treasury();
        uint256 feeBps = receiver.systemFeeBps();

        vm.startBroadcast(pk);
        receiver.upgradeToAndCall(address(new AgentX402Receiver()), "");
        escrow = AgentServiceEscrow(address(new ERC1967Proxy(
            address(new AgentServiceEscrow()),
            abi.encodeCall(AgentServiceEscrow.initialize, (address(receiver), window))
        )));
        receiver.setServiceEscrow(address(escrow));
        vm.stopBroadcast();

        require(address(receiver.identityRegistry()) == identity, "identity registry changed");
        require(address(receiver.reputationRegistry()) == reputation, "reputation registry changed");
        require(receiver.treasury() == treasury && receiver.systemFeeBps() == feeBps, "fee config changed");
        require(address(receiver.serviceEscrow()) == address(escrow), "escrow not wired");
        console.log("AgentServiceEscrow:", address(escrow));
    }
}
