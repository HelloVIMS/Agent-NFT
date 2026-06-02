// SPDX-License-Identifier: MIT
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
}
