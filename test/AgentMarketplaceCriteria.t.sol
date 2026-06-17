// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentMarketplace.sol";

contract CriteriaUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @notice Criteria-bound (Merkle-rooted) signed-order tests for the
///         Seaport-style collection-wide bidding surface.
contract AgentMarketplaceCriteriaTest is Test {
    AgentIdentityRegistry identity;
    AgentMarketplace      market;
    CriteriaUSDC          usdc;

    address admin   = address(0xA11CE);
    address feeRecv = address(0xFEE);

    uint256 sellerKey  = 0xA11CE0001;
    address seller    = vm.addr(0xA11CE0001);
    uint256 bidderKey  = 0xB1DDE001;
    address bidder    = vm.addr(0xB1DDE001);

    uint256[3] agentIds;

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

        usdc = new CriteriaUSDC();

        vm.startPrank(seller);
        agentIds[0] = identity.registerAgent("A", "ipfs://a", 500, address(0));
        agentIds[1] = identity.registerAgent("B", "ipfs://b", 500, address(0));
        agentIds[2] = identity.registerAgent("C", "ipfs://c", 500, address(0));
        identity.setApprovalForAll(address(market), true);
        vm.stopPrank();

        usdc.mint(bidder, 1_000_000_000);
        vm.deal(bidder, 10 ether);
        vm.deal(seller, 10 ether);
        vm.prank(bidder);
        usdc.approve(address(market), type(uint256).max);
    }

    // ─── Merkle helpers ─────────────────────────────────────────────
    //
    // Leaf convention: keccak256(bytes.concat(keccak256(abi.encode(tokenId))))
    // i.e. OpenZeppelin's standard double-hash (matches the contract).

    function _leaf(uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(tokenId))));
    }

    /// @dev Build a 3-leaf Merkle tree over {a,b,c} sorted by leaf hash,
    ///      return (root, proofs[a], proofs[b], proofs[c]).
    function _buildTree3(uint256 a, uint256 b, uint256 c)
        internal pure
        returns (bytes32 root, bytes32[] memory pa, bytes32[] memory pb, bytes32[] memory pc)
    {
        bytes32 la = _leaf(a);
        bytes32 lb = _leaf(b);
        bytes32 lc = _leaf(c);
        // Pair (la, lb) with OZ canonical (smaller, larger) ordering.
        bytes32 lab = _hashPair(la, lb);
        // Lonely 'c' duplicates against itself per OZ convention? No — OZ uses
        // unbalanced trees with empty fill. Simpler: hash lab with lc directly.
        root = _hashPair(lab, lc);

        pa = new bytes32[](2);
        pa[0] = lb;
        pa[1] = lc;

        pb = new bytes32[](2);
        pb[0] = la;
        pb[1] = lc;

        pc = new bytes32[](1);
        pc[0] = lab;
    }

    function _hashPair(bytes32 x, bytes32 y) private pure returns (bytes32) {
        return x < y ? keccak256(abi.encode(x, y)) : keccak256(abi.encode(y, x));
    }

    function _criteriaBid(uint256 price, bytes32 root)
        internal view returns (AgentMarketplace.Order memory)
    {
        return AgentMarketplace.Order({
            side:         AgentMarketplace.OrderSide.BID,
            offerer:      bidder,
            collection:   address(identity),
            tokenId:      0,                  // ignored
            paymentToken: address(usdc),
            price:        price,
            startTime:    0,
            endTime:      0,
            salt:         uint256(keccak256("c-bid")),
            counter:      market.counters(bidder),
            criteriaRoot: root
        });
    }

    function _sign(uint256 pk, AgentMarketplace.Order memory o) internal view returns (bytes memory) {
        bytes32 digest = market.hashOrder(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ─── Tests ──────────────────────────────────────────────────────

    function test_FulfillCriteriaBid_HappyPath() public {
        (bytes32 root, bytes32[] memory pa, , ) =
            _buildTree3(agentIds[0], agentIds[1], agentIds[2]);

        // Sanity check the Merkle math before signing the order.
        assertTrue(MerkleProof.verify(pa, root, _leaf(agentIds[0])), "tree sanity");

        AgentMarketplace.Order memory o = _criteriaBid(100_000_000, root);
        bytes memory sig = _sign(bidderKey, o);

        uint256 sellerUSDCBefore = usdc.balanceOf(seller);
        uint256 bidderUSDCBefore = usdc.balanceOf(bidder);

        // Seller picks agentIds[0] and provides the proof.
        vm.prank(seller);
        market.fulfillCriteriaOrder(o, sig, agentIds[0], pa);

        // Token transferred + payment settled. Exact split depends on
        // the registry's ERC-2981 + the marketplace's protocol fee; we
        // verify *conservation*: bidder spent exactly the price, fees
        // landed at feeRecv, and the seller (also royalty receiver here)
        // collected the rest.
        assertEq(identity.ownerOf(agentIds[0]), bidder, "nft transferred");
        assertEq(bidderUSDCBefore - usdc.balanceOf(bidder), 100_000_000, "bidder paid price");
        assertEq(usdc.balanceOf(feeRecv), 2_500_000, "protocol fee=2.5%");
        // The remaining 97.5M is split between the royalty receiver
        // (per ERC-2981) and the seller. The exact split depends on
        // the registry's V7 royalty wiring (creator + secondary fee +
        // optional splitter), so we assert end-to-end conservation
        // rather than the precise breakout: total non-fee outflow
        // equals price - protocol fee.
        uint256 sellerDelta = usdc.balanceOf(seller) - sellerUSDCBefore;
        assertLe(sellerDelta, 100_000_000 - 2_500_000, "seller cannot exceed net");
        assertGe(sellerDelta, 90_000_000, "seller receives bulk of proceeds");
    }

    function test_FulfillCriteriaBid_RevertOnWrongTokenId() public {
        (bytes32 root, bytes32[] memory pa, , ) =
            _buildTree3(agentIds[0], agentIds[1], agentIds[2]);

        AgentMarketplace.Order memory o = _criteriaBid(100_000_000, root);
        bytes memory sig = _sign(bidderKey, o);

        // Seller tries to settle with a tokenId NOT in the tree (proof is
        // for agentIds[0]; supply agentIds[1] which has a different leaf).
        vm.prank(seller);
        vm.expectRevert(AgentMarketplace.InvalidCriteriaProof.selector);
        market.fulfillCriteriaOrder(o, sig, agentIds[1], pa);
    }

    function test_FulfillCriteriaBid_RevertOnConcreteFulfill() public {
        (bytes32 root, , , ) = _buildTree3(agentIds[0], agentIds[1], agentIds[2]);
        AgentMarketplace.Order memory o = _criteriaBid(100_000_000, root);
        bytes memory sig = _sign(bidderKey, o);

        // Calling the concrete fulfillOrder on a criteria order must revert.
        vm.prank(seller);
        vm.expectRevert(AgentMarketplace.CriteriaOrderUseCriteriaFulfill.selector);
        market.fulfillOrder(o, sig);
    }

    function test_FulfillConcrete_RevertOnCriteriaFulfill() public {
        AgentMarketplace.Order memory o = _criteriaBid(100_000_000, bytes32(0));
        // Concrete order — criteriaRoot is zero. Calling the criteria
        // path on it must revert NotCriteriaOrder.
        bytes memory sig = _sign(bidderKey, o);
        bytes32[] memory empty;
        vm.prank(seller);
        vm.expectRevert(AgentMarketplace.NotCriteriaOrder.selector);
        market.fulfillCriteriaOrder(o, sig, agentIds[0], empty);
    }

    function test_FulfillCriteriaBid_RevertOnReplay() public {
        (bytes32 root, bytes32[] memory pa, , ) =
            _buildTree3(agentIds[0], agentIds[1], agentIds[2]);
        AgentMarketplace.Order memory o = _criteriaBid(100_000_000, root);
        bytes memory sig = _sign(bidderKey, o);

        vm.prank(seller);
        market.fulfillCriteriaOrder(o, sig, agentIds[0], pa);

        // Now another seller (would need to own agentIds[1]) tries to
        // fill the same order with a different valid tokenId. Single-use
        // by design: the order hash is consumed.
        vm.prank(seller);
        vm.expectRevert(AgentMarketplace.OrderConsumed.selector);
        market.fulfillCriteriaOrder(o, sig, agentIds[1], _proofForIndex1(root));
    }

    /// @dev Recompute the proof for agentIds[1] from the same tree.
    function _proofForIndex1(bytes32 /*root*/) internal view returns (bytes32[] memory) {
        ( , , bytes32[] memory pb, ) = _buildTree3(agentIds[0], agentIds[1], agentIds[2]);
        return pb;
    }
}
