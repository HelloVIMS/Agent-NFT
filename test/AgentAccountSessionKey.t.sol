// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentTBARegistry.sol";
import "../src/AgentAccount.sol";

/**
 * @title  AgentAccountSessionKeyTest
 * @notice Drives the executeWithSessionKey path end-to-end against a real
 *         deployment of the identity-registry + TBA-registry stack, lifting
 *         coverage on the highest-attack-surface contract in the suite.
 *
 * @dev    Audit fix F-2 changed the signed-message construction from
 *         abi.encodePacked → abi.encode(…, keccak256(data), state) to close
 *         a collision-via-padding hole. These tests pin the new shape:
 *         every signature here is computed against the post-fix message,
 *         and a regression to encodePacked would fail signature recovery.
 */
contract AgentAccountSessionKeyTest is Test {
    AgentIdentityRegistry public identityRegistry;
    AgentTBARegistry      public tbaRegistry;
    AgentAccount          public account;

    address public agentOwner = makeAddr("agentOwner");
    address public stranger   = makeAddr("stranger");

    // Session-key keypair (deterministic).
    uint256 public constant SIGNER_PK = 0xA11CE;
    address public sessionSigner;

    uint256 public agentId;

    receive() external payable {}

    function setUp() public {
        sessionSigner = vm.addr(SIGNER_PK);

        AgentIdentityRegistry impl = new AgentIdentityRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identityRegistry = AgentIdentityRegistry(address(proxy));
        tbaRegistry = new AgentTBARegistry(address(identityRegistry), address(0xEEEE));

        vm.prank(agentOwner);
        agentId = identityRegistry.registerAgent("SessionTest", "uri", 1000, address(0));

        vm.prank(agentOwner);
        address acct = tbaRegistry.createAccount(agentId, bytes32(0));
        account = AgentAccount(payable(acct));

        // Fund the TBA so executeWithSessionKey can forward ETH value.
        vm.deal(address(account), 10 ether);
    }

    // ─── helpers ───────────────────────────────────────────────────────────

    function _createKey(
        address[] memory allowedTargets,
        bytes4[]  memory allowedSelectors,
        uint256 maxValuePerTx,
        uint256 maxTotalValue,
        uint48 validAfter,
        uint48 validUntil
    ) internal returns (bytes32 keyHash) {
        vm.prank(agentOwner);
        keyHash = account.createSessionKey(
            sessionSigner, allowedTargets, allowedSelectors,
            maxValuePerTx, maxTotalValue, validAfter, validUntil
        );
    }

    /// @dev Mirror the F-2 message construction inside the contract.
    function _signMsg(address to, uint256 value, bytes memory data) internal view returns (bytes memory) {
        uint256 state = account.state();
        bytes32 messageHash = keccak256(abi.encode(
            address(account),
            block.chainid,
            to,
            value,
            keccak256(data),
            state
        ));
        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    // ─── createSessionKey edge cases ───────────────────────────────────────

    function test_createSessionKey_revertsOnZeroSigner() public {
        address[] memory targets;
        bytes4[]  memory selectors;
        vm.prank(agentOwner);
        vm.expectRevert("Invalid signer");
        account.createSessionKey(address(0), targets, selectors, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 days));
    }

    function test_createSessionKey_revertsOnInvertedValidity() public {
        address[] memory targets;
        bytes4[]  memory selectors;
        vm.prank(agentOwner);
        vm.expectRevert("Invalid validity period");
        account.createSessionKey(sessionSigner, targets, selectors, 1 ether, 5 ether, uint48(block.timestamp + 1 days), uint48(block.timestamp));
    }

    function test_createSessionKey_revertsForNonOwner() public {
        address[] memory targets;
        bytes4[]  memory selectors;
        vm.prank(stranger);
        vm.expectRevert("Only owner can create session keys");
        account.createSessionKey(sessionSigner, targets, selectors, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 days));
    }

    function test_createSessionKey_emitsAndStoresKey() public {
        address[] memory targets = new address[](1);
        targets[0] = address(this);
        bytes4[] memory selectors;

        vm.prank(agentOwner);
        bytes32 keyHash = account.createSessionKey(sessionSigner, targets, selectors, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 days));

        (address signer,uint256 maxValuePerTx,uint256 maxTotalValue,uint256 usedValue,uint48 validAfter,uint48 validUntil,bool revoked) =
            account.getSessionKey(keyHash);
        assertEq(signer, sessionSigner);
        assertEq(maxValuePerTx, 1 ether);
        assertEq(maxTotalValue, 5 ether);
        assertEq(usedValue, 0);
        assertEq(validAfter, 0);
        assertEq(validUntil, uint48(block.timestamp + 1 days));
        assertFalse(revoked);
    }

    // ─── executeWithSessionKey happy path ──────────────────────────────────

    function test_executeWithSessionKey_happyPathSendsEthToAllowedTarget() public {
        address payable receiver = payable(makeAddr("receiver"));
        address[] memory targets = new address[](1);
        targets[0] = receiver;
        bytes4[]  memory selectors;
        bytes32 keyHash = _createKey(targets, selectors, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 days));

        bytes memory data = "";
        bytes memory sig  = _signMsg(receiver, 0.5 ether, data);

        uint256 receiverBefore = receiver.balance;
        uint256 stateBefore    = account.state();

        // Anyone can submit a session-key call; authority comes from the sig.
        vm.prank(stranger);
        account.executeWithSessionKey(keyHash, sig, receiver, 0.5 ether, data);

        assertEq(receiver.balance, receiverBefore + 0.5 ether, "receiver did not get ETH");
        assertEq(account.state(), stateBefore + 1, "state nonce did not advance");

        ( , , , uint256 usedAfter, , , ) = account.getSessionKey(keyHash);
        assertEq(usedAfter, 0.5 ether, "usedValue not bumped");
    }

    function test_executeWithSessionKey_consecutiveCallsBumpStateAndUsedValue() public {
        address payable receiver = payable(makeAddr("receiver"));
        address[] memory targets = new address[](1);
        targets[0] = receiver;
        bytes4[]  memory selectors;
        bytes32 keyHash = _createKey(targets, selectors, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 days));

        for (uint256 i = 0; i < 4; i++) {
            bytes memory data = abi.encodePacked("call-", i);
            bytes memory sig = _signMsg(receiver, 0.1 ether, data);
            vm.prank(stranger);
            account.executeWithSessionKey(keyHash, sig, receiver, 0.1 ether, data);
        }
        ( , , , uint256 usedAfter, , , ) = account.getSessionKey(keyHash);
        assertEq(usedAfter, 0.4 ether);
        assertEq(account.state(), 4);
    }

    // ─── Authority gates ───────────────────────────────────────────────────

    function test_executeWithSessionKey_revertsAfterRevokeSingle() public {
        address payable receiver = payable(makeAddr("receiver"));
        address[] memory targets = new address[](1);
        targets[0] = receiver;
        bytes4[]  memory selectors;
        bytes32 keyHash = _createKey(targets, selectors, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 days));

        vm.prank(agentOwner);
        account.revokeSessionKey(keyHash);

        bytes memory sig = _signMsg(receiver, 0.1 ether, "");
        vm.prank(stranger);
        vm.expectRevert("Session key revoked");
        account.executeWithSessionKey(keyHash, sig, receiver, 0.1 ether, "");
    }

    function test_executeWithSessionKey_revertsAfterRevokeAll() public {
        address payable receiver = payable(makeAddr("receiver"));
        address[] memory targets = new address[](1);
        targets[0] = receiver;
        bytes4[]  memory selectors;
        bytes32 keyHash = _createKey(targets, selectors, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 days));

        vm.prank(agentOwner);
        account.revokeAllSessionKeys();

        bytes memory sig = _signMsg(receiver, 0.1 ether, "");
        vm.prank(stranger);
        vm.expectRevert("Session key epoch invalidated");
        account.executeWithSessionKey(keyHash, sig, receiver, 0.1 ether, "");
    }

    function test_executeWithSessionKey_revertsBeforeValidAfter() public {
        address payable receiver = payable(makeAddr("receiver"));
        address[] memory targets = new address[](1);
        targets[0] = receiver;
        bytes4[]  memory selectors;
        // Key not valid until +1 hour.
        bytes32 keyHash = _createKey(targets, selectors, 1 ether, 5 ether, uint48(block.timestamp + 1 hours), uint48(block.timestamp + 1 days));

        bytes memory sig = _signMsg(receiver, 0.1 ether, "");
        vm.prank(stranger);
        vm.expectRevert("Session key not yet valid");
        account.executeWithSessionKey(keyHash, sig, receiver, 0.1 ether, "");
    }

    function test_executeWithSessionKey_revertsAfterValidUntil() public {
        address payable receiver = payable(makeAddr("receiver"));
        address[] memory targets = new address[](1);
        targets[0] = receiver;
        bytes4[]  memory selectors;
        bytes32 keyHash = _createKey(targets, selectors, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 hours));

        // Move past the expiry.
        vm.warp(block.timestamp + 2 hours);
        bytes memory sig = _signMsg(receiver, 0.1 ether, "");
        vm.prank(stranger);
        vm.expectRevert("Session key expired");
        account.executeWithSessionKey(keyHash, sig, receiver, 0.1 ether, "");
    }

    function test_executeWithSessionKey_revertsOnPerTxValueOverflow() public {
        address payable receiver = payable(makeAddr("receiver"));
        address[] memory targets = new address[](1);
        targets[0] = receiver;
        bytes4[]  memory selectors;
        bytes32 keyHash = _createKey(targets, selectors, 0.1 ether, 5 ether, 0, uint48(block.timestamp + 1 days));

        bytes memory sig = _signMsg(receiver, 0.5 ether, "");
        vm.prank(stranger);
        vm.expectRevert("Exceeds per-tx value limit");
        account.executeWithSessionKey(keyHash, sig, receiver, 0.5 ether, "");
    }

    function test_executeWithSessionKey_revertsOnTotalValueOverflow() public {
        address payable receiver = payable(makeAddr("receiver"));
        address[] memory targets = new address[](1);
        targets[0] = receiver;
        bytes4[]  memory selectors;
        // Per-tx 1 ETH OK, total cap 0.5 ETH so first 0.4 succeeds, second 0.2 must fail.
        bytes32 keyHash = _createKey(targets, selectors, 1 ether, 0.5 ether, 0, uint48(block.timestamp + 1 days));

        bytes memory sig = _signMsg(receiver, 0.4 ether, "");
        vm.prank(stranger);
        account.executeWithSessionKey(keyHash, sig, receiver, 0.4 ether, "");

        bytes memory sig2 = _signMsg(receiver, 0.2 ether, "");
        vm.prank(stranger);
        vm.expectRevert("Exceeds total value limit");
        account.executeWithSessionKey(keyHash, sig2, receiver, 0.2 ether, "");
    }

    function test_executeWithSessionKey_revertsOnDisallowedTarget() public {
        address payable allowed   = payable(makeAddr("allowed"));
        address payable disallowed = payable(makeAddr("disallowed"));
        address[] memory targets = new address[](1);
        targets[0] = allowed;
        bytes4[] memory selectors;
        bytes32 keyHash = _createKey(targets, selectors, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 days));

        bytes memory sig = _signMsg(disallowed, 0.1 ether, "");
        vm.prank(stranger);
        vm.expectRevert("Target not allowed");
        account.executeWithSessionKey(keyHash, sig, disallowed, 0.1 ether, "");
    }

    function test_executeWithSessionKey_revertsOnDisallowedSelector() public {
        address payable receiver = payable(makeAddr("receiver"));
        address[] memory targets = new address[](1);
        targets[0] = receiver;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(0xdeadbeef); // only this selector is allowed
        bytes32 keyHash = _createKey(targets, selectors, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 days));

        bytes memory data = abi.encodeWithSelector(bytes4(0xcafebabe), uint256(1));
        bytes memory sig  = _signMsg(receiver, 0, data);
        vm.prank(stranger);
        vm.expectRevert("Selector not allowed");
        account.executeWithSessionKey(keyHash, sig, receiver, 0, data);
    }

    function test_executeWithSessionKey_revertsOnBadSignature() public {
        address payable receiver = payable(makeAddr("receiver"));
        address[] memory targets = new address[](1);
        targets[0] = receiver;
        bytes4[] memory selectors;
        bytes32 keyHash = _createKey(targets, selectors, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 days));

        // Sign for a DIFFERENT value than the call uses → recovery returns the
        // wrong address, the strict equality check reverts.
        bytes memory sig = _signMsg(receiver, 0.5 ether, "");
        vm.prank(stranger);
        vm.expectRevert("Invalid session key signature");
        account.executeWithSessionKey(keyHash, sig, receiver, 0.6 ether, "");
    }

    function test_executeWithSessionKey_replayCannotReuseStateNonce() public {
        // Re-using the same signature after state has advanced should fail
        // because state is in the signed message.
        address payable receiver = payable(makeAddr("receiver"));
        address[] memory targets = new address[](1);
        targets[0] = receiver;
        bytes4[]  memory selectors;
        bytes32 keyHash = _createKey(targets, selectors, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 days));

        bytes memory data = "first";
        bytes memory sig  = _signMsg(receiver, 0.1 ether, data);
        vm.prank(stranger);
        account.executeWithSessionKey(keyHash, sig, receiver, 0.1 ether, data);

        // Replay attempt with the same sig — state has incremented, hash mismatches.
        vm.prank(stranger);
        vm.expectRevert("Invalid session key signature");
        account.executeWithSessionKey(keyHash, sig, receiver, 0.1 ether, data);
    }

    // ─── revoke paths ──────────────────────────────────────────────────────

    function test_revokeSessionKey_revertsForNonOwner() public {
        address[] memory t; bytes4[] memory s;
        bytes32 keyHash = _createKey(t, s, 1 ether, 5 ether, 0, uint48(block.timestamp + 1 days));
        vm.prank(stranger);
        vm.expectRevert();
        account.revokeSessionKey(keyHash);
    }

    function test_revokeAllSessionKeys_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Only owner can revoke session keys");
        account.revokeAllSessionKeys();
    }

    function test_revokeAllSessionKeys_bumpsEpochAndEmits() public {
        uint256 epochBefore = account.sessionKeyEpoch();
        vm.prank(agentOwner);
        account.revokeAllSessionKeys();
        assertEq(account.sessionKeyEpoch(), epochBefore + 1);
    }
}
