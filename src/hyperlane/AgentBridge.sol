// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./IMailbox.sol";

/**
 * @title AgentBridge
 * @notice Cross-chain bridge for Agent NFTs using Hyperlane
 * @dev Enables Agent agents to be bridged between supported chains
 * 
 * Flow:
 * 1. User calls bridgeAgent() on source chain
 * 2. NFT is locked in bridge contract
 * 3. Hyperlane message sent to destination chain
 * 4. Destination bridge receives message via handle()
 * 5. Mirror NFT minted on destination chain
 * 
 * On bridge back:
 * 1. User calls bridgeBack() on destination chain
 * 2. Mirror NFT burned
 * 3. Hyperlane message sent to origin chain
 * 4. Original NFT unlocked and returned to user
 */
import {VimsProvenance} from "../VimsProvenance.sol";

contract AgentBridge is 
    Initializable,
    VimsProvenance,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IMessageRecipient,
    IERC721Receiver
{
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentBridge";
    }

    // Hyperlane mailbox
    IMailbox public mailbox;
    
    // Agent NFT contract on this chain
    IERC721 public agentNFT;
    
    // Mapping of domain ID to remote bridge address
    mapping(uint32 => bytes32) public remoteBridges;
    
    // Mapping of token ID to original owner (for locked tokens)
    mapping(uint256 => address) public lockedTokenOwners;
    
    // Mapping of token ID to origin domain (for bridged tokens)
    mapping(uint256 => uint32) public tokenOriginDomain;
    
    // Mapping of token ID to whether it's a mirror (bridged from another chain)
    mapping(uint256 => bool) public isMirrorToken;
    
    // Supported destination domains
    mapping(uint32 => bool) public supportedDomains;
    
    // Domain IDs for common chains (Hyperlane standard)
    uint32 public constant ETHEREUM_DOMAIN = 1;
    uint32 public constant BASE_DOMAIN = 8453;
    uint32 public constant OPTIMISM_DOMAIN = 10;
    uint32 public constant ARBITRUM_DOMAIN = 42161;
    uint32 public constant POLYGON_DOMAIN = 137;
    uint32 public constant BASE_SEPOLIA_DOMAIN = 84532;
    
    // Message types
    uint8 public constant MSG_BRIDGE = 1;
    uint8 public constant MSG_BRIDGE_BACK = 2;
    
    // Events
    event BridgeInitiated(
        uint256 indexed tokenId,
        address indexed sender,
        uint32 destinationDomain,
        bytes32 messageId
    );
    
    event BridgeReceived(
        uint256 indexed tokenId,
        address indexed recipient,
        uint32 originDomain
    );
    
    event BridgeBackInitiated(
        uint256 indexed tokenId,
        address indexed sender,
        uint32 originDomain,
        bytes32 messageId
    );
    
    event BridgeBackReceived(
        uint256 indexed tokenId,
        address indexed recipient
    );
    
    event RemoteBridgeSet(uint32 domain, bytes32 bridgeAddress);
    event DomainSupportUpdated(uint32 domain, bool supported);
    
    // Errors
    error InvalidDomain();
    error UnsupportedDomain();
    error NotTokenOwner();
    error TokenNotLocked();
    error TokenNotMirror();
    error InvalidSender();
    error InvalidMessageType();
    error InsufficientFee();
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the bridge
     * @param _mailbox Hyperlane mailbox address
     * @param _agentNFT Agent NFT contract address
     * @param _owner Owner address
     */
    function initialize(
        address _mailbox,
        address _agentNFT,
        address _owner
    ) external initializer {
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        mailbox = IMailbox(_mailbox);
        agentNFT = IERC721(_agentNFT);
        
        // Enable common domains by default
        supportedDomains[ETHEREUM_DOMAIN] = true;
        supportedDomains[BASE_DOMAIN] = true;
        supportedDomains[OPTIMISM_DOMAIN] = true;
        supportedDomains[ARBITRUM_DOMAIN] = true;
        supportedDomains[POLYGON_DOMAIN] = true;
        supportedDomains[BASE_SEPOLIA_DOMAIN] = true;
    }
    
    /**
     * @notice Bridge a Agent to another chain
     * @param tokenId The Agent token ID to bridge
     * @param destinationDomain The Hyperlane domain ID of destination chain
     * @param recipient The recipient address on destination chain
     */
    function bridgeAgent(
        uint256 tokenId,
        uint32 destinationDomain,
        address recipient
    ) external payable nonReentrant {
        if (!supportedDomains[destinationDomain]) revert UnsupportedDomain();
        if (remoteBridges[destinationDomain] == bytes32(0)) revert InvalidDomain();
        if (agentNFT.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        
        // Get token metadata before locking
        string memory tokenURI = _getTokenURI(tokenId);
        
        // Lock the NFT in this contract
        agentNFT.safeTransferFrom(msg.sender, address(this), tokenId);
        lockedTokenOwners[tokenId] = msg.sender;
        
        // Encode the bridge message
        bytes memory message = abi.encode(
            MSG_BRIDGE,
            tokenId,
            recipient,
            tokenURI,
            mailbox.localDomain() // Origin domain for tracking
        );
        
        // Calculate fee
        uint256 fee = mailbox.quoteDispatch(
            destinationDomain,
            remoteBridges[destinationDomain],
            message
        );
        
        if (msg.value < fee) revert InsufficientFee();
        
        // Dispatch message via Hyperlane
        bytes32 messageId = mailbox.dispatch{value: fee}(
            destinationDomain,
            remoteBridges[destinationDomain],
            message
        );
        
        // Refund excess
        if (msg.value > fee) {
            (bool success, ) = msg.sender.call{value: msg.value - fee}("");
            require(success, "Refund failed");
        }
        
        emit BridgeInitiated(tokenId, msg.sender, destinationDomain, messageId);
    }
    
    /**
     * @notice Bridge a mirror Agent back to its origin chain
     * @param tokenId The mirror token ID to bridge back
     */
    function bridgeBack(uint256 tokenId) external payable nonReentrant {
        if (!isMirrorToken[tokenId]) revert TokenNotMirror();
        if (agentNFT.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        
        uint32 originDomain = tokenOriginDomain[tokenId];
        if (remoteBridges[originDomain] == bytes32(0)) revert InvalidDomain();
        
        // Burn the mirror token (requires NFT contract to support this)
        // For now, we transfer to address(0xdead) as a burn mechanism
        agentNFT.safeTransferFrom(msg.sender, address(0xdead), tokenId);
        
        // Clean up mappings
        delete isMirrorToken[tokenId];
        delete tokenOriginDomain[tokenId];
        
        // Encode the bridge back message
        bytes memory message = abi.encode(
            MSG_BRIDGE_BACK,
            tokenId,
            msg.sender, // Recipient on origin chain
            "", // No URI needed for unlock
            uint32(0) // Not used for bridge back
        );
        
        // Calculate fee
        uint256 fee = mailbox.quoteDispatch(
            originDomain,
            remoteBridges[originDomain],
            message
        );
        
        if (msg.value < fee) revert InsufficientFee();
        
        // Dispatch message
        bytes32 messageId = mailbox.dispatch{value: fee}(
            originDomain,
            remoteBridges[originDomain],
            message
        );
        
        // Refund excess
        if (msg.value > fee) {
            (bool success, ) = msg.sender.call{value: msg.value - fee}("");
            require(success, "Refund failed");
        }
        
        emit BridgeBackInitiated(tokenId, msg.sender, originDomain, messageId);
    }
    
    /**
     * @notice Handle incoming Hyperlane message
     * @param origin Origin domain
     * @param sender Sender address (as bytes32)
     * @param message Message content
     */
    function handle(
        uint32 origin,
        bytes32 sender,
        bytes calldata message
    ) external payable override {
        // Only mailbox can call
        require(msg.sender == address(mailbox), "Only mailbox");
        
        // Verify sender is a registered remote bridge
        if (remoteBridges[origin] != sender) revert InvalidSender();
        
        // Decode message
        (
            uint8 msgType,
            uint256 tokenId,
            address recipient,
            string memory tokenURI,
            uint32 originDomain
        ) = abi.decode(message, (uint8, uint256, address, string, uint32));
        
        if (msgType == MSG_BRIDGE) {
            // Mint mirror token on this chain
            _handleBridge(tokenId, recipient, tokenURI, origin);
        } else if (msgType == MSG_BRIDGE_BACK) {
            // Unlock original token
            _handleBridgeBack(tokenId, recipient);
        } else {
            revert InvalidMessageType();
        }
    }
    
    /**
     * @notice Handle incoming bridge message - mint mirror token
     */
    function _handleBridge(
        uint256 tokenId,
        address recipient,
        string memory tokenURI,
        uint32 originDomain
    ) internal {
        // Mark as mirror token
        isMirrorToken[tokenId] = true;
        tokenOriginDomain[tokenId] = originDomain;
        
        // Mint mirror token to recipient
        // This requires the Agent NFT to have a mintMirror function
        // or we use a separate mirror NFT contract
        _mintMirrorToken(tokenId, recipient, tokenURI);
        
        emit BridgeReceived(tokenId, recipient, originDomain);
    }
    
    /**
     * @notice Handle incoming bridge back message - unlock original token
     */
    function _handleBridgeBack(uint256 tokenId, address recipient) internal {
        address originalOwner = lockedTokenOwners[tokenId];
        if (originalOwner == address(0)) revert TokenNotLocked();
        
        // Clear locked state
        delete lockedTokenOwners[tokenId];
        
        // Transfer back to recipient (could be different from original owner)
        agentNFT.safeTransferFrom(address(this), recipient, tokenId);
        
        emit BridgeBackReceived(tokenId, recipient);
    }
    
    /**
     * @notice Mint a mirror token (placeholder - requires NFT integration)
     */
    function _mintMirrorToken(
        uint256 tokenId,
        address recipient,
        string memory tokenURI
    ) internal {
        // TODO: Integrate with Agent NFT's mintMirror function
        // For now this is a placeholder that would call:
        // IAgentMintable(address(agentNFT)).mintMirror(recipient, tokenId, tokenURI);
    }
    
    /**
     * @notice Get token URI (placeholder - requires NFT integration)
     */
    function _getTokenURI(uint256 tokenId) internal view returns (string memory) {
        // TODO: Call tokenURI on the NFT contract
        // return IERC721Metadata(address(agentNFT)).tokenURI(tokenId);
        return "";
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Set remote bridge address for a domain
     */
    function setRemoteBridge(uint32 domain, address bridge) external onlyOwner {
        remoteBridges[domain] = addressToBytes32(bridge);
        emit RemoteBridgeSet(domain, addressToBytes32(bridge));
    }
    
    /**
     * @notice Update domain support
     */
    function setSupportedDomain(uint32 domain, bool supported) external onlyOwner {
        supportedDomains[domain] = supported;
        emit DomainSupportUpdated(domain, supported);
    }
    
    /**
     * @notice Update mailbox address
     */
    function setMailbox(address _mailbox) external onlyOwner {
        mailbox = IMailbox(_mailbox);
    }
    
    /**
     * @notice Update Agent NFT address
     */
    function setAgentNFT(address _agentNFT) external onlyOwner {
        agentNFT = IERC721(_agentNFT);
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get bridge fee quote
     */
    function quoteBridgeFee(
        uint256 tokenId,
        uint32 destinationDomain,
        address recipient
    ) external view returns (uint256) {
        bytes memory message = abi.encode(
            MSG_BRIDGE,
            tokenId,
            recipient,
            "", // Placeholder URI
            mailbox.localDomain()
        );
        
        return mailbox.quoteDispatch(
            destinationDomain,
            remoteBridges[destinationDomain],
            message
        );
    }
    
    /**
     * @notice Check if a token is locked in the bridge
     */
    function isTokenLocked(uint256 tokenId) external view returns (bool) {
        return lockedTokenOwners[tokenId] != address(0);
    }
    
    /**
     * @notice Get the original owner of a locked token
     */
    function getLockedTokenOwner(uint256 tokenId) external view returns (address) {
        return lockedTokenOwners[tokenId];
    }
    
    // ============ Utility Functions ============
    
    function addressToBytes32(address addr) public pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
    
    function bytes32ToAddress(bytes32 b) public pure returns (address) {
        return address(uint160(uint256(b)));
    }
    
    // ============ ERC721 Receiver ============
    
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
    
    // ============ UUPS ============
    
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
