// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentTBARegistry.sol";
import "../src/AgentAccount.sol";

contract V5Token is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// AgentAccount V5: sovereign mode (an account holding its own NFT, or in
/// an ownership cycle, is run by its sovereign key), nesting, recovery.
contract AgentAccountV5Test is Test {
    AgentIdentityRegistry registry;
    AgentTBARegistry tbas;
    AgentAccount a; // the agent that goes sovereign
    AgentAccount b; // the agent a comes to own
    uint256 idA;
    uint256 idB;
    V5Token usdc;
    address owner = makeAddr("owner");
    uint256 constant AGENT_PK = 0xA6E7; // the agent's runtime key
    uint256 constant NEXT_PK = 0xBEEF;
    address agentKey;
    address nextKey;
    address guardian = makeAddr("guardian");
    address stranger = makeAddr("stranger");

    function setUp() public {
        agentKey = vm.addr(AGENT_PK);
        nextKey = vm.addr(NEXT_PK);
        AgentIdentityRegistry impl = new AgentIdentityRegistry();
        registry = AgentIdentityRegistry(address(new ERC1967Proxy(address(impl), abi.encodeCall(AgentIdentityRegistry.initialize, ()))));
        tbas = new AgentTBARegistry(address(registry), address(0xEEEE));
        vm.startPrank(owner);
        idA = registry.registerAgent("A", "uri", 1000, address(0));
        idB = registry.registerAgent("B", "uri", 1000, address(0));
        a = AgentAccount(payable(tbas.createAccount(idA, bytes32(0))));
        b = AgentAccount(payable(tbas.createAccount(idB, bytes32(0))));
        vm.stopPrank();
        usdc = new V5Token();
        usdc.mint(address(a), 100e6);
        usdc.mint(address(b), 50e6);
    }

    function _goSovereign() internal {
        vm.startPrank(owner);
        a.setSovereignKey(agentKey);
        registry.safeTransferFrom(owner, address(a), idA);
        vm.stopPrank();
    }

    function _pay(AgentAccount acct, address from, address to, uint256 amt) internal {
        vm.prank(from);
        acct.execute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (to, amt)), 0);
    }

    // Going sovereign: the owner names the agent's key, then hands the NFT
    // to the agent's own account. The key now acts as owner; the former
    // owner can do nothing.
    function test_sovereignKeyRunsTheAccount() public {
        _goSovereign();
        assertEq(registry.ownerOf(idA), address(a));
        assertTrue(a.isSovereign());
        _pay(a, agentKey, agentKey, 5e6);
        assertEq(usdc.balanceOf(agentKey), 5e6);
        vm.prank(owner);
        vm.expectRevert("Invalid signer");
        a.execute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (owner, 1)), 0);
        vm.prank(stranger);
        vm.expectRevert("Invalid signer");
        a.execute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (stranger, 1)), 0);
        // It can mint session keys for its own runtime, as an owner could.
        address[] memory t = new address[](1);
        t[0] = address(usdc);
        bytes4[] memory sel;
        AgentAccount.TokenLimit[] memory lim;
        vm.prank(agentKey);
        a.createSessionKey(nextKey, t, sel, 0, 0, 0, uint48(block.timestamp + 1 days), lim);
    }

    // Without a sovereign key, receiving its own NFT would lock the account
    // for good (V4): a safe transfer is refused.
    function test_cannotGoSovereignWithoutAKey() public {
        vm.prank(owner);
        vm.expectRevert();
        registry.safeTransferFrom(owner, address(a), idA);
        assertEq(registry.ownerOf(idA), owner);
    }

    // While sovereign the key can be rotated but never cleared.
    function test_rotationAndNoClearing() public {
        _goSovereign();
        vm.prank(agentKey);
        vm.expectRevert(AgentAccount.SovereignKeyRequired.selector);
        a.setSovereignKey(address(0));
        vm.prank(agentKey);
        a.setSovereignKey(nextKey);
        vm.prank(agentKey);
        vm.expectRevert("Invalid signer");
        a.execute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (agentKey, 1)), 0);
        _pay(a, nextKey, nextKey, 1e6);
        assertEq(usdc.balanceOf(nextKey), 1e6);
    }

    // A lost key: the guardian proposes a new one, which takes effect after
    // the delay; until then the current key can veto.
    function test_guardianRecoveryAndVeto() public {
        vm.prank(owner);
        a.setGuardian(guardian, 7 days);
        _goSovereign();
        vm.prank(stranger);
        vm.expectRevert(AgentAccount.NotGuardian.selector);
        a.proposeRecovery(stranger);

        vm.prank(guardian);
        a.proposeRecovery(stranger);
        vm.prank(agentKey);
        a.cancelRecovery();
        vm.expectRevert(AgentAccount.NoRecovery.selector);
        a.completeRecovery();

        vm.prank(guardian);
        a.proposeRecovery(nextKey);
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(AgentAccount.RecoveryNotReady.selector);
        a.completeRecovery();
        vm.warp(block.timestamp + 1);
        a.completeRecovery();
        assertEq(a.sovereignKey(), nextKey);
        _pay(a, nextKey, nextKey, 1e6);
        // The guardian itself never acts as owner.
        vm.prank(guardian);
        vm.expectRevert("Invalid signer");
        a.execute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (guardian, 1)), 0);
    }

    function test_guardianDelayBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(AgentAccount.InvalidDelay.selector);
        a.setGuardian(guardian, 1 hours);
        vm.expectRevert(AgentAccount.InvalidDelay.selector);
        a.setGuardian(guardian, 91 days);
        vm.stopPrank();
    }

    // Recovery only exists for a sovereign account.
    function test_noRecoveryWhileOwned() public {
        vm.prank(owner);
        a.setGuardian(guardian, 1 days);
        vm.prank(guardian);
        vm.expectRevert(AgentAccount.SovereignKeyRequired.selector);
        a.proposeRecovery(nextKey);
    }

    // The agent can give itself back: moving its NFT out ends sovereignty,
    // and the key loses its power.
    function test_exitSovereignty() public {
        _goSovereign();
        vm.prank(agentKey);
        a.execute(address(registry), 0, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(a), owner, idA), 0);
        assertEq(registry.ownerOf(idA), owner);
        assertFalse(a.isSovereign());
        vm.prank(agentKey);
        vm.expectRevert("Invalid signer");
        a.execute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (agentKey, 1)), 0);
        _pay(a, owner, owner, 1e6);
    }

    // An agent owning another agent: A's account holds B's NFT, so B's
    // account answers to A's — and A, sovereign, runs both.
    function test_sovereignAgentRunsTheAgentItOwns() public {
        vm.prank(owner);
        registry.safeTransferFrom(owner, address(a), idB);
        assertEq(b.owner(), address(a));
        _goSovereign();
        bytes memory inner = abi.encodeCall(AgentAccount.execute, (address(usdc), 0, abi.encodeCall(IERC20.transfer, (agentKey, 7e6)), 0));
        vm.prank(agentKey);
        a.execute(address(b), 0, inner, 0);
        assertEq(usdc.balanceOf(agentKey), 7e6);
        // Nobody but A reaches B.
        vm.prank(agentKey);
        vm.expectRevert("Invalid signer");
        b.execute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (agentKey, 1)), 0);
    }

    // A cycle (A holds B's NFT, B holds A's) locked both under V4. V5 sees
    // the cycle: each account's sovereign key runs it.
    function test_ownershipCycleIsSovereign() public {
        vm.startPrank(owner);
        a.setSovereignKey(agentKey);
        b.setSovereignKey(nextKey);
        registry.safeTransferFrom(owner, address(a), idB);
        registry.safeTransferFrom(owner, address(b), idA);
        vm.stopPrank();
        assertTrue(a.isSovereign());
        assertTrue(b.isSovereign());
        _pay(a, agentKey, agentKey, 2e6);
        _pay(b, nextKey, nextKey, 3e6);
        // The other account's key doesn't cross over directly.
        vm.prank(nextKey);
        vm.expectRevert("Invalid signer");
        a.execute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (nextKey, 1)), 0);
    }

    // ERC-1271: a sovereign account's signer is its key; in a cycle the
    // check ends (bounded forwarding) instead of recursing until out of gas.
    function test_signaturesSovereignAndCycle() public {
        _goSovereign();
        bytes32 h = keccak256("hello");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AGENT_PK, MessageHashUtils.toEthSignedMessageHash(h));
        assertEq(a.isValidSignature(h, abi.encodePacked(r, s, v)), bytes4(0x1626ba7e));
        (v, r, s) = vm.sign(NEXT_PK, MessageHashUtils.toEthSignedMessageHash(h));
        assertEq(a.isValidSignature(h, abi.encodePacked(r, s, v)), bytes4(0xffffffff));

        // B, owned by sovereign A, accepts A's key: its check forwards to A.
        vm.prank(owner);
        registry.safeTransferFrom(owner, address(a), idB);
        (v, r, s) = vm.sign(AGENT_PK, MessageHashUtils.toEthSignedMessageHash(h));
        assertEq(b.isValidSignature(h, abi.encodePacked(r, s, v)), bytes4(0x1626ba7e));
    }

    function test_cycleSignatureCheckTerminates() public {
        vm.startPrank(owner);
        registry.safeTransferFrom(owner, address(b), idA); // A's NFT held by B (no keys: not via self)
        vm.stopPrank();
        // B's NFT held by A closes the cycle; neither has a sovereign key.
        vm.prank(owner);
        registry.transferFrom(owner, address(a), idB);
        bytes32 h = keccak256("x");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(AGENT_PK, MessageHashUtils.toEthSignedMessageHash(h));
        uint256 g = gasleft();
        assertEq(a.isValidSignature(h, abi.encodePacked(r, s, v)), bytes4(0xffffffff));
        assertLt(g - gasleft(), 1_000_000);
    }

    // A sovereign key set on an account that isn't sovereign has no power.
    function test_keyIsPowerlessUntilSovereign() public {
        vm.prank(owner);
        a.setSovereignKey(agentKey);
        vm.prank(agentKey);
        vm.expectRevert("Invalid signer");
        a.execute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (agentKey, 1)), 0);
    }

    function testFuzz_onlyTheSovereignKeyActs(address caller) public {
        vm.assume(caller != agentKey);
        _goSovereign();
        vm.prank(caller);
        vm.expectRevert("Invalid signer");
        a.execute(address(usdc), 0, abi.encodeCall(IERC20.transfer, (caller, 1)), 0);
        vm.prank(caller);
        vm.expectRevert("Only owner");
        a.setSovereignKey(caller);
    }
}
