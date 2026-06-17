// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentAuctionHouse.sol";

contract AucUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @notice English + Dutch auction lifecycle tests.
contract AgentAuctionHouseTest is Test {
    AgentIdentityRegistry identity;
    AgentAuctionHouse     house;
    AucUSDC               usdc;

    address admin   = address(0xA11CE);
    address feeRecv = address(0xFEE);

    address seller  = address(0xBEEF1);
    address alice   = address(0xA11CE2);
    address bob     = address(0xB0B);
    address carol   = address(0xCAA01);

    uint256 agentId;

    function setUp() public {
        AgentIdentityRegistry idImpl = new AgentIdentityRegistry();
        ERC1967Proxy idProxy = new ERC1967Proxy(
            address(idImpl), abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identity = AgentIdentityRegistry(address(idProxy));

        AgentAuctionHouse impl = new AgentAuctionHouse();
        ERC1967Proxy prx = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AgentAuctionHouse.initialize, (admin, feeRecv, 250))
        );
        house = AgentAuctionHouse(address(prx));

        usdc = new AucUSDC();

        vm.prank(seller);
        agentId = identity.registerAgent("Bot", "ipfs://m", 500, address(0));

        vm.prank(seller);
        identity.setApprovalForAll(address(house), true);

        vm.deal(seller, 10 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);
        vm.deal(carol, 10 ether);

        usdc.mint(alice, 1_000_000_000);
        usdc.mint(bob,   1_000_000_000);
        vm.prank(alice); usdc.approve(address(house), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(house), type(uint256).max);
    }

    // ─── English ───────────────────────────────────────────────────

    function test_English_HappyPath_ETH() public {
        vm.prank(seller);
        uint256 id = house.createEnglishAuction(
            address(identity), agentId, address(0),
            1 ether, 500 /*5% min increment*/,
            uint64(block.timestamp + 1 days), 60
        );

        // Bid #1 = reserve.
        vm.prank(alice);
        house.bid{value: 1 ether}(id, 1 ether);
        assertEq(address(house).balance, 1 ether, "escrow holds bid 1");

        // Bid #2 must exceed bid1 + 5% = 1.05 ether → use 1.1.
        vm.prank(bob);
        uint256 aliceBefore = alice.balance;
        house.bid{value: 1.1 ether}(id, 1.1 ether);
        assertEq(alice.balance - aliceBefore, 1 ether, "alice refunded");
        assertEq(address(house).balance, 1.1 ether, "escrow holds bid 2");

        // Settle after endTime.
        vm.warp(block.timestamp + 2 days);
        uint256 sellerBefore = seller.balance;
        uint256 feeBefore = feeRecv.balance;
        house.settleEnglish(id);

        assertEq(identity.ownerOf(agentId), bob, "winner gets nft");
        // Protocol fee 2.5% of 1.1 = 0.0275.
        assertEq(feeRecv.balance - feeBefore, 0.0275 ether, "fee");
        // Seller proceeds = price - royalty - fee. Royalty path is the
        // registry's ERC-2981 — assert seller got *something* and that
        // funds drained from the auction house.
        assertGt(seller.balance, sellerBefore, "seller paid");
        assertEq(address(house).balance, 0, "escrow drained");
    }

    function test_English_AntiSnipe_ExtendsEndTime() public {
        uint64 endT = uint64(block.timestamp + 1 hours);
        uint64 snipeWin = 5 minutes;

        vm.prank(seller);
        uint256 id = house.createEnglishAuction(
            address(identity), agentId, address(0),
            1 ether, 100, endT, snipeWin
        );

        // Warp to 2 minutes before the end so a new bid lies inside
        // the anti-snipe window.
        vm.warp(endT - 2 minutes);
        vm.prank(alice);
        house.bid{value: 1 ether}(id, 1 ether);

        (, , , , , , , , uint64 newEnd, , , , , , , ) = _spreadAuction(id);
        assertGt(newEnd, endT, "anti-snipe pushed endTime out");
        // Exactly: new endTime = now + snipeWin.
        assertEq(newEnd, block.timestamp + snipeWin, "snipe window applied");
    }

    function test_English_Reverts() public {
        vm.prank(seller);
        uint256 id = house.createEnglishAuction(
            address(identity), agentId, address(0),
            1 ether, 500, uint64(block.timestamp + 1 days), 60
        );

        // Below reserve.
        vm.prank(alice);
        vm.expectRevert(AgentAuctionHouse.BidBelowReserve.selector);
        house.bid{value: 0.5 ether}(id, 0.5 ether);

        // Successful bid then under-incremented next bid.
        vm.prank(alice);
        house.bid{value: 1 ether}(id, 1 ether);
        vm.prank(bob);
        vm.expectRevert(AgentAuctionHouse.BidBelowIncrement.selector);
        house.bid{value: 1.04 ether}(id, 1.04 ether); // 4% < 5%

        // Self-trade guard for seller.
        vm.prank(seller);
        vm.expectRevert(AgentAuctionHouse.NoSelfTrade.selector);
        house.bid{value: 2 ether}(id, 2 ether);

        // Settle before endTime.
        vm.expectRevert(AgentAuctionHouse.AuctionStillRunning.selector);
        house.settleEnglish(id);
    }

    function test_English_NoBidsClosesCancelled() public {
        vm.prank(seller);
        uint256 id = house.createEnglishAuction(
            address(identity), agentId, address(0),
            1 ether, 100, uint64(block.timestamp + 1 hours), 0
        );
        vm.warp(block.timestamp + 2 hours);
        house.settleEnglish(id);
        assertEq(uint8(_status(id)), uint8(AgentAuctionHouse.AuctionStatus.Cancelled));
        // NFT stays with seller.
        assertEq(identity.ownerOf(agentId), seller);
    }

    // ─── Dutch ─────────────────────────────────────────────────────

    function test_Dutch_PriceDecay() public {
        uint64 start = uint64(block.timestamp);
        uint64 endT  = uint64(block.timestamp + 1000);
        vm.prank(seller);
        uint256 id = house.createDutchAuction(
            address(identity), agentId, address(0),
            10 ether, 1 ether, start, endT
        );

        assertEq(house.currentDutchPrice(id), 10 ether, "start price");
        vm.warp(start + 500);
        assertEq(house.currentDutchPrice(id), 5.5 ether, "midpoint");
        vm.warp(endT + 10);
        assertEq(house.currentDutchPrice(id), 1 ether, "floor");
    }

    function test_Dutch_BuyAtCurrentPrice() public {
        uint64 start = uint64(block.timestamp);
        uint64 endT  = uint64(block.timestamp + 1000);
        vm.prank(seller);
        uint256 id = house.createDutchAuction(
            address(identity), agentId, address(0),
            10 ether, 1 ether, start, endT
        );

        vm.warp(start + 250); // 25% through → price = 10 - 0.25*9 = 7.75 ether
        uint256 price = house.currentDutchPrice(id);
        assertEq(price, 7.75 ether);

        // Overpay slightly to hedge clock movement; expect refund.
        vm.prank(alice);
        uint256 aliceBefore = alice.balance;
        house.buyDutch{value: 8 ether}(id);
        assertEq(identity.ownerOf(agentId), alice);
        // Alice should have spent exactly `price` net of the refund.
        assertEq(aliceBefore - alice.balance, price, "exact spend");
    }

    function test_Dutch_RevertOnDoubleBuy() public {
        uint64 start = uint64(block.timestamp);
        vm.prank(seller);
        uint256 id = house.createDutchAuction(
            address(identity), agentId, address(0),
            10 ether, 1 ether, start, start + 1000
        );
        vm.prank(alice);
        house.buyDutch{value: 10 ether}(id);
        // Second buyer should hit AuctionNotOpen (status flipped to Settled).
        vm.prank(bob);
        vm.expectRevert(AgentAuctionHouse.AuctionNotOpen.selector);
        house.buyDutch{value: 10 ether}(id);
    }

    function test_Dutch_USDC() public {
        uint64 start = uint64(block.timestamp);
        vm.prank(seller);
        uint256 id = house.createDutchAuction(
            address(identity), agentId, address(usdc),
            100_000_000, 10_000_000, start, start + 1000
        );

        vm.warp(start + 500); // midpoint → 55M
        uint256 price = house.currentDutchPrice(id);
        assertEq(price, 55_000_000);

        vm.prank(alice);
        house.buyDutch(id);
        assertEq(identity.ownerOf(agentId), alice);
        assertEq(usdc.balanceOf(feeRecv), (price * 250) / 10_000, "2.5% fee");
    }

    // ─── Helpers ────────────────────────────────────────────────────

    /// @dev Field-by-field spreading for the giant Auction struct.
    function _spreadAuction(uint256 id)
        internal view returns (
            AgentAuctionHouse.AuctionKind kind,
            AgentAuctionHouse.AuctionStatus status,
            address sellerAddr,
            address collection,
            uint256 tokenId,
            address paymentToken,
            uint256 reservePrice,
            uint256 minBidIncrementBps,
            uint64  endTime,
            uint64  antiSnipeWindow,
            uint256 startPrice,
            uint256 endPrice,
            uint64  startTime,
            address currentBidder,
            uint256 currentBid,
            uint64  createdAt
        )
    {
        AgentAuctionHouse.Auction memory a = house.getAuction(id);
        return (
            a.kind, a.status, a.seller, a.collection, a.tokenId, a.paymentToken,
            a.reservePrice, a.minBidIncrementBps, a.endTime, a.antiSnipeWindow,
            a.startPrice, a.endPrice, a.startTime, a.currentBidder, a.currentBid, a.createdAt
        );
    }

    function _status(uint256 id) internal view returns (AgentAuctionHouse.AuctionStatus) {
        return house.getAuction(id).status;
    }
}
