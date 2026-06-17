// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentMarketplace.sol";

contract SignedUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @dev Minimal ERC-1271 contract wallet for signed-order testing.
///      Approves any signature already produced by `signer` over the
///      passed digest. Real Safe / Argent flows have richer logic.
contract Mock1271Wallet {
    address public signer;
    constructor(address _signer) { signer = _signer; }
    receive() external payable {}
    function isValidSignature(bytes32 hash, bytes memory sig) external view returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s) = _split(sig);
        address recovered = ecrecover(hash, v, r, s);
        if (recovered == signer) return 0x1626ba7e;
        return 0xffffffff;
    }
    function approveERC20(address token, address spender, uint256 amount) external {
        ERC20(token).approve(spender, amount);
    }
    function _split(bytes memory s) internal pure returns (uint8 v, bytes32 r, bytes32 ss) {
        assembly {
            r  := mload(add(s, 32))
            ss := mload(add(s, 64))
            v  := byte(0, mload(add(s, 96)))
        }
    }
}

contract AgentMarketplaceSignedTest is Test {
    AgentIdentityRegistry identity;
    AgentMarketplace      market;
    SignedUSDC            usdc;

    address admin   = address(0xA11CE);
    address feeRecv = address(0xFEE);

    uint256 sellerKey = 0xA11CE0001;
    address seller   = vm.addr(0xA11CE0001);
    uint256 buyerKey = 0xB0B0001;
    address buyer    = vm.addr(0xB0B0001);
    uint256 bidderKey = 0xB1DDE001;
    address bidder    = vm.addr(0xB1DDE001);

    uint256 agentId;

    function setUp() public {
        AgentIdentityRegistry idImpl = new AgentIdentityRegistry();
        ERC1967Proxy idProxy = new ERC1967Proxy(
            address(idImpl), abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identity = AgentIdentityRegistry(address(idProxy));

        AgentMarketplace mkImpl = new AgentMarketplace();
        ERC1967Proxy mkProxy = new ERC1967Proxy(
            address(mkImpl),
            abi.encodeCall(AgentMarketplace.initialize, (admin, feeRecv, 250))
        );
        market = AgentMarketplace(address(mkProxy));

        usdc = new SignedUSDC();

        vm.prank(seller);
        agentId = identity.registerAgent("Bot", "ipfs://m", 1000, address(0));

        usdc.mint(buyer,  1_000_000_000);
        usdc.mint(bidder, 1_000_000_000);
        vm.deal(buyer,  10 ether);
        vm.deal(bidder, 10 ether);
        vm.deal(seller, 10 ether);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _ask(address paymentToken, uint256 price, uint64 endTime)
        internal view returns (AgentMarketplace.Order memory)
    {
        return AgentMarketplace.Order({
            side:         AgentMarketplace.OrderSide.ASK,
            offerer:      seller,
            collection:   address(identity),
            tokenId:      agentId,
            paymentToken: paymentToken,
            price:        price,
            startTime:    0,
            endTime:      endTime,
            salt:         uint256(keccak256(abi.encode(block.number, "ask"))),
            counter:      market.counters(seller)
        });
    }

    function _bid(address paymentToken, uint256 price, uint64 endTime)
        internal view returns (AgentMarketplace.Order memory)
    {
        return AgentMarketplace.Order({
            side:         AgentMarketplace.OrderSide.BID,
            offerer:      bidder,
            collection:   address(identity),
            tokenId:      agentId,
            paymentToken: paymentToken,
            price:        price,
            startTime:    0,
            endTime:      endTime,
            salt:         uint256(keccak256(abi.encode(block.number, "bid"))),
            counter:      market.counters(bidder)
        });
    }

    function _sign(uint256 pk, AgentMarketplace.Order memory o) internal view returns (bytes memory) {
        bytes32 digest = market.hashOrder(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ─── ASK fills ───────────────────────────────────────────────────

    function test_FulfillSignedAsk_ETH() public {
        // Seller pre-approves the marketplace once (still required: NFT
        // transfer is on-chain).
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);

        AgentMarketplace.Order memory o = _ask(address(0), 1 ether, 0);
        bytes memory sig = _sign(sellerKey, o);

        uint256 sellerBefore  = seller.balance;
        uint256 feeRecvBefore = feeRecv.balance;
        address vault = identity.royaltyVaultAddress(agentId);

        vm.prank(buyer);
        market.fulfillOrder{value: 1 ether}(o, sig);

        // 11% to vault, 2.5% to feeRecv, 86.5% to seller.
        assertEq(vault.balance,                  0.11 ether,  "vault");
        assertEq(feeRecv.balance - feeRecvBefore, 0.025 ether, "feeRecv");
        assertEq(seller.balance - sellerBefore,   0.865 ether, "seller");
        assertEq(identity.ownerOf(agentId),       buyer,        "transfer");
        assertTrue(market.orderFilled(market.hashOrder(o)), "filled flag");
    }

    function test_FulfillSignedAsk_USDC() public {
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);

        AgentMarketplace.Order memory o = _ask(address(usdc), 100_000_000, 0);
        bytes memory sig = _sign(sellerKey, o);

        vm.prank(buyer);
        usdc.approve(address(market), type(uint256).max);

        vm.prank(buyer);
        market.fulfillOrder(o, sig);

        address vault = identity.royaltyVaultAddress(agentId);
        assertEq(usdc.balanceOf(vault),    11_000_000);
        assertEq(usdc.balanceOf(feeRecv),   2_500_000);
        assertEq(usdc.balanceOf(seller),   86_500_000);
        assertEq(identity.ownerOf(agentId), buyer);
    }

    function test_FulfillSignedAsk_RevertOnReplay() public {
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);
        AgentMarketplace.Order memory o = _ask(address(0), 1 ether, 0);
        bytes memory sig = _sign(sellerKey, o);

        vm.prank(buyer);
        market.fulfillOrder{value: 1 ether}(o, sig);

        // First buyer transfers NFT back to seller for replay attempt.
        vm.prank(buyer);
        identity.transferFrom(buyer, seller, agentId);

        vm.deal(address(0xDEAD), 1 ether);
        vm.prank(address(0xDEAD));
        vm.expectRevert(AgentMarketplace.OrderConsumed.selector);
        market.fulfillOrder{value: 1 ether}(o, sig);
    }

    function test_FulfillSignedAsk_RevertOnBadSignature() public {
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);
        AgentMarketplace.Order memory o = _ask(address(0), 1 ether, 0);
        // Sign with the wrong key.
        bytes memory sig = _sign(buyerKey, o);

        vm.prank(buyer);
        vm.expectRevert(AgentMarketplace.InvalidSignature.selector);
        market.fulfillOrder{value: 1 ether}(o, sig);
    }

    function test_FulfillSignedAsk_RevertOnExpired() public {
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);
        AgentMarketplace.Order memory o = _ask(address(0), 1 ether, uint64(block.timestamp + 1 hours));
        bytes memory sig = _sign(sellerKey, o);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(buyer);
        vm.expectRevert(AgentMarketplace.Expired.selector);
        market.fulfillOrder{value: 1 ether}(o, sig);
    }

    function test_IncrementCounter_InvalidatesAllOpenAsks() public {
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);
        AgentMarketplace.Order memory o = _ask(address(0), 1 ether, 0);
        bytes memory sig = _sign(sellerKey, o);

        // Seller bumps their counter.
        vm.prank(seller);
        market.incrementCounter();

        vm.prank(buyer);
        vm.expectRevert(AgentMarketplace.WrongCounter.selector);
        market.fulfillOrder{value: 1 ether}(o, sig);
    }

    function test_CancelOrder_BlocksFill() public {
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);
        AgentMarketplace.Order memory o = _ask(address(0), 1 ether, 0);
        bytes memory sig = _sign(sellerKey, o);

        vm.prank(seller);
        market.cancelOrder(o);

        vm.prank(buyer);
        vm.expectRevert(AgentMarketplace.OrderConsumed.selector);
        market.fulfillOrder{value: 1 ether}(o, sig);
    }

    function test_CancelOrder_RejectsNonOfferer() public {
        AgentMarketplace.Order memory o = _ask(address(0), 1 ether, 0);
        vm.prank(buyer);
        vm.expectRevert(AgentMarketplace.CallerNotOfferer.selector);
        market.cancelOrder(o);
    }

    // ─── BID fills ───────────────────────────────────────────────────

    function test_FulfillSignedBid_USDC() public {
        // Bidder approves the marketplace to pull USDC at fill time.
        vm.prank(bidder);
        usdc.approve(address(market), type(uint256).max);
        AgentMarketplace.Order memory o = _bid(address(usdc), 100_000_000, 0);
        bytes memory sig = _sign(bidderKey, o);

        // Seller approves NFT transfer and accepts.
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);

        vm.prank(seller);
        market.fulfillOrder(o, sig);

        address vault = identity.royaltyVaultAddress(agentId);
        assertEq(usdc.balanceOf(vault),    11_000_000);
        assertEq(usdc.balanceOf(feeRecv),   2_500_000);
        assertEq(usdc.balanceOf(seller),   86_500_000);
        assertEq(identity.ownerOf(agentId), bidder);
    }

    function test_FulfillSignedBid_RevertOnETHPayment() public {
        AgentMarketplace.Order memory o = _bid(address(0), 1 ether, 0);
        bytes memory sig = _sign(bidderKey, o);
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);
        vm.prank(seller);
        vm.expectRevert(AgentMarketplace.BidPaymentMustBeERC20.selector);
        market.fulfillOrder(o, sig);
    }

    function test_FulfillSignedBid_RevertWhenSellerNotOwner() public {
        vm.prank(bidder);
        usdc.approve(address(market), type(uint256).max);
        AgentMarketplace.Order memory o = _bid(address(usdc), 100_000_000, 0);
        bytes memory sig = _sign(bidderKey, o);
        vm.prank(buyer); // buyer doesn't own the agent
        vm.expectRevert(AgentMarketplace.NotOwner.selector);
        market.fulfillOrder(o, sig);
    }

    // ─── Bulk fulfill ────────────────────────────────────────────────

    function test_FulfillOrders_BatchETH() public {
        // Mint a second agent and list both via signed asks.
        vm.prank(seller);
        uint256 a2 = identity.registerAgent("Bot2", "ipfs://m2", 1000, address(0));
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);

        AgentMarketplace.Order memory o1 = _ask(address(0), 1 ether, 0);
        AgentMarketplace.Order memory o2 = _ask(address(0), 2 ether, 0);
        o2.tokenId = a2;
        o2.salt    = uint256(keccak256("o2-salt"));

        bytes memory s1 = _sign(sellerKey, o1);
        bytes memory s2 = _sign(sellerKey, o2);

        AgentMarketplace.Order[] memory orders = new AgentMarketplace.Order[](2);
        orders[0] = o1; orders[1] = o2;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = s1; sigs[1] = s2;
        uint256[] memory eth = new uint256[](2);
        eth[0] = 1 ether; eth[1] = 2 ether;

        vm.prank(buyer);
        market.fulfillOrders{value: 3 ether}(orders, sigs, eth);

        assertEq(identity.ownerOf(agentId), buyer);
        assertEq(identity.ownerOf(a2),      buyer);
    }

    // ─── ERC-1271 ────────────────────────────────────────────────────

    function test_FulfillSignedAsk_ERC1271_SmartWallet() public {
        // Deploy a 1271 wallet whose signer is `seller`'s key. Transfer
        // the NFT to the wallet so it owns it at fill time.
        Mock1271Wallet wallet = new Mock1271Wallet(seller);
        vm.prank(seller);
        identity.transferFrom(seller, address(wallet), agentId);
        // Wallet must approve the marketplace (no prank needed; the
        // Mock1271Wallet exposes a helper, but for ERC-721 we need a
        // direct call from the wallet itself):
        vm.prank(address(wallet));
        identity.setApprovalForAll(address(market), true);

        // Build an ASK whose offerer is the *wallet*.
        AgentMarketplace.Order memory o = AgentMarketplace.Order({
            side:         AgentMarketplace.OrderSide.ASK,
            offerer:      address(wallet),
            collection:   address(identity),
            tokenId:      agentId,
            paymentToken: address(0),
            price:        1 ether,
            startTime:    0,
            endTime:      0,
            salt:         uint256(keccak256("1271-salt")),
            counter:      market.counters(address(wallet))
        });
        // Wallet's `signer` (the seller EOA) signs the order digest.
        bytes32 digest = market.hashOrder(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 walletBefore = address(wallet).balance;
        vm.prank(buyer);
        market.fulfillOrder{value: 1 ether}(o, sig);

        assertEq(identity.ownerOf(agentId), buyer);
        assertEq(address(wallet).balance - walletBefore, 0.865 ether, "wallet proceeds");
    }
}
