// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";

/// On-chain SVG agents keep their art on-chain and point at their metadata
/// document (services manifest, avatars) through agent_uri.
contract CollectionAgentURITest is Test {
    AgentCollectionFactory factory;
    AgentCollectionImpl collection;
    address creator = address(0xC0);
    address buyer   = address(0xB0);

    function setUp() public {
        AgentCollectionImpl impl = new AgentCollectionImpl();
        factory = new AgentCollectionFactory(address(impl), address(0xFEE));
        vm.prank(creator);
        (, address addr) = factory.createCollection("Agents \"on-chain\"", "AOC", 100, 500, 500, "Line one\nline two");
        collection = AgentCollectionImpl(addr);
    }

    /// Decodes the data:application/json;base64 token URI.
    function _json(uint256 id) internal view returns (string memory) {
        bytes memory uri = bytes(collection.tokenURI(id));
        bytes memory prefix = "data:application/json;base64,";
        for (uint256 i; i < prefix.length; ++i) require(uri[i] == prefix[i], "not a base64 JSON data URI");
        bytes memory b64 = new bytes(uri.length - prefix.length);
        for (uint256 i; i < b64.length; ++i) b64[i] = uri[prefix.length + i];
        return string(_b64decode(b64));
    }

    function _b64decode(bytes memory data) internal pure returns (bytes memory out) {
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint8[128] memory rev;
        for (uint8 i; i < 64; ++i) rev[uint8(table[i])] = i;
        uint256 pad = data.length > 0 && data[data.length - 1] == "=" ? (data[data.length - 2] == "=" ? 2 : 1) : 0;
        out = new bytes((data.length / 4) * 3 - pad);
        uint256 j;
        for (uint256 i; i < data.length; i += 4) {
            uint256 n = (uint256(rev[uint8(data[i])]) << 18) | (uint256(rev[uint8(data[i + 1])]) << 12)
                | (uint256(data[i + 2] == "=" ? 0 : rev[uint8(data[i + 2])]) << 6) | uint256(data[i + 3] == "=" ? 0 : rev[uint8(data[i + 3])]);
            if (j < out.length) out[j++] = bytes1(uint8(n >> 16));
            if (j < out.length) out[j++] = bytes1(uint8(n >> 8));
            if (j < out.length) out[j++] = bytes1(uint8(n));
        }
    }

    function test_onChainArtWithAMetadataDocument() public {
        vm.prank(creator);
        uint256 id = collection.mintAgentWithSVG("Seer", "<svg/>", "ipfs://manifest");
        string memory json = _json(id);
        assertEq(vm.parseJsonString(json, ".agent_uri"), "ipfs://manifest");
        assertEq(vm.parseJsonString(json, ".image"), "data:image/svg+xml;base64,PHN2Zy8+");
    }

    function test_noMetadataDocumentNoField() public {
        vm.prank(creator);
        uint256 id = collection.mintAgentWithSVG("Seer", "<svg/>", "");
        assertFalse(vm.keyExistsJson(_json(id), ".agent_uri"));
    }

    /// The owner updates the document — e.g. publishing services — and the
    /// art stays on-chain; a sale moves that right to the buyer.
    function test_ownerUpdatesTheDocument() public {
        vm.prank(creator);
        uint256 id = collection.mintAgentWithSVG("Seer", "<svg/>", "ipfs://v1");
        vm.prank(creator);
        collection.updateAgentURI(id, "data:application/json,%7B%22services%22%3A%5B%5D%7D");
        assertEq(vm.parseJsonString(_json(id), ".agent_uri"), "data:application/json,%7B%22services%22%3A%5B%5D%7D");
        assertEq(uint8(collection.metadataMode(id)), uint8(AgentCollectionImpl.MetadataMode.OnChainSVG));
        vm.prank(creator);
        collection.transferFrom(creator, buyer, id);
        vm.prank(creator);
        vm.expectRevert(AgentCollectionImpl.NotOwner.selector);
        collection.updateAgentURI(id, "ipfs://hijack");
        vm.prank(buyer);
        collection.updateAgentURI(id, "ipfs://v2");
        assertEq(vm.parseJsonString(_json(id), ".agent_uri"), "ipfs://v2");
    }

    /// Names, descriptions and URIs with quotes, backslashes or control
    /// characters can't break or inject into the generated JSON.
    function test_userTextIsEscaped() public {
        vm.prank(creator);
        uint256 id = collection.mintAgentWithSVG('Evil", "agent_uri":"ipfs://fake', "<svg/>", 'ipfs://real"\\x');
        string memory json = _json(id);
        assertEq(vm.parseJsonString(json, ".name"), 'Evil", "agent_uri":"ipfs://fake');
        assertEq(vm.parseJsonString(json, ".agent_uri"), 'ipfs://real"\\x');
        assertEq(vm.parseJsonString(json, ".description"), "Line one\nline two");
    }

    function test_baseURITokensStayLocked() public {
        vm.startPrank(creator);
        collection.setBaseURI("ipfs://drop/");
        uint256 id = collection.registerAgent("Drop", "");
        vm.expectRevert(AgentCollectionImpl.MetadataModeLocked.selector);
        collection.updateAgentURI(id, "ipfs://other");
        vm.stopPrank();
    }
}
