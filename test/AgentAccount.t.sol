// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentTBARegistry.sol";
import "../src/AgentAccount.sol";

contract AgentAccountTest is Test {
    AgentIdentityRegistry public identityRegistry;
    AgentTBARegistry public tbaRegistry;
    AgentAccount public account;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public attacker = address(0x666);
    
    uint256 public agentId;
    
    event Executed(address indexed target, uint256 value, bytes data, uint256 newState);
    event SessionKeyCreated(bytes32 indexed keyHash, address indexed signer, uint48 validUntil);
    event SessionKeyRevoked(bytes32 indexed keyHash);
    
    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy Identity Registry with proxy
        AgentIdentityRegistry identityImpl = new AgentIdentityRegistry();
        ERC1967Proxy identityProxy = new ERC1967Proxy(
            address(identityImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identityRegistry = AgentIdentityRegistry(address(identityProxy));
        
        // Use a mock entry point for testing
        address mockEntryPoint = address(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);
        tbaRegistry = new AgentTBARegistry(address(identityRegistry), mockEntryPoint);
        vm.stopPrank();
        
        // Create an agent and its TBA
        vm.prank(user1);
        agentId = identityRegistry.registerAgent("TestBot", "uri", 1000, address(0));
        
        vm.prank(user1);
        address accountAddress = tbaRegistry.createAccount(
            agentId,
            bytes32(0)
        );
        
        account = AgentAccount(payable(accountAddress));
        
        // Fund the account
        vm.deal(accountAddress, 10 ether);
    }
    
    function test_Owner() public view {
        assertEq(account.owner(), user1);
    }
    
    function test_Execute() public {
        address target = address(0x123);
        uint256 value = 1 ether;
        bytes memory data = "";
        
        uint256 initialState = account.state();
        
        vm.prank(user1);
        account.execute(target, value, data, 0);
        
        assertEq(target.balance, 1 ether);
        assertEq(account.state(), initialState + 1);
    }
    
    function test_Execute_RevertNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert("Invalid signer");
        account.execute(address(0x123), 1 ether, "", 0);
    }
    
    function test_Execute_RevertInvalidOperation() public {
        vm.prank(user1);
        vm.expectRevert("Only call operations supported");
        account.execute(address(0x123), 0, "", 1);
    }
    
    function test_CreateSessionKey() public {
        address signer = address(0x999);
        address[] memory targets = new address[](1);
        targets[0] = address(0x123);
        bytes4[] memory selectors = new bytes4[](0);
        
        uint48 validAfter = uint48(block.timestamp);
        uint48 validUntil = uint48(block.timestamp + 1 hours);
        
        vm.prank(user1);
        bytes32 keyHash = account.createSessionKey(
            signer,
            targets,
            selectors,
            0.1 ether,  // maxValuePerTx
            1 ether,    // maxTotalValue
            validAfter,
            validUntil
        );
        
        assertNotEq(keyHash, bytes32(0));
        
        // Verify session key data
        (
            address storedSigner,
            uint256 maxValuePerTx,
            uint256 maxTotalValue,
            uint256 usedValue,
            uint48 storedValidAfter,
            uint48 storedValidUntil,
            bool revoked
        ) = account.getSessionKey(keyHash);
        
        assertEq(storedSigner, signer);
        assertEq(maxValuePerTx, 0.1 ether);
        assertEq(maxTotalValue, 1 ether);
        assertEq(usedValue, 0);
        assertEq(storedValidAfter, validAfter);
        assertEq(storedValidUntil, validUntil);
        assertFalse(revoked);
    }
    
    function test_CreateSessionKey_RevertNotOwner() public {
        address[] memory targets = new address[](0);
        bytes4[] memory selectors = new bytes4[](0);
        
        vm.prank(attacker);
        vm.expectRevert("Only owner can create session keys");
        account.createSessionKey(
            address(0x999),
            targets,
            selectors,
            0.1 ether,
            1 ether,
            uint48(block.timestamp),
            uint48(block.timestamp + 1 hours)
        );
    }
    
    function test_CreateSessionKey_RevertInvalidPeriod() public {
        address[] memory targets = new address[](0);
        bytes4[] memory selectors = new bytes4[](0);
        
        vm.prank(user1);
        vm.expectRevert("Invalid validity period");
        account.createSessionKey(
            address(0x999),
            targets,
            selectors,
            0.1 ether,
            1 ether,
            uint48(block.timestamp + 1 hours), // validAfter > validUntil
            uint48(block.timestamp)
        );
    }
    
    function test_RevokeSessionKey() public {
        address[] memory targets = new address[](0);
        bytes4[] memory selectors = new bytes4[](0);
        
        vm.prank(user1);
        bytes32 keyHash = account.createSessionKey(
            address(0x999),
            targets,
            selectors,
            0.1 ether,
            1 ether,
            uint48(block.timestamp),
            uint48(block.timestamp + 1 hours)
        );
        
        vm.prank(user1);
        account.revokeSessionKey(keyHash);
        
        (,,,,,,bool revoked) = account.getSessionKey(keyHash);
        assertTrue(revoked);
    }
    
    function test_RevokeSessionKey_RevertNotOwner() public {
        address[] memory targets = new address[](0);
        bytes4[] memory selectors = new bytes4[](0);
        
        vm.prank(user1);
        bytes32 keyHash = account.createSessionKey(
            address(0x999),
            targets,
            selectors,
            0.1 ether,
            1 ether,
            uint48(block.timestamp),
            uint48(block.timestamp + 1 hours)
        );
        
        vm.prank(attacker);
        vm.expectRevert("Only owner can revoke session keys");
        account.revokeSessionKey(keyHash);
    }
    
    function test_GetSessionKeyHashes() public {
        address[] memory targets = new address[](0);
        bytes4[] memory selectors = new bytes4[](0);
        
        vm.startPrank(user1);
        bytes32 key1 = account.createSessionKey(
            address(0x111),
            targets,
            selectors,
            0.1 ether,
            1 ether,
            uint48(block.timestamp),
            uint48(block.timestamp + 1 hours)
        );
        
        bytes32 key2 = account.createSessionKey(
            address(0x222),
            targets,
            selectors,
            0.1 ether,
            1 ether,
            uint48(block.timestamp),
            uint48(block.timestamp + 1 hours)
        );
        vm.stopPrank();
        
        bytes32[] memory hashes = account.getSessionKeyHashes();
        assertEq(hashes.length, 2);
        assertEq(hashes[0], key1);
        assertEq(hashes[1], key2);
    }
    
    function test_ReceiveERC721() public {
        // Deploy a mock ERC721
        MockERC721 nft = new MockERC721();
        nft.mint(address(this), 1);
        
        // Transfer to account
        nft.safeTransferFrom(address(this), address(account), 1);
        
        assertEq(nft.ownerOf(1), address(account));
    }
    
    function test_SupportsInterface() public view {
        // ERC165
        assertTrue(account.supportsInterface(0x01ffc9a7));
        // ERC721Receiver
        assertTrue(account.supportsInterface(0x150b7a02));
        // ERC1155Receiver
        assertTrue(account.supportsInterface(0x4e2312e0));
    }
}

// Mock ERC721 for testing
contract MockERC721 {
    mapping(uint256 => address) public ownerOf;
    
    function mint(address to, uint256 tokenId) public {
        ownerOf[tokenId] = to;
    }
    
    function safeTransferFrom(address from, address to, uint256 tokenId) public {
        require(ownerOf[tokenId] == from, "Not owner");
        ownerOf[tokenId] = to;
        
        if (to.code.length > 0) {
            (bool success,) = to.call(
                abi.encodeWithSignature(
                    "onERC721Received(address,address,uint256,bytes)",
                    msg.sender,
                    from,
                    tokenId,
                    ""
                )
            );
            require(success, "Transfer failed");
        }
    }
}
