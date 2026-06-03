// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

interface IAgentTBARegistryLikeLib {
    function createAccount(uint256 agentId, bytes32 salt) external returns (address);
}

interface IAgentX402ReceiverLikeLib {
    function registerServiceFromIdentity(
        uint256 agentId,
        address agentOwner,
        bytes32 serviceId,
        address token,
        uint256 price
    ) external;
}

/**
 * @title  AgentIdentityFullStackLib
 * @notice External library DELEGATECALLed from {AgentIdentityRegistry}'s
 *         `mintWithFullStack` to keep the ERC-6551 + x402 dispatch selectors
 *         out of the impl bytecode.
 *
 * @dev    Twin of {AgentCollectionAtomicLib} — same pattern, same rationale
 *         (EIP-170 24,576 B impl ceiling). Logic is identical to inlining;
 *         the only reason this lives here is bytecode budget on the impl.
 *
 *         Functions are `external` so the Solidity linker inserts
 *         delegatecalls (rather than inlining) — `address(this)` and
 *         `msg.sender` observed inside these functions are the
 *         AgentIdentityRegistry's, which is critical for the x402
 *         receiver's `trustedAgentRegistry == msg.sender` check.
 */
library AgentIdentityFullStackLib {
    /// @notice Run the optional TBA-creation leg. Returns address(0) when
    ///         the trusted registry is unset (the registry-disabled path).
    function tbaLeg(
        address trustedTBARegistry,
        uint256 agentId,
        bytes32 tbaSalt
    ) external returns (address tba) {
        if (trustedTBARegistry == address(0)) return address(0);
        return IAgentTBARegistryLikeLib(trustedTBARegistry).createAccount(agentId, tbaSalt);
    }

    /// @notice Run the optional x402 service-registration leg. Skipped when
    ///         any of (receiver, serviceId, token, price) is zero.
    function serviceLeg(
        address linkedX402Receiver,
        uint256 agentId,
        address agentOwner,
        bytes32 serviceId,
        address token,
        uint256 price
    ) external {
        if (
            linkedX402Receiver == address(0) ||
            serviceId == bytes32(0) ||
            token == address(0) ||
            price == 0
        ) return;
        IAgentX402ReceiverLikeLib(linkedX402Receiver).registerServiceFromIdentity(
            agentId, agentOwner, serviceId, token, price
        );
    }
}
