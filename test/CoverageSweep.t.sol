// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentRoyaltyVault.sol";
import "../src/AgentRoyaltySplitter.sol";
import "../src/AgentRoyaltySplitterFactory.sol";
import "../src/AgentLinkedAccountRegistry.sol";
import "../src/AgentReputationRegistry.sol";
import "../src/AgentCollectionRenderer.sol";
import "../src/AgentCollectionFactory.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentTBARegistry.sol";

/**
 * @title  CoverageSweepTest
 * @notice Single-file sweep covering small uncovered branches across many
 *         contracts: view-getters, factory enumeration, pause/unpause,
 *         setIdentityRegistry, revokeFeedback, getTagScore zero-branch,
 *         getCollectionByAddress fallback, AgentTBARegistry catch-on-bad-token,
 *         AgentRoyaltyVault.pendingSplit math, AgentCollectionRenderer
 *         buildSequentialURI helper.
 */
contract CoverageSweepTest is Test {
    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob   = makeAddr("bob");

    AgentIdentityRegistry public identityRegistry;
    AgentLinkedAccountRegistry public linked;
    AgentReputationRegistry public reputation;
    AgentTBARegistry public tba;

    function setUp() public {
        // Identity registry
        AgentIdentityRegistry idImpl = new AgentIdentityRegistry();
        ERC1967Proxy idProxy = new ERC1967Proxy(
            address(idImpl), abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identityRegistry = AgentIdentityRegistry(address(idProxy));

        // Linked account registry
        AgentLinkedAccountRegistry linkedImpl = new AgentLinkedAccountRegistry();
        ERC1967Proxy linkedProxy = new ERC1967Proxy(
            address(linkedImpl), abi.encodeCall(AgentLinkedAccountRegistry.initialize, (address(identityRegistry)))
        );
        linked = AgentLinkedAccountRegistry(address(linkedProxy));

        // Reputation registry
        AgentReputationRegistry repImpl = new AgentReputationRegistry();
        ERC1967Proxy repProxy = new ERC1967Proxy(
            address(repImpl), abi.encodeCall(AgentReputationRegistry.initialize, (address(identityRegistry)))
        );
        reputation = AgentReputationRegistry(address(repProxy));

        // TBA registry
        tba = new AgentTBARegistry(address(identityRegistry), makeAddr("entrypoint"));
    }

    // ─── AgentLinkedAccountRegistry: pause / setIdentityRegistry / linkedAccountCount

    function test_linked_pause_unpause_byOwner() public {
        linked.pause();
        assertTrue(linked.paused());
        linked.unpause();
        assertFalse(linked.paused());
    }

    function test_linked_pause_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        linked.pause();
    }

    function test_linked_setIdentityRegistry_byOwner() public {
        AgentIdentityRegistry newImpl = new AgentIdentityRegistry();
        linked.setIdentityRegistry(address(newImpl));
        assertEq(address(linked.identityRegistry()), address(newImpl));
    }

    function test_linked_setIdentityRegistry_zeroReverts() public {
        vm.expectRevert(AgentLinkedAccountRegistry.ZeroAddress.selector);
        linked.setIdentityRegistry(address(0));
    }

    function test_linked_setIdentityRegistry_nonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        linked.setIdentityRegistry(address(0xdead));
    }

    function test_linked_linkedAccountCount_zeroByDefault() public {
        vm.prank(alice);
        uint256 agentId = identityRegistry.registerAgent("A", "ipfs://m", 500, address(0));
        assertEq(linked.linkedAccountCount(agentId), 0);
    }

    // ─── AgentReputationRegistry: getTagScore zero-branch + revokeFeedback

    function test_reputation_getTagScore_zeroForUnknownTag() public {
        vm.prank(alice);
        uint256 agentId = identityRegistry.registerAgent("A", "ipfs://m", 500, address(0));

        (int256 avg, uint256 count) = reputation.getTagScore(agentId, "unknown");
        assertEq(avg, 0);
        assertEq(count, 0);
    }

    function test_reputation_revokeFeedback_revertsWhenNoFeedback() public {
        vm.prank(alice);
        uint256 agentId = identityRegistry.registerAgent("A", "ipfs://m", 500, address(0));
        // Caller is alice but no feedback exists from her.
        vm.prank(alice);
        vm.expectRevert(bytes("No feedback to revoke"));
        reputation.revokeFeedback(agentId);
    }

    // ─── AgentTBARegistry: createAccount on invalid token reverts via catch

    function test_tba_createAccount_invalidTokenReverts() public {
        vm.expectRevert(AgentTBARegistry.InvalidToken.selector);
        tba.createAccount(999_999, bytes32(0));
    }

    function test_tba_account_returnsDeterministic() public {
        vm.prank(alice);
        uint256 agentId = identityRegistry.registerAgent("A", "ipfs://m", 500, address(0));
        address a = tba.account(address(identityRegistry), agentId, bytes32(0));
        address b = tba.account(address(identityRegistry), agentId, bytes32(0));
        assertEq(a, b, "deterministic per (token, salt, chainid)");
    }

    function test_tba_isAccountDeployed_falseUntilCreate() public {
        vm.prank(alice);
        uint256 agentId = identityRegistry.registerAgent("A", "ipfs://m", 500, address(0));
        assertFalse(tba.isAccountDeployed(address(identityRegistry), agentId, bytes32(0)));

        vm.prank(alice);
        tba.createAccount(agentId, bytes32(0));
        assertTrue(tba.isAccountDeployed(address(identityRegistry), agentId, bytes32(0)));
    }

    function test_tba_createAccountLegacy_pathWorks() public {
        vm.prank(alice);
        uint256 agentId = identityRegistry.registerAgent("A", "ipfs://m", 500, address(0));
        vm.prank(alice);
        address acct = tba.createAccountLegacy(address(identityRegistry), agentId, bytes32("legacy-salt"));
        assertTrue(acct != address(0));
    }

    function test_tba_createAccountLegacy_revertsForWrongRegistry() public {
        vm.expectRevert(bytes("Must use linked registry"));
        tba.createAccountLegacy(makeAddr("other"), 1, bytes32(0));
    }

    // ─── AgentCollectionRenderer.buildSequentialURI ──────────────────────

    function test_collectionRenderer_buildSequentialURI() public pure {
        string memory uri = AgentCollectionRenderer.buildSequentialURI("ipfs://base/", 7);
        assertEq(uri, "ipfs://base/7.json");
    }

    // ─── AgentCollectionFactory.getCollectionByAddress: not-found path ───

    function test_collectionFactory_getCollectionByAddress_revertsForUnknown() public {
        AgentCollectionImpl impl = new AgentCollectionImpl();
        AgentCollectionFactory factory = new AgentCollectionFactory(address(impl), makeAddr("fee"));
        vm.expectRevert(bytes("Collection not found"));
        factory.getCollectionByAddress(makeAddr("nope"));
    }

    function test_collectionFactory_getCollectionByAddress_returnsKnown() public {
        AgentCollectionImpl impl = new AgentCollectionImpl();
        AgentCollectionFactory factory = new AgentCollectionFactory(address(impl), makeAddr("fee"));
        vm.prank(alice);
        (uint256 cid, address addr) = factory.createCollection("Test", "T", 100, 500, 500, "");
        AgentCollectionFactory.CollectionInfo memory info = factory.getCollectionByAddress(addr);
        assertEq(info.contractAddress, addr);
        assertEq(info.creator, alice);
        cid;
    }

    // ─── AgentRoyaltySplitterFactory enumeration + AgentRoyaltySplitter views

    function test_royaltySplitterFactory_enumerationsEmpty() public {
        AgentRoyaltySplitterFactory factory = new AgentRoyaltySplitterFactory();
        assertEq(factory.totalSplitters(), 0);
        assertEq(factory.allSplitters().length, 0);
        assertEq(factory.splittersByDeployer(alice).length, 0);
    }

    function test_royaltySplitterFactory_deploysAndEnumerates() public {
        AgentRoyaltySplitterFactory factory = new AgentRoyaltySplitterFactory();
        address[] memory payeesArr = new address[](2);
        payeesArr[0] = alice;
        payeesArr[1] = bob;
        uint256[] memory shares = new uint256[](2);
        shares[0] = 6000;
        shares[1] = 4000;

        vm.prank(alice);
        address splitter = factory.deploySplitter(payeesArr, shares);

        assertEq(factory.totalSplitters(), 1);
        assertEq(factory.allSplitters()[0], splitter);
        assertEq(factory.splittersByDeployer(alice).length, 1);
        assertEq(factory.splittersByDeployer(alice)[0], splitter);

        // AgentRoyaltySplitter views
        AgentRoyaltySplitter rs = AgentRoyaltySplitter(payable(splitter));
        assertEq(rs.payeeCount(), 2);
        address[] memory ps = rs.payees();
        assertEq(ps.length, 2);
        assertEq(ps[0], alice);
        assertEq(ps[1], bob);
    }

    // ─── AgentRoyaltyVault.pendingSplit math ─────────────────────────────

    function test_royaltyVault_pendingSplit_zeroWhenNoBps() public {
        // Default secondarySystemFeeBps is 50; zero it out explicitly.
        identityRegistry.setSecondarySystemFeeBps(0);
        vm.prank(alice);
        uint256 agentId = identityRegistry.registerAgent("V0", "ipfs://m", 0, address(0));
        AgentRoyaltyVault vault = new AgentRoyaltyVault(address(identityRegistry), agentId);
        (uint256 cr, uint256 tr) = vault.pendingSplit(1 ether);
        assertEq(cr, 0);
        assertEq(tr, 0);
    }

    function test_royaltyVault_pendingSplit_splitsByBps() public {
        // creator royalty is capped at 5000 (50%), secondary system fee at 500 (5%).
        identityRegistry.setSecondarySystemFeeBps(500); // 5%
        identityRegistry.setSecondaryTreasury(address(0xfee));

        vm.prank(alice);
        uint256 agentId = identityRegistry.registerAgent("V1", "ipfs://m", 4500, address(0)); // 45%
        AgentRoyaltyVault vault = new AgentRoyaltyVault(address(identityRegistry), agentId);

        (uint256 cr, uint256 tr) = vault.pendingSplit(1 ether);
        // total = 4500 + 500 = 5000.
        // treasury = 1e18 * 500 / 5000 = 0.1 ether.
        // creator  = 1 ether - 0.1 ether = 0.9 ether.
        assertEq(tr, 0.1 ether);
        assertEq(cr, 0.9 ether);
        assertEq(cr + tr, 1 ether);
    }
}
