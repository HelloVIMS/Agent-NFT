// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/hyperlane/AgentBridge.sol";
import "../src/hyperlane/IMailbox.sol";

/**
 * @title AgentBridgeAdminTest
 * @notice Tests the admin-gated setters and view-getters on AgentBridge
 *         that the existing AgentBridge.t.sol doesn't cover. Lifts the
 *         coverage above the 90 % release-qual gate.
 */

contract MockMailbox is IMailbox {
    uint32 public override localDomain;
    uint32 public lastDestination;
    bytes32 public lastRecipient;
    bytes public lastMessage;

    constructor(uint32 _domain) { localDomain = _domain; }

    function dispatch(uint32 destinationDomain, bytes32 recipient, bytes calldata message)
        external payable override returns (bytes32)
    {
        lastDestination = destinationDomain;
        lastRecipient = recipient;
        lastMessage = message;
        return keccak256(abi.encodePacked(block.timestamp, message));
    }

    function quoteDispatch(uint32, bytes32, bytes calldata) external pure override returns (uint256) {
        return 0.01 ether;
    }
}

contract MockAgentNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public approved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    uint256 public nextId;

    function mint(address to) external returns (uint256 id) {
        id = nextId++;
        ownerOf[id] = to;
    }

    function approve(address to, uint256 tokenId) external {
        approved[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not from");
        ownerOf[tokenId] = to;
        approved[tokenId] = address(0);
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not from");
        ownerOf[tokenId] = to;
        approved[tokenId] = address(0);
    }

    function setApprovalForAll(address operator, bool ok) external {
        isApprovedForAll[msg.sender][operator] = ok;
    }
}

contract AgentBridgeAdminTest is Test {
    AgentBridge   public bridge;
    MockMailbox   public mailbox;
    MockAgentNFT  public nft;

    address public owner    = makeAddr("owner");
    address public stranger = makeAddr("stranger");

    uint32 constant LOCAL_DOMAIN = 8453;
    uint32 constant REMOTE_DOMAIN = 1;

    function setUp() public {
        mailbox = new MockMailbox(LOCAL_DOMAIN);
        nft     = new MockAgentNFT();

        AgentBridge impl = new AgentBridge();
        bytes memory init = abi.encodeWithSelector(
            AgentBridge.initialize.selector, address(mailbox), address(nft), owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        bridge = AgentBridge(address(proxy));
    }

    // ── setSupportedDomain ────────────────────────────────────────────────

    function test_setSupportedDomain_enablesAndDisables() public {
        vm.startPrank(owner);
        bridge.setSupportedDomain(REMOTE_DOMAIN, true);
        assertTrue(bridge.supportedDomains(REMOTE_DOMAIN));

        bridge.setSupportedDomain(REMOTE_DOMAIN, false);
        assertFalse(bridge.supportedDomains(REMOTE_DOMAIN));
        vm.stopPrank();
    }

    function test_setSupportedDomain_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        bridge.setSupportedDomain(REMOTE_DOMAIN, true);
    }

    // ── setMailbox ────────────────────────────────────────────────────────

    function test_setMailbox_updatesPointer() public {
        MockMailbox newMb = new MockMailbox(LOCAL_DOMAIN);
        vm.prank(owner);
        bridge.setMailbox(address(newMb));
        assertEq(address(bridge.mailbox()), address(newMb));
    }

    function test_setMailbox_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        bridge.setMailbox(address(0xdead));
    }

    // ── setAgentNFT ──────────────────────────────────────────────────────

    function test_setAgentNFT_updatesPointer() public {
        MockAgentNFT newNft = new MockAgentNFT();
        vm.prank(owner);
        bridge.setAgentNFT(address(newNft));
        assertEq(address(bridge.agentNFT()), address(newNft));
    }

    function test_setAgentNFT_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        bridge.setAgentNFT(address(0xdead));
    }

    // ── getLockedTokenOwner ───────────────────────────────────────────────

    function test_getLockedTokenOwner_zeroForUnlockedToken() public view {
        assertEq(bridge.getLockedTokenOwner(0), address(0));
        assertEq(bridge.getLockedTokenOwner(type(uint256).max), address(0));
    }

    function test_isTokenLocked_falseForUnlocked() public view {
        assertFalse(bridge.isTokenLocked(0));
        assertFalse(bridge.isTokenLocked(type(uint256).max));
    }

    // ── addressToBytes32 (pure utility) ───────────────────────────────────

    function test_addressToBytes32_isLeftPaddedZero() public {
        address probe = makeAddr("probe");
        bytes32 expected = bytes32(uint256(uint160(probe)));
        assertEq(bridge.addressToBytes32(probe), expected);
        assertEq(bridge.addressToBytes32(address(0)), bytes32(0));
    }

    // ── initialize re-entry guard ────────────────────────────────────────

    function test_initialize_cannotBeCalledTwice() public {
        vm.expectRevert();
        bridge.initialize(address(mailbox), address(nft), owner);
    }

    // ── ownership transfer (inherited from OZ Ownable) ───────────────────

    function test_transferOwnership_byOwner() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        bridge.transferOwnership(newOwner);
        assertEq(bridge.owner(), newOwner);
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        bridge.transferOwnership(stranger);
    }
}
