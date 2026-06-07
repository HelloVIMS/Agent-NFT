// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentIdentityURILib} from "../src/AgentIdentityURILib.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @title  AgentIdentityURILibTest
 * @notice Locks the on-chain JSON tokenURI shape produced by the registry's
 *         delegatecall path. The library is the byte-for-byte source of
 *         truth for `tokenURI(...)` reads, so any drift here would silently
 *         break OpenSea / NFT explorers indexing live agents.
 */
contract AgentIdentityURILibTest is Test {
    function _buildURI(uint256 tokenId, string memory name, string memory svg, bool active, bool hasTBA)
        internal
        view
        returns (string memory)
    {
        // Library function is `external pure`; the testing harness needs no
        // wrapper — call directly on the deployed library address that forge
        // injects when the library is referenced from a contract. For unit
        // testing, we can call it via this contract's delegatecall path.
        return AgentIdentityURILib.buildOnChainTokenURI(tokenId, name, svg, active, hasTBA);
    }

    // ── Encoding shape ─────────────────────────────────────────────────────

    function test_buildOnChainTokenURI_returnsDataJsonBase64Prefix() public view {
        string memory uri = _buildURI(1, "Alice", "<svg/>", true, true);
        bytes memory uriBytes = bytes(uri);
        bytes memory expectedPrefix = bytes("data:application/json;base64,");
        require(uriBytes.length > expectedPrefix.length, "uri too short");
        for (uint256 i = 0; i < expectedPrefix.length; i++) {
            assertEq(uriBytes[i], expectedPrefix[i], "prefix byte mismatch");
        }
    }

    function test_buildOnChainTokenURI_decodedJsonContainsName() public view {
        // Build → strip prefix → base64-decode → assert the JSON contains
        // the agent name we passed in. Token ID embedded in the description.
        string memory uri = _buildURI(42, "Pixel", "<svg></svg>", true, false);
        string memory decoded = _decodeBase64Suffix(uri);
        assertTrue(_contains(decoded, '"name":"Pixel"'), "name missing");
        assertTrue(_contains(decoded, "Agent AI Agent #42"),  "agent id missing from description");
        assertTrue(_contains(decoded, '"image":"data:image/svg+xml;base64,'), "image prefix missing");
    }

    function test_buildOnChainTokenURI_activeTrueRendered() public view {
        string memory uri = _buildURI(1, "x", "<svg/>", true, false);
        string memory decoded = _decodeBase64Suffix(uri);
        assertTrue(_contains(decoded, '"trait_type":"Active","value":"true"'), "active true missing");
        assertTrue(_contains(decoded, '"trait_type":"Has TBA","value":"false"'), "TBA false missing");
    }

    function test_buildOnChainTokenURI_activeFalseRendered() public view {
        string memory uri = _buildURI(7, "x", "<svg/>", false, true);
        string memory decoded = _decodeBase64Suffix(uri);
        assertTrue(_contains(decoded, '"trait_type":"Active","value":"false"'), "active false missing");
        assertTrue(_contains(decoded, '"trait_type":"Has TBA","value":"true"'),  "TBA true missing");
    }

    // ── Edge cases ─────────────────────────────────────────────────────────

    function test_buildOnChainTokenURI_emptySvg() public view {
        string memory uri = _buildURI(1, "x", "", true, true);
        string memory decoded = _decodeBase64Suffix(uri);
        // Empty SVG → empty base64 → image data URI ends in the prefix only.
        assertTrue(_contains(decoded, '"image":"data:image/svg+xml;base64,"'), "empty svg image prefix missing");
    }

    function test_buildOnChainTokenURI_emptyName() public view {
        string memory uri = _buildURI(0, "", "<svg/>", false, false);
        string memory decoded = _decodeBase64Suffix(uri);
        assertTrue(_contains(decoded, '"name":""'), "empty name");
    }

    function testFuzz_buildOnChainTokenURI_alwaysReturnsDataUri(uint256 tokenId, bool active, bool hasTBA) public view {
        string memory uri = _buildURI(tokenId, "fuzz", "<svg/>", active, hasTBA);
        bytes memory expectedPrefix = bytes("data:application/json;base64,");
        bytes memory uriBytes = bytes(uri);
        for (uint256 i = 0; i < expectedPrefix.length; i++) {
            assertEq(uriBytes[i], expectedPrefix[i], "fuzz prefix mismatch");
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    /// @dev Strips the "data:application/json;base64," prefix and base64-decodes the rest.
    function _decodeBase64Suffix(string memory uri) internal pure returns (string memory) {
        bytes memory u = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory body = new bytes(u.length - prefix.length);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = u[prefix.length + i];
        }
        // OZ Base64 has no decode helper; we assert against the raw base64
        // payload instead by re-base64-encoding the expected substring and
        // checking presence. Simpler: do it through naïve substring search
        // on the decoded value via _decode below.
        return string(_decode(string(body)));
    }

    /// @dev Minimal RFC 4648 base64 decoder — enough for our test vectors.
    function _decode(string memory data) internal pure returns (bytes memory) {
        bytes memory in_ = bytes(data);
        if (in_.length == 0) return new bytes(0);
        require(in_.length % 4 == 0, "bad base64 length");

        // Build a 256-entry decode lookup once.
        bytes memory tbl = new bytes(256);
        for (uint256 i = 0; i < tbl.length; i++) tbl[i] = bytes1(uint8(0xff));
        bytes memory alphabet = bytes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/");
        for (uint256 i = 0; i < alphabet.length; i++) {
            tbl[uint8(alphabet[i])] = bytes1(uint8(i));
        }

        uint256 padding = 0;
        if (in_[in_.length - 1] == "=") padding++;
        if (in_[in_.length - 2] == "=") padding++;

        uint256 outLen = (in_.length / 4) * 3 - padding;
        bytes memory out = new bytes(outLen);
        uint256 j;
        for (uint256 i = 0; i < in_.length; i += 4) {
            uint256 c0 = uint8(tbl[uint8(in_[i])]);
            uint256 c1 = uint8(tbl[uint8(in_[i + 1])]);
            uint256 c2 = in_[i + 2] == "=" ? 0 : uint8(tbl[uint8(in_[i + 2])]);
            uint256 c3 = in_[i + 3] == "=" ? 0 : uint8(tbl[uint8(in_[i + 3])]);
            uint256 triple = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
            if (j < outLen) out[j++] = bytes1(uint8((triple >> 16) & 0xff));
            if (j < outLen) out[j++] = bytes1(uint8((triple >> 8) & 0xff));
            if (j < outLen) out[j++] = bytes1(uint8(triple & 0xff));
        }
        return out;
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return n.length == 0;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) { match_ = false; break; }
            }
            if (match_) return true;
        }
        return false;
    }
}
