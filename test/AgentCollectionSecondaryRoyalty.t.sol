// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";
import "../src/AgentCollectionRoyaltyVault.sol";
import "../src/AgentRoyaltySplitter.sol";

/// Secondary sales of factory-collection agents: the ERC-2981 royalty is the
/// creator's sales royalty plus the protocol's secondary fee (0.5%), paid to a
/// per-token vault that splits the two — as identity-registry agents do.
contract AgentCollectionSecondaryRoyaltyTest is Test {
    AgentCollectionFactory public factory;
    AgentCollectionImpl    public collection;

    address public owner    = makeAddr("owner");
    address public creator  = makeAddr("creator");
    address public treasury = makeAddr("treasury");
    address public minter   = makeAddr("minter");

    uint256 constant SALES_BPS = 500;  // creator 5%
    uint256 constant SYSTEM_BPS = 50;  // protocol 0.5% (factory constant)

    function setUp() public {
        vm.startPrank(owner);
        factory = new AgentCollectionFactory(address(new AgentCollectionImpl()), treasury);
        vm.stopPrank();
        vm.prank(creator);
        (, address addr) = factory.createCollection("Royalty", "RY", 100, SALES_BPS, 1000, "");
        collection = AgentCollectionImpl(addr);
        vm.prank(creator);
        collection.setMintConfig(0, 0, 0, 0);
    }

    function _mint() internal returns (uint256 id) {
        vm.prank(minter);
        id = collection.mintAgent("A", "ipfs://meta");
    }

    function test_royaltyInfo_includesProtocolShare_toTheTokenVault() public {
        uint256 id = _mint();
        (address receiver, uint256 amount) = collection.royaltyInfo(id, 10 ether);
        assertEq(receiver, factory.collectionRoyaltyVault(address(collection), id));
        assertEq(amount, (10 ether * (SALES_BPS + SYSTEM_BPS)) / 10_000); // 0.55 ETH
        assertEq(SYSTEM_BPS, factory.PROTOCOL_SECONDARY_FEE_BPS());
    }

    function test_vault_splitsCreatorAndTreasury_paidBeforeDeployment() public {
        uint256 id = _mint();
        (address receiver, uint256 amount) = collection.royaltyInfo(id, 10 ether);
        // A marketplace pays the royalty before anyone deploys the vault.
        vm.deal(receiver, amount);

        address vault = factory.deployCollectionRoyaltyVault(address(collection), id);
        assertEq(vault, receiver);
        AgentCollectionRoyaltyVault(payable(vault)).release();

        uint256 toTreasury = (amount * SYSTEM_BPS) / (SALES_BPS + SYSTEM_BPS);
        assertEq(treasury.balance, toTreasury);                 // 0.05 ETH
        assertEq(minter.balance, amount - toTreasury);          // creator (the minter) 0.5 ETH
        assertEq(vault.balance, 0);
    }

    function test_vault_paysTheCollectionSplitter_whenItHasOne() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        address[] memory payees = new address[](2);
        payees[0] = a; payees[1] = b;
        uint256[] memory shares = new uint256[](2);
        shares[0] = 6000; shares[1] = 4000;
        vm.prank(creator);
        (, address addr, address splitter) = factory.createCollectionWithSplits("Split", "SP", 100, SALES_BPS, 1000, "", payees, shares);
        AgentCollectionImpl split = AgentCollectionImpl(addr);
        vm.prank(creator);
        split.setMintConfig(0, 0, 0, 0);
        vm.prank(minter);
        uint256 id = split.mintAgent("A", "ipfs://meta");

        (address receiver, uint256 amount) = split.royaltyInfo(id, 10 ether);
        vm.deal(receiver, amount);
        factory.deployCollectionRoyaltyVault(address(split), id);
        AgentCollectionRoyaltyVault(payable(receiver)).release();

        uint256 toTreasury = (amount * SYSTEM_BPS) / (SALES_BPS + SYSTEM_BPS);
        assertEq(treasury.balance, toTreasury);
        assertEq(splitter.balance, amount - toTreasury); // the creator share goes to the splitter
        assertEq(minter.balance, 0);
    }

    function test_deployVault_isIdempotent_andOnlyForThisFactorysCollections() public {
        uint256 id = _mint();
        address v1 = factory.deployCollectionRoyaltyVault(address(collection), id);
        address v2 = factory.deployCollectionRoyaltyVault(address(collection), id);
        assertEq(v1, v2);

        AgentCollectionFactory other = new AgentCollectionFactory(address(new AgentCollectionImpl()), treasury);
        vm.prank(creator);
        (, address foreign) = other.createCollection("Other", "OT", 10, SALES_BPS, 0, "");
        vm.expectRevert(AgentCollectionFactory.NotFactoryCollection.selector);
        factory.deployCollectionRoyaltyVault(foreign, 1);
    }

    function test_vaultAddressesDifferPerToken() public {
        uint256 a = _mint();
        uint256 b = _mint();
        assertTrue(factory.collectionRoyaltyVault(address(collection), a) != factory.collectionRoyaltyVault(address(collection), b));
    }
}
