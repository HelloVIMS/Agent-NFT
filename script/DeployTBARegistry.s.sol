// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentTBARegistry.sol";

interface IIdentityTBA {
    function setTrustedTBARegistry(address r) external;
    function trustedTBARegistry() external view returns (address);
}

/// Deploys an AgentTBARegistry (which deploys the current AgentAccount
/// implementation — V5) and makes it the identity registry's trusted TBA
/// registry, so agents minted from now on get it. Accounts that
/// already exist keep their implementation (ERC-6551 accounts can't be
/// re-pointed).
///
///   IDENTITY_REGISTRY, ENTRYPOINT, PRIVATE_KEY
contract DeployTBARegistry is Script {
    function run() external returns (AgentTBARegistry tba) {
        address identity = vm.envAddress("IDENTITY_REGISTRY");
        address entryPoint = vm.envAddress("ENTRYPOINT");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        tba = deploy(identity, entryPoint);
        vm.stopBroadcast();
        console.log("AgentTBARegistry:", address(tba));
        console.log("AgentAccount implementation:", tba.implementation());
    }

    function deploy(address identity, address entryPoint) public returns (AgentTBARegistry tba) {
        tba = new AgentTBARegistry(identity, entryPoint);
        IIdentityTBA(identity).setTrustedTBARegistry(address(tba));
        require(IIdentityTBA(identity).trustedTBARegistry() == address(tba), "trusted registry not set");
    }
}
