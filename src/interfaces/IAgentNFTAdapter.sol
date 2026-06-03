// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

/**
 * @title IAgentNFTAdapter
 * @notice Read-only adapter that lets {AgentX402Receiver} resolve agent
 *         identity, royalty recipient, and payout target for an NFT token
 *         held in *any* compatible contract (the global identity registry,
 *         per-collection ERC-721 impls, or external partner registries).
 *
 *         Concrete implementations may either be a thin standalone adapter
 *         contract or the NFT contract itself (recommended for collections
 *         that already hold all the data — saves a hop and an extra deploy).
 *
 * @dev    Functions are all `view`. Implementations MUST revert (and not
 *         silently return zero) for non-existent token ids so the receiver
 *         can fail closed.
 */
interface IAgentNFTAdapter {
    /// @notice Current holder of the NFT.
    function ownerOf(uint256 tokenId) external view returns (address);

    /**
     * @notice Royalty recipient and basis points for the *service-side* (x402)
     *         royalty. This is the share that flows to the creator on every
     *         service settlement.
     *
     * @dev    For the global {AgentIdentityRegistry} this is the per-agent
     *         creator + royalty. For {AgentCollectionImpl}-style collections
     *         this is the *collection-level* financial recipient (splitter or
     *         collection deployer) and the collection's service royalty bps,
     *         NOT the per-token minter — otherwise downstream buyers who mint
     *         tokens from the collection would themselves receive the royalty
     *         on services rendered by those tokens.
     *
     * @return creator The address that receives the creator cut.
     * @return bps     Creator cut in basis points (0–10_000).
     */
    function serviceRoyaltyOf(uint256 tokenId)
        external
        view
        returns (address creator, uint256 bps);

    /**
     * @notice Token-bound account address for the token, or address(0) if
     *         none is bound. The receiver prefers this over `ownerOf` for the
     *         agent payout leg so funds accrue inside the agent's TBA.
     */
    function tbaOf(uint256 tokenId) external view returns (address);
}
