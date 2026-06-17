// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title  AgentIdentityURILib
 * @notice External library DELEGATECALLed from {AgentIdentityRegistry.tokenURI}
 *         to keep the Base64 + JSON-builder bytecode out of the impl.
 *
 * @dev    Extraction rationale: the JSON construction in `_buildTokenURI` is
 *         ~1 KB of static-string + Base64 dispatch that is exercised only
 *         on `tokenURI(...)` reads. Moving it to a library gets us back
 *         under the EIP-170 24,576 B impl ceiling without any behavioural
 *         change. Output is byte-identical to the previous in-impl path.
 */
library AgentIdentityURILib {
    using Strings for uint256;

    function buildOnChainTokenURI(
        uint256 tokenId,
        string memory agentName,
        string memory svg,
        bool active,
        bool hasTBA
    ) external pure returns (string memory) {
        string memory svgBase64 = Base64.encode(bytes(svg));

        bytes memory jsonPart1 = abi.encodePacked(
            '{"name":"', agentName, '",',
            '"description":"Agent AI Agent #', tokenId.toString(), '",',
            '"image":"data:image/svg+xml;base64,', svgBase64, '",'
        );

        bytes memory jsonPart2 = abi.encodePacked(
            '"attributes":[',
            '{"trait_type":"Active","value":"', active ? "true" : "false", '"},',
            '{"trait_type":"Has TBA","value":"', hasTBA ? "true" : "false", '"}',
            ']}'
        );

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(abi.encodePacked(jsonPart1, jsonPart2))
        ));
    }

    /// @notice Rich tokenURI variant exposing creator, royalty, anchor,
    ///         createdAt and collection traits so OpenSea/Blur trait
    ///         filters surface meaningful facets. Output is JSON
    ///         compliant with the OpenSea metadata standard.
    struct RichTokenInputs {
        uint256 tokenId;
        string  agentName;
        string  svg;
        bool    active;
        bool    hasTBA;
        address creator;
        uint256 creatorRoyaltyBps;
        uint256 systemRoyaltyBps;
        uint256 createdAt;
        uint256 collectionId;
        address anchor;
    }

    function buildOnChainTokenURIRich(RichTokenInputs memory i)
        external pure returns (string memory)
    {
        string memory svgBase64 = Base64.encode(bytes(i.svg));

        bytes memory head = abi.encodePacked(
            '{"name":"', i.agentName, '",',
            '"description":"VIMS Agent #', i.tokenId.toString(),
            ' \u2014 an autonomous on-chain AI agent with soulbound creator royalties (ERC-2981) and a Token-Bound Account (ERC-6551).",',
            '"image":"data:image/svg+xml;base64,', svgBase64, '",'
        );

        bytes memory traitsA = abi.encodePacked(
            '"attributes":[',
            '{"trait_type":"Active","value":"', i.active ? "true" : "false", '"},',
            '{"trait_type":"Has TBA","value":"', i.hasTBA ? "true" : "false", '"},',
            '{"trait_type":"Creator","value":"', _addrToHexString(i.creator), '"},'
        );

        bytes memory traitsB = abi.encodePacked(
            '{"trait_type":"Creator Royalty","display_type":"boost_percentage","value":', _bpsToPercentString(i.creatorRoyaltyBps), '},',
            '{"trait_type":"Protocol Royalty","display_type":"boost_percentage","value":', _bpsToPercentString(i.systemRoyaltyBps), '},',
            '{"trait_type":"Created","display_type":"date","value":', i.createdAt.toString(), '}'
        );

        bytes memory traitsC = abi.encodePacked(
            i.collectionId == 0 ? bytes("") : abi.encodePacked(
                ',{"trait_type":"Collection","display_type":"number","value":', i.collectionId.toString(), '}'
            ),
            i.anchor == address(0) ? bytes("") : abi.encodePacked(
                ',{"trait_type":"Anchor","value":"', _addrToHexString(i.anchor), '"}'
            ),
            ']}'
        );

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(abi.encodePacked(head, traitsA, traitsB, traitsC))
        ));
    }

    /// @notice OpenSea / Blur compatible collection-level metadata for
    ///         the AgentIdentityRegistry contract. Returned as a base64
    ///         data: URI so no IPFS pin is required.
    function buildContractURIIdentity(
        string  memory collectionName,
        string  memory collectionDescription,
        string  memory externalLink,
        uint256 sellerFeeBps,
        address feeRecipient
    ) external pure returns (string memory) {
        bytes memory json = abi.encodePacked(
            '{"name":"', collectionName, '",',
            '"description":"', collectionDescription, '",',
            '"external_link":"', externalLink, '",',
            '"seller_fee_basis_points":', sellerFeeBps.toString(), ',',
            '"fee_recipient":"', _addrToHexString(feeRecipient), '"}'
        );
        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(json)
        ));
    }

    // ─── helpers ─────────────────────────────────────────────────────

    function _addrToHexString(address a) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes20 raw = bytes20(a);
        bytes memory out = new bytes(42);
        out[0] = "0"; out[1] = "x";
        for (uint256 i; i < 20; ) {
            uint8 b = uint8(raw[i]);
            out[2 + i * 2]     = hexChars[b >> 4];
            out[2 + i * 2 + 1] = hexChars[b & 0x0f];
            unchecked { ++i; }
        }
        return string(out);
    }

    /// @dev Render basis-points as a base-100 string (e.g. 1000 => "10").
    ///      OpenSea's `boost_percentage` expects an integer percentage.
    function _bpsToPercentString(uint256 bps) internal pure returns (string memory) {
        return (bps / 100).toString();
    }
}
