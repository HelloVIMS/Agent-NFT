// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentTBARegistry.sol";
import "../src/AgentAccount.sol";

contract AgentTBARegistryTest is Test {
    AgentIdentityRegistry public identityRegistry;
    AgentTBARegistry public tbaRegistry;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    
    event AccountCreated(
        address indexed account,
        address indexed implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    );
    
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
    }
    
    function test_Implementation() public view {
        address impl = tbaRegistry.implementation();
        assertNotEq(impl, address(0));
        assertTrue(impl.code.length > 0);
    }
    
    function test_ComputeAccountAddress() public {
        vm.prank(user1);
        uint256 agentId = identityRegistry.registerAgent("TestBot", "uri");
        
        bytes32 salt = bytes32(0);
        
        address computedAddress = tbaRegistry.account(
            address(identityRegistry),
            agentId,
            salt
        );
        
        assertNotEq(computedAddress, address(0));
    }
    
    function test_CreateAccount() public {
        vm.prank(user1);
        uint256 agentId = identityRegistry.registerAgent("TestBot", "uri");
        
        bytes32 salt = bytes32(0);
        
        vm.prank(user1);
        address accountAddress = tbaRegistry.createAccount(
            agentId,
            salt
        );
        
        assertNotEq(accountAddress, address(0));
        assertTrue(accountAddress.code.length > 0);
    }
    
    function test_CreateAccountDeterministic() public {
        vm.prank(user1);
        uint256 agentId = identityRegistry.registerAgent("TestBot", "uri");
        
        bytes32 salt = bytes32(0);
        
        // Compute address before creation
        address computedAddress = tbaRegistry.account(
            address(identityRegistry),
            agentId,
            salt
        );
        
        // Create the account
        vm.prank(user1);
        address createdAddress = tbaRegistry.createAccount(
            agentId,
            salt
        );
        
        // Should match
        assertEq(computedAddress, createdAddress);
    }
    
    function test_IsAccountDeployed() public {
        vm.prank(user1);
        uint256 agentId = identityRegistry.registerAgent("TestBot", "uri");
        
        bytes32 salt = bytes32(0);
        
        // Not deployed yet
        assertFalse(tbaRegistry.isAccountDeployed(
            address(identityRegistry),
            agentId,
            salt
        ));
        
        // Deploy
        vm.prank(user1);
        tbaRegistry.createAccount(agentId, salt);
        
        // Now deployed
        assertTrue(tbaRegistry.isAccountDeployed(
            address(identityRegistry),
            agentId,
            salt
        ));
    }
    
    function test_CreateAccountReventsOnDuplicate() public {
        vm.prank(user1);
        uint256 agentId = identityRegistry.registerAgent("TestBot", "uri");
        
        bytes32 salt = bytes32(0);
        
        // Create first TBA
        vm.prank(user1);
        address addr1 = tbaRegistry.createAccount(agentId, salt);
        assertNotEq(addr1, address(0));
        
        // V2: TBARegistry now reverts on duplicate TBA creation
        vm.prank(user1);
        vm.expectRevert(AgentTBARegistry.TBAAlreadyExists.selector);
        tbaRegistry.createAccount(agentId, salt);
    }
    
    function test_AccountOwner() public {
        vm.prank(user1);
        uint256 agentId = identityRegistry.registerAgent("TestBot", "uri");
        
        bytes32 salt = bytes32(0);
        
        vm.prank(user1);
        address accountAddress = tbaRegistry.createAccount(
            agentId,
            salt
        );
        
        AgentAccount account = AgentAccount(payable(accountAddress));
        assertEq(account.owner(), user1);
    }
    
    function test_AccountReceiveETH() public {
        vm.prank(user1);
        uint256 agentId = identityRegistry.registerAgent("TestBot", "uri");
        
        bytes32 salt = bytes32(0);
        
        vm.prank(user1);
        address accountAddress = tbaRegistry.createAccount(
            agentId,
            salt
        );
        
        // Fund the account
        vm.deal(address(this), 1 ether);
        (bool success,) = accountAddress.call{value: 0.5 ether}("");
        assertTrue(success);
        
        assertEq(accountAddress.balance, 0.5 ether);
    }
    
    function test_DifferentSaltsCreateDifferentAccounts() public {
        vm.prank(user1);
        uint256 agentId = identityRegistry.registerAgent("TestBot", "uri");
        
        bytes32 salt1 = bytes32(uint256(1));
        bytes32 salt2 = bytes32(uint256(2));
        
        vm.prank(user1);
        address addr1 = tbaRegistry.createAccount(agentId, salt1);
        
        vm.prank(user1);
        address addr2 = tbaRegistry.createAccount(agentId, salt2);
        
        assertNotEq(addr1, addr2);
    }
}
