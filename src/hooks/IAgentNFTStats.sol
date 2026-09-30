// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

/// @notice Per-NFT paid-hire stats AgentX402Receiver records on every
///         settlement (identity and collection agents alike).
interface IAgentNFTStats {
    function nftSettlements(address nft, uint256 tokenId) external view returns (uint64);
    function nftVolume(address nft, uint256 tokenId, address token) external view returns (uint256);
    function identityRegistry() external view returns (address);
}
