// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentLinkedAccountRegistry.sol";

/// @title AgentLinkedAccountRegistryTest
/// @notice Covers Option B: external/cross-chain linked accounts with
///         owner-attested and EIP-712 self-attested flows.
contract AgentLinkedAccountRegistryTest is Test {
    AgentIdentityRegistry      public identity;
    AgentLinkedAccountRegistry public links;

    address public deployer = address(0xD);
    address public alice    = address(0xA11CE);
    address public bob      = address(0xB0B);

    // EIP-712 self-attest signer
    uint256 public sigPk = 0xA11CE_BEEF;
    address public sigAddr;

    function setUp() public {
        sigAddr = vm.addr(sigPk);

        vm.startPrank(deployer);

        AgentIdentityRegistry idImpl = new AgentIdentityRegistry();
        ERC1967Proxy idProxy = new ERC1967Proxy(
            address(idImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identity = AgentIdentityRegistry(address(idProxy));

        AgentLinkedAccountRegistry linksImpl = new AgentLinkedAccountRegistry();
        ERC1967Proxy linksProxy = new ERC1967Proxy(
            address(linksImpl),
            abi.encodeCall(AgentLinkedAccountRegistry.initialize, (address(identity)))
        );
        links = AgentLinkedAccountRegistry(address(linksProxy));

        vm.stopPrank();
    }

    function _mint(address who) internal returns (uint256 id) {
        vm.prank(who);
        id = identity.registerAgent("a", "ipfs://a", 1000, address(0));
    }

    // ---- owner-attested ----

    function test_OwnerAttestedLink_HappyPath() public {
        uint96 permPayout = links.PERM_PAYOUT();
        uint256 id = _mint(alice);
        bytes32 solanaAccount = keccak256(abi.encodePacked("Sol1111pubkey"));

        vm.prank(alice);
        links.linkAccount(id, 0, solanaAccount, "solana", "payouts", permPayout);

        (uint256 boundId, bool linked, uint96 perms, bool active) = links.agentIdOf(0, solanaAccount);
        assertEq(boundId, id);
        assertTrue(linked);
        assertTrue(active);
        assertEq(perms, permPayout);
        assertTrue(links.hasPermission(0, solanaAccount, permPayout));
    }

    function test_OwnerAttestedLink_RevertsWhenNotOwner() public {
        uint96 permPay = links.PERM_PAY();
        uint256 id = _mint(alice);
        bytes32 acc = keccak256("x");
        vm.prank(bob);
        vm.expectRevert(AgentLinkedAccountRegistry.NotOwner.selector);
        links.linkAccount(id, 0, acc, "evm", "x", permPay);
    }

    function test_DoubleLink_SameAccount_Reverts() public {
        uint96 permPay = links.PERM_PAY();
        uint256 id = _mint(alice);
        bytes32 acc = keccak256("dup");
        vm.startPrank(alice);
        links.linkAccount(id, 0, acc, "evm", "x", permPay);
        vm.expectRevert(AgentLinkedAccountRegistry.AlreadyLinked.selector);
        links.linkAccount(id, 0, acc, "evm", "x", permPay);
        vm.stopPrank();
    }

    function test_Unlink_AndRelinkUnderDifferentAgent() public {
        uint96 permPay = links.PERM_PAY();
        uint256 id1 = _mint(alice);
        uint256 id2 = _mint(bob);
        bytes32 acc = keccak256("portable");

        vm.startPrank(alice);
        links.linkAccount(id1, 0, acc, "evm", "x", permPay);
        links.unlinkAccount(id1, 0, acc);
        vm.stopPrank();

        (, bool linked,,) = links.agentIdOf(0, acc);
        assertFalse(linked);

        vm.prank(bob);
        links.linkAccount(id2, 0, acc, "evm", "x", permPay);
        (uint256 boundId, bool linked2,,) = links.agentIdOf(0, acc);
        assertTrue(linked2);
        assertEq(boundId, id2);
    }

    function test_UpdatePermissions() public {
        uint96 permPay = links.PERM_PAY();
        uint96 permRep = links.PERM_REPUTATION();
        uint256 id = _mint(alice);
        bytes32 acc = keccak256("perm");

        vm.startPrank(alice);
        links.linkAccount(id, 0, acc, "evm", "x", permPay);
        links.updatePermissions(id, 0, acc, permPay | permRep);
        vm.stopPrank();
        assertTrue(links.hasPermission(0, acc, permRep));
    }

    // ---- EIP-712 self-attested ----

    function test_SelfAttestedLink_HappyPath() public {
        uint96 permPay = links.PERM_PAY();
        uint256 id = _mint(alice);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = links.attestationNonce(id);

        bytes32 digest = links.eip712Digest(
            id,
            block.chainid,
            links.evmAccountId(sigAddr),
            nonce,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sigPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(alice);
        links.linkAccountWithAttestation(
            id,
            sigAddr,
            "evm",
            "self",
            permPay,
            deadline,
            sig
        );

        (uint256 boundId, bool linked,, bool active) =
            links.agentIdOfEvm(block.chainid, sigAddr);
        assertEq(boundId, id);
        assertTrue(linked);
        assertTrue(active);
        assertEq(links.attestationNonce(id), nonce + 1);
    }

    function test_SelfAttestedLink_BadSignatureReverts() public {
        uint96 permPay = links.PERM_PAY();
        uint256 id = _mint(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = new bytes(65); // all zeros

        vm.prank(alice);
        vm.expectRevert(AgentLinkedAccountRegistry.InvalidSignature.selector);
        links.linkAccountWithAttestation(
            id, sigAddr, "evm", "self", permPay, deadline, sig
        );
    }

    function test_SelfAttestedLink_ExpiredReverts() public {
        uint96 permPay = links.PERM_PAY();
        uint256 id = _mint(alice);

        // Warp forward so block.timestamp > 0, then craft an already-expired
        // deadline. Signature contents don't matter — the deadline check runs
        // first.
        vm.warp(1_000_000);
        uint256 expiredDeadline = block.timestamp - 1;

        vm.prank(alice);
        vm.expectRevert(AgentLinkedAccountRegistry.ExpiredAttestation.selector);
        links.linkAccountWithAttestation(
            id, sigAddr, "evm", "self", permPay, expiredDeadline, new bytes(65)
        );
    }
}
