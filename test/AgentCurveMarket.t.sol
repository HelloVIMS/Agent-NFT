// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";
import {AgentCurveMarket} from "../src/AgentCurveMarket.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";

contract FakeCreatorOnly {
    address public collectionCreator;
    constructor(address c) { collectionCreator = c; }
}

/// Re-enters buy() from the agent's arrival.
contract ReentrantBuyer is IERC721Receiver {
    AgentCurveMarket m;
    address c;
    constructor(AgentCurveMarket m_, address c_) { m = m_; c = c_; }
    function go() external payable { m.buy{value: msg.value}(c, type(uint256).max); }
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        m.buy{value: 1 ether}(c, type(uint256).max);
        return this.onERC721Received.selector;
    }
    receive() external payable {}
}

contract AgentCurveMarketTest is Test, IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    AgentCollectionFactory factory;
    AgentCollectionImpl col;
    AgentCurveMarket market;
    ERC20Mock usdc;

    address protocol = address(0xFEE);
    address creator = address(0xC0);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint96 constant FLOOR = 10e6;
    uint96 constant CEIL = 110e6;

    function setUp() public {
        AgentCollectionImpl impl = new AgentCollectionImpl();
        factory = new AgentCollectionFactory(address(impl), protocol);
        vm.prank(creator);
        (, address addr) = factory.createCollection("Curved", "CRV", 0, 500, 500, "");
        col = AgentCollectionImpl(addr);
        usdc = new ERC20Mock();
        market = new AgentCurveMarket(address(usdc), addr);
        for (uint256 i; i < 20; ++i) _mint();
        vm.prank(creator);
        col.setApprovalForAll(address(market), true);
        for (uint256 i; i < 3; ++i) {
            address who = [alice, bob, address(this)][i];
            usdc.mint(who, 10_000e6);
            vm.prank(who);
            usdc.approve(address(market), type(uint256).max);
            vm.deal(who, 100 ether);
            vm.prank(who);
            col.setApprovalForAll(address(market), true);
        }
    }

    function _mint() internal returns (uint256 id) {
        vm.prank(creator);
        id = col.registerAgent("A", "ipfs://a");
    }

    function _curve(CurveMath.Kind k) internal pure returns (CurveMath.Curve memory c) {
        c = CurveMath.Curve({kind: k, floor: FLOOR, ceiling: CEIL, length: 11, a: k == CurveMath.Kind.Power ? 2 : 0, b: 0});
    }

    function _open(CurveMath.Kind k, address currency, uint16 reserveBps, uint256 n) internal {
        vm.startPrank(creator);
        market.configure(address(col), _curve(k), currency, reserveBps);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = i + 1;
        market.stock(address(col), ids);
        vm.stopPrank();
    }

    // ── terms ────────────────────────────────────────────────────────────

    function test_onlyTheCreatorOfAFactoryCollectionConfigures() public {
        vm.prank(alice);
        vm.expectRevert(AgentCurveMarket.NotCreator.selector);
        market.configure(address(col), _curve(CurveMath.Kind.Linear), address(0), 0);
        FakeCreatorOnly fake = new FakeCreatorOnly(alice);
        vm.prank(alice);
        vm.expectRevert(AgentCurveMarket.NotACollection.selector);
        market.configure(address(fake), _curve(CurveMath.Kind.Linear), address(0), 0);
        vm.startPrank(creator);
        vm.expectRevert(AgentCurveMarket.UnsupportedCurrency.selector);
        market.configure(address(col), _curve(CurveMath.Kind.Linear), address(0xBAD), 0);
        vm.expectRevert(AgentCurveMarket.ReserveTooHigh.selector);
        market.configure(address(col), _curve(CurveMath.Kind.Linear), address(0), 10_001);
        vm.stopPrank();
    }

    function test_termsLockAtTheFirstSale() public {
        _open(CurveMath.Kind.Linear, address(usdc), 5_000, 5);
        vm.prank(creator);
        market.configure(address(col), _curve(CurveMath.Kind.Power), address(usdc), 5_000); // before: fine
        vm.prank(alice);
        market.buy(address(col), type(uint256).max);
        vm.prank(creator);
        vm.expectRevert(AgentCurveMarket.TermsLocked.selector);
        market.configure(address(col), _curve(CurveMath.Kind.Linear), address(usdc), 0);
    }

    // ── buying ───────────────────────────────────────────────────────────

    function test_buyInUSDCFollowsTheCurveAndSplitsProceeds() public {
        _open(CurveMath.Kind.Linear, address(usdc), 0, 5);
        uint256 a0 = usdc.balanceOf(alice);
        vm.startPrank(alice);
        (uint256 id1, uint256 p1) = market.buy(address(col), FLOOR);
        (, uint256 p2) = market.buy(address(col), FLOOR + 10e6);
        vm.stopPrank();
        assertEq(p1, FLOOR);
        assertEq(p2, FLOOR + 10e6, "linear: +10 per agent");
        assertEq(col.ownerOf(id1), alice);
        assertEq(a0 - usdc.balanceOf(alice), p1 + p2);
        uint256 fee = ((p1 + p2) * 200) / 10_000;
        assertEq(market.credit(address(usdc), protocol), fee, "the collection's 2% primary fee");
        assertEq(market.credit(address(usdc), creator), p1 + p2 - fee);
        vm.prank(creator);
        market.withdraw(address(usdc));
        assertEq(usdc.balanceOf(creator), p1 + p2 - fee);
        assertEq(usdc.balanceOf(address(market)), fee);
    }

    function test_slippageLimitAndSoldOut() public {
        _open(CurveMath.Kind.Linear, address(usdc), 0, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentCurveMarket.PriceAboveLimit.selector, FLOOR, FLOOR - 1));
        market.buy(address(col), FLOOR - 1);
        vm.prank(alice);
        market.buy(address(col), FLOOR);
        vm.prank(bob);
        vm.expectRevert(AgentCurveMarket.SoldOut.selector);
        market.buy(address(col), type(uint256).max);
    }

    function test_ethBuyRefundsOverpaymentAndRefusesUnderpayment() public {
        CurveMath.Curve memory c = CurveMath.Curve({kind: CurveMath.Kind.Elliptical, floor: 0.01 ether, ceiling: 0.11 ether, length: 11, a: 0, b: 0});
        vm.startPrank(creator);
        market.configure(address(col), c, address(0), 0);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1; ids[1] = 2;
        market.stock(address(col), ids);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(AgentCurveMarket.WrongPayment.selector);
        market.buy{value: 0.01 ether - 1}(address(col), 1 ether);
        uint256 b0 = alice.balance;
        vm.prank(alice);
        (, uint256 p) = market.buy{value: 1 ether}(address(col), 1 ether);
        assertEq(b0 - alice.balance, p, "only the price is kept");
        vm.prank(alice);
        vm.expectRevert(AgentCurveMarket.WrongPayment.selector);
        market.buy{value: 1}(address(col), type(uint256).max); // wrong currency mix
        _usdcOnly();
    }

    function _usdcOnly() internal {
        // A USDC sale refuses ETH riding along.
        vm.startPrank(creator);
        (, address other) = factory.createCollection("U", "U", 0, 0, 0, "");
        uint256 id = AgentCollectionImpl(other).registerAgent("U", "ipfs://u");
        AgentCollectionImpl(other).setApprovalForAll(address(market), true);
        market.configure(other, _curve(CurveMath.Kind.Linear), address(usdc), 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        market.stock(other, ids);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(AgentCurveMarket.WrongPayment.selector);
        market.buy{value: 1}(other, type(uint256).max);
    }

    // ── selling back ─────────────────────────────────────────────────────

    function test_sellBackPaysTheShareOfTheLastPriceAndRestocks() public {
        _open(CurveMath.Kind.Linear, address(usdc), 8_000, 5);
        vm.prank(alice);
        (uint256 id1, uint256 p1) = market.buy(address(col), type(uint256).max);
        vm.prank(bob);
        (uint256 id2, uint256 p2) = market.buy(address(col), type(uint256).max);
        assertEq(market.saleOf(address(col)).reserve, (p1 * 8_000) / 10_000 + (p2 * 8_000) / 10_000);
        assertEq(market.quoteSell(address(col)), (p2 * 8_000) / 10_000);
        // Alice sells back the earlier one: she gets the last position's share.
        uint256 a0 = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 out = market.sell(address(col), id1, (p2 * 8_000) / 10_000);
        assertEq(out, (p2 * 8_000) / 10_000);
        assertEq(usdc.balanceOf(alice) - a0, out);
        assertEq(col.ownerOf(id1), address(market), "back in stock");
        assertEq(market.saleOf(address(col)).sold, 1);
        // The next buyer pays the same as Bob did, for Alice's agent.
        vm.prank(address(this));
        (uint256 id3, uint256 p3) = market.buy(address(col), type(uint256).max);
        assertEq(id3, id1);
        assertEq(p3, p2);
        // Bob and the new holder sell out: the reserve empties exactly.
        vm.prank(bob);
        market.sell(address(col), id2, 0);
        market.sell(address(col), id3, 0);
        assertEq(market.saleOf(address(col)).reserve, 0);
        assertEq(market.saleOf(address(col)).sold, 0);
    }

    function test_onlyAgentsBoughtHereSellBack_andOnlyByTheirHolder() public {
        _open(CurveMath.Kind.Linear, address(usdc), 5_000, 5);
        vm.prank(alice);
        (uint256 id, ) = market.buy(address(col), type(uint256).max);
        // An agent from outside the market can't drain the reserve.
        uint256 outside = _mint();
        vm.prank(creator);
        col.transferFrom(creator, bob, outside);
        vm.prank(bob);
        vm.expectRevert(AgentCurveMarket.NotBoughtHere.selector);
        market.sell(address(col), outside, 0);
        vm.prank(bob);
        vm.expectRevert(AgentCurveMarket.NotHolder.selector);
        market.sell(address(col), id, 0);
        // A minimum payout protects against a front-run sell.
        vm.prank(alice);
        vm.expectRevert();
        market.sell(address(col), id, type(uint256).max);
    }

    function test_buyOnlyHasNoSellBack() public {
        _open(CurveMath.Kind.Linear, address(usdc), 0, 5);
        vm.prank(alice);
        (uint256 id, ) = market.buy(address(col), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(AgentCurveMarket.NoReserve.selector);
        market.sell(address(col), id, 0);
    }

    function test_unstockLeavesTheReserveForHolders() public {
        _open(CurveMath.Kind.Linear, address(usdc), 10_000, 5);
        vm.prank(alice);
        (uint256 id, uint256 p) = market.buy(address(col), type(uint256).max);
        vm.prank(creator);
        market.unstock(address(col), 10);
        assertEq(market.stockOf(address(col)), 0);
        vm.prank(alice);
        assertEq(market.sell(address(col), id, p), p, "a 100% reserve returns the full price");
    }

    // ── safety ──────────────────────────────────────────────────────────

    function test_reentrantBuyerIsRefused() public {
        CurveMath.Curve memory c = CurveMath.Curve({kind: CurveMath.Kind.Linear, floor: 0.01 ether, ceiling: 0.02 ether, length: 11, a: 0, b: 0});
        vm.startPrank(creator);
        market.configure(address(col), c, address(0), 5_000);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1; ids[1] = 2; ids[2] = 3;
        market.stock(address(col), ids);
        vm.stopPrank();
        ReentrantBuyer r = new ReentrantBuyer(market, address(col));
        vm.deal(address(r), 5 ether);
        vm.expectRevert();
        r.go{value: 1 ether}();
    }

    function test_unsolicitedAgentsAreRefused() public {
        uint256 id = _mint();
        vm.prank(creator);
        vm.expectRevert();
        col.safeTransferFrom(creator, address(market), id);
    }

    function test_termsCanBeReadAndQuoted() public {
        _open(CurveMath.Kind.Power, address(usdc), 0, 5);
        uint256 three = market.quoteBuy(address(col), 3);
        assertEq(three, market.priceAt(address(col), 0) + market.priceAt(address(col), 1) + market.priceAt(address(col), 2));
        vm.prank(alice);
        (, uint256 p) = market.buy(address(col), type(uint256).max);
        assertEq(p, market.priceAt(address(col), 0));
    }
}

/// Random buys and sells by several holders: the market always holds
/// exactly its reserves plus what it owes in credits, and the reserve is
/// what every outstanding position put in.
contract CurveMarketHandler is Test {
    AgentCurveMarket public m;
    address public c;
    ERC20Mock public usdc;
    address[] public actors;
    uint256[] public held; // token ids held by actors (index aligned with holder)
    address[] public holderOf;

    constructor(AgentCurveMarket m_, address c_, ERC20Mock u_, address[] memory a) {
        m = m_; c = c_; usdc = u_; actors = a;
    }

    function buy(uint256 who) external {
        if (m.stockOf(c) == 0) return;
        address a = actors[who % actors.length];
        vm.prank(a);
        (uint256 id, ) = m.buy(c, type(uint256).max);
        held.push(id);
        holderOf.push(a);
    }

    function sell(uint256 which) external {
        if (held.length == 0) return;
        uint256 k = which % held.length;
        vm.prank(holderOf[k]);
        m.sell(c, held[k], 0);
        held[k] = held[held.length - 1];
        holderOf[k] = holderOf[holderOf.length - 1];
        held.pop();
        holderOf.pop();
    }

    function heldCount() external view returns (uint256) {
        return held.length;
    }
}

contract AgentCurveMarketInvariant is Test {
    AgentCurveMarket market;
    AgentCollectionImpl col;
    ERC20Mock usdc;
    CurveMarketHandler handler;
    address creator = address(0xC0);
    address protocol = address(0xFEE);
    address[] actors;

    function setUp() public {
        AgentCollectionImpl impl = new AgentCollectionImpl();
        AgentCollectionFactory factory = new AgentCollectionFactory(address(impl), protocol);
        vm.prank(creator);
        (, address addr) = factory.createCollection("Inv", "INV", 0, 500, 500, "");
        col = AgentCollectionImpl(addr);
        usdc = new ERC20Mock();
        market = new AgentCurveMarket(address(usdc), addr);
        vm.startPrank(creator);
        market.configure(addr, CurveMath.Curve({kind: CurveMath.Kind.Smootherstep, floor: 1e6, ceiling: 97e6, length: 40, a: 0, b: 0}), address(usdc), 7_300);
        uint256[] memory ids = new uint256[](30);
        for (uint256 i; i < 30; ++i) ids[i] = col.registerAgent("I", "ipfs://i");
        col.setApprovalForAll(address(market), true);
        market.stock(addr, ids);
        vm.stopPrank();
        for (uint256 i; i < 4; ++i) {
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            usdc.mint(a, 1_000_000e6);
            vm.startPrank(a);
            usdc.approve(address(market), type(uint256).max);
            col.setApprovalForAll(address(market), true);
            vm.stopPrank();
        }
        handler = new CurveMarketHandler(market, addr, usdc, actors);
        targetContract(address(handler));
    }

    function invariant_holdsExactlyReservePlusCredits() public view {
        AgentCurveMarket.Sale memory s = market.saleOf(address(col));
        uint256 owed = s.reserve + market.credit(address(usdc), creator) + market.credit(address(usdc), protocol);
        assertEq(usdc.balanceOf(address(market)), owed);
    }

    function invariant_reserveIsWhatOutstandingPositionsPutIn() public view {
        AgentCurveMarket.Sale memory s = market.saleOf(address(col));
        uint256 expected;
        for (uint256 i; i < s.sold; ++i) expected += (market.priceAt(address(col), i) * 7_300) / 10_000;
        assertEq(s.reserve, expected);
        assertEq(s.sold, handler.heldCount());
    }
}
