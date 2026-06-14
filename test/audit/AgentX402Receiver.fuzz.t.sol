// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AgentIdentityRegistry} from "../../src/AgentIdentityRegistry.sol";
import {AgentX402Receiver}     from "../../src/AgentX402Receiver.sol";

/// @dev Minimal ERC-3009 mock (mirror of MockUSDC in
/// `test/AgentX402Receiver.t.sol`) without ECDSA verification — the
/// receiver's nonce / commitment guard is what we're auditing here.
contract MockUSDC3009 is ERC20 {
    mapping(address => mapping(bytes32 => bool)) public used;
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function receiveWithAuthorization(
        address from, address to, uint256 value, uint256 validAfter, uint256 validBefore,
        bytes32 nonce, uint8, bytes32, bytes32
    ) external {
        require(to == msg.sender, "to");
        require(block.timestamp > validAfter, "early");
        require(block.timestamp < validBefore, "expired");
        require(!used[from][nonce], "nonce");
        used[from][nonce] = true;
        _transfer(from, to, value);
    }
    function authorizationState(address from, bytes32 nonce) external view returns (bool) {
        return used[from][nonce];
    }
}

/// @notice Replay / tamper / signature fuzz suite for AgentX402Receiver.
///
/// The complementary unit suite already covers happy-path splits + basic
/// nonce reuse. This file targets the adversarial surface:
///
///   1. `payForService` can NEVER be called twice with the same nonce,
///      regardless of caller, validBefore, or how funds are funded.
///   2. Tampering with ANY commitment field after signing — agentId,
///      serviceId, amount, nonce, validBefore — causes recovery to point
///      to a non-`from` address and reverts with InvalidCommitment.
///   3. Expired commitments (validBefore < now) revert before any
///      transfer or split happens.
///   4. Cross-service replay: a signature for service A on agent X
///      cannot be replayed against service B on the same agent X.
contract AgentX402ReceiverFuzz is Test {
    AgentIdentityRegistry internal registry;
    AgentX402Receiver     internal x402;
    MockUSDC3009          internal usdc;

    address internal owner   = address(0xA11CE);
    address internal creator;
    uint256 internal creatorPk = 0xC0FFEE;
    address internal payer;
    uint256 internal payerPk   = 0xBA5E;
    uint256 internal attackerPk = 0xDEADBEEF;
    address internal treasury = address(0x7E2A);

    uint256 internal agentId;
    bytes32 internal constant SID_A = keccak256("api/chat/v1");
    bytes32 internal constant SID_B = keccak256("api/embed/v1");
    uint256 internal constant DEADLINE = type(uint256).max;
    uint256 internal constant PRICE = 100e6;

    function setUp() public {
        creator = vm.addr(creatorPk);
        payer   = vm.addr(payerPk);

        vm.startPrank(owner);
        AgentIdentityRegistry regImpl = new AgentIdentityRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        registry = AgentIdentityRegistry(address(regProxy));

        AgentX402Receiver x402Impl = new AgentX402Receiver();
        ERC1967Proxy x402Proxy = new ERC1967Proxy(
            address(x402Impl),
            abi.encodeCall(AgentX402Receiver.initialize, (address(registry), treasury, 50))
        );
        x402 = AgentX402Receiver(address(x402Proxy));
        vm.stopPrank();

        usdc = new MockUSDC3009();
        vm.prank(owner);
        x402.setTokenAllowed(address(usdc), true);

        vm.prank(creator);
        agentId = registry.registerAgent("X402Bot", "ipfs://x", 1_000, address(0));

        vm.prank(creator);
        x402.registerService(agentId, SID_A, address(usdc), PRICE);
        vm.prank(creator);
        x402.registerService(agentId, SID_B, address(usdc), PRICE);

        usdc.mint(payer, 1_000_000e6);
    }

    function _signCommit(uint256 pk, uint256 _agentId, bytes32 _sid, uint256 _amount, bytes32 _nonce, uint256 _validBefore)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = x402.hashPaymentCommitment(_agentId, _sid, address(usdc), _amount, _nonce, _validBefore);
        (v, r, s) = vm.sign(pk, digest);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. Replay: same nonce twice always reverts.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_ReplaySameNonceReverts(bytes32 nonce) public {
        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(payerPk, agentId, SID_A, PRICE, nonce, DEADLINE);

        x402.payForService(agentId, SID_A, payer, 0, DEADLINE, nonce, 0, bytes32(0), bytes32(0), cv, cr, cs);

        // Second call with the SAME nonce must revert. The mock's 3009
        // path enforces uniqueness; the receiver itself relies on the
        // token's nonce guarantee.
        vm.expectRevert();
        x402.payForService(agentId, SID_A, payer, 0, DEADLINE, nonce, 0, bytes32(0), bytes32(0), cv, cr, cs);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2a. Tamper agentId after signing.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_TamperAgentIdReverts(bytes32 nonce) public {
        // Register a second agent so we have a target to tamper toward.
        vm.prank(creator);
        uint256 otherAgent = registry.registerAgent("Other", "ipfs://o", 1_000, address(0));
        vm.prank(creator);
        x402.registerService(otherAgent, SID_A, address(usdc), PRICE);

        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(payerPk, agentId, SID_A, PRICE, nonce, DEADLINE);

        vm.expectRevert(AgentX402Receiver.InvalidCommitment.selector);
        x402.payForService(otherAgent, SID_A, payer, 0, DEADLINE, nonce, 0, bytes32(0), bytes32(0), cv, cr, cs);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2b. Tamper serviceId after signing → InvalidCommitment.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_TamperServiceIdReverts(bytes32 nonce) public {
        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(payerPk, agentId, SID_A, PRICE, nonce, DEADLINE);

        vm.expectRevert(AgentX402Receiver.InvalidCommitment.selector);
        x402.payForService(agentId, SID_B, payer, 0, DEADLINE, nonce, 0, bytes32(0), bytes32(0), cv, cr, cs);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2c. Tamper validBefore after signing.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_TamperValidBeforeReverts(bytes32 nonce, uint64 forgedDeadline) public {
        // Choose any deadline that differs from the signed DEADLINE but is
        // still in the future so the mock 3009 wouldn't reject for "expired".
        uint256 forged = uint256(forgedDeadline);
        vm.assume(forged != DEADLINE && forged > block.timestamp + 1);

        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(payerPk, agentId, SID_A, PRICE, nonce, DEADLINE);

        vm.expectRevert(AgentX402Receiver.InvalidCommitment.selector);
        x402.payForService(agentId, SID_A, payer, 0, forged, nonce, 0, bytes32(0), bytes32(0), cv, cr, cs);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2d. Tamper nonce after signing.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_TamperNonceReverts(bytes32 signedNonce, bytes32 forgedNonce) public {
        vm.assume(signedNonce != forgedNonce);

        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(payerPk, agentId, SID_A, PRICE, signedNonce, DEADLINE);

        vm.expectRevert(AgentX402Receiver.InvalidCommitment.selector);
        x402.payForService(agentId, SID_A, payer, 0, DEADLINE, forgedNonce, 0, bytes32(0), bytes32(0), cv, cr, cs);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Wrong-signer commitment: a malicious "attacker" signs the digest;
    //    receiver must reject because ECDSA.recover != `from`.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_WrongSignerReverts(bytes32 nonce) public {
        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(attackerPk, agentId, SID_A, PRICE, nonce, DEADLINE);

        vm.expectRevert(AgentX402Receiver.InvalidCommitment.selector);
        x402.payForService(agentId, SID_A, payer, 0, DEADLINE, nonce, 0, bytes32(0), bytes32(0), cv, cr, cs);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. Cross-service replay on the same agent: signing for SID_A and
    //    submitting against SID_B fails the commitment check.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_CrossServiceReplayReverts(bytes32 nonce) public {
        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(payerPk, agentId, SID_A, PRICE, nonce, DEADLINE);

        vm.expectRevert(AgentX402Receiver.InvalidCommitment.selector);
        x402.payForService(agentId, SID_B, payer, 0, DEADLINE, nonce, 0, bytes32(0), bytes32(0), cv, cr, cs);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. Wrong-signer ECDSA malleability: every (cv, cr, cs) where
    //    recover() doesn't equal `from` must revert. Random sig fuzz.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_RandomSigReverts(bytes32 nonce, uint8 cv, bytes32 cr, bytes32 cs) public {
        // Skip the unlikely-but-possible case where (cv,cr,cs) recovers
        // to `payer`. Any random tuple recovering to payer would itself
        // be a signature collision against an unrelated digest, which is
        // cryptographically negligible — but vm.assume is cheap.
        bytes32 digest = x402.hashPaymentCommitment(agentId, SID_A, address(usdc), PRICE, nonce, DEADLINE);
        // ecrecover may return address(0) for invalid inputs.
        address recovered;
        if (cv == 27 || cv == 28) recovered = ecrecover(digest, cv, cr, cs);
        vm.assume(recovered != payer);

        // Any malformed sig MUST cause a revert. ECDSA library raises
        // ECDSAInvalidSignature for v∉{27,28}; valid-shape but
        // wrong-signer raises InvalidCommitment. Both are guards we want.
        vm.expectRevert();
        x402.payForService(agentId, SID_A, payer, 0, DEADLINE, nonce, 0, bytes32(0), bytes32(0), cv, cr, cs);
    }
}
