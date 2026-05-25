// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentContextRegistry.sol";

/// @title AgentSubaccountsTest
/// @notice Covers the 1:Many subaccount API on AgentIdentityRegistry plus
///         the on-chain enforcement path in AgentContextRegistry.
contract AgentSubaccountsTest is Test {
    AgentIdentityRegistry public identity;
    AgentContextRegistry  public context;

    address public deployer = address(0xD);
    address public alice    = address(0xA11CE);
    address public bob      = address(0xB0B);
    address public primaryTba = address(0xCAFE);
    address public sub1       = address(0xBEEF);
    address public sub2       = address(0xFEED);

    function setUp() public {
        vm.startPrank(deployer);

        AgentIdentityRegistry idImpl = new AgentIdentityRegistry();
        ERC1967Proxy idProxy = new ERC1967Proxy(
            address(idImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identity = AgentIdentityRegistry(address(idProxy));

        AgentContextRegistry ctxImpl = new AgentContextRegistry();
        ERC1967Proxy ctxProxy = new ERC1967Proxy(
            address(ctxImpl),
            abi.encodeCall(AgentContextRegistry.initialize, (address(identity)))
        );
        context = AgentContextRegistry(address(ctxProxy));

        vm.stopPrank();
    }

    function _mint(address who) internal returns (uint256 agentId) {
        vm.prank(who);
        agentId = identity.registerAgent("a", "ipfs://a", 1000, address(0));
    }

    // ---- subaccount lifecycle ----

    function test_RegisterSubaccount_BindsReverseLookup() public {
        uint256 id = _mint(alice);
        uint96 permPay = identity.PERM_PAY();

        vm.prank(alice);
        identity.registerSubaccount(id, sub1, bytes32(uint256(1)), permPay);

        (uint256 boundId, bool bound, bool isPrimary, uint96 perms, bool active) = identity.agentIdOf(sub1);
        assertEq(boundId, id);
        assertTrue(bound);
        assertFalse(isPrimary);
        assertEq(perms, permPay);
        assertTrue(active);
        assertEq(identity.subaccountCount(id), 1);
    }

    function test_RegisterSubaccount_RevertsWhenNotOwner() public {
        uint256 id = _mint(alice);
        uint96 permPay = identity.PERM_PAY();
        vm.prank(bob);
        vm.expectRevert(AgentIdentityRegistry.NotOwner.selector);
        identity.registerSubaccount(id, sub1, bytes32(0), permPay);
    }

    function test_RegisterSubaccount_RevertsWhenAlreadyBound() public {
        uint256 id1 = _mint(alice);
        uint256 id2 = _mint(alice);
        uint96 permPay = identity.PERM_PAY();

        vm.startPrank(alice);
        identity.registerSubaccount(id1, sub1, bytes32(0), permPay);
        vm.expectRevert(AgentIdentityRegistry.AlreadyBound.selector);
        identity.registerSubaccount(id2, sub1, bytes32(0), permPay);
        vm.stopPrank();
    }

    function test_PrimaryTBABinding_OnSetTBAAddress() public {
        uint256 id = _mint(alice);
        uint96 permAll = identity.PERM_ALL();
        uint96 permPay = identity.PERM_PAY();
        uint96 permCtx = identity.PERM_CONTEXT_WRITE();

        vm.prank(alice);
        identity.setTBAAddress(id, primaryTba);

        (uint256 boundId, bool bound, bool isPrimary, uint96 perms,) = identity.agentIdOf(primaryTba);
        assertEq(boundId, id);
        assertTrue(bound);
        assertTrue(isPrimary);
        assertEq(perms, permAll);
        assertTrue(identity.hasPermission(primaryTba, permPay));
        assertTrue(identity.hasPermission(primaryTba, permCtx));
    }

    function test_BindPrimaryTBA_NoDoubleBindAcrossAgents() public {
        uint256 id1 = _mint(alice);
        uint256 id2 = _mint(alice);

        vm.startPrank(alice);
        identity.setTBAAddress(id1, primaryTba);
        vm.expectRevert(AgentIdentityRegistry.AlreadyBound.selector);
        identity.setTBAAddress(id2, primaryTba);
        vm.stopPrank();
    }

    function test_UpdatePermissions_AndRevoke() public {
        uint96 permPay = identity.PERM_PAY();
        uint96 permRep = identity.PERM_REPUTATION();
        uint256 id = _mint(alice);

        vm.startPrank(alice);
        identity.registerSubaccount(id, sub1, bytes32(0), permPay);
        identity.updateSubaccountPermissions(id, sub1, permPay | permRep);
        vm.stopPrank();
        assertTrue(identity.hasPermission(sub1, permRep));

        vm.prank(alice);
        identity.revokeSubaccount(id, sub1);
        assertFalse(identity.hasPermission(sub1, permPay));
        (, bool bound,,,) = identity.agentIdOf(sub1);
        assertFalse(bound);

        // re-bind to a different agent
        uint256 id2 = _mint(bob);
        vm.prank(bob);
        identity.registerSubaccount(id2, sub1, bytes32(0), permPay);
        (uint256 boundId,,,,) = identity.agentIdOf(sub1);
        assertEq(boundId, id2);
    }

    function test_RequirePermission_RevertsForUnboundOrWrongAgent() public {
        uint96 permCtx = identity.PERM_CONTEXT_WRITE();
        uint96 permTreasury = identity.PERM_TREASURY();
        uint256 id = _mint(alice);

        vm.prank(alice);
        identity.registerSubaccount(id, sub1, bytes32(0), permCtx);

        vm.expectRevert(AgentIdentityRegistry.NotBound.selector);
        identity.requirePermission(sub1, permCtx, id + 999);

        vm.expectRevert(AgentIdentityRegistry.PermissionDenied.selector);
        identity.requirePermission(sub1, permTreasury, id);

        identity.requirePermission(sub1, permCtx, id);
    }

    function test_DeactivatedAgent_DropsPermissions() public {
        uint96 permPay = identity.PERM_PAY();
        uint256 id = _mint(alice);

        vm.startPrank(alice);
        identity.registerSubaccount(id, sub1, bytes32(0), permPay);
        identity.deactivateAgent(id);
        vm.stopPrank();

        assertFalse(identity.hasPermission(sub1, permPay));
    }

    // ---- on-chain enforcement: AgentContextRegistry ----

    function test_ContextRegistry_SubaccountWithPermissionCanWrite() public {
        uint96 permCtx = identity.PERM_CONTEXT_WRITE();
        uint256 id = _mint(alice);
        vm.prank(alice);
        identity.registerSubaccount(id, sub1, bytes32(0), permCtx);

        // sub1 (not the NFT owner) writes a file
        vm.prank(sub1);
        context.addFile(
            id,
            "skill-A",
            "ipfs://abc",
            keccak256("body"),
            0, // FILE_MD
            0, // CAT_SKILL
            "first skill"
        );
        assertEq(context.fileCount(id), 1);
    }

    function test_ContextRegistry_SubaccountWithoutPermissionReverts() public {
        uint96 permPay = identity.PERM_PAY();
        uint256 id = _mint(alice);
        vm.prank(alice);
        identity.registerSubaccount(id, sub2, bytes32(0), permPay);

        vm.prank(sub2);
        vm.expectRevert(AgentContextRegistry.NotOwner.selector);
        context.addFile(id, "x", "ipfs://x", keccak256("x"), 0, 0, "");
    }

    function test_ContextRegistry_OwnerStillWorks() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        context.addFile(id, "owner-file", "ipfs://o", keccak256("o"), 0, 0, "");
        assertEq(context.fileCount(id), 1);
    }
}
