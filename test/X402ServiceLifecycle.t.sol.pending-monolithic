// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/AgentIdentityRegistry.sol";
import "../src/AgentX402Receiver.sol";
import "../src/AgentTBARegistry.sol";
import "../src/AgentReputationRegistry.sol";

/// @dev ERC-3009-shaped USDC mock. Records nonces, transfers balance.
///      Skips ECDSA verification — the EIP-712 commitment in the receiver
///      provides the binding under test; the EIP-3009 sig is only the
///      transfer-pull primitive and is unit-tested in `AgentX402Receiver.t.sol`.
contract LifecycleUSDC is ERC20 {
    mapping(address => mapping(bytes32 => bool)) public used;

    constructor() ERC20("Mock USDC", "mUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8, bytes32, bytes32
    ) external {
        require(to == msg.sender, "3009: to != msg.sender");
        require(block.timestamp > validAfter, "3009: too early");
        require(block.timestamp < validBefore, "3009: expired");
        require(!used[from][nonce], "3009: nonce used");
        used[from][nonce] = true;
        _transfer(from, to, value);
    }

    function authorizationState(address from, bytes32 nonce) external view returns (bool) {
        return used[from][nonce];
    }
}

/// @notice Extended end-to-end lifecycle suite covering the full x402 service
///         loop a real client experiences:
///
///           1. Mint agent (NFT + TBA)
///           2. Register a priced service
///           3. Settle a payment via `payForService` (EIP-3009 + EIP-712)
///           4. Verify on-chain split: system / creator / agent
///           5. Job-completion side effects (USDC arrival at TBA, event payload)
///           6. Buyer attests delivery via `giveFeedback`
///           7. Buyer revokes attestation; reputation summary updates
///           8. Re-attestation after revocation is permitted (single live entry)
///           9. Multiple buyers + average aggregation
///          10. Service deactivation gates future payments
///          11. Replay protection (3009 nonce + EIP-712 commitment)
///          12. Token-allowlist gating prevents service registration drift
///
/// The intent is to catch any divergence between the marketplace MCP's
/// calldata builders and the on-chain contracts that backstop them. If a
/// regression sneaks into split math, event topics, or attestation
/// canonicalisation, this suite fails loudly.
contract X402ServiceLifecycleTest is Test {
    AgentIdentityRegistry   public identity;
    AgentX402Receiver       public x402;
    AgentTBARegistry        public tbaRegistry;
    AgentReputationRegistry public reputation;
    LifecycleUSDC           public usdc;

    address public owner    = address(0xA11CE);
    address public treasury = address(0x7E2A);

    // Creator owns the agent NFT + TBA. Uses a known privkey so we can sign
    // EIP-712 commitments below.
    uint256 public creatorPk = uint256(keccak256("creator/x402-lifecycle"));
    address public creator;

    // Two distinct buyers so we can exercise multi-attestation aggregation.
    uint256 public buyer1Pk = uint256(keccak256("buyer1/x402-lifecycle"));
    address public buyer1;
    uint256 public buyer2Pk = uint256(keccak256("buyer2/x402-lifecycle"));
    address public buyer2;

    bytes32 public constant SERVICE_ID = keccak256("api/chat/v1");
    uint256 public constant SERVICE_PRICE = 100e6; // 100 USDC

    uint256 public constant SYSTEM_FEE_BPS  = 50;   // 0.5%
    uint256 public constant CREATOR_ROYALTY = 1000; // 10%
    uint256 public constant DEADLINE        = type(uint256).max;

    uint256 public agentId;
    address public agentTBA;

    // Same canonical address `AgentTBARegistry` consults.
    address constant ERC6551_REGISTRY = 0x000000006551c19487814612e58FE06813775758;

    function setUp() public {
        creator = vm.addr(creatorPk);
        buyer1  = vm.addr(buyer1Pk);
        buyer2  = vm.addr(buyer2Pk);

        // ─── Identity ────────────────────────────────────────────────────
        vm.startPrank(owner);
        AgentIdentityRegistry idImpl = new AgentIdentityRegistry();
        ERC1967Proxy idProxy = new ERC1967Proxy(
            address(idImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identity = AgentIdentityRegistry(address(idProxy));

        // ─── x402 ────────────────────────────────────────────────────────
        AgentX402Receiver x402Impl = new AgentX402Receiver();
        ERC1967Proxy x402Proxy = new ERC1967Proxy(
            address(x402Impl),
            abi.encodeCall(
                AgentX402Receiver.initialize,
                (address(identity), treasury, SYSTEM_FEE_BPS)
            )
        );
        x402 = AgentX402Receiver(address(x402Proxy));

        // ─── Reputation ──────────────────────────────────────────────────
        AgentReputationRegistry repImpl = new AgentReputationRegistry();
        ERC1967Proxy repProxy = new ERC1967Proxy(
            address(repImpl),
            abi.encodeCall(AgentReputationRegistry.initialize, (address(identity)))
        );
        reputation = AgentReputationRegistry(address(repProxy));

        // ─── TBA registry ────────────────────────────────────────────────
        address mockEntryPoint = address(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);
        tbaRegistry = new AgentTBARegistry(address(identity), mockEntryPoint);

        identity.setTrustedTBARegistry(address(tbaRegistry));
        identity.setLinkedX402Receiver(address(x402));
        x402.setTrustedAgentRegistry(address(identity));

        usdc = new LifecycleUSDC();
        x402.setTokenAllowed(address(usdc), true);

        vm.stopPrank();

        // Mint with full stack: NFT + TBA + initial service registration.
        vm.prank(creator);
        (agentId, agentTBA) = identity.mintWithFullStack(
            "Pixel",
            "ipfs://pixel/agent.json",
            CREATOR_ROYALTY,
            address(0),
            bytes32(0),
            SERVICE_ID,
            address(usdc),
            SERVICE_PRICE
        );

        // Fund both buyers with enough USDC for several settlement runs.
        usdc.mint(buyer1, 10_000e6);
        usdc.mint(buyer2, 10_000e6);

        // Move past genesis so EIP-3009 `validAfter == 0` checks pass.
        vm.warp(1_700_000_000);
    }

    // ───────────────────────────────────────────────────────────────────
    //  Helpers
    // ───────────────────────────────────────────────────────────────────

    /// @dev Sign the EIP-712 PaymentCommitment with `pk`. Returns the
    ///      buyer-side dual-sig tuple consumed by `payForService`.
    function _signCommit(uint256 pk, uint256 amount, bytes32 nonce)
        internal view returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = x402.hashPaymentCommitment(
            agentId, SERVICE_ID, address(usdc), amount, nonce, DEADLINE
        );
        (v, r, s) = vm.sign(pk, digest);
    }

    /// @dev Settle a payment from `buyer`. The EIP-3009 sig fields go unused
    ///      by `LifecycleUSDC`; we still pass valid bytes so a future strict
    ///      mock would not need reshuffling.
    function _pay(address buyer, uint256 buyerPk, bytes32 nonce)
        internal returns (uint256 gross)
    {
        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(buyerPk, SERVICE_PRICE, nonce);
        vm.prank(buyer);
        gross = x402.payForService(
            agentId, SERVICE_ID, buyer,
            0, DEADLINE, nonce,
            uint8(27), bytes32(uint256(1)), bytes32(uint256(2)),
            cv, cr, cs
        );
    }

    function _expectedSplit(uint256 gross)
        internal pure returns (uint256 systemCut, uint256 creatorCut, uint256 agentCut)
    {
        systemCut  = (gross * SYSTEM_FEE_BPS) / 10_000;
        creatorCut = (gross * CREATOR_ROYALTY) / 10_000;
        agentCut   = gross - systemCut - creatorCut;
    }

    // ───────────────────────────────────────────────────────────────────
    //  Tests
    // ───────────────────────────────────────────────────────────────────

    /// @notice Single-buyer happy path: settlement → split → attestation.
    function test_Lifecycle_PaymentSplitAttestation() public {
        // Pre-balances.
        uint256 buyerBefore  = usdc.balanceOf(buyer1);
        uint256 tbaBefore    = usdc.balanceOf(agentTBA);
        uint256 creatorBefore= usdc.balanceOf(creator);
        uint256 trezBefore   = usdc.balanceOf(treasury);

        // 1. Settle the x402 payment.
        uint256 gross = _pay(buyer1, buyer1Pk, keccak256("nonce-1"));
        assertEq(gross, SERVICE_PRICE, "gross == price");

        // 2. Verify on-chain disbursement matches quoteSplit math.
        (uint256 systemCut, uint256 creatorCut, uint256 agentCut) = _expectedSplit(gross);
        assertEq(usdc.balanceOf(buyer1),    buyerBefore   - gross,       "buyer debit");
        assertEq(usdc.balanceOf(treasury),  trezBefore    + systemCut,   "treasury credit");
        assertEq(usdc.balanceOf(creator),   creatorBefore + creatorCut,  "creator credit");
        assertEq(usdc.balanceOf(agentTBA),  tbaBefore     + agentCut,    "TBA credit");

        // Sanity: split sums to gross.
        assertEq(systemCut + creatorCut + agentCut, gross, "split conservation");

        // 3. Buyer attests delivery on-chain.
        vm.prank(buyer1);
        reputation.giveFeedback(
            agentId, int128(5), uint8(0), "quality", "speed", "ipfs://review/job-1.json"
        );

        // 4. Reputation summary reflects the new entry.
        (uint256 total, int256 avg, uint256 last) = reputation.getReputationSummary(agentId);
        assertEq(total, 1, "1 feedback recorded");
        assertEq(avg, int256(5), "average is 5");
        assertEq(last, block.timestamp, "timestamp anchored to block");
    }

    /// @notice Settlement emits `ServicePaid` with the exact split written
    ///         to chain (audit L-4 — events match disbursement).
    function test_Lifecycle_ServicePaidEventMatchesDisbursement() public {
        (uint256 systemCut, uint256 creatorCut, uint256 agentCut) = _expectedSplit(SERVICE_PRICE);

        bytes32 nonce = keccak256("nonce-event");
        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(buyer1Pk, SERVICE_PRICE, nonce);

        vm.expectEmit(true, true, true, true);
        emit AgentX402Receiver.ServicePaid(
            agentId, SERVICE_ID, buyer1,
            address(usdc), SERVICE_PRICE,
            systemCut, creatorCut, agentCut,
            agentTBA
        );

        vm.prank(buyer1);
        x402.payForService(
            agentId, SERVICE_ID, buyer1,
            0, DEADLINE, nonce,
            uint8(27), bytes32(uint256(1)), bytes32(uint256(2)),
            cv, cr, cs
        );
    }

    /// @notice Multi-buyer attestation: each settlement is independent and
    ///         the reputation registry averages across distinct clients.
    function test_Lifecycle_MultiBuyerAggregation() public {
        // Two distinct buyers each pay + attest.
        _pay(buyer1, buyer1Pk, keccak256("multi-1"));
        vm.prank(buyer1);
        reputation.giveFeedback(agentId, int128(5), 0, "great", "", "ipfs://r/1");

        _pay(buyer2, buyer2Pk, keccak256("multi-2"));
        vm.prank(buyer2);
        reputation.giveFeedback(agentId, int128(3), 0, "okay", "", "ipfs://r/2");

        (uint256 total, int256 avg,) = reputation.getReputationSummary(agentId);
        assertEq(total, 2, "two attestations");
        assertEq(avg, int256(4), "average is (5+3)/2 = 4");
    }

    /// @notice Buyer revokes prior attestation; summary reflects the revocation.
    ///         A subsequent re-attestation from the same buyer is then allowed.
    function test_Lifecycle_RevokeAndReAttest() public {
        _pay(buyer1, buyer1Pk, keccak256("revoke-1"));

        vm.prank(buyer1);
        reputation.giveFeedback(agentId, int128(5), 0, "", "", "");

        // Revoke.
        vm.prank(buyer1);
        reputation.revokeFeedback(agentId);

        // Active count drops to zero (summary excludes revoked entries).
        (uint256 total,,) = reputation.getReputationSummary(agentId);
        assertEq(total, 0, "revocation clears active count");

        // Re-attest after revocation. Must succeed (no "already gave feedback").
        vm.prank(buyer1);
        reputation.giveFeedback(agentId, int128(2), 0, "second-thought", "", "");

        (uint256 totalAfter, int256 avgAfter,) = reputation.getReputationSummary(agentId);
        assertEq(totalAfter, 1, "re-attestation registered");
        assertEq(avgAfter, int256(2), "new value is canonical");
    }

    /// @notice Replay protection — submitting the *same* EIP-3009 nonce twice
    ///         must revert. The first call burns the nonce.
    function test_Lifecycle_RejectsReplayedNonce() public {
        bytes32 nonce = keccak256("replay-once");
        _pay(buyer1, buyer1Pk, nonce);

        // Re-sign the same commitment + reuse the same nonce — token
        // contract must reject. Receiver bubbles the revert through.
        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(buyer1Pk, SERVICE_PRICE, nonce);
        vm.prank(buyer1);
        vm.expectRevert(bytes("3009: nonce used"));
        x402.payForService(
            agentId, SERVICE_ID, buyer1,
            0, DEADLINE, nonce,
            uint8(27), bytes32(uint256(1)), bytes32(uint256(2)),
            cv, cr, cs
        );
    }

    /// @notice The EIP-712 PaymentCommitment must be signed by the same
    ///         account that the EIP-3009 transfer pulls from. A commitment
    ///         signed by a *different* key for the same `from` address
    ///         must revert with `InvalidCommitment` (audit M-1 binding).
    function test_Lifecycle_RejectsCommitmentSignedByWrongKey() public {
        bytes32 nonce = keccak256("wrong-key");

        // buyer2 signs a commitment claiming buyer1 is the payer.
        bytes32 digest = x402.hashPaymentCommitment(
            agentId, SERVICE_ID, address(usdc), SERVICE_PRICE, nonce, DEADLINE
        );
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(buyer2Pk, digest);

        vm.prank(buyer1);
        vm.expectRevert(AgentX402Receiver.InvalidCommitment.selector);
        x402.payForService(
            agentId, SERVICE_ID, buyer1,
            0, DEADLINE, nonce,
            uint8(27), bytes32(uint256(1)), bytes32(uint256(2)),
            cv, cr, cs
        );
    }

    /// @notice Deactivating a service halts new settlements. Existing
    ///         attestations stay intact but no further payments succeed
    ///         until reactivation.
    function test_Lifecycle_DeactivatedServiceBlocksPayment() public {
        // First payment + attestation succeed.
        _pay(buyer1, buyer1Pk, keccak256("deact-1"));
        vm.prank(buyer1);
        reputation.giveFeedback(agentId, 5, 0, "", "", "");

        // Creator deactivates the service.
        vm.prank(creator);
        x402.updateService(agentId, SERVICE_ID, SERVICE_PRICE, false);

        // Buyer2 attempt fails — `ServiceInactive`.
        bytes32 nonce = keccak256("deact-2");
        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(buyer2Pk, SERVICE_PRICE, nonce);
        vm.prank(buyer2);
        vm.expectRevert(AgentX402Receiver.ServiceInactive.selector);
        x402.payForService(
            agentId, SERVICE_ID, buyer2,
            0, DEADLINE, nonce,
            uint8(27), bytes32(uint256(1)), bytes32(uint256(2)),
            cv, cr, cs
        );

        // Attestation count from before the deactivation is preserved.
        (uint256 total,,) = reputation.getReputationSummary(agentId);
        assertEq(total, 1, "earlier attestation untouched");

        // Reactivate; subsequent payments succeed again.
        vm.prank(creator);
        x402.updateService(agentId, SERVICE_ID, SERVICE_PRICE, true);
        _pay(buyer2, buyer2Pk, keccak256("deact-3"));
    }

    /// @notice `registerService` must reject any token that's not on the
    ///         owner-controlled allowlist. Removing USDC blocks new
    ///         registrations but leaves the existing service operable.
    function test_Lifecycle_TokenAllowlistGatesRegistration() public {
        // Disallow USDC.
        vm.prank(owner);
        x402.setTokenAllowed(address(usdc), false);

        // Any new service registration with USDC must revert.
        bytes32 newSid = keccak256("api/chat/v2");
        vm.prank(creator);
        vm.expectRevert(AgentX402Receiver.TokenNotAllowed.selector);
        x402.registerService(agentId, newSid, address(usdc), SERVICE_PRICE);

        // Existing service still settles — allowlist gates registration only.
        _pay(buyer1, buyer1Pk, keccak256("after-disallow"));
    }

    /// @notice A non-creator caller cannot revoke a feedback they did not
    ///         create. This protects on-chain attestations from third-party
    ///         tampering.
    function test_Lifecycle_OnlyAuthorMayRevoke() public {
        _pay(buyer1, buyer1Pk, keccak256("auth-1"));
        vm.prank(buyer1);
        reputation.giveFeedback(agentId, 5, 0, "", "", "");

        // buyer2 (who never attested) tries to revoke buyer1's feedback.
        vm.prank(buyer2);
        vm.expectRevert();
        reputation.revokeFeedback(agentId);

        // Original attestation untouched.
        (uint256 total, int256 avg,) = reputation.getReputationSummary(agentId);
        assertEq(total, 1, "feedback survives third-party revoke attempt");
        assertEq(avg, int256(5), "value untouched");
    }

    /// @notice `quoteSplit` must mirror `payForService`'s on-chain math.
    ///         Off-chain UIs rely on this view to display fee breakdowns
    ///         before the user signs. Drift between view and write paths
    ///         is a UX-breaking bug class.
    function test_Lifecycle_QuoteSplitMatchesActual() public {
        (uint256 qGross, uint256 qSys, uint256 qCreator, uint256 qAgent) =
            x402.quoteSplit(agentId, SERVICE_ID);

        (uint256 eSys, uint256 eCreator, uint256 eAgent) = _expectedSplit(qGross);
        assertEq(qGross,   SERVICE_PRICE, "quote gross == price");
        assertEq(qSys,     eSys,          "quote sys == math");
        assertEq(qCreator, eCreator,      "quote creator == math");
        assertEq(qAgent,   eAgent,        "quote agent == math");

        // Now settle and confirm the actual split equals the quote.
        uint256 trezBefore   = usdc.balanceOf(treasury);
        uint256 creBefore    = usdc.balanceOf(creator);
        uint256 tbaBefore    = usdc.balanceOf(agentTBA);

        _pay(buyer1, buyer1Pk, keccak256("quote-actual"));

        assertEq(usdc.balanceOf(treasury) - trezBefore, qSys,     "actual sys cut");
        assertEq(usdc.balanceOf(creator)  - creBefore,  qCreator, "actual creator cut");
        assertEq(usdc.balanceOf(agentTBA) - tbaBefore,  qAgent,   "actual agent cut");
    }

    /// @notice Sanity check that paying for a never-registered service
    ///         (different `serviceId`) reverts as inactive without leaving
    ///         partial state.
    function test_Lifecycle_RejectsUnregisteredService() public {
        bytes32 ghostSid = keccak256("api/ghost/v1");
        bytes32 nonce    = keccak256("ghost");

        // Sign over the ghost serviceId.
        bytes32 digest = x402.hashPaymentCommitment(
            agentId, ghostSid, address(usdc), SERVICE_PRICE, nonce, DEADLINE
        );
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(buyer1Pk, digest);

        vm.prank(buyer1);
        vm.expectRevert(AgentX402Receiver.ServiceInactive.selector);
        x402.payForService(
            agentId, ghostSid, buyer1,
            0, DEADLINE, nonce,
            uint8(27), bytes32(uint256(1)), bytes32(uint256(2)),
            cv, cr, cs
        );
    }
}
