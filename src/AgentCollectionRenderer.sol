// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title  AgentCollectionRenderer
 * @notice External library that builds the on-chain `tokenURI` and
 *         `contractURI` JSON+SVG payloads for {AgentCollectionImpl}.
 *
 * @dev    Deployed once per chain. The impl links against it at compile
 *         time and dispatches via DELEGATECALL, keeping the impl bytecode
 *         well under the EIP-170 24,576-byte ceiling.
 *
 *         All functions are pure and operate purely on calldata/memory
 *         arguments — no library-side storage, no privileged callers.
 */
library AgentCollectionRenderer {
    using Strings for uint256;

    /// @notice Inputs needed to render a single token's metadata JSON.
    /// @dev    The impl gathers these from its own storage and passes them
    ///         in; this struct is intentionally flat to avoid nested ABI
    ///         encoding overhead and to keep the call gas-cheap.
    struct TokenURIInput {
        uint256 tokenId;
        uint256 maxSupply;
        bytes   svg;             // raw on-chain SVG bytes
        string  agentName;
        string  collectionDescription;
        string  collectionName;
        bool    active;
        bool    hasTBA;
        uint256 salesBps;
        uint256 serviceBps;
        uint256 pixeVersionsLen;
        uint256 createdAt;
        address agentCreator;
    }

    /**
     * @notice Build the data:application/json;base64,... token URI for an
     *         agent that has on-chain SVG storage configured.
     */
    function buildTokenURI(TokenURIInput memory i) external pure returns (string memory) {
        string memory svgBase64 = Base64.encode(i.svg);

        string memory editionStr = i.maxSupply > 0
            ? string(abi.encodePacked("#", i.tokenId.toString(), " of ", i.maxSupply.toString()))
            : string(abi.encodePacked("#", i.tokenId.toString()));

        bytes memory part1 = abi.encodePacked(
            '{"name":"', i.agentName, '",',
            '"description":"', i.collectionDescription, '",',
            '"image":"data:image/svg+xml;base64,', svgBase64, '",',
            '"external_url":"https://bots.vims.com/agent/', i.tokenId.toString(), '",'
        );

        bytes memory part2 = abi.encodePacked(
            '"attributes":[',
            '{"trait_type":"Edition","value":"', editionStr, '"},',
            '{"trait_type":"Collection","value":"', i.collectionName, '"},',
            '{"trait_type":"Status","value":"', i.active ? "Active" : "Inactive", '"},',
            '{"trait_type":"Sales Royalty","value":"', (i.salesBps / 100).toString(), '%"},',
            '{"trait_type":"Service Royalty","value":"', (i.serviceBps / 100).toString(), '%"},'
        );

        bytes memory part3 = abi.encodePacked(
            '{"trait_type":"Has TBA","value":"', i.hasTBA ? "Yes" : "No", '"},',
            '{"trait_type":"Pixe Versions","display_type":"number","value":', i.pixeVersionsLen.toString(), '},',
            '{"trait_type":"Created","display_type":"date","value":', i.createdAt.toString(), '},',
            '{"trait_type":"Creator","value":"', addressToString(i.agentCreator), '"}',
            ']}'
        );

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(abi.encodePacked(part1, part2, part3))
        ));
    }

    /**
     * @notice Build the data:application/json;base64,... collection-level
     *         contractURI consumed by OpenSea and other marketplaces.
     */
    function buildContractURI(
        string memory collectionName,
        string memory collectionDescription,
        uint256 sellerFeeBps,
        address feeRecipient
    ) external pure returns (string memory) {
        bytes memory json = abi.encodePacked(
            '{"name":"', collectionName, '",',
            '"description":"', collectionDescription, '",',
            '"seller_fee_basis_points":', sellerFeeBps.toString(), ',',
            '"fee_recipient":"', addressToString(feeRecipient), '"}'
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    /**
     * @notice Compose a generative-drop tokenURI as
     *         `string.concat(baseURI, tokenId, ".json")`.
     *         Lives here (not in the impl) so the impl bytecode stays
     *         under the EIP-170 ceiling.
     */
    function buildSequentialURI(string memory baseURI, uint256 tokenId)
        external
        pure
        returns (string memory)
    {
        return string.concat(baseURI, tokenId.toString(), ".json");
    }

    /**
     * @notice Hex-encode an address as a 0x-prefixed lowercase string.
     */
    function addressToString(address addr) public pure returns (string memory) {
        bytes16 alphabet = "0123456789abcdef";
        bytes20 data = bytes20(addr);
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; ++i) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}
