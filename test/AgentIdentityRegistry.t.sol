// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";

contract AgentIdentityRegistryTest is Test {
    AgentIdentityRegistry public registry;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    
    event AgentRegistered(uint256 indexed agentId, address indexed owner, string name, string agentURI);
    event TBAAddressSet(uint256 indexed agentId, address indexed tbaAddress);
    event AgentActivated(uint256 indexed agentId);
    event AgentDeactivated(uint256 indexed agentId);
    
    function setUp() public {
        vm.startPrank(owner);
        AgentIdentityRegistry impl = new AgentIdentityRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        registry = AgentIdentityRegistry(address(proxy));
        vm.stopPrank();
    }
    
    function test_RegisterAgent() public {
        vm.prank(user1);
        
        vm.expectEmit(true, true, false, true);
        emit AgentRegistered(0, user1, "TestBot", "ipfs://metadata");
        
        uint256 agentId = registry.registerAgent("TestBot", "ipfs://metadata");
        
        assertEq(agentId, 0);
        assertEq(registry.ownerOf(0), user1);
        assertEq(registry.totalSupply(), 1);
    }
    
    function test_RegisterMultipleAgents() public {
        vm.prank(user1);
        uint256 id1 = registry.registerAgent("Bot1", "uri1");
        
        vm.prank(user1);
        uint256 id2 = registry.registerAgent("Bot2", "uri2");
        
        vm.prank(user2);
        uint256 id3 = registry.registerAgent("Bot3", "uri3");
        
        assertEq(id1, 0);
        assertEq(id2, 1);
        assertEq(id3, 2);
        assertEq(registry.totalSupply(), 3);
    }
    
    function test_GetAgent() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "ipfs://test");
        
        (string memory name, address tba, uint256 createdAt, bool active, address agentOwner) = registry.getAgent(agentId);
        
        assertEq(name, "TestBot");
        assertEq(tba, address(0));
        assertGt(createdAt, 0);
        assertTrue(active);
        assertEq(agentOwner, user1);
    }
    
    function test_GetAgentsByOwner() public {
        vm.startPrank(user1);
        registry.registerAgent("Bot1", "uri1");
        registry.registerAgent("Bot2", "uri2");
        vm.stopPrank();
        
        vm.prank(user2);
        registry.registerAgent("Bot3", "uri3");
        
        uint256[] memory user1Agents = registry.getAgentsByOwner(user1);
        uint256[] memory user2Agents = registry.getAgentsByOwner(user2);
        
        assertEq(user1Agents.length, 2);
        assertEq(user2Agents.length, 1);
        assertEq(user1Agents[0], 0);
        assertEq(user1Agents[1], 1);
        assertEq(user2Agents[0], 2);
    }
    
    function test_SetTBAAddress() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "uri");
        
        address tbaAddress = address(0x123);
        
        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit TBAAddressSet(agentId, tbaAddress);
        
        registry.setTBAAddress(agentId, tbaAddress);
        
        (,address tba,,,) = registry.getAgent(agentId);
        assertEq(tba, tbaAddress);
    }
    
    function test_SetTBAAddress_RevertNotOwner() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "uri");
        
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(AgentIdentityRegistry.NotOwner.selector));
        registry.setTBAAddress(agentId, address(0x123));
    }
    
    function test_SetTBAAddress_RevertAlreadySet() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "uri");
        
        vm.startPrank(user1);
        registry.setTBAAddress(agentId, address(0x123));
        
        vm.expectRevert(abi.encodeWithSelector(AgentIdentityRegistry.AlreadySet.selector));
        registry.setTBAAddress(agentId, address(0x456));
        vm.stopPrank();
    }
    
    function test_DeactivateAgent() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "uri");
        
        vm.prank(user1);
        vm.expectEmit(true, false, false, false);
        emit AgentDeactivated(agentId);
        
        registry.deactivateAgent(agentId);
        
        (,,,bool active,) = registry.getAgent(agentId);
        assertFalse(active);
    }
    
    function test_ActivateAgent() public {
        vm.startPrank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "uri");
        registry.deactivateAgent(agentId);
        
        vm.expectEmit(true, false, false, false);
        emit AgentActivated(agentId);
        
        registry.activateAgent(agentId);
        vm.stopPrank();
        
        (,,,bool active,) = registry.getAgent(agentId);
        assertTrue(active);
    }
    
    function test_TokenURI() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "ipfs://metadata123");
        
        string memory uri = registry.tokenURI(agentId);
        assertEq(uri, "ipfs://metadata123");
    }
    
    function test_UpdateAgentURI() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "old-uri");
        
        vm.prank(user1);
        registry.updateAgentURI(agentId, "new-uri");
        
        assertEq(registry.tokenURI(agentId), "new-uri");
    }
    
    function test_UpdateAgentURI_RevertNotOwner() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "uri");
        
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(AgentIdentityRegistry.NotOwner.selector));
        registry.updateAgentURI(agentId, "hacked");
    }
    
    function test_Transfer() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "uri");
        
        vm.prank(user1);
        registry.transferFrom(user1, user2, agentId);
        
        assertEq(registry.ownerOf(agentId), user2);
        
        // Check owner tracking updated
        uint256[] memory user1Agents = registry.getAgentsByOwner(user1);
        uint256[] memory user2Agents = registry.getAgentsByOwner(user2);
        
        assertEq(user1Agents.length, 0);
        assertEq(user2Agents.length, 1);
        assertEq(user2Agents[0], agentId);
    }
    
    function testFuzz_RegisterAgent(string memory name, string memory uri) public {
        vm.assume(bytes(name).length > 0);
        vm.assume(bytes(uri).length > 0);
        
        vm.prank(user1);
        uint256 agentId = registry.registerAgent(name, uri);
        
        assertEq(agentId, 0); // First token ID is 0
        assertEq(registry.ownerOf(0), user1);
    }

    // ============ On-chain SVG (MAX_SVG_SIZE = 48KB) ============

    function test_MaxSVGSize_Is48KB() public view {
        assertEq(registry.MAX_SVG_SIZE(), 49152, "MAX_SVG_SIZE must be 48KB (49152 bytes)");
    }

    function test_SetSVGImage_AcceptsUpTo48KB() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("SVGBot", "ipfs://meta");

        // Exactly 48KB — should succeed
        bytes memory svg = new bytes(49152);
        for (uint256 i = 0; i < svg.length; i++) svg[i] = bytes1(uint8(0x20)); // printable ASCII

        vm.prank(user1);
        registry.setSVGImage(agentId, string(svg));
        assertTrue(registry.hasSVGImage(agentId));
        assertEq(bytes(registry.getSVGImage(agentId)).length, 49152);
    }

    function test_SetSVGImage_RevertsOver48KB() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("SVGBot", "ipfs://meta");

        // 48KB + 1 byte — must revert TooLarge
        bytes memory svg = new bytes(49153);
        for (uint256 i = 0; i < svg.length; i++) svg[i] = bytes1(uint8(0x20));

        vm.prank(user1);
        vm.expectRevert(AgentIdentityRegistry.TooLarge.selector);
        registry.setSVGImage(agentId, string(svg));
    }

    function test_SetSVGImage_RevertsIfNotOwner() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("SVGBot", "ipfs://meta");

        vm.prank(user2);
        vm.expectRevert(AgentIdentityRegistry.NotOwner.selector);
        registry.setSVGImage(agentId, "<svg/>");
    }
}
