// SPDX-License-Identifier: AGPL-3.0-or-later
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
        bool active,
        address reputationAnchor
    );
    function reputationAnchorOf(uint256 agentId) external view returns (address);

    // Secondary-market royalty splitter
    function secondarySystemFeeBps() external view returns (uint256);
    function secondaryTreasury() external view returns (address);
    function royaltyVaultAddress(uint256 agentId) external view returns (address);
    function deployRoyaltyVault(uint256 agentId) external returns (address);

    // 1:Many subaccount registry
    function PERM_PAY()           external view returns (uint96);
    function PERM_REPUTATION()    external view returns (uint96);
    function PERM_CONTEXT_WRITE() external view returns (uint96);
    function PERM_MEMORY_WRITE()  external view returns (uint96);
    function PERM_TREASURY()      external view returns (uint96);
    function PERM_LINK()          external view returns (uint96);
    function agentIdOf(address account) external view returns (
        uint256 agentId,
        bool    bound,
        bool    isPrimary,
        uint96  permissions,
        bool    active
    );
    function hasPermission(address account, uint96 perm) external view returns (bool);
    function requirePermission(address account, uint96 perm, uint256 expectedAgentId) external view;
}
