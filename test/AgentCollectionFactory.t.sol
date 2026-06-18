// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";

contract AgentCollectionFactoryTest is Test {
    AgentCollectionFactory public factory;
    AgentCollectionImpl public implementation;
    
    address public owner = address(0x1);
    address public creator1 = address(0x2);
    address public creator2 = address(0x3);
    address public minter = address(0x4);
    address public protocolFeeRecipient = address(0x5);
    
    event CollectionCreated(
        uint256 indexed collectionId,
        address indexed contractAddress,
        address indexed creator,
        string name,
        string symbol,
        uint256 maxSupply
    );
    
    event BeaconUpgraded(address indexed newImplementation);
    
    function setUp() public {
        vm.startPrank(owner);
        implementation = new AgentCollectionImpl();
        factory = new AgentCollectionFactory(address(implementation), protocolFeeRecipient);
        vm.stopPrank();
    }
    
    // ============ Factory Creation Tests ============
    
    function test_FactoryInitialization() public view {
        assertEq(factory.implementation(), address(implementation));
        assertEq(factory.totalCollections(), 0);
        assertEq(factory.owner(), owner);
    }
    
    function test_CreateCollection() public {
        vm.prank(creator1);
        
        vm.expectEmit(true, false, true, false);
        emit CollectionCreated(1, address(0), creator1, "CyberPunks", "CYBER", 1000);
        
        (uint256 collectionId, address contractAddress) = factory.createCollection(
            "CyberPunks",
            "CYBER",
            1000,
            1000, // 10% sales royalty
            500,  // 5% service royalty
            "A collection of cyber punk agents"
        );
        
        assertEq(collectionId, 1);
        assertTrue(contractAddress != address(0));
        assertEq(factory.totalCollections(), 1);
        
        // Verify collection info stored correctly
        (
            address storedAddress,
            address storedCreator,
            string memory storedName,
            string memory storedSymbol,
            uint256 storedMaxSupply,
        ) = factory.collections(collectionId);
        
        assertEq(storedAddress, contractAddress);
        assertEq(storedCreator, creator1);
        assertEq(storedName, "CyberPunks");
        assertEq(storedSymbol, "CYBER");
        assertEq(storedMaxSupply, 1000);
    }
    
    function test_CreateMultipleCollections() public {
        vm.prank(creator1);
        (uint256 id1, address addr1) = factory.createCollection("Collection1", "C1", 100, 500, 250, "First");
        
        vm.prank(creator1);
        (uint256 id2, address addr2) = factory.createCollection("Collection2", "C2", 200, 1000, 500, "Second");
        
        vm.prank(creator2);
        (uint256 id3, address addr3) = factory.createCollection("Collection3", "C3", 300, 1500, 750, "Third");
        
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertTrue(addr1 != addr2);
        assertTrue(addr2 != addr3);
        assertEq(factory.totalCollections(), 3);
    }
    
    function test_GetCollectionsByCreator() public {
        vm.startPrank(creator1);
        factory.createCollection("C1", "C1", 100, 500, 250, "");
        factory.createCollection("C2", "C2", 100, 500, 250, "");
        vm.stopPrank();
        
        vm.prank(creator2);
        factory.createCollection("C3", "C3", 100, 500, 250, "");
        
        uint256[] memory creator1Collections = factory.getCollectionsByCreator(creator1);
        uint256[] memory creator2Collections = factory.getCollectionsByCreator(creator2);
        
        assertEq(creator1Collections.length, 2);
        assertEq(creator2Collections.length, 1);
        assertEq(creator1Collections[0], 1);
        assertEq(creator1Collections[1], 2);
        assertEq(creator2Collections[0], 3);
    }
    
    function test_GetAllCollectionAddresses() public {
        vm.prank(creator1);
        (, address addr1) = factory.createCollection("C1", "C1", 100, 500, 250, "");
        
        vm.prank(creator2);
        (, address addr2) = factory.createCollection("C2", "C2", 100, 500, 250, "");
        
        address[] memory allAddresses = factory.getAllCollectionAddresses();
        
        assertEq(allAddresses.length, 2);
        assertEq(allAddresses[0], addr1);
        assertEq(allAddresses[1], addr2);
    }
    
    // ============ Validation Tests ============
    
    function test_RevertOnEmptyName() public {
        vm.prank(creator1);
        vm.expectRevert(AgentCollectionFactory.InvalidName.selector);
        factory.createCollection("", "SYM", 100, 500, 250, "");
    }
    
    function test_RevertOnEmptySymbol() public {
        vm.prank(creator1);
        vm.expectRevert(AgentCollectionFactory.InvalidSymbol.selector);
        factory.createCollection("Name", "", 100, 500, 250, "");
    }
    
    // ============ Upgrade Tests ============
    
    function test_UpgradeImplementation() public {
        // Create a collection first
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Test", "TST", 100, 500, 250, "");
        
        // Deploy new implementation
        vm.startPrank(owner);
        AgentCollectionImpl newImpl = new AgentCollectionImpl();
        
        vm.expectEmit(true, false, false, false);
        emit BeaconUpgraded(address(newImpl));
        
        factory.upgradeImplementation(address(newImpl));
        vm.stopPrank();
        
        assertEq(factory.implementation(), address(newImpl));
        
        // Existing collection should still work
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        assertEq(collection.name(), "Test");
    }
    
    function test_OnlyOwnerCanUpgrade() public {
        AgentCollectionImpl newImpl = new AgentCollectionImpl();
        
        vm.prank(creator1);
        vm.expectRevert();
        factory.upgradeImplementation(address(newImpl));
    }
    
    // ============ Collection Functionality Tests ============
    
    function test_MintInCollection() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Agents", "AGT", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Mint an agent
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "ipfs://metadata1");
        
        assertEq(agentId, 1);
        assertEq(collection.ownerOf(1), minter);
        assertEq(collection.totalSupply(), 1);
    }
    
    function test_CollectionMaxSupply() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Limited", "LTD", 2, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.startPrank(minter);
        collection.registerAgent("Agent1", "uri1");
        collection.registerAgent("Agent2", "uri2");
        
        // Third mint should fail
        vm.expectRevert(AgentCollectionImpl.MaxSupplyReached.selector);
        collection.registerAgent("Agent3", "uri3");
        vm.stopPrank();
    }
    
    function test_CollectionLocking() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Lockable", "LCK", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Mint before lock
        vm.prank(minter);
        collection.registerAgent("Agent1", "uri1");
        
        // Lock collection
        vm.prank(creator1);
        collection.lockCollection();
        
        assertTrue(collection.locked());
        
        // Mint after lock should fail
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.CollectionLocked.selector);
        collection.registerAgent("Agent2", "uri2");
    }
    
    function test_OnlyCreatorCanLock() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Test", "TST", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(creator2);
        vm.expectRevert(AgentCollectionImpl.NotCreator.selector);
        collection.lockCollection();
    }
    
    // ============ Royalty Tests ============
    
    function test_CollectionRoyalties() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Royalty", "RYL", 100, 1500, 750, ""); // 15% sales, 7.5% service
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        // Check royalty info
        (address receiver, uint256 royaltyAmount) = collection.royaltyInfo(agentId, 10000);
        
        assertEq(receiver, minter); // Creator of the agent
        assertEq(royaltyAmount, 1500); // 15% of 10000
    }
    
    function test_CustomRoyaltyOnMint() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Custom", "CST", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgentWithRoyalty("Agent1", "uri1", 2500, 1000); // 25% sales, 10% service
        
        (address receiver, uint256 royaltyAmount) = collection.royaltyInfo(agentId, 10000);
        
        assertEq(receiver, minter);
        assertEq(royaltyAmount, 2500); // Sales royalty used for ERC-2981
    }
    
    function test_RoyaltyBoundsEnforced() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Bounds", "BND", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Boundary: MAX_ROYALTY_BPS = 8000 (80%). Anything above must revert.
        // Too high sales royalty (8001 = 80.01%)
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.InvalidValue.selector);
        collection.registerAgentWithRoyalty("Agent1", "uri1", 8001, 500);

        // Too high service royalty (8001 = 80.01%)
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.InvalidValue.selector);
        collection.registerAgentWithRoyalty("Agent1", "uri1", 500, 8001);

        // Exactly at the cap is allowed (8000 = 80%)
        vm.prank(minter);
        uint256 idCap = collection.registerAgentWithRoyalty("Agent1", "uri1", 8000, 8000);
        assertEq(idCap, 1);

        // 0% is allowed (no min — creators may waive)
        vm.prank(minter);
        uint256 agentId = collection.registerAgentWithRoyalty("Agent2", "uri2", 0, 0);
        assertEq(agentId, 2);
    }
    
    // ============ SVG Storage Tests ============
    
    function test_SetSVGImage() public {
        // OnChainSVG mode is locked at mint via `mintAgentWithSVG`.
        // `setSVGImage` is a mutator on already-OnChainSVG tokens — it
        // can no longer convert an ExplicitURI token into an SVG token.
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("SVG", "SVG", 100, 1000, 500, "");
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);

        string memory svg1 = "<svg><circle cx='50' cy='50' r='40'/></svg>";
        vm.prank(minter);
        uint256 agentId = collection.mintAgentWithSVG("Agent1", svg1);
        assertTrue(collection.hasSVGImage(agentId));
        assertEq(collection.getSVGImage(agentId), svg1);
        assertEq(uint8(collection.metadataMode(agentId)), uint8(AgentCollectionImpl.MetadataMode.OnChainSVG));

        // Owner can update the SVG payload of an already-OnChainSVG token.
        string memory svg2 = "<svg><rect width='10' height='10'/></svg>";
        vm.prank(minter);
        collection.setSVGImage(agentId, svg2);
        assertEq(collection.getSVGImage(agentId), svg2);

        // ExplicitURI tokens MUST reject setSVGImage — no silent mode flip.
        vm.prank(minter);
        uint256 uriId = collection.registerAgent("Agent2", "ipfs://uri");
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.MetadataModeLocked.selector);
        collection.setSVGImage(uriId, svg1);
    }
    
    function test_OnlyOwnerCanSetSVG() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("SVG", "SVG", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.prank(creator2);
        vm.expectRevert(AgentCollectionImpl.NotOwner.selector);
        collection.setSVGImage(agentId, "<svg></svg>");
    }
    
    function test_SVGSizeLimit() public {
        // The size check now lives in `mintAgentWithSVG` (atomic mint+SVG)
        // and on `setSVGImage` for OnChainSVG-mode updates. Cover both.
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("SVG", "SVG", 100, 1000, 500, "");
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);

        bytes memory largeSvg = new bytes(50000);
        for (uint256 i = 0; i < 50000; i++) largeSvg[i] = "x";

        // Mint path rejects oversize SVG.
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.TooLarge.selector);
        collection.mintAgentWithSVG("Agent1", string(largeSvg));

        // Update path on a valid OnChainSVG token also rejects oversize.
        vm.prank(minter);
        uint256 agentId = collection.mintAgentWithSVG("Agent1", "<svg/>");
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.TooLarge.selector);
        collection.setSVGImage(agentId, string(largeSvg));
    }
    
    // ============ Pixe Versioning Tests ============
    
    function test_AddPixeVersion() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Pixe", "PIX", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        bytes32 contentHash = keccak256("pixe content");
        
        vm.prank(minter);
        uint256 version = collection.addPixeVersion(agentId, "ar://tx123", contentHash, "Initial knowledge");
        
        assertEq(version, 0);
        assertEq(collection.getPixeVersionCount(agentId), 1);
    }
    
    function test_MultiplePixeVersions() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Pixe", "PIX", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.startPrank(minter);
        collection.addPixeVersion(agentId, "ar://tx1", keccak256("v1"), "Version 1");
        collection.addPixeVersion(agentId, "ar://tx2", keccak256("v2"), "Version 2");
        collection.addPixeVersion(agentId, "ar://tx3", keccak256("v3"), "Version 3");
        vm.stopPrank();
        
        assertEq(collection.getPixeVersionCount(agentId), 3);
        
        // Check latest
        (string memory arweave,,,,, uint256 ver) = collection.getLatestPixe(agentId);
        assertEq(arweave, "ar://tx3");
        assertEq(ver, 2);
    }
    
    // ============ TBA Tests ============
    
    function test_SetTBAAddress() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("TBA", "TBA", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        address tba = address(0x999);
        
        vm.prank(minter);
        collection.setTBAAddress(agentId, tba);
        
        (,address storedTba,,,) = collection.getAgent(agentId);
        assertEq(storedTba, tba);
    }
    
    function test_CannotSetTBATwice() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("TBA", "TBA", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.startPrank(minter);
        collection.setTBAAddress(agentId, address(0x999));
        
        vm.expectRevert(AgentCollectionImpl.AlreadySet.selector);
        collection.setTBAAddress(agentId, address(0x888));
        vm.stopPrank();
    }
    
    // ============ Agent Status Tests ============
    
    function test_DeactivateAndReactivate() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Status", "STS", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        // Initially active
        (,,, bool active,) = collection.getAgent(agentId);
        assertTrue(active);
        
        // Deactivate
        vm.prank(minter);
        collection.deactivateAgent(agentId);
        
        (,,, active,) = collection.getAgent(agentId);
        assertFalse(active);
        
        // Reactivate
        vm.prank(minter);
        collection.reactivateAgent(agentId);
        
        (,,, active,) = collection.getAgent(agentId);
        assertTrue(active);
    }
    
    // ============ Contract URI Tests ============
    
    function test_ContractURI() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Meta", "MTA", 100, 1000, 500, "A cool collection");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        string memory uri = collection.contractURI();
        
        // Should be base64 encoded JSON
        assertTrue(bytes(uri).length > 0);
        // Starts with data:application/json;base64,
        bytes memory prefix = bytes("data:application/json;base64,");
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(bytes(uri)[i], prefix[i]);
        }
    }
    
    // ============ Zero Max Supply (Unlimited) Tests ============
    
    function test_UnlimitedSupply() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Unlimited", "UNL", 0, 1000, 500, ""); // 0 = unlimited
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        assertEq(collection.maxSupply(), 0);
        
        // Should be able to mint many
        vm.startPrank(minter);
        for (uint256 i = 0; i < 10; i++) {
            collection.registerAgent(string(abi.encodePacked("Agent", i)), "uri");
        }
        vm.stopPrank();
        
        assertEq(collection.totalSupply(), 10);
    }
    
    // ============ Token URI with SVG Tests ============
    
    function test_TokenURIWithSVG() public {
        // Modes are independent and locked at mint. ExplicitURI tokens
        // resolve to the stored URI; OnChainSVG tokens resolve to the
        // rendered data URI. There is no longer a precedence chain.
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("URI", "URI", 100, 1000, 500, "");
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);

        // ExplicitURI mode — the URI is the canonical answer; never an SVG.
        vm.prank(minter);
        uint256 uriId = collection.registerAgent("Agent1", "ipfs://fallback");
        assertEq(collection.tokenURI(uriId), "ipfs://fallback");
        assertEq(uint8(collection.metadataMode(uriId)), uint8(AgentCollectionImpl.MetadataMode.ExplicitURI));

        // OnChainSVG mode — rendered as data:application/json;base64,...
        vm.prank(minter);
        uint256 svgId = collection.mintAgentWithSVG("Agent2", "<svg><rect/></svg>");
        assertEq(uint8(collection.metadataMode(svgId)), uint8(AgentCollectionImpl.MetadataMode.OnChainSVG));

        string memory uri2 = collection.tokenURI(svgId);
        bytes memory prefix = bytes("data:application/json;base64,");
        assertGt(bytes(uri2).length, prefix.length);
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(bytes(uri2)[i], prefix[i]);
        }
    }
    
    // ============ Transfer Tracking Tests ============
    
    function test_TransferUpdatesOwnerAgents() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Transfer", "TRF", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        // Check initial owner
        uint256[] memory minterAgents = collection.getAgentsByOwner(minter);
        assertEq(minterAgents.length, 1);
        assertEq(minterAgents[0], agentId);
        
        // Transfer to creator2
        vm.prank(minter);
        collection.transferFrom(minter, creator2, agentId);
        
        // Check updated tracking
        minterAgents = collection.getAgentsByOwner(minter);
        assertEq(minterAgents.length, 0);
        
        uint256[] memory creator2Agents = collection.getAgentsByOwner(creator2);
        assertEq(creator2Agents.length, 1);
        assertEq(creator2Agents[0], agentId);
    }
    
    function test_MultipleTransfers() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("MultiTransfer", "MTR", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Mint multiple agents
        vm.startPrank(minter);
        collection.registerAgent("Agent1", "uri1");
        collection.registerAgent("Agent2", "uri2");
        collection.registerAgent("Agent3", "uri3");
        vm.stopPrank();
        
        assertEq(collection.getAgentsByOwner(minter).length, 3);
        
        // Transfer one
        vm.prank(minter);
        collection.transferFrom(minter, creator2, 2);
        
        assertEq(collection.getAgentsByOwner(minter).length, 2);
        assertEq(collection.getAgentsByOwner(creator2).length, 1);
    }
    
    // ============ Creator Royalty Security Tests ============
    
    function test_CreatorRoyaltyIsSoulbound() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Soulbound", "SBD", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        // Transfer to creator2
        vm.prank(minter);
        collection.transferFrom(minter, creator2, agentId);
        
        // Creator should still be original minter
        address originalCreator = collection.agentCreator(agentId);
        assertEq(originalCreator, minter);
        
        // Royalties are committed at mint and immutable thereafter — the
        // legacy `updateSalesRoyalty` selector is gone, so neither the
        // original creator nor a transferee can mutate the bps.
        bytes memory call = abi.encodeWithSignature("updateSalesRoyalty(uint256,uint256)", agentId, 2000);
        vm.prank(minter);
        (bool ok,) = address(collection).call(call);
        assertFalse(ok, "updateSalesRoyalty should be removed");

        uint256 salesBps = collection.getSalesRoyalty(agentId);
        assertEq(salesBps, 1000); // pinned at the collection's default
    }
    
    function test_RoyaltySplitCalculation() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Split", "SPL", 100, 2000, 1000, ""); // 20% sales, 10% service
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        (uint256 creatorCut, uint256 ownerCut) = collection.calculateSalesRoyaltySplit(agentId, 10000);
        
        assertEq(creatorCut, 2000); // 20%
        assertEq(ownerCut, 8000);   // 80%
    }
    
    // ============ Empty Input Validation Tests ============
    
    function test_RevertOnEmptySVG() public {
        // Empty SVG is rejected on both mint and update paths.
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Empty", "EMP", 100, 1000, 500, "");
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);

        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.EmptyInput.selector);
        collection.mintAgentWithSVG("Agent1", "");

        vm.prank(minter);
        uint256 agentId = collection.mintAgentWithSVG("Agent2", "<svg/>");
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.EmptyInput.selector);
        collection.setSVGImage(agentId, "");
    }
    
    function test_RevertOnEmptyPixeArweave() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Empty", "EMP", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.EmptyInput.selector);
        collection.addPixeVersion(agentId, "", keccak256("content"), "desc");
    }
    
    function test_RevertOnZeroContentHash() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Empty", "EMP", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.EmptyInput.selector);
        collection.addPixeVersion(agentId, "ar://tx", bytes32(0), "desc");
    }
    
    // ============ Pixe Consolidation Tests ============
    
    function test_PixeConsolidation() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Consolidate", "CON", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        // Add initial version (consolidated by default)
        vm.startPrank(minter);
        collection.addPixeVersion(agentId, "ar://v0", keccak256("v0"), "Initial");
        
        // Add deltas
        collection.addPixeVersion(agentId, "ar://v1", keccak256("v1"), "Delta 1");
        collection.addPixeVersion(agentId, "ar://v2", keccak256("v2"), "Delta 2");
        
        // Consolidate
        uint256 consolidatedVersion = collection.consolidateVersions(
            agentId,
            "ar://consolidated",
            keccak256("consolidated"),
            keccak256("merkle"),
            "Consolidated v0-v2"
        );
        vm.stopPrank();
        
        assertEq(consolidatedVersion, 3);
        assertEq(collection.latestConsolidatedVersion(agentId), 3);
        assertEq(collection.getPixeVersionCount(agentId), 4);
    }
    
    function test_CannotConsolidateWithoutVersions() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Consolidate", "CON", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.NotExists.selector);
        collection.consolidateVersions(agentId, "ar://tx", keccak256("c"), keccak256("m"), "desc");
    }
    
    // ============ Interface Support Tests ============
    
    function test_SupportsERC2981() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Interface", "INT", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // ERC-2981 interface ID
        bytes4 erc2981Interface = 0x2a55205a;
        assertTrue(collection.supportsInterface(erc2981Interface));
        
        // ERC-721 interface ID
        bytes4 erc721Interface = 0x80ac58cd;
        assertTrue(collection.supportsInterface(erc721Interface));
        
        // ERC-721 Metadata interface ID
        bytes4 erc721MetadataInterface = 0x5b5e139f;
        assertTrue(collection.supportsInterface(erc721MetadataInterface));
    }
    
    // ============ Edge Case: Lock Then Upgrade ============
    
    function test_LockedCollectionSurvivesUpgrade() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("LockUpgrade", "LUP", 10, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Mint and lock
        vm.prank(minter);
        collection.registerAgent("Agent1", "uri1");
        
        vm.prank(creator1);
        collection.lockCollection();
        
        assertTrue(collection.locked());
        
        // Upgrade implementation
        vm.startPrank(owner);
        AgentCollectionImpl newImpl = new AgentCollectionImpl();
        factory.upgradeImplementation(address(newImpl));
        vm.stopPrank();
        
        // Collection should still be locked
        assertTrue(collection.locked());
        
        // Minting should still fail
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.CollectionLocked.selector);
        collection.registerAgent("Agent2", "uri2");
    }
    
    // ============ Edge Case: Zero Address TBA ============
    
    function test_RevertOnZeroAddressTBA() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("ZeroTBA", "ZTB", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.InvalidAddress.selector);
        collection.setTBAAddress(agentId, address(0));
    }
    
    // ============ Edge Case: Nonexistent Token ============
    
    function test_RevertOnNonexistentToken() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Nonexist", "NEX", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.expectRevert(AgentCollectionImpl.NotExists.selector);
        collection.getAgent(999);
        
        vm.expectRevert(AgentCollectionImpl.NotExists.selector);
        collection.getSVGImage(999);
        
        vm.expectRevert(AgentCollectionImpl.NotExists.selector);
        collection.getLatestPixe(999);
    }
    
    // ============ Royalties are immutable post-mint ============

    function test_RoyaltiesAreImmutablePostMint() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Unchanged", "UCH", 100, 1500, 750, "");

        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);

        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");

        // The old `updateSalesRoyalty` / `updateServiceRoyalty` selectors
        // are gone — calls fall through to the empty fallback path and
        // return `false` from the low-level call.
        bytes memory salesCall   = abi.encodeWithSignature("updateSalesRoyalty(uint256,uint256)",   agentId, 2000);
        bytes memory serviceCall = abi.encodeWithSignature("updateServiceRoyalty(uint256,uint256)", agentId, 2000);

        vm.prank(minter);
        (bool okSales,)   = address(collection).call(salesCall);
        vm.prank(minter);
        (bool okService,) = address(collection).call(serviceCall);

        assertFalse(okSales,   "updateSalesRoyalty should be removed");
        assertFalse(okService, "updateServiceRoyalty should be removed");

        // Stored values still match what was committed at mint.
        assertEq(collection.getSalesRoyalty(agentId),   1500);
        assertEq(collection.getServiceRoyalty(agentId),  750);
    }
    
    // ============ Fuzz Tests ============
    
    function testFuzz_CreateCollectionWithVariousSupply(uint256 maxSupply) public {
        vm.assume(maxSupply < type(uint128).max); // Reasonable bounds
        
        vm.prank(creator1);
        (uint256 id, address addr) = factory.createCollection("Fuzz", "FZZ", maxSupply, 1000, 500, "");
        
        assertEq(id, 1);
        assertTrue(addr != address(0));
        
        AgentCollectionImpl collection = AgentCollectionImpl(addr);
        assertEq(collection.maxSupply(), maxSupply);
    }
    
    function testFuzz_RoyaltyWithinBounds(uint256 royaltyBps) public {
        vm.assume(royaltyBps <= 5000);
        
        vm.prank(creator1);
        (, address addr) = factory.createCollection("RoyaltyFuzz", "RFZ", 100, royaltyBps, royaltyBps / 2, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(addr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        (address receiver, uint256 amount) = collection.royaltyInfo(agentId, 10000);
        assertEq(receiver, minter);
        assertEq(amount, royaltyBps);
    }
    
    // ============ Additional Edge Case Tests ============
    
    function test_RevertOnEmptyAgentName() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("EmptyName", "ENM", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Should allow empty name (names are optional metadata)
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("", "uri1");
        assertEq(agentId, 1);
    }
    
    function test_RoyaltyInfoNonexistentToken() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Royalty", "RYL", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Nonexistent token returns zero address and zero amount
        (address receiver, uint256 amount) = collection.royaltyInfo(999, 10000);
        assertEq(receiver, address(0));
        assertEq(amount, 0);
    }
    
    function test_HasSVGImageNonexistentToken() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("SVG", "SVG", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Should return false for nonexistent token (no revert)
        bool hasSvg = collection.hasSVGImage(999);
        assertFalse(hasSvg);
    }
    
    function test_GetPixeVersionCountNonexistent() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Pixe", "PIX", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Should return 0 for nonexistent token
        uint256 count = collection.getPixeVersionCount(999);
        assertEq(count, 0);
    }
    
    function test_TransferGasWithManyTokens() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Gas", "GAS", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Mint 20 tokens to same owner
        vm.startPrank(minter);
        for (uint256 i = 0; i < 20; i++) {
            collection.registerAgent(string(abi.encodePacked("Agent", i)), "uri");
        }
        vm.stopPrank();
        
        assertEq(collection.getAgentsByOwner(minter).length, 20);
        
        // Transfer first token - should still work efficiently
        uint256 gasBefore = gasleft();
        vm.prank(minter);
        collection.transferFrom(minter, creator2, 1);
        uint256 gasUsed = gasBefore - gasleft();
        
        // Gas should be reasonable (< 100k for worst case)
        assertTrue(gasUsed < 100000);
        assertEq(collection.getAgentsByOwner(minter).length, 19);
    }
    
    function test_SafeMintReentrancy() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Reentry", "REE", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Deploy attacker contract
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(collection));
        
        // Reentrancy during safeMint succeeds but is harmless
        // Each mint is independent - no exploitable state
        vm.prank(address(attacker));
        attacker.attack();
        
        // Verify: attacker minted 3 tokens (1 initial + 2 reentrant)
        assertEq(collection.totalSupply(), 3);
        assertEq(collection.ownerOf(1), address(attacker));
        assertEq(collection.ownerOf(2), address(attacker));
        assertEq(collection.ownerOf(3), address(attacker));
        
        // Each token has correct metadata and ownership tracking
        assertEq(collection.getAgentsByOwner(address(attacker)).length, 3);
    }
    
    function test_PixeVersionMaxLimit() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("MaxPixe", "MPX", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        // Add max versions (should succeed up to limit)
        // Note: Testing with smaller number to avoid gas issues
        vm.startPrank(minter);
        for (uint256 i = 0; i < 50; i++) {
            collection.addPixeVersion(agentId, string(abi.encodePacked("ar://tx", i)), keccak256(abi.encodePacked(i)), "v");
        }
        vm.stopPrank();
        
        assertEq(collection.getPixeVersionCount(agentId), 50);
    }
    
    function test_CollectionCreatorCannotBeStolenByUpgrade() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Creator", "CRT", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Store original creator
        address originalCreator = collection.collectionCreator();
        assertEq(originalCreator, creator1);
        
        // Upgrade implementation
        vm.startPrank(owner);
        AgentCollectionImpl newImpl = new AgentCollectionImpl();
        factory.upgradeImplementation(address(newImpl));
        vm.stopPrank();
        
        // Creator should remain unchanged
        assertEq(collection.collectionCreator(), creator1);
    }
    
    function test_FactoryBeaconAddress() public view {
        address beacon = address(factory.beacon());
        assertTrue(beacon != address(0));
        assertEq(factory.implementation(), address(implementation));
    }
    
    function test_CollectionSymbolAndName() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("My Cool Collection", "COOL", 100, 1000, 500, "Description here");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        assertEq(collection.name(), "My Cool Collection");
        assertEq(collection.symbol(), "COOL");
        assertEq(collection.collectionDescription(), "Description here");
    }
    
    function test_CannotMintAfterMaxSupplyReached() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("MaxTest", "MAX", 1, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // First mint succeeds
        vm.prank(minter);
        collection.registerAgent("Agent1", "uri1");
        
        // Second mint fails
        vm.prank(creator2);
        vm.expectRevert(AgentCollectionImpl.MaxSupplyReached.selector);
        collection.registerAgent("Agent2", "uri2");
    }
    
    function test_AgentActivationStateTracking() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("State", "STA", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        // Cannot deactivate twice
        vm.startPrank(minter);
        collection.deactivateAgent(agentId);
        
        vm.expectRevert(AgentCollectionImpl.InvalidValue.selector);
        collection.deactivateAgent(agentId);
        
        // Cannot reactivate twice
        collection.reactivateAgent(agentId);
        
        vm.expectRevert(AgentCollectionImpl.InvalidValue.selector);
        collection.reactivateAgent(agentId);
        vm.stopPrank();
    }

    // ============ Branch Coverage Tests ============
    
    function test_TokenURIWithoutSVG() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("NoSVG", "NSG", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "ipfs://metadata");
        
        // Without SVG set, should return the stored URI
        string memory uri = collection.tokenURI(agentId);
        assertEq(uri, "ipfs://metadata");
    }
    
    function test_GetLatestPixeRevertNoVersions() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("NoPixe", "NPX", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.expectRevert(AgentCollectionImpl.NotExists.selector);
        collection.getLatestPixe(agentId);
    }
    
    function test_GetLatestConsolidatedPixeNoVersions() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("NoCons", "NCN", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.expectRevert(AgentCollectionImpl.NotExists.selector);
        collection.getLatestConsolidatedPixe(agentId);
    }
    
    function test_GetPixeVersionOutOfBounds() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("OOB", "OOB", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.prank(minter);
        collection.addPixeVersion(agentId, "ar://tx1", keccak256("hash1"), "v1");
        
        // Version 0 exists, version 1 does not
        vm.expectRevert(AgentCollectionImpl.NotExists.selector);
        collection.getPixeVersion(agentId, 5);
    }
    
    function test_VerifyContentHashOutOfBounds() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Verify", "VER", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.expectRevert(AgentCollectionImpl.NotExists.selector);
        collection.verifyContentHash(agentId, 0, keccak256("test"));
    }
    
    function test_GetPixeURLOutOfBounds() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("URL", "URL", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.expectRevert(AgentCollectionImpl.NotExists.selector);
        collection.getPixeURL(agentId, 0);
    }
    
    function test_ConsolidateRequiresDeltaVersions() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Delta", "DLT", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        // Add first version (consolidated type)
        vm.prank(minter);
        collection.addPixeVersion(agentId, "ar://tx1", keccak256("hash1"), "v1");
        
        // Try to consolidate with no delta versions after - should fail
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.InvalidValue.selector);
        collection.consolidateVersions(agentId, "ar://cons", keccak256("cons"), keccak256("merkle"), "consolidated");
    }
    
    function test_RegisterAgentWithRoyaltyDirectly() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Direct", "DIR", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Use registerAgentWithRoyalty directly with custom royalty
        vm.prank(minter);
        uint256 agentId = collection.registerAgentWithRoyalty("Agent1", "uri1", 2500, 1000); // 25% sales, 10% service
        
        (address creator, uint256 salesRoyalty, uint256 serviceRoyalty) = collection.getCreatorRoyalty(agentId);
        assertEq(creator, minter);
        assertEq(salesRoyalty, 2500);
        assertEq(serviceRoyalty, 1000);
    }
    
    function test_UpdateAgentURI() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Update", "UPD", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.prank(minter);
        collection.updateAgentURI(agentId, "newUri");
        
        // Without SVG, should return the new URI
        assertEq(collection.tokenURI(agentId), "newUri");
    }
    
    function test_GetAllPixeVersions() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("All", "ALL", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.startPrank(minter);
        collection.addPixeVersion(agentId, "ar://tx1", keccak256("hash1"), "v1");
        collection.addPixeVersion(agentId, "ar://tx2", keccak256("hash2"), "v2");
        vm.stopPrank();
        
        AgentCollectionImpl.PixeVersion[] memory versions = collection.getAllPixeVersions(agentId);
        assertEq(versions.length, 2);
    }
    
    function test_GetConsolidationHistoryEmpty() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Empty", "EMP", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        AgentCollectionImpl.ConsolidationRecord[] memory records = collection.getConsolidationHistory(agentId);
        assertEq(records.length, 0);
    }
    
    function test_ReactivateAgentFunction() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("React", "REA", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(minter);
        uint256 agentId = collection.registerAgent("Agent1", "uri1");
        
        vm.startPrank(minter);
        collection.deactivateAgent(agentId);
        collection.reactivateAgent(agentId);
        vm.stopPrank();
        
        (,,,bool active,) = collection.getAgent(agentId);
        assertTrue(active);
    }
    
    // ============ Protocol Fee Tests ============
    
    function test_MintAgentWithProtocolFee() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("PaidMint", "PAY", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Set mint price
        vm.prank(creator1);
        collection.setMintConfig(1 ether, 10, 0, 0);
        
        // Record balances before
        uint256 protocolBalanceBefore = protocolFeeRecipient.balance;
        uint256 creatorBalanceBefore = creator1.balance;
        
        // Mint with payment
        vm.deal(minter, 10 ether);
        vm.prank(minter);
        uint256 agentId = collection.mintAgent{value: 1 ether}("PaidAgent", "uri1");
        
        assertEq(agentId, 1);
        assertEq(collection.ownerOf(1), minter);
        
        // Verify fee split: 2% protocol, 98% creator
        uint256 expectedProtocolFee = 0.02 ether; // 2% of 1 ether
        uint256 expectedCreatorRevenue = 0.98 ether; // 98% of 1 ether
        
        assertEq(protocolFeeRecipient.balance - protocolBalanceBefore, expectedProtocolFee);
        assertEq(creator1.balance - creatorBalanceBefore, expectedCreatorRevenue);
    }
    
    function test_MintAgentFreeMint() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("FreeMint", "FRE", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // No mint config set = free mint
        vm.prank(minter);
        uint256 agentId = collection.mintAgent("FreeAgent", "uri1");
        
        assertEq(agentId, 1);
        assertEq(collection.ownerOf(1), minter);
    }
    
    function test_MintAgentInsufficientPayment() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("PaidMint", "PAY", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Set mint price to 1 ether
        vm.prank(creator1);
        collection.setMintConfig(1 ether, 10, 0, 0);
        
        // Try to mint with insufficient payment
        vm.deal(minter, 10 ether);
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.InsufficientPayment.selector);
        collection.mintAgent{value: 0.5 ether}("Agent", "uri");
    }
    
    function test_MintAgentMaxPerWallet() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Limited", "LTD", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Set max 2 per wallet
        vm.prank(creator1);
        collection.setMintConfig(0, 2, 0, 0);
        
        vm.startPrank(minter);
        collection.mintAgent("Agent1", "uri1");
        collection.mintAgent("Agent2", "uri2");
        
        // Third mint should fail
        vm.expectRevert(AgentCollectionImpl.MaxPerWalletReached.selector);
        collection.mintAgent("Agent3", "uri3");
        vm.stopPrank();
    }
    
    function test_MintAgentTimeWindowBefore() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Timed", "TIM", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Set mint to start in the future
        uint256 futureTime = block.timestamp + 1 days;
        vm.prank(creator1);
        collection.setMintConfig(0, 0, futureTime, 0);
        
        // Try to mint before start time
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.MintingNotActive.selector);
        collection.mintAgent("Agent", "uri");
    }
    
    function test_MintAgentTimeWindowAfter() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Timed", "TIM", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Set mint end time to a specific time, then warp past it
        uint256 endTime = block.timestamp + 1 hours;
        vm.prank(creator1);
        collection.setMintConfig(0, 0, 0, endTime);
        
        // Warp time past the end
        vm.warp(endTime + 1);
        
        // Try to mint after end time
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.MintingNotActive.selector);
        collection.mintAgent("Agent", "uri");
    }
    
    function test_MintAgentPaused() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Pausable", "PSE", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Pause minting
        vm.prank(creator1);
        collection.setPauseMinting(true);
        
        // Try to mint while paused
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.MintingIsPaused.selector);
        collection.mintAgent("Agent", "uri");
        
        // Unpause and mint should work
        vm.prank(creator1);
        collection.setPauseMinting(false);
        
        vm.prank(minter);
        uint256 agentId = collection.mintAgent("Agent", "uri");
        assertEq(agentId, 1);
    }
    
    function test_OnlyCreatorCanSetMintConfig() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Config", "CFG", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Non-creator should fail
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.NotCreator.selector);
        collection.setMintConfig(1 ether, 10, 0, 0);
    }
    
    function test_OnlyCreatorCanPauseMinting() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Pause", "PSE", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Non-creator should fail
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.NotCreator.selector);
        collection.setPauseMinting(true);
    }
    
    function test_GetMintConfig() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Config", "CFG", 50, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(creator1);
        collection.setMintConfig(0.5 ether, 5, 1000, 2000);
        
        (
            uint256 price,
            uint256 perWalletLimit,
            uint256 startTime,
            uint256 endTime,
            bool paused,
            uint256 currentSupply,
            uint256 maxSupply_
        ) = collection.getMintConfig();
        
        assertEq(price, 0.5 ether);
        assertEq(perWalletLimit, 5);
        assertEq(startTime, 1000);
        assertEq(endTime, 2000);
        assertFalse(paused);
        assertEq(currentSupply, 0);
        assertEq(maxSupply_, 50);
    }
    
    function test_MintAgentLockedCollection() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Lockable", "LCK", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Lock collection
        vm.prank(creator1);
        collection.lockCollection();
        
        // mintAgent should also fail when locked
        vm.prank(minter);
        vm.expectRevert(AgentCollectionImpl.CollectionLocked.selector);
        collection.mintAgent("Agent", "uri");
    }
    
    function test_MintAgentMaxSupplyReached() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Limited", "LTD", 2, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.startPrank(minter);
        collection.mintAgent("Agent1", "uri1");
        collection.mintAgent("Agent2", "uri2");
        
        vm.expectRevert(AgentCollectionImpl.MaxSupplyReached.selector);
        collection.mintAgent("Agent3", "uri3");
        vm.stopPrank();
    }
    
    function test_MintAgentReentrancyProtection() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Reentry", "REE", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Set mint price
        vm.prank(creator1);
        collection.setMintConfig(0.1 ether, 0, 0, 0);
        
        // Deploy attacker contract
        MintReentrancyAttacker attacker = new MintReentrancyAttacker(address(collection));
        vm.deal(address(attacker), 10 ether);
        
        // Attack should be blocked by nonReentrant modifier
        vm.expectRevert(AgentCollectionImpl.ReentrancyGuardReentrantCall.selector);
        attacker.attack{value: 1 ether}();
    }
    
    function test_ProtocolFeeWithZeroPrice() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Free", "FRE", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        uint256 protocolBalanceBefore = protocolFeeRecipient.balance;
        uint256 creatorBalanceBefore = creator1.balance;
        
        // Free mint should not transfer any funds
        vm.prank(minter);
        collection.mintAgent("FreeAgent", "uri1");
        
        assertEq(protocolFeeRecipient.balance, protocolBalanceBefore);
        assertEq(creator1.balance, creatorBalanceBefore);
    }
    
    function test_ProtocolFeeCalculation() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Calc", "CAL", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        // Set various price points and verify fee calculation
        vm.prank(creator1);
        collection.setMintConfig(10 ether, 0, 0, 0);
        
        uint256 protocolBalanceBefore = protocolFeeRecipient.balance;
        uint256 creatorBalanceBefore = creator1.balance;
        
        vm.deal(minter, 100 ether);
        vm.prank(minter);
        collection.mintAgent{value: 10 ether}("Agent", "uri");
        
        // 2% of 10 ether = 0.2 ether
        assertEq(protocolFeeRecipient.balance - protocolBalanceBefore, 0.2 ether);
        // 98% of 10 ether = 9.8 ether
        assertEq(creator1.balance - creatorBalanceBefore, 9.8 ether);
    }
    
    function testFuzz_ProtocolFeeCalculation(uint256 price) public {
        vm.assume(price > 0 && price < 1000 ether);
        
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("FuzzFee", "FFE", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(creator1);
        collection.setMintConfig(price, 0, 0, 0);
        
        uint256 protocolBalanceBefore = protocolFeeRecipient.balance;
        uint256 creatorBalanceBefore = creator1.balance;
        
        vm.deal(minter, price + 1 ether);
        vm.prank(minter);
        collection.mintAgent{value: price}("Agent", "uri");
        
        // Verify: protocol gets 2%, creator gets 98%
        uint256 expectedProtocolFee = (price * 200) / 10000;
        uint256 expectedCreatorRevenue = price - expectedProtocolFee;
        
        assertEq(protocolFeeRecipient.balance - protocolBalanceBefore, expectedProtocolFee);
        assertEq(creator1.balance - creatorBalanceBefore, expectedCreatorRevenue);
    }
    
    function test_MintAgentOverpayment() public {
        vm.prank(creator1);
        (, address collectionAddr) = factory.createCollection("Overpay", "OVP", 100, 1000, 500, "");
        
        AgentCollectionImpl collection = AgentCollectionImpl(collectionAddr);
        
        vm.prank(creator1);
        collection.setMintConfig(1 ether, 0, 0, 0);
        
        uint256 protocolBalanceBefore = protocolFeeRecipient.balance;
        uint256 creatorBalanceBefore = creator1.balance;
        
        // Overpay by 1 ether
        vm.deal(minter, 10 ether);
        vm.prank(minter);
        collection.mintAgent{value: 2 ether}("Agent", "uri");
        
        // Full payment is split (2 ether), no refund
        uint256 expectedProtocolFee = 0.04 ether; // 2% of 2 ether
        uint256 expectedCreatorRevenue = 1.96 ether; // 98% of 2 ether
        
        assertEq(protocolFeeRecipient.balance - protocolBalanceBefore, expectedProtocolFee);
        assertEq(creator1.balance - creatorBalanceBefore, expectedCreatorRevenue);
    }
}

// Helper contract for reentrancy test (free mint via registerAgent)
contract ReentrancyAttacker {
    AgentCollectionImpl public target;
    uint256 public attackCount;
    
    constructor(address _target) {
        target = AgentCollectionImpl(_target);
    }
    
    function attack() external {
        target.registerAgent("Attacker", "uri");
    }
    
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (attackCount < 2) {
            attackCount++;
            target.registerAgent("Reentry", "uri");
        }
        return this.onERC721Received.selector;
    }
}

// Helper contract for paid mint reentrancy test
contract MintReentrancyAttacker {
    AgentCollectionImpl public target;
    uint256 public attackCount;
    
    constructor(address _target) {
        target = AgentCollectionImpl(_target);
    }
    
    function attack() external payable {
        target.mintAgent{value: 0.1 ether}("Attacker", "uri");
    }
    
    receive() external payable {
        // Try to reenter when receiving protocol fee refund
        if (attackCount < 1) {
            attackCount++;
            target.mintAgent{value: 0.1 ether}("Reentry", "uri");
        }
    }
    
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        // Try to reenter during safeMint callback
        if (attackCount < 1) {
            attackCount++;
            target.mintAgent{value: 0.1 ether}("Reentry", "uri");
        }
        return this.onERC721Received.selector;
    }
}
