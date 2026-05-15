// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAgentIdentityRegistry
 * @notice Interface for Agent Identity Registry
 * @dev Shared interface used by TBARegistry, PaymentRouter, and other contracts
 */
interface IAgentIdentityRegistry {
    function ownerOf(uint256 tokenId) external view returns (address);
    function setTBAAddress(uint256 agentId, address tbaAddress) external;
    function getCreatorRoyalty(uint256 agentId) external view returns (address creator, uint256 royaltyBps);
    function agents(uint256 agentId) external view returns (
        string memory name,
        address tbaAddress,
        uint256 createdAt,
        bool active
    );

    // V7: Secondary-market royalty splitter
    function secondarySystemFeeBps() external view returns (uint256);
    function secondaryTreasury() external view returns (address);
    function royaltyVaultAddress(uint256 agentId) external view returns (address);
    function deployRoyaltyVault(uint256 agentId) external returns (address);
}
