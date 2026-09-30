// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgentIdentityRegistry} from "../src/AgentIdentityRegistry.sol";
import {AgentX402Receiver} from "../src/AgentX402Receiver.sol";
import {AgentReputationRegistry} from "../src/AgentReputationRegistry.sol";
import {AgentCollectionImpl} from "../src/AgentCollectionImpl.sol";
import {AgentCollectionFactory} from "../src/AgentCollectionFactory.sol";
import {BuyerSellerUSDC} from "./BuyerSellerAgentEconomy.t.sol";

/// Collection agents get the same reputation as identity agents: paid hires
/// through the receiver's NFT path, paid-only ratings, per-owner eras.
contract CollectionAgentReputationTest is Test {
    AgentIdentityRegistry identity;
    AgentX402Receiver x402;
    AgentReputationRegistry reputation;
    AgentCollectionImpl collection;
    BuyerSellerUSDC usdc;

    address admin = makeAddr("admin");
    address creator = makeAddr("creator");
    address nextOwner = makeAddr("next-owner");
    address outsider = makeAddr("outsider");
    uint256 buyerPk = uint256(keccak256("collection-buyer"));
    address buyer;
    bytes32 constant SID = keccak256("read");
    uint256 constant PRICE = 20_000;
    uint256 tokenId;

    function setUp() public {
        buyer = vm.addr(buyerPk);
        vm.startPrank(admin);
        identity = AgentIdentityRegistry(address(new ERC1967Proxy(address(new AgentIdentityRegistry()), abi.encodeCall(AgentIdentityRegistry.initialize, ()))));
        x402 = AgentX402Receiver(address(new ERC1967Proxy(address(new AgentX402Receiver()), abi.encodeCall(AgentX402Receiver.initialize, (address(identity), makeAddr("treasury"), 50)))));
        reputation = AgentReputationRegistry(address(new ERC1967Proxy(address(new AgentReputationRegistry()), abi.encodeCall(AgentReputationRegistry.initialize, (address(identity))))));
        reputation.setSettlementRecorder(address(x402), true);
        x402.setReputationRegistry(address(reputation));
        usdc = new BuyerSellerUSDC();
        x402.setTokenAllowed(address(usdc), true);
        AgentCollectionFactory factory = new AgentCollectionFactory(address(new AgentCollectionImpl()), makeAddr("protocol"));
        vm.stopPrank();

        vm.startPrank(creator);
        (, address addr) = factory.createCollection("Seers", "SEER", 10, 500, 500, "");
        collection = AgentCollectionImpl(addr);
        tokenId = collection.mintAgentWithSVG("Seer", "<svg/>", "");
        x402.selfRegisterCollection(addr);
        x402.registerServiceForNFT(addr, tokenId, SID, address(usdc), PRICE);
        vm.stopPrank();
    }

    function _pay(uint256 payerPk, bytes32 nonce) internal {
        address payer = vm.addr(payerPk);
        usdc.mint(payer, PRICE);
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 digest = x402.hashPaymentCommitmentForNFT(address(collection), tokenId, SID, address(usdc), PRICE, nonce, validBefore);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerPk, digest);
        x402.payForServiceForNFT(address(collection), tokenId, SID, payer, 0, validBefore, nonce, 0, bytes32(0), bytes32(0), v, r, s);
    }

    function test_paidHireRecordedAndBuyerRates() public {
        _pay(buyerPk, bytes32(uint256(1)));
        uint256 ref = reputation.refOf(address(collection), tokenId);
        (address nft, uint256 id) = reputation.nftOf(ref);
        assertEq(nft, address(collection));
        assertEq(id, tokenId);
        assertEq(reputation.eraCount(ref), 1);
        assertEq(reputation.eraStats(ref, 0).settlements, 1);
        assertEq(reputation.eraStats(ref, 0).volume, PRICE);

        vm.prank(outsider);
        vm.expectRevert(AgentReputationRegistry.NotAPayingClient.selector);
        reputation.giveFeedback(ref, 1, 0, "x402", "read", "");

        vm.prank(buyer);
        reputation.giveFeedback(ref, 1, 0, "x402", "read", "");
        assertEq(reputation.eraStats(ref, 0).feedbackCount, 1);
        vm.prank(buyer);
        vm.expectRevert(bytes("Already gave feedback"));
        reputation.giveFeedback(ref, 1, 0, "x402", "read", "");
    }

    function test_ownerPayingItsOwnAgentIsNotASale() public {
        uint256 creatorPk = uint256(keccak256("creator-pays"));
        vm.prank(creator);
        collection.transferFrom(creator, vm.addr(creatorPk), tokenId);
        _pay(creatorPk, bytes32(uint256(2)));
        assertEq(reputation.eraStats(reputation.refOf(address(collection), tokenId), 0).settlements, 0);
    }

    function test_saleStartsANewEraAndKeepsTheOldOne() public {
        _pay(buyerPk, bytes32(uint256(1)));
        uint256 ref = reputation.refOf(address(collection), tokenId);
        vm.prank(buyer);
        reputation.giveFeedback(ref, 1, 0, "x402", "read", "");
        vm.prank(creator);
        collection.transferFrom(creator, nextOwner, tokenId);
        assertEq(reputation.currentEra(ref), 1, "new owner, new era");
        (address eraOwner,,, bool current) = reputation.eraInfo(ref, 0);
        assertEq(eraOwner, creator);
        assertFalse(current);
        assertEq(reputation.eraStats(ref, 0).settlements, 1, "old era kept");
        vm.prank(buyer);
        vm.expectRevert(AgentReputationRegistry.NotAPayingClient.selector);
        reputation.giveFeedback(ref, 1, 0, "x402", "read", "");
    }

    /// Identity agent #1 and collection token #1 are different agents.
    function test_collectionAgentIsNotTheIdentityAgentWithTheSameId() public {
        _pay(buyerPk, bytes32(uint256(1)));
        assertTrue(reputation.refOf(address(collection), tokenId) != tokenId);
        assertEq(reputation.refOf(address(identity), tokenId), tokenId);
        (address nft,) = reputation.nftOf(tokenId);
        assertEq(nft, address(identity), "plain id names the identity agent");
        (nft,) = reputation.nftOf(reputation.refOf(address(collection), tokenId));
        assertEq(nft, address(collection));
    }

    function test_onlyRecordersRecord() public {
        vm.expectRevert(AgentReputationRegistry.NotSettlementRecorder.selector);
        reputation.recordSettlementForNFT(address(collection), tokenId, outsider, SID, PRICE);
    }
}
