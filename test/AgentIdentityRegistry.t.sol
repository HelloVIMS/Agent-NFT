// SPDX-License-Identifier: AGPL-3.0-or-later
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
        
        uint256 agentId = registry.registerAgent("TestBot", "ipfs://metadata", 1000, address(0));
        
        assertEq(agentId, 0);
        assertEq(registry.ownerOf(0), user1);
        assertEq(registry.totalSupply(), 1);
    }
    
    function test_RegisterMultipleAgents() public {
        vm.prank(user1);
        uint256 id1 = registry.registerAgent("Bot1", "uri1", 1000, address(0));
        
        vm.prank(user1);
        uint256 id2 = registry.registerAgent("Bot2", "uri2", 1000, address(0));
        
        vm.prank(user2);
        uint256 id3 = registry.registerAgent("Bot3", "uri3", 1000, address(0));
        
        assertEq(id1, 0);
        assertEq(id2, 1);
        assertEq(id3, 2);
        assertEq(registry.totalSupply(), 3);
    }
    
    function test_GetAgent() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "ipfs://test", 1000, address(0));
        
        (string memory name, address tba, uint256 createdAt, bool active, address agentOwner,) = registry.getAgent(agentId);
        
        assertEq(name, "TestBot");
        assertEq(tba, address(0));
        assertGt(createdAt, 0);
        assertTrue(active);
        assertEq(agentOwner, user1);
    }
    
    function test_GetAgentsByOwner() public {
        vm.startPrank(user1);
        registry.registerAgent("Bot1", "uri1", 1000, address(0));
        registry.registerAgent("Bot2", "uri2", 1000, address(0));
        vm.stopPrank();
        
        vm.prank(user2);
        registry.registerAgent("Bot3", "uri3", 1000, address(0));
        
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
        uint256 agentId = registry.registerAgent("TestBot", "uri", 1000, address(0));
        
        address tbaAddress = address(0x123);
        
        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit TBAAddressSet(agentId, tbaAddress);
        
        registry.setTBAAddress(agentId, tbaAddress);
        
        (,address tba,,,,) = registry.getAgent(agentId);
        assertEq(tba, tbaAddress);
    }
    
    function test_SetTBAAddress_RevertNotOwner() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "uri", 1000, address(0));
        
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(AgentIdentityRegistry.NotOwner.selector));
        registry.setTBAAddress(agentId, address(0x123));
    }
    
    function test_SetTBAAddress_RevertAlreadySet() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "uri", 1000, address(0));
        
        vm.startPrank(user1);
        registry.setTBAAddress(agentId, address(0x123));
        
        vm.expectRevert(abi.encodeWithSelector(AgentIdentityRegistry.AlreadySet.selector));
        registry.setTBAAddress(agentId, address(0x456));
        vm.stopPrank();
    }
    
    function test_DeactivateAgent() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "uri", 1000, address(0));
        
        vm.prank(user1);
        vm.expectEmit(true, false, false, false);
        emit AgentDeactivated(agentId);
        
        registry.deactivateAgent(agentId);
        
        (,,,bool active,,) = registry.getAgent(agentId);
        assertFalse(active);
    }
    
    function test_ActivateAgent() public {
        vm.startPrank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "uri", 1000, address(0));
        registry.deactivateAgent(agentId);
        
        vm.expectEmit(true, false, false, false);
        emit AgentActivated(agentId);
        
        registry.reactivateAgent(agentId);
        vm.stopPrank();
        
        (,,,bool active,,) = registry.getAgent(agentId);
        assertTrue(active);
    }
    
    function test_TokenURI() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "ipfs://metadata123", 1000, address(0));
        
        string memory uri = registry.tokenURI(agentId);
        assertEq(uri, "ipfs://metadata123");
    }
    
    function test_UpdateAgentURI() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "old-uri", 1000, address(0));
        
        vm.prank(user1);
        registry.updateAgentURI(agentId, "new-uri");
        
        assertEq(registry.tokenURI(agentId), "new-uri");
    }
    
    function test_UpdateAgentURI_RevertNotOwner() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "uri", 1000, address(0));
        
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(AgentIdentityRegistry.NotOwner.selector));
        registry.updateAgentURI(agentId, "hacked");
    }
    
    function test_Transfer() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("TestBot", "uri", 1000, address(0));
        
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
    
    // ============ A++ Audit regressions ============

    /**
     * @dev Whale-DoS guard: transferring any token MUST cost roughly the same
     *      gas regardless of how many agents the seller holds. Pre-fix the
     *      ownerAgents removal was O(n); the swap-and-pop index makes it O(1).
     *      We assert the heavy-holder transfer is within 1.5x of the single-
     *      holder transfer to lock the invariant.
     */
    function test_AUDIT_TransferIsO1_RegardlessOfHoldings() public {
        // Baseline: user1 holds exactly 1 agent.
        vm.prank(user1);
        uint256 lonelyAgent = registry.registerAgent("Solo", "uri", 0, address(0));

        // user2 holds 50 agents.
        vm.startPrank(user2);
        uint256 firstId;
        for (uint256 i; i < 50; ++i) {
            uint256 id = registry.registerAgent("M", "uri", 0, address(0));
            if (i == 0) firstId = id;
        }
        vm.stopPrank();

        // Measure baseline transfer (1-holding).
        vm.prank(user1);
        uint256 g0 = gasleft();
        registry.transferFrom(user1, address(0xCAFE), lonelyAgent);
        uint256 baselineGas = g0 - gasleft();

        // Measure transfer from heavy holder (50-holding) of the FIRST token,
        // which is the worst case for the legacy linear scan.
        vm.prank(user2);
        uint256 g1 = gasleft();
        registry.transferFrom(user2, address(0xBEEF), firstId);
        uint256 heavyGas = g1 - gasleft();

        // Heavy transfer must not balloon. 1.5x ceiling is generous enough to
        // absorb event/encoding noise while still catching O(n) regressions
        // (which would push heavyGas into 5-10x baseline territory).
        assertLt(heavyGas, (baselineGas * 3) / 2, "transfer is not O(1)");

        // Integrity: user2 now holds 49, and `firstId` is no longer in the list.
        uint256[] memory left = registry.getAgentsByOwner(user2);
        assertEq(left.length, 49);
        for (uint256 i; i < left.length; ++i) {
            assertTrue(left[i] != firstId, "swap-and-pop failed to remove");
        }
    }

    /**
     * @dev Swap-and-pop must preserve the integrity of every remaining
     *      tokenId, and update the reverse index for the swapped-in token so
     *      a subsequent transfer still works in O(1).
     */
    function test_AUDIT_OwnerAgents_SwapAndPopIntegrity() public {
        vm.startPrank(user1);
        uint256 a = registry.registerAgent("A", "u", 0, address(0));
        uint256 b = registry.registerAgent("B", "u", 0, address(0));
        uint256 c = registry.registerAgent("C", "u", 0, address(0));
        vm.stopPrank();

        // Transfer middle agent — forces swap of `c` into b's slot.
        vm.prank(user1);
        registry.transferFrom(user1, user2, b);

        uint256[] memory remaining = registry.getAgentsByOwner(user1);
        assertEq(remaining.length, 2);
        // `a` retains position 0; `c` should now sit at position 1.
        assertEq(remaining[0], a);
        assertEq(remaining[1], c);

        // Now transfer `c` — must still work (index for `c` was updated to slot 1).
        vm.prank(user1);
        registry.transferFrom(user1, user2, c);

        uint256[] memory final_ = registry.getAgentsByOwner(user1);
        assertEq(final_.length, 1);
        assertEq(final_[0], a);
    }

    function testFuzz_RegisterAgent(string memory name, string memory uri) public {
        vm.assume(bytes(name).length > 0);
        vm.assume(bytes(uri).length > 0);
        
        vm.prank(user1);
        uint256 agentId = registry.registerAgent(name, uri, 1000, address(0));
        
        assertEq(agentId, 0); // First token ID is 0
        assertEq(registry.ownerOf(0), user1);
    }

    // ============ On-chain SVG (MAX_SVG_SIZE = 48KB) ============

    function test_MaxSVGSize_Is48KB() public view {
        assertEq(registry.MAX_SVG_SIZE(), 49152, "MAX_SVG_SIZE must be 48KB (49152 bytes)");
    }

    function test_SetSVGImage_AcceptsUpTo48KB() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("SVGBot", "ipfs://meta", 1000, address(0));

        // Exactly 48KB — should succeed
        bytes memory svg = new bytes(49152);
        for (uint256 i = 0; i < svg.length; i++) svg[i] = bytes1(uint8(0x20)); // printable ASCII

        vm.prank(user1);
        registry.setSVGImage(agentId, string(svg));
        assertEq(bytes(registry.getSVGImage(agentId)).length, 49152);
    }

    function test_SetSVGImage_RevertsOver48KB() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("SVGBot", "ipfs://meta", 1000, address(0));

        // 48KB + 1 byte — must revert TooLarge
        bytes memory svg = new bytes(49153);
        for (uint256 i = 0; i < svg.length; i++) svg[i] = bytes1(uint8(0x20));

        vm.prank(user1);
        vm.expectRevert(AgentIdentityRegistry.TooLarge.selector);
        registry.setSVGImage(agentId, string(svg));
    }

    function test_SetSVGImage_RevertsIfNotOwner() public {
        vm.prank(user1);
        uint256 agentId = registry.registerAgent("SVGBot", "ipfs://meta", 1000, address(0));

        vm.prank(user2);
        vm.expectRevert(AgentIdentityRegistry.NotOwner.selector);
        registry.setSVGImage(agentId, "<svg/>");
    }
}
