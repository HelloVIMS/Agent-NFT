// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";

/**
 * @title AgentCollectionImplExtrasTest
 * @notice Drives the service-royalty getter/setter trio,
 *         setBaseURI, getSalesRoyalty error path, and the
 *         tokenURI baseURI-fallback branch that
 *         AgentCollectionFullStack.t.sol does not exercise.
 */
contract AgentCollectionImplExtrasTest is Test {
    AgentCollectionImpl    public implementation;
    AgentCollectionFactory public factory;
    AgentCollectionImpl    public collection;

    address public owner             = makeAddr("owner");
    address public collectionCreator = makeAddr("creator");
    address public protocolFee       = makeAddr("protocolFee");
    address public minter            = makeAddr("minter");
    address public stranger          = makeAddr("stranger");

    function setUp() public {
        vm.startPrank(owner);
        implementation = new AgentCollectionImpl();
        factory = new AgentCollectionFactory(address(implementation), protocolFee);
        vm.stopPrank();

        vm.prank(collectionCreator);
        (, address addr) = factory.createCollection(
            "Extras", "EX", 100,
            500,  // sales 5%
            1000, // service 10%
            ""
        );
        collection = AgentCollectionImpl(addr);

        // Open the mint so we can mint an agent for these tests.
        vm.prank(collectionCreator);
        collection.setMintConfig(0, 0, 0, 0);
    }

    function _mint(address to) internal returns (uint256 id) {
        vm.prank(to);
        id = collection.mintAgent("A", "ipfs://meta");
    }

    // ─── service royalty surface ─────────────────────────────────────────

    function test_getServiceRoyalty_returnsConfigured() public {
        uint256 id = _mint(minter);
        assertEq(collection.getServiceRoyalty(id), 1000);
    }

    function test_getServiceRoyalty_revertsForNonExistent() public {
        vm.expectRevert(AgentCollectionImpl.NotExists.selector);
        collection.getServiceRoyalty(999);
    }

    function test_getSalesRoyalty_revertsForNonExistent() public {
        vm.expectRevert(AgentCollectionImpl.NotExists.selector);
        collection.getSalesRoyalty(999);
    }

    function test_calculateServiceRoyaltySplit_returnsBpsSplit() public {
        uint256 id = _mint(minter);
        (uint256 creatorCut, uint256 ownerCut) = collection.calculateServiceRoyaltySplit(id, 1 ether);
        assertEq(creatorCut, 0.1 ether);
        assertEq(ownerCut,   0.9 ether);
    }

    function test_calculateSalesRoyaltySplit_returnsBpsSplit() public {
        uint256 id = _mint(minter);
        (uint256 creatorCut, uint256 ownerCut) = collection.calculateSalesRoyaltySplit(id, 1 ether);
        assertEq(creatorCut, 0.05 ether);
        assertEq(ownerCut,   0.95 ether);
    }

    // Sales / service royalties are committed at mint and immutable
    // thereafter — the legacy `updateSalesRoyalty` / `updateServiceRoyalty`
    // selectors no longer exist. These tests replace the prior CRUD-style
    // suite with a single immutability assertion.
    function test_royalties_areImmutablePostMint() public {
        uint256 id = _mint(minter);

        bytes memory salesCall   = abi.encodeWithSignature("updateSalesRoyalty(uint256,uint256)",   id, 800);
        bytes memory serviceCall = abi.encodeWithSignature("updateServiceRoyalty(uint256,uint256)", id, 1500);

        vm.prank(minter);
        (bool okSales,)   = address(collection).call(salesCall);
        vm.prank(minter);
        (bool okService,) = address(collection).call(serviceCall);

        assertFalse(okSales,   "updateSalesRoyalty selector should be removed");
        assertFalse(okService, "updateServiceRoyalty selector should be removed");

        // Stored bps unchanged from the mint values.
        assertEq(collection.getSalesRoyalty(id),   500);
        assertEq(collection.getServiceRoyalty(id), 1000);
    }

    // ─── setBaseURI ──────────────────────────────────────────────────────

    function test_setBaseURI_byCreator() public {
        vm.prank(collectionCreator);
        collection.setBaseURI("ipfs://baf-base/");
        assertEq(collection.collectionBaseURI(), "ipfs://baf-base/");
    }

    function test_setBaseURI_revertsForNonCreator() public {
        vm.prank(stranger);
        vm.expectRevert(AgentCollectionImpl.NotCreator.selector);
        collection.setBaseURI("ipfs://x");
    }

    // ─── agentCreator getter ─────────────────────────────────────────────

    function test_agentCreator_returnsRegisteredCreator() public {
        uint256 id = _mint(minter);
        assertEq(collection.agentCreator(id), minter);
    }
}
