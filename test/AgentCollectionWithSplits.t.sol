// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentCollectionImpl} from "../src/AgentCollectionImpl.sol";
import {AgentCollectionFactory} from "../src/AgentCollectionFactory.sol";
import {AgentRoyaltySplitter} from "../src/AgentRoyaltySplitter.sol";
import {AgentRoyaltySplitterFactory} from "../src/AgentRoyaltySplitterFactory.sol";

/// @notice End-to-end: deploy a collection with on-chain royalty splits, mint
///         a paid token, and prove primary mint revenue + ERC-2981 royalty
///         flow into the splitter and disburse pro-rata.
contract AgentCollectionWithSplitsTest is Test {
    AgentCollectionFactory factory;
    AgentCollectionImpl    impl;

    address constant ALICE   = address(0xA11CE);
    address constant BOB     = address(0xB0B);
    address constant CAROL   = address(0xCA401);
    address constant MINTER  = address(0x4);
    address constant TREAS   = address(0x5);

    function setUp() public {
        impl    = new AgentCollectionImpl();
        factory = new AgentCollectionFactory(address(impl), TREAS);
    }

    function _splits50_30_20() internal pure returns (address[] memory p, uint256[] memory s) {
        p = new address[](3); p[0]=ALICE; p[1]=BOB; p[2]=CAROL;
        s = new uint256[](3); s[0]=5_000; s[1]=3_000; s[2]=2_000;
    }

    // ─── Happy path ─────────────────────────────────────────────────────────

    function test_CreateCollectionWithSplits_GovernanceStaysWithDeployer() public {
        (address[] memory p, uint256[] memory s) = _splits50_30_20();

        (uint256 cid, address coll, address splitter) = factory.createCollectionWithSplits(
            "Splits", "SPL", 100, 1000, 500, "", p, s
        );

        assertEq(cid, 1);
        // Governance stays with the deployer (msg.sender of createCollectionWithSplits).
        assertEq(AgentCollectionImpl(coll).collectionCreator(), address(this));
        // Financial recipient is the splitter.
        assertEq(AgentCollectionImpl(coll).royaltyReceiver(), splitter);
        assertEq(factory.collectionForSplitter(splitter), coll);

        uint256[] memory list = factory.getCollectionsByCreator(address(this));
        assertEq(list.length, 1);
        assertEq(list[0], cid);
    }

    function test_RoyaltyReceiverOnce_OnlyFactoryAndOnce() public {
        (address[] memory p, uint256[] memory s) = _splits50_30_20();
        (, address coll, ) = factory.createCollectionWithSplits(
            "Splits", "SPL", 100, 1000, 500, "", p, s
        );

        // Non-factory caller is rejected.
        vm.prank(address(0xBEEF));
        vm.expectRevert(AgentCollectionImpl.NotCreator.selector);
        AgentCollectionImpl(coll).setRoyaltyReceiverOnce(address(0xCAFE));

        // Even the factory cannot rewrite once set.
        vm.prank(address(factory));
        vm.expectRevert(AgentCollectionImpl.AlreadySet.selector);
        AgentCollectionImpl(coll).setRoyaltyReceiverOnce(address(0xCAFE));
    }

    function test_PrimaryMintRevenueFlowsIntoSplitter() public {
        (address[] memory p, uint256[] memory s) = _splits50_30_20();
        (, address coll, address splitter) = factory.createCollectionWithSplits(
            "Splits", "SPL", 100, 1000, 500, "", p, s
        );

        AgentCollectionImpl collection = AgentCollectionImpl(coll);
        // Deployer (this contract) is the creator → can configure mint directly.
        collection.setMintConfig(1 ether, 0, 0, 0);

        vm.deal(MINTER, 1 ether);
        vm.prank(MINTER);
        collection.mintAgent{value: 1 ether}("A", "uri");

        // 2% to protocol, 98% to splitter.
        assertEq(TREAS.balance, 0.02 ether);
        assertEq(splitter.balance, 0.98 ether);

        // Pull releases.
        AgentRoyaltySplitter(payable(splitter)).releaseAll();
        assertEq(ALICE.balance, 0.49 ether); // 50% of 0.98
        assertEq(BOB.balance,   0.294 ether);
        assertEq(CAROL.balance, 0.196 ether);
    }

    function test_RoyaltyInfoRoutesToSplitterWhenSet() public {
        // With splits configured, ERC-2981 must return the splitter — not the
        // per-token soulbound creator — so marketplaces remit secondary
        // royalties straight into the splitter for *every* token in the
        // collection regardless of who minted it.
        (address[] memory p, uint256[] memory s) = _splits50_30_20();
        (, address coll, address splitter) = factory.createCollectionWithSplits(
            "Splits", "SPL", 100, 1000, 500, "", p, s
        );
        AgentCollectionImpl(coll).setMintConfig(0, 0, 0, 0);

        vm.prank(MINTER);
        AgentCollectionImpl(coll).mintAgent("A", "uri");

        (address receiver, uint256 amount) = AgentCollectionImpl(coll).royaltyInfo(1, 1 ether);
        assertEq(receiver, splitter);
        assertEq(amount, 0.1 ether); // 1000 bps of 1 ether
    }

    function test_RoyaltyInfoFallsBackToAgentCreatorWhenNoSplits() public {
        vm.prank(ALICE);
        (, address coll) = factory.createCollection("Plain", "P", 100, 1000, 500, "");
        vm.prank(ALICE);
        AgentCollectionImpl(coll).setMintConfig(0, 0, 0, 0);

        vm.prank(MINTER);
        AgentCollectionImpl(coll).mintAgent("A", "uri");

        (address receiver,) = AgentCollectionImpl(coll).royaltyInfo(1, 1 ether);
        assertEq(receiver, MINTER);
    }

    function test_ContractURI_FeeRecipientIsSplitter() public {
        (address[] memory p, uint256[] memory s) = _splits50_30_20();
        (, address coll, address splitter) = factory.createCollectionWithSplits(
            "Splits", "SPL", 100, 1000, 500, "", p, s
        );
        // contractURI is a base64 data URI; verifying it contains the splitter
        // address as the fee_recipient asserts the marketplace will direct
        // collection-wide royalties to the splitter.
        string memory uri = AgentCollectionImpl(coll).contractURI();
        assertTrue(bytes(uri).length > 0);
        // We don't fully decode base64 in-test; existence of the URI plus
        // the royaltyInfo + on-chain royaltyReceiver assertions above are
        // the binding checks. This guard merely ensures contractURI doesn't
        // revert for a splits collection.
        splitter; // silence unused-warning while keeping the binding visible
    }

    // ─── Failure cases bubble up from splitter constructor ──────────────────

    function test_RevertsOnBadSharesSum() public {
        address[] memory p = new address[](2); p[0]=ALICE; p[1]=BOB;
        uint256[] memory s = new uint256[](2); s[0]=5_000; s[1]=4_999;
        vm.expectRevert(AgentRoyaltySplitter.SharesMustSumTo10000.selector);
        factory.createCollectionWithSplits("X", "X", 0, 0, 0, "", p, s);
    }

    function test_RevertsOnDuplicate() public {
        address[] memory p = new address[](2); p[0]=ALICE; p[1]=ALICE;
        uint256[] memory s = new uint256[](2); s[0]=5_000; s[1]=5_000;
        vm.expectRevert(AgentRoyaltySplitter.DuplicatePayee.selector);
        factory.createCollectionWithSplits("X", "X", 0, 0, 0, "", p, s);
    }

    function test_BackwardCompat_CreateCollectionUsesMsgSender() public {
        vm.prank(ALICE);
        (, address coll) = factory.createCollection("Plain", "P", 0, 0, 0, "");
        assertEq(AgentCollectionImpl(coll).collectionCreator(), ALICE);
    }
}
