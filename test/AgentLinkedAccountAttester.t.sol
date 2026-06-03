// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentLinkedAccountRegistry.sol";

/**
 * @dev Minimal reference attester. A real attester would verify a bridge
 *      message / VAA / Merkle proof in its public entry point before
 *      forwarding to the registry. Here we just expose `forward` so the
 *      tests can drive the registry's external-attester path with a
 *      contract caller (msg.sender must be a contract address that the
 *      registry has trusted).
 */
contract MockAttester {
    AgentLinkedAccountRegistry public immutable target;
    string public kind;

    constructor(address _target, string memory _kind) {
        target = AgentLinkedAccountRegistry(_target);
        kind = _kind;
    }

    function forward(
        uint256 agentId,
        uint256 chainId,
        bytes32 accountId,
        string calldata accountKind,
        string calldata label,
        uint96 permissions
    ) external returns (uint256) {
        // A real attester would verify a proof argument here. We assume
        // the caller (test) has already done the equivalent.
        return target.linkAccountAttested(
            agentId, chainId, accountId, accountKind, label, permissions
        );
    }
}

contract AgentLinkedAccountAttesterTest is Test {
    AgentIdentityRegistry      public identity;
    AgentLinkedAccountRegistry public links;

    address public deployer = address(0xD);
    address public alice    = address(0xA11CE);
    address public bob      = address(0xB0B);
    address public mallory  = address(0xBAD);

    MockAttester public wormhole;
    MockAttester public layerZero;

    uint256 public agentId;
    uint96  public PERM_PAYOUT;
    uint96  public PERM_PAY;

    function setUp() public {
        vm.startPrank(deployer);
        AgentIdentityRegistry idImpl = new AgentIdentityRegistry();
        identity = AgentIdentityRegistry(address(new ERC1967Proxy(
            address(idImpl), abi.encodeCall(AgentIdentityRegistry.initialize, ())
        )));

        AgentLinkedAccountRegistry laImpl = new AgentLinkedAccountRegistry();
        links = AgentLinkedAccountRegistry(address(new ERC1967Proxy(
            address(laImpl), abi.encodeCall(AgentLinkedAccountRegistry.initialize, (address(identity)))
        )));

        wormhole  = new MockAttester(address(links), "wormhole");
        layerZero = new MockAttester(address(links), "layerzero");

        // Register only wormhole at the start; layerZero is registered later
        // in the relevant test.
        links.registerAttester(address(wormhole), "wormhole");
        vm.stopPrank();

        vm.prank(alice);
        agentId = identity.registerAgent("a", "ipfs://a", 1000, address(0));

        PERM_PAYOUT = links.PERM_PAYOUT();
        PERM_PAY    = links.PERM_PAY();
    }

    // ============ Admin ============

    function test_RegisterAttester_OnlyOwner() public {
        vm.prank(bob);
        vm.expectRevert();
        links.registerAttester(address(layerZero), "layerzero");
    }

    function test_RegisterAttester_RejectsZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(AgentLinkedAccountRegistry.ZeroAddress.selector);
        links.registerAttester(address(0), "layerzero");
    }

    function test_RegisterAttester_RejectsEmptyKind() public {
        vm.prank(deployer);
        vm.expectRevert(AgentLinkedAccountRegistry.EmptyInput.selector);
        links.registerAttester(address(layerZero), "");
    }

    function test_RegisterAttester_RejectsDuplicate() public {
        vm.prank(deployer);
        vm.expectRevert(AgentLinkedAccountRegistry.AttesterAlreadyRegistered.selector);
        links.registerAttester(address(wormhole), "wormhole");
    }

    function test_RevokeAttester_BlocksFutureCalls() public {
        vm.prank(deployer);
        links.revokeAttester(address(wormhole));

        bytes32 sol = keccak256("Sol-1");
        vm.expectRevert(AgentLinkedAccountRegistry.NotAttester.selector);
        wormhole.forward(agentId, 0, sol, "solana", "wh-link", PERM_PAYOUT);
    }

    function test_RevokeAttester_RevertsWhenNotRegistered() public {
        vm.prank(deployer);
        vm.expectRevert(AgentLinkedAccountRegistry.AttesterNotRegistered.selector);
        links.revokeAttester(address(layerZero));
    }

    // ============ Attestation flow ============

    function test_LinkAccountAttested_RoutesAndStampsAttester() public {
        bytes32 sol = keccak256("Solana-pubkey-1");
        uint96  perm = PERM_PAYOUT;

        uint256 idx = wormhole.forward(agentId, 0, sol, "solana", "wh-payout", perm);
        assertEq(idx, 0);

        (uint256 boundId, bool linked, uint96 perms, bool active) = links.agentIdOf(0, sol);
        assertEq(boundId, agentId);
        assertTrue(linked);
        assertTrue(active);
        assertEq(perms, perm);

        assertEq(links.attesterOf(0, sol), address(wormhole));

        // selfAttested must be false on externally-attested links.
        AgentLinkedAccountRegistry.LinkedAccount[] memory all = links.getLinkedAccounts(agentId);
        assertEq(all.length, 1);
        assertFalse(all[0].selfAttested);
        assertEq(all[0].attestedBy, address(wormhole));
    }

    function test_LinkAccountAttested_RevertsWhenCallerNotRegistered() public {
        bytes32 acc = keccak256("evm-mainnet-1");
        vm.expectRevert(AgentLinkedAccountRegistry.NotAttester.selector);
        layerZero.forward(agentId, 1, acc, "evm", "lz-link", PERM_PAY);
    }

    function test_LinkAccountAttested_RevertsWhenDirectCallerEoa() public {
        bytes32 acc = keccak256("evm-direct");
        vm.prank(mallory);
        vm.expectRevert(AgentLinkedAccountRegistry.NotAttester.selector);
        links.linkAccountAttested(agentId, 1, acc, "evm", "x", PERM_PAY);
    }

    function test_LinkAccountAttested_NoOwnerCheck() public {
        // Critical property: the attester model bypasses agent-owner check.
        // The agent NFT owner (alice) does NOT need to sign or send the tx;
        // the attester contract is the trust anchor.
        bytes32 acc = keccak256("attester-direct-link");
        uint256 idx = wormhole.forward(agentId, 0, acc, "bitcoin", "btc-wallet", PERM_PAYOUT);
        assertEq(idx, 0);
        (, bool linked,, ) = links.agentIdOf(0, acc);
        assertTrue(linked);
    }

    function test_LinkAccountAttested_RequiresExistingAgent() public {
        bytes32 acc = keccak256("orphan");
        // agentId 999 does not exist; ownerOf reverts inside linkAccountAttested.
        vm.expectRevert();
        wormhole.forward(999, 0, acc, "solana", "x", PERM_PAYOUT);
    }

    function test_LinkAccountAttested_RespectsAlreadyLinked() public {
        bytes32 acc = keccak256("dup");
        wormhole.forward(agentId, 0, acc, "solana", "first", PERM_PAYOUT);

        // Same (chainId, accountId) cannot be linked twice, even by another
        // attester.
        vm.prank(deployer);
        links.registerAttester(address(layerZero), "layerzero");
        vm.expectRevert(AgentLinkedAccountRegistry.AlreadyLinked.selector);
        layerZero.forward(agentId, 0, acc, "solana", "second", PERM_PAYOUT);
    }

    function test_AttestedLink_CanBeUnlinkedByAgentOwner() public {
        bytes32 acc = keccak256("portable");
        wormhole.forward(agentId, 0, acc, "solana", "x", PERM_PAYOUT);

        vm.prank(alice);
        links.unlinkAccount(agentId, 0, acc);

        (, bool linked,,) = links.agentIdOf(0, acc);
        assertFalse(linked);
    }

    function test_OwnerAttested_HasZeroAttester() public {
        // Sanity check: owner-attested links still return address(0) from
        // attesterOf, so indexers can distinguish provenance.
        bytes32 acc = keccak256("owner-direct");
        vm.prank(alice);
        links.linkAccount(agentId, 0, acc, "solana", "x", PERM_PAYOUT);
        assertEq(links.attesterOf(0, acc), address(0));
    }
}
