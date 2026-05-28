// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAgentMintable
 * @notice Interface for Agent NFT contracts that support cross-chain minting
 * @dev Implement this interface on AgentIdentityRegistry to enable Hyperlane bridging
 */
interface IAgentMintable {
    /**
     * @notice Mint a mirror token from another chain
     * @param to Recipient address
     * @param tokenId Original token ID (must match across chains)
     * @param tokenURI Token metadata URI
     * @param originDomain The Hyperlane domain where the original token exists
     */
    function mintMirror(
        address to,
        uint256 tokenId,
        string calldata tokenURI,
        uint32 originDomain
    ) external;
    
    /**
     * @notice Burn a mirror token when bridging back
     * @param tokenId Token ID to burn
     */
    function burnMirror(uint256 tokenId) external;
    
    /**
     * @notice Check if a token is a mirror (bridged from another chain)
     * @param tokenId Token ID to check
     * @return True if the token is a mirror
     */
    function isMirror(uint256 tokenId) external view returns (bool);
    
    /**
     * @notice Get the origin domain of a mirror token
     * @param tokenId Token ID to check
     * @return The Hyperlane domain ID where the original token exists
     */
    function mirrorOriginDomain(uint256 tokenId) external view returns (uint32);
}
