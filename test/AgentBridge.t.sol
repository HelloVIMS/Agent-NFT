// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/hyperlane/AgentBridge.sol";
import "../src/hyperlane/IMailbox.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title MockMailbox
 * @notice Mock Hyperlane mailbox for testing
 */
contract MockMailbox is IMailbox {
    uint32 public override localDomain;
    uint256 public dispatchCount;
    bytes32 public lastMessageId;
    
    // Store dispatched messages for verification
    struct DispatchedMessage {
        uint32 destinationDomain;
        bytes32 recipientAddress;
        bytes messageBody;
        uint256 value;
    }
    
    DispatchedMessage[] public dispatchedMessages;
    
    constructor(uint32 _localDomain) {
        localDomain = _localDomain;
    }
    
    function dispatch(
        uint32 destinationDomain,
        bytes32 recipientAddress,
        bytes calldata messageBody
    ) external payable override returns (bytes32 messageId) {
        dispatchedMessages.push(DispatchedMessage({
            destinationDomain: destinationDomain,
            recipientAddress: recipientAddress,
            messageBody: messageBody,
            value: msg.value
        }));
        
        dispatchCount++;
        lastMessageId = keccak256(abi.encodePacked(dispatchCount, block.timestamp));
        return lastMessageId;
    }
    
    function quoteDispatch(
        uint32,
        bytes32,
        bytes calldata
    ) external pure override returns (uint256) {
        return 0.001 ether; // Fixed fee for testing
    }
    
    function getDispatchedMessage(uint256 index) external view returns (DispatchedMessage memory) {
        return dispatchedMessages[index];
    }
}

/**
 * @title MockAgentNFT
 * @notice Mock Agent NFT for testing
 */
contract MockAgentNFT is ERC721 {
    uint256 private _nextTokenId;
    mapping(uint256 => string) private _tokenURIs;
    
    constructor() ERC721("MockAgent", "MCB") {}
    
    function mint(address to) external returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _mint(to, tokenId);
        _tokenURIs[tokenId] = string(abi.encodePacked("ipfs://agent/", tokenId));
        return tokenId;
    }
    
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return _tokenURIs[tokenId];
    }
}

/**
 * @title AgentBridgeTest
 * @notice Test suite for AgentBridge
 */
contract AgentBridgeTest is Test {
    AgentBridge public bridge;
    MockMailbox public mailbox;
    MockAgentNFT public nft;
    
    address public owner = address(1);
    address public user = address(2);
    address public remoteBridge = address(3);
    
    uint32 constant LOCAL_DOMAIN = 8453; // Base
    uint32 constant REMOTE_DOMAIN = 1; // Ethereum
    
    function setUp() public {
        // Deploy mock contracts
        mailbox = new MockMailbox(LOCAL_DOMAIN);
        nft = new MockAgentNFT();
        
        // Deploy bridge implementation
        AgentBridge impl = new AgentBridge();
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            AgentBridge.initialize.selector,
            address(mailbox),
            address(nft),
            owner
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        bridge = AgentBridge(address(proxy));
        
        // Setup remote bridge
        vm.prank(owner);
        bridge.setRemoteBridge(REMOTE_DOMAIN, remoteBridge);
        
        // Mint NFT to user
        nft.mint(user);

        // Fund accounts that pay relayer fees
        vm.deal(user, 100 ether);
        vm.deal(address(99), 100 ether);
        vm.deal(address(mailbox), 100 ether);
    }
    
    function test_Initialize() public view {
        assertEq(address(bridge.mailbox()), address(mailbox));
        assertEq(address(bridge.agentNFT()), address(nft));
        assertEq(bridge.owner(), owner);
    }
    
    function test_BridgeAgent() public {
        uint256 tokenId = 0;
        
        // Approve bridge
        vm.startPrank(user);
        nft.approve(address(bridge), tokenId);
        
        // Bridge with fee
        bridge.bridgeAgent{value: 0.01 ether}(
            tokenId,
            REMOTE_DOMAIN,
            user
        );
        vm.stopPrank();
        
        // Verify NFT locked
        assertEq(nft.ownerOf(tokenId), address(bridge));
        assertEq(bridge.lockedTokenOwners(tokenId), user);
        
        // Verify message dispatched
        assertEq(mailbox.dispatchCount(), 1);
    }
    
    function test_BridgeAgent_RevertIfNotOwner() public {
        uint256 tokenId = 0;
        
        vm.prank(address(99)); // Not the owner
        vm.expectRevert(AgentBridge.NotTokenOwner.selector);
        bridge.bridgeAgent{value: 0.01 ether}(
            tokenId,
            REMOTE_DOMAIN,
            user
        );
    }
    
    function test_BridgeAgent_RevertIfUnsupportedDomain() public {
        uint256 tokenId = 0;
        
        vm.prank(user);
        nft.approve(address(bridge), tokenId);
        
        vm.prank(user);
        vm.expectRevert(AgentBridge.UnsupportedDomain.selector);
        bridge.bridgeAgent{value: 0.01 ether}(
            tokenId,
            999, // Unsupported domain
            user
        );
    }
    
    function test_HandleBridgeMessage() public {
        // Simulate receiving a bridge message from remote chain
        bytes memory message = abi.encode(
            uint8(1), // MSG_BRIDGE
            uint256(100), // tokenId
            user, // recipient
            "ipfs://metadata", // tokenURI
            REMOTE_DOMAIN // origin domain
        );
        
        // Call handle as if from mailbox (precompute sender so vm.prank survives)
        bytes32 sender = bridge.addressToBytes32(remoteBridge);
        vm.prank(address(mailbox));
        bridge.handle(REMOTE_DOMAIN, sender, message);
        
        // Verify token marked as mirror
        assertTrue(bridge.isMirrorToken(100));
        assertEq(bridge.tokenOriginDomain(100), REMOTE_DOMAIN);
    }
    
    function test_HandleBridgeBack() public {
        // First lock a token
        uint256 tokenId = 0;
        
        vm.startPrank(user);
        nft.approve(address(bridge), tokenId);
        bridge.bridgeAgent{value: 0.01 ether}(
            tokenId,
            REMOTE_DOMAIN,
            user
        );
        vm.stopPrank();
        
        // Simulate receiving bridge back message
        bytes memory message = abi.encode(
            uint8(2), // MSG_BRIDGE_BACK
            tokenId,
            user, // recipient
            "", // no URI needed
            uint32(0) // not used
        );
        
        bytes32 sender2 = bridge.addressToBytes32(remoteBridge);
        vm.prank(address(mailbox));
        bridge.handle(REMOTE_DOMAIN, sender2, message);
        
        // Verify token unlocked
        assertEq(nft.ownerOf(tokenId), user);
        assertEq(bridge.lockedTokenOwners(tokenId), address(0));
    }
    
    function test_QuoteBridgeFee() public view {
        uint256 fee = bridge.quoteBridgeFee(0, REMOTE_DOMAIN, user);
        assertEq(fee, 0.001 ether);
    }
    
    function test_SetRemoteBridge() public {
        address newRemote = address(99);
        
        vm.prank(owner);
        bridge.setRemoteBridge(REMOTE_DOMAIN, newRemote);
        
        assertEq(
            bridge.remoteBridges(REMOTE_DOMAIN),
            bridge.addressToBytes32(newRemote)
        );
    }
    
    function test_SetRemoteBridge_RevertIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        bridge.setRemoteBridge(REMOTE_DOMAIN, address(99));
    }
    
    function test_IsTokenLocked() public {
        uint256 tokenId = 0;
        
        assertFalse(bridge.isTokenLocked(tokenId));
        
        vm.startPrank(user);
        nft.approve(address(bridge), tokenId);
        bridge.bridgeAgent{value: 0.01 ether}(
            tokenId,
            REMOTE_DOMAIN,
            user
        );
        vm.stopPrank();
        
        assertTrue(bridge.isTokenLocked(tokenId));
    }
    
    receive() external payable {}
}
