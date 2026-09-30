// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title  AgentNFTRefs
 * @notice One agent id for every agent NFT. Contracts that key data by an
 *         identity-registry token id (reputation, identity keys, memory,
 *         avatars) also serve agents of any other ERC-721 — collections from
 *         AgentCollectionFactory — through the reference `refOf(nft, id)`:
 *         the token id itself for the identity registry, otherwise a hash of
 *         (nft, id) tagged with the top bit, which no identity token id has.
 *
 *         A reference is bound to its NFT the first time something is
 *         written for it; from then on the owner is that NFT's `ownerOf`.
 *
 * @dev    Namespaced storage (ERC-7201), so inheriting it never shifts an
 *         upgradeable contract's existing layout.
 */
abstract contract AgentNFTRefs {
    struct NFTRef { address nft; uint256 tokenId; }

    /// @custom:storage-location erc7201:vims.storage.AgentNFTRefs
    struct RefsStorage { mapping(uint256 => NFTRef) refs; }

    // keccak256(abi.encode(uint256(keccak256("vims.storage.AgentNFTRefs")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant REFS_SLOT = 0xa68fdaec6fe49b41f402369285169ddb98b8a1e04676208755da6a051edd3300;

    uint256 internal constant NFT_REF_TAG = 1 << 255;

    event AgentRefBound(uint256 indexed ref, address indexed nft, uint256 indexed tokenId);

    error InvalidNFT();

    /// @dev The identity registry: its token ids are their own references.
    function _identityNFT() internal view virtual returns (address);

    function _refs() private pure returns (RefsStorage storage $) {
        bytes32 slot = REFS_SLOT;
        assembly { $.slot := slot }
    }

    /// @notice The agent id every function takes for token `tokenId` of `nft`.
    function refOf(address nft, uint256 tokenId) public view returns (uint256) {
        if (nft == _identityNFT()) return tokenId;
        return uint256(keccak256(abi.encode(nft, tokenId))) | NFT_REF_TAG;
    }

    /// @notice The agent NFT a reference names: the identity registry for a
    ///         plain token id, zero for a tagged reference not yet bound.
    function nftOf(uint256 ref) public view returns (address nft, uint256 tokenId) {
        if (ref & NFT_REF_TAG == 0) return (_identityNFT(), ref);
        NFTRef storage r = _refs().refs[ref];
        return (r.nft, r.tokenId);
    }

    /// @dev The reference for (nft, tokenId), bound on first use.
    function _bindRef(address nft, uint256 tokenId) internal returns (uint256 ref) {
        if (nft == address(0)) revert InvalidNFT();
        ref = refOf(nft, tokenId);
        if (ref == tokenId) return ref;
        NFTRef storage r = _refs().refs[ref];
        if (r.nft == address(0)) {
            r.nft = nft;
            r.tokenId = tokenId;
            emit AgentRefBound(ref, nft, tokenId);
        }
    }

    /// @dev The current owner of the agent a reference names (reverts when
    ///      the token doesn't exist or a tagged reference is unbound).
    function _ownerOfRef(uint256 ref) internal view returns (address) {
        (address nft, uint256 tokenId) = nftOf(ref);
        if (nft == address(0)) revert InvalidNFT();
        return IERC721(nft).ownerOf(tokenId);
    }
}
