// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../src/hyperlane/AgentBridge.sol";
import "../src/hyperlane/IMailbox.sol";

contract Mailbox is IMailbox {
    uint32 public override localDomain;
    uint256 public quote = 0.001 ether;

    constructor(uint32 _domain) { localDomain = _domain; }
    function setQuote(uint256 q) external { quote = q; }
    function dispatch(uint32, bytes32, bytes calldata) external payable override returns (bytes32) {
        return bytes32(uint256(0xdeadbeef));
    }
    function quoteDispatch(uint32, bytes32, bytes calldata) external view override returns (uint256) {
        return quote;
    }
}

/// @dev Mintable mock NFT — supports arbitrary id-targeted mint so tests
///      can pre-seed mirror tokens with predictable IDs.
contract MintableNFT is ERC721 {
    constructor() ERC721("MockAgent", "MCA") {}
    function mintTo(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @dev Recipient that refuses ETH — used to trigger the refund-failed branch.
contract NoEthRecv {
    AgentBridge public bridge;
    MintableNFT public nft;
    uint256 public tokenId;

    constructor(AgentBridge _bridge, MintableNFT _nft, uint256 _tokenId) {
        bridge = _bridge;
        nft = _nft;
        tokenId = _tokenId;
    }

    function approveAndBridgeBack() external payable {
        nft.approve(address(bridge), tokenId);
        bridge.bridgeBack{value: msg.value}(tokenId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        revert("no eth");
    }
}

contract AgentBridgeHandleTest is Test {
    AgentBridge public bridge;
    Mailbox     public mailbox;
    MintableNFT public nft;

    address public owner    = makeAddr("owner");
    address public user     = makeAddr("user");
    address public attacker = makeAddr("attacker");
    address public remoteBridge = makeAddr("remoteBridge");

    uint32 constant LOCAL_DOMAIN = 8453;
    uint32 constant REMOTE_DOMAIN = 1;

    uint8 constant MSG_BRIDGE      = 1;
    uint8 constant MSG_BRIDGE_BACK = 2;
    uint8 constant MSG_UNKNOWN     = 9;

    function setUp() public {
        mailbox = new Mailbox(LOCAL_DOMAIN);
        nft = new MintableNFT();

        AgentBridge impl = new AgentBridge();
        bytes memory init = abi.encodeWithSelector(
            AgentBridge.initialize.selector, address(mailbox), address(nft), owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        bridge = AgentBridge(address(proxy));

        vm.prank(owner);
        bridge.setRemoteBridge(REMOTE_DOMAIN, remoteBridge);

        vm.deal(user, 100 ether);
        vm.deal(address(mailbox), 100 ether);
    }

    // ─── handle() authority + decode error paths ──────────────────────────

    function test_handle_revertsForNonMailbox() public {
        bytes memory message = abi.encode(MSG_BRIDGE, uint256(0), user, "", REMOTE_DOMAIN);
        bytes32 sender = bridge.addressToBytes32(remoteBridge);

        vm.prank(attacker);
        vm.expectRevert("Only mailbox");
        bridge.handle(REMOTE_DOMAIN, sender, message);
    }

    function test_handle_revertsForUnknownRemoteSender() public {
        bytes32 wrongSender = bridge.addressToBytes32(attacker);
        bytes memory message = abi.encode(MSG_BRIDGE, uint256(0), user, "", REMOTE_DOMAIN);

        vm.prank(address(mailbox));
        vm.expectRevert(AgentBridge.InvalidSender.selector);
        bridge.handle(REMOTE_DOMAIN, wrongSender, message);
    }

    function test_handle_revertsForUnknownMessageType() public {
        bytes32 sender = bridge.addressToBytes32(remoteBridge);
        bytes memory message = abi.encode(MSG_UNKNOWN, uint256(0), user, "", REMOTE_DOMAIN);

        vm.prank(address(mailbox));
        vm.expectRevert(AgentBridge.InvalidMessageType.selector);
        bridge.handle(REMOTE_DOMAIN, sender, message);
    }

    function test_handle_bridgeBackRevertsWhenTokenNotLocked() public {
        bytes32 sender = bridge.addressToBytes32(remoteBridge);
        bytes memory message = abi.encode(MSG_BRIDGE_BACK, uint256(404), user, "", uint32(0));

        vm.prank(address(mailbox));
        vm.expectRevert(AgentBridge.TokenNotLocked.selector);
        bridge.handle(REMOTE_DOMAIN, sender, message);
    }

    // ─── bridgeBack revert paths ──────────────────────────────────────────

    function test_bridgeBack_revertsForNonMirrorToken() public {
        nft.mintTo(user, 0);
        vm.prank(user);
        vm.expectRevert(AgentBridge.TokenNotMirror.selector);
        bridge.bridgeBack{value: 0.01 ether}(0);
    }

    function test_bridgeBack_revertsForNonOwnerOfMirror() public {
        uint256 mirrorId = 555;
        _seedMirror(mirrorId, user);
        vm.deal(attacker, 1 ether);

        vm.prank(attacker);
        vm.expectRevert(AgentBridge.NotTokenOwner.selector);
        bridge.bridgeBack{value: 0.01 ether}(mirrorId);
    }

    function test_bridgeBack_revertsForInsufficientFee() public {
        uint256 mirrorId = 666;
        _seedMirror(mirrorId, user);
        mailbox.setQuote(0.05 ether);

        vm.startPrank(user);
        nft.approve(address(bridge), mirrorId);
        vm.expectRevert(AgentBridge.InsufficientFee.selector);
        bridge.bridgeBack{value: 0.01 ether}(mirrorId);
        vm.stopPrank();
    }

    function test_bridgeBack_happyPathAndRefundsExcessFee() public {
        uint256 mirrorId = 777;
        _seedMirror(mirrorId, user);
        mailbox.setQuote(0.001 ether);

        uint256 userBalBefore = user.balance;

        vm.startPrank(user);
        nft.approve(address(bridge), mirrorId);
        bridge.bridgeBack{value: 0.051 ether}(mirrorId);
        vm.stopPrank();

        assertFalse(bridge.isMirrorToken(mirrorId));
        assertEq(bridge.tokenOriginDomain(mirrorId), uint32(0));
        // Mirror NFT burned (transferred to 0xdead).
        assertEq(nft.ownerOf(mirrorId), address(0xdead));
        // User paid only the quote fee — rest refunded.
        assertEq(userBalBefore - user.balance, 0.001 ether, "should be charged only the quote fee");
    }

    function test_bridgeBack_revertsWhenRefundFails() public {
        uint256 mirrorId = 888;
        // Mint to a recipient that refuses ETH refunds.
        NoEthRecv rejecter = new NoEthRecv(bridge, nft, mirrorId);
        nft.mintTo(address(rejecter), mirrorId);

        // Seed the mirror flag via a MSG_BRIDGE handle() for this id.
        bytes32 sender = bridge.addressToBytes32(remoteBridge);
        bytes memory msg_ = abi.encode(MSG_BRIDGE, mirrorId, address(rejecter), "", REMOTE_DOMAIN);
        vm.prank(address(mailbox));
        bridge.handle(REMOTE_DOMAIN, sender, msg_);

        mailbox.setQuote(0.001 ether);
        vm.deal(address(rejecter), 1 ether);

        // Overpay → refund branch executes → refund call reverts → "Refund failed".
        vm.expectRevert(bytes("Refund failed"));
        rejecter.approveAndBridgeBack{value: 0.05 ether}();
    }

    // ─── handle bridge-back happy path (the inbound side of bridgeAgent) ──

    function test_handle_bridgeBack_unlocksLockedToken() public {
        // First, the bridge holds a token (because bridgeAgent locked it
        // on the way out). Then a remote MSG_BRIDGE_BACK arrives.
        uint256 lockedId = 12;
        nft.mintTo(user, lockedId);

        vm.prank(owner);
        bridge.setSupportedDomain(REMOTE_DOMAIN, true);

        vm.prank(user);
        nft.approve(address(bridge), lockedId);
        vm.prank(user);
        bridge.bridgeAgent{value: 0.01 ether}(lockedId, REMOTE_DOMAIN, user);

        assertEq(nft.ownerOf(lockedId), address(bridge), "bridge should hold the locked token");
        assertEq(bridge.lockedTokenOwners(lockedId), user);

        // Now the remote chain says: deliver this token back to `user`.
        bytes32 sender = bridge.addressToBytes32(remoteBridge);
        bytes memory msg_ = abi.encode(MSG_BRIDGE_BACK, lockedId, user, "", uint32(0));
        vm.prank(address(mailbox));
        bridge.handle(REMOTE_DOMAIN, sender, msg_);

        assertEq(nft.ownerOf(lockedId), user, "token should return to user");
        assertEq(bridge.lockedTokenOwners(lockedId), address(0), "lock cleared");
    }

    // ─── ERC-721 receiver + bytes32 utility ──────────────────────────────

    function test_onERC721Received_returnsSelector() public view {
        assertEq(
            bridge.onERC721Received(address(0), address(0), 0, ""),
            IERC721Receiver.onERC721Received.selector
        );
    }

    function test_bytes32ToAddress_roundTrip() public {
        address a = makeAddr("addr");
        assertEq(bridge.bytes32ToAddress(bridge.addressToBytes32(a)), a);
    }

    // ─── helper ───────────────────────────────────────────────────────────

    /// @dev Flip the bridge into the "received a mirror token for id" state
    ///      and mint a matching NFT to `recipient` so subsequent bridgeBack
    ///      calls find an actual token to burn. We drive handle() to set the
    ///      mirror flags and then mint the NFT independently since
    ///      `_mintMirrorToken` in the live contract is currently a no-op
    ///      placeholder (see AgentBridge.sol line ~333).
    function _seedMirror(uint256 mirrorId, address recipient) internal {
        bytes32 sender = bridge.addressToBytes32(remoteBridge);
        bytes memory msg_ = abi.encode(MSG_BRIDGE, mirrorId, recipient, "", REMOTE_DOMAIN);
        vm.prank(address(mailbox));
        bridge.handle(REMOTE_DOMAIN, sender, msg_);
        nft.mintTo(recipient, mirrorId);
    }
}
