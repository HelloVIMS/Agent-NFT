// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentMarketplace.sol";

contract MarketUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract AgentMarketplaceTest is Test {
    AgentIdentityRegistry identity;
    AgentMarketplace      market;
    MarketUSDC            usdc;

    address admin   = address(0xA11CE);
    address feeRecv = address(0xFEE);
    address seller  = address(0xBEEF);
    address buyer   = address(0xC0FFEE);
    address bidder  = address(0xBABE);

    uint256 agentId;

    function setUp() public {
        // Identity registry (UUPS) — same setup as other suites.
        AgentIdentityRegistry idImpl = new AgentIdentityRegistry();
        ERC1967Proxy idProxy = new ERC1967Proxy(
            address(idImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identity = AgentIdentityRegistry(address(idProxy));

        // Marketplace (UUPS) — 2.5% protocol fee.
        AgentMarketplace mkImpl = new AgentMarketplace();
        ERC1967Proxy mkProxy = new ERC1967Proxy(
            address(mkImpl),
            abi.encodeCall(AgentMarketplace.initialize, (admin, feeRecv, 250))
        );
        market = AgentMarketplace(address(mkProxy));

        usdc = new MarketUSDC();

        // Seller mints a 10% royalty agent (default creator royalty).
        vm.prank(seller);
        agentId = identity.registerAgent("Bot", "ipfs://m", 1000, address(0));

        // Fund participants.
        usdc.mint(buyer,  100_000_000);    // 100 USDC
        usdc.mint(bidder, 100_000_000);
        vm.deal(buyer,  10 ether);
        vm.deal(bidder, 10 ether);
        vm.deal(seller, 10 ether);
    }

    // ─── Listings ────────────────────────────────────────────────────

    function test_CreateListing_AndPurchase_ETH() public {
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);

        vm.prank(seller);
        uint256 lid = market.createListing(address(identity), agentId, address(0), 1 ether, 0);

        uint256 sellerBefore  = seller.balance;
        uint256 feeRecvBefore = feeRecv.balance;
        address vault = identity.royaltyVaultAddress(agentId);

        vm.prank(buyer);
        market.purchase{value: 1 ether}(lid);

        // 10% creator royalty + 1% system = 11% to vault, 2.5% protocol fee, 86.5% to seller.
        assertEq(vault.balance,                  0.11 ether,  "vault");
        assertEq(feeRecv.balance - feeRecvBefore, 0.025 ether, "feeRecv");
        assertEq(seller.balance - sellerBefore,   0.865 ether, "seller");
        assertEq(identity.ownerOf(agentId),       buyer,        "transferred");

        AgentMarketplace.Listing memory l = market.getListing(lid);
        assertEq(uint8(l.status), uint8(AgentMarketplace.ListingStatus.Sold));
    }

    function test_CreateListing_AndPurchase_USDC() public {
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);

        vm.prank(seller);
        uint256 lid = market.createListing(address(identity), agentId, address(usdc), 100_000_000, 0);

        vm.prank(buyer);
        usdc.approve(address(market), type(uint256).max);

        vm.prank(buyer);
        market.purchase(lid);

        address vault = identity.royaltyVaultAddress(agentId);
        assertEq(usdc.balanceOf(vault),    11_000_000, "vault");
        assertEq(usdc.balanceOf(feeRecv),   2_500_000, "feeRecv");
        assertEq(usdc.balanceOf(seller),   86_500_000, "seller");
        assertEq(identity.ownerOf(agentId), buyer);
    }

    function test_CancelListing() public {
        vm.startPrank(seller);
        identity.setApprovalForAll(address(market), true);
        uint256 lid = market.createListing(address(identity), agentId, address(0), 1 ether, 0);
        market.cancelListing(lid);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(AgentMarketplace.ListingNotOpen.selector);
        market.purchase{value: 1 ether}(lid);
        assertEq(market.openListingOf(address(identity), agentId), 0);
    }

    function test_Listing_RevertWhenNotOwner() public {
        vm.prank(buyer);
        vm.expectRevert(AgentMarketplace.NotOwner.selector);
        market.createListing(address(identity), agentId, address(0), 1 ether, 0);
    }

    function test_Listing_RevertWhenNotApproved() public {
        vm.prank(seller);
        vm.expectRevert(AgentMarketplace.NotApproved.selector);
        market.createListing(address(identity), agentId, address(0), 1 ether, 0);
    }

    function test_Listing_RevertOnSelfTrade() public {
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);
        vm.prank(seller);
        uint256 lid = market.createListing(address(identity), agentId, address(0), 1 ether, 0);
        vm.prank(seller);
        vm.expectRevert(AgentMarketplace.NoSelfTrade.selector);
        market.purchase{value: 1 ether}(lid);
    }

    function test_Listing_RevertOnExpired() public {
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);
        vm.prank(seller);
        uint256 lid = market.createListing(
            address(identity), agentId, address(0), 1 ether, uint64(block.timestamp + 1 hours)
        );
        vm.warp(block.timestamp + 2 hours);
        vm.prank(buyer);
        vm.expectRevert(AgentMarketplace.Expired.selector);
        market.purchase{value: 1 ether}(lid);
    }

    function test_Listing_RevertOnWrongPaymentValue() public {
        vm.prank(seller);
        identity.setApprovalForAll(address(market), true);
        vm.prank(seller);
        uint256 lid = market.createListing(address(identity), agentId, address(0), 1 ether, 0);
        vm.prank(buyer);
        vm.expectRevert(AgentMarketplace.WrongPayment.selector);
        market.purchase{value: 0.5 ether}(lid);
    }

    function test_NewListing_AutoCancelsPriorOpenOne() public {
        vm.startPrank(seller);
        identity.setApprovalForAll(address(market), true);
        uint256 a = market.createListing(address(identity), agentId, address(0), 1 ether, 0);
        uint256 b = market.createListing(address(identity), agentId, address(0), 2 ether, 0);
        vm.stopPrank();

        AgentMarketplace.Listing memory la = market.getListing(a);
        AgentMarketplace.Listing memory lb = market.getListing(b);
        assertEq(uint8(la.status), uint8(AgentMarketplace.ListingStatus.Cancelled));
        assertEq(uint8(lb.status), uint8(AgentMarketplace.ListingStatus.Open));
        assertEq(market.openListingOf(address(identity), agentId), b);
    }

    // ─── Offers ──────────────────────────────────────────────────────

    function test_MakeOffer_EscrowsETH_AcceptOffer_Settles() public {
        vm.prank(bidder);
        uint256 oid = market.makeOffer{value: 1 ether}(
            address(identity), agentId, address(0), 1 ether, 0
        );
        assertEq(address(market).balance, 1 ether, "escrow held");

        vm.startPrank(seller);
        identity.setApprovalForAll(address(market), true);
        uint256 sellerBefore = seller.balance;
        market.acceptOffer(oid);
        vm.stopPrank();

        address vault = identity.royaltyVaultAddress(agentId);
        assertEq(vault.balance,                  0.11 ether);
        assertEq(feeRecv.balance,                0.025 ether);
        assertEq(seller.balance - sellerBefore,  0.865 ether);
        assertEq(identity.ownerOf(agentId),      bidder);
        assertEq(address(market).balance,        0, "escrow released");
    }

    function test_MakeOffer_EscrowsUSDC_AcceptOffer_Settles() public {
        vm.prank(bidder);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(bidder);
        uint256 oid = market.makeOffer(
            address(identity), agentId, address(usdc), 100_000_000, 0
        );
        assertEq(usdc.balanceOf(address(market)), 100_000_000);

        vm.startPrank(seller);
        identity.setApprovalForAll(address(market), true);
        market.acceptOffer(oid);
        vm.stopPrank();

        address vault = identity.royaltyVaultAddress(agentId);
        assertEq(usdc.balanceOf(vault),    11_000_000);
        assertEq(usdc.balanceOf(feeRecv),   2_500_000);
        assertEq(usdc.balanceOf(seller),   86_500_000);
        assertEq(identity.ownerOf(agentId), bidder);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function test_CancelOffer_RefundsBidder_ETH() public {
        vm.prank(bidder);
        uint256 oid = market.makeOffer{value: 1 ether}(
            address(identity), agentId, address(0), 1 ether, 0
        );
        uint256 bal = bidder.balance;
        vm.prank(bidder);
        market.cancelOffer(oid);
        assertEq(bidder.balance, bal + 1 ether);
    }

    function test_CancelOffer_AnyoneCanCancelExpired() public {
        vm.prank(bidder);
        uint256 oid = market.makeOffer{value: 1 ether}(
            address(identity), agentId, address(0), 1 ether, uint64(block.timestamp + 1 hours)
        );
        vm.warp(block.timestamp + 2 hours);
        uint256 bal = bidder.balance;
        // Anyone (e.g. seller) can clean up an expired offer.
        vm.prank(seller);
        market.cancelOffer(oid);
        assertEq(bidder.balance, bal + 1 ether);
    }

    function test_AcceptOffer_CancelsMatchingOpenListing() public {
        vm.startPrank(seller);
        identity.setApprovalForAll(address(market), true);
        uint256 lid = market.createListing(address(identity), agentId, address(0), 1 ether, 0);
        vm.stopPrank();

        vm.prank(bidder);
        uint256 oid = market.makeOffer{value: 0.8 ether}(
            address(identity), agentId, address(0), 0.8 ether, 0
        );

        vm.prank(seller);
        market.acceptOffer(oid);

        AgentMarketplace.Listing memory l = market.getListing(lid);
        assertEq(uint8(l.status), uint8(AgentMarketplace.ListingStatus.Cancelled));
        assertEq(market.openListingOf(address(identity), agentId), 0);
    }

    function test_Offer_RevertOnSelfBid() public {
        vm.prank(seller);
        vm.expectRevert(AgentMarketplace.NoSelfTrade.selector);
        market.makeOffer{value: 1 ether}(address(identity), agentId, address(0), 1 ether, 0);
    }

    function test_Offer_RevertOnZeroPrice() public {
        vm.prank(bidder);
        vm.expectRevert(AgentMarketplace.ZeroPrice.selector);
        market.makeOffer(address(identity), agentId, address(0), 0, 0);
    }

    // ─── Admin ───────────────────────────────────────────────────────

    function test_SetProtocolFee_OnlyOwner() public {
        vm.prank(buyer);
        vm.expectRevert();
        market.setProtocolFee(500, feeRecv);

        vm.prank(admin);
        market.setProtocolFee(500, feeRecv);
        assertEq(market.protocolFeeBps(), 500);
    }

    function test_SetProtocolFee_RejectsAboveCap() public {
        vm.prank(admin);
        vm.expectRevert(AgentMarketplace.FeeTooHigh.selector);
        market.setProtocolFee(1001, feeRecv);
    }

    // ─── purchaseMany (sweep) ────────────────────────────────────────

    function test_PurchaseMany_SweepETH() public {
        // Mint two more agents so the seller has a sweepable inventory.
        vm.startPrank(seller);
        uint256 a2 = identity.registerAgent("B", "ipfs://b", 500, address(0));
        uint256 a3 = identity.registerAgent("C", "ipfs://c", 500, address(0));
        identity.setApprovalForAll(address(market), true);

        uint256 lid1 = market.createListing(address(identity), agentId, address(0), 1 ether, 0);
        uint256 lid2 = market.createListing(address(identity), a2,      address(0), 2 ether, 0);
        uint256 lid3 = market.createListing(address(identity), a3,      address(0), 3 ether, 0);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](3);
        ids[0] = lid1; ids[1] = lid2; ids[2] = lid3;

        uint256 feeBefore = feeRecv.balance;
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        market.purchaseMany{value: 6 ether}(ids);

        // All three NFTs transferred.
        assertEq(identity.ownerOf(agentId), buyer);
        assertEq(identity.ownerOf(a2),      buyer);
        assertEq(identity.ownerOf(a3),      buyer);
        // Total protocol fee = 2.5% of 6 ether = 0.15 ether.
        assertEq(feeRecv.balance - feeBefore, 0.15 ether, "aggregate fee");
        // All listings now Sold.
        ( , , , , , , , AgentMarketplace.ListingStatus s1) = market.listings(lid1);
        ( , , , , , , , AgentMarketplace.ListingStatus s2) = market.listings(lid2);
        ( , , , , , , , AgentMarketplace.ListingStatus s3) = market.listings(lid3);
        assertEq(uint8(s1), uint8(AgentMarketplace.ListingStatus.Sold));
        assertEq(uint8(s2), uint8(AgentMarketplace.ListingStatus.Sold));
        assertEq(uint8(s3), uint8(AgentMarketplace.ListingStatus.Sold));
    }

    function test_PurchaseMany_RefundsOverpayment() public {
        vm.startPrank(seller);
        identity.setApprovalForAll(address(market), true);
        uint256 lid = market.createListing(address(identity), agentId, address(0), 1 ether, 0);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](1);
        ids[0] = lid;

        vm.deal(buyer, 10 ether);
        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        market.purchaseMany{value: 2 ether}(ids); // 1 ether overpaid
        assertEq(buyerBefore - buyer.balance, 1 ether, "exact spend, overpayment refunded");
    }

    function test_PurchaseMany_RevertsOnInsufficientETH() public {
        vm.startPrank(seller);
        uint256 a2 = identity.registerAgent("B", "ipfs://b", 500, address(0));
        identity.setApprovalForAll(address(market), true);
        uint256 lid1 = market.createListing(address(identity), agentId, address(0), 1 ether, 0);
        uint256 lid2 = market.createListing(address(identity), a2,      address(0), 2 ether, 0);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](2);
        ids[0] = lid1; ids[1] = lid2;

        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        vm.expectRevert(AgentMarketplace.WrongPayment.selector);
        market.purchaseMany{value: 1.5 ether}(ids); // need 3 ether
    }

    function test_PurchaseMany_RevertsOnClosedListing() public {
        vm.startPrank(seller);
        identity.setApprovalForAll(address(market), true);
        uint256 lid = market.createListing(address(identity), agentId, address(0), 1 ether, 0);
        market.cancelListing(lid);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](1);
        ids[0] = lid;
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        vm.expectRevert(AgentMarketplace.ListingNotOpen.selector);
        market.purchaseMany{value: 1 ether}(ids);
    }
}
