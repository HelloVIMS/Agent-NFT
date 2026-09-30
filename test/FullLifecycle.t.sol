// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/AgentIdentityRegistry.sol";
import "../src/AgentX402Receiver.sol";
import "../src/AgentTBARegistry.sol";
import "../src/AgentReputationRegistry.sol";

/// @dev Minimal ERC-20 used in place of USDC for the lifecycle. Six decimals
///      to match real USDC so `parseUnits(amount, 6)` semantics carry over.
contract LifecycleUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    /// EIP-3009 stand-in: the receiver pulls from `from` (signature checks
    /// belong to real USDC; the receiver's own commitment check is real).
    function receiveWithAuthorization(address from, address to, uint256 value, uint256, uint256, bytes32, uint8, bytes32, bytes32) external {
        require(msg.sender == to, "caller must be the payee");
        _transfer(from, to, value);
    }
}

/// @notice End-to-end test that walks the *exact* sequence the marketplace
///         MCP server (`marketplace-api/src/mcp.ts`) produces calldata for:
///
///           1. agent_vims_mint_agent_tx   → AgentIdentityRegistry.mintWithFullStack
///           2. agent_vims_resolve_tba     → ERC-6551 account()        (asserted via mint result)
///           3. agent_vims_get_service     → AgentX402Receiver.getService
///           4. agent_vims_hire_agent_tx   → USDC.transfer(splitter, amount)
///           5. agent_vims_attest_delivery_tx → AgentReputationRegistry.giveFeedback
///           6. agent_vims_get_agent       → AgentReputationRegistry.getReputationSummary
///
///         If this test breaks, the MCP calldata builders are out of sync
///         with the deployed contracts.
contract FullLifecycleTest is Test {
    AgentIdentityRegistry   public identity;
    AgentX402Receiver       public x402;
    AgentTBARegistry        public tbaRegistry;
    AgentReputationRegistry public reputation;
    LifecycleUSDC           public usdc;

    address public owner   = address(0xA11CE);
    address public creator = address(0xC1EA7);  // owns the agent NFT + TBA
    uint256 public constant HIRER_PK = uint256(keccak256("full-lifecycle-hirer"));
    address public hirer;                        // pays the agent for a service
    address public treasury = address(0x7E2A);

    bytes32 public constant SERVICE_ID = keccak256("api/chat/v1");
    uint256 public constant SERVICE_PRICE = 5e6;     // 5 USDC, 6 decimals
    uint256 public constant HIRE_PAYMENT  = 5e6;     // hirer pays exactly the service price
    bytes32 public constant TBA_SALT      = bytes32(0);

    // Canonical ERC-6551 registry address used by AgentTBARegistry. We deploy
    // bytecode at this address via vm.etch so createAccount/account succeed.
    address constant ERC6551_REGISTRY = 0x000000006551c19487814612e58FE06813775758;

    function setUp() public {
        hirer = vm.addr(HIRER_PK);
        // ─── Identity ────────────────────────────────────────────────────
        vm.startPrank(owner);
        AgentIdentityRegistry idImpl = new AgentIdentityRegistry();
        ERC1967Proxy idProxy = new ERC1967Proxy(
            address(idImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        identity = AgentIdentityRegistry(address(idProxy));

        // ─── x402 receiver ───────────────────────────────────────────────
        AgentX402Receiver x402Impl = new AgentX402Receiver();
        ERC1967Proxy x402Proxy = new ERC1967Proxy(
            address(x402Impl),
            abi.encodeCall(AgentX402Receiver.initialize, (address(identity), treasury, 50))
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

        // ─── Wire trust ──────────────────────────────────────────────────
        identity.setTrustedTBARegistry(address(tbaRegistry));
        identity.setLinkedX402Receiver(address(x402));
        x402.setTrustedAgentRegistry(address(identity));

        // ─── USDC + allowlist ────────────────────────────────────────────
        usdc = new LifecycleUSDC();
        x402.setTokenAllowed(address(usdc), true);
        // Reputation v2: the receiver records settlements; only payers attest.
        reputation.setSettlementRecorder(address(x402), true);
        x402.setReputationRegistry(address(reputation));

        vm.stopPrank();

        // Fund the hirer with USDC for the hire step.
        usdc.mint(hirer, 100e6);
    }

    /// @notice Walks the complete happy-path lifecycle in a single test so
    ///         a regression in any stage fails loudly.
    function test_FullLifecycle_MintHireAttest() public {
        // ─── 1. Mint (agent_vims_mint_agent_tx) ──────────────────────────
        vm.prank(creator);
        (uint256 agentId, address tba) = identity.mintWithFullStack(
            "Pixel",                 // name
            "ipfs://pixel/agent.json", // agentURI
            500,                     // 5% creator royalty
            address(0),              // no reputation anchor override
            TBA_SALT,
            SERVICE_ID,
            address(usdc),
            SERVICE_PRICE
        );

        assertEq(identity.ownerOf(agentId), creator, "creator owns NFT");
        assertGt(uint256(uint160(tba)), 0, "TBA was created");

        // ─── 2. TBA binding (agent_vims_resolve_tba semantics) ──────────
        (, address bound,,,) = identity.agents(agentId);
        assertEq(bound, tba, "agent.tbaAddress matches");

        // ─── 3. Service lookup (agent_vims_get_service) ──────────────────
        AgentX402Receiver.Service memory svc = x402.getService(agentId, SERVICE_ID);
        assertEq(svc.token, address(usdc),  "service token");
        assertEq(svc.price, SERVICE_PRICE,  "service price");
        assertTrue(svc.active,              "service active");

        // ─── 4. Hire: a settlement through AgentX402Receiver ─────────────
        uint256 tbaBefore = usdc.balanceOf(tba);
        _hire(agentId, keccak256("hire-1"));
        (, , , uint256 agentCut) = x402.quoteSplit(agentId, SERVICE_ID);
        assertEq(usdc.balanceOf(tba) - tbaBefore, agentCut, "TBA received its share");
        assertEq(reputation.eraStats(agentId, 0).settlements, 1, "settlement is system reputation");

        // ─── 5. Attest delivery (agent_vims_attest_delivery_tx) ──────────
        vm.prank(hirer);
        reputation.giveFeedback(
            agentId,
            int128(1),       // positive (ERC-8004 tri-state)
            uint8(0),        // decimals = 0
            "quality",
            "speed",
            "ipfs://review/job-1.json"
        );

        // ─── 6. Read summary (agent_vims_get_agent reputation block) ─────
        (uint256 totalFeedbacks, int256 averageScore, uint256 lastFeedbackTime) =
            reputation.getReputationSummary(agentId);
        assertEq(totalFeedbacks, 1, "feedback recorded");
        assertEq(averageScore, int256(1), "average is positive");
        assertEq(lastFeedbackTime, block.timestamp, "timestamp set");
    }

    /// @notice The reputation contract MUST reject self-review even after a
    ///         successful mint. The MCP's `agent_vims_attest_delivery_tx`
    ///         exposes this constraint via its `note` field.
    function test_FullLifecycle_RejectsSelfReview() public {
        vm.prank(creator);
        (uint256 agentId, ) = identity.mintWithFullStack(
            "Pixel", "ipfs://pixel", 500, address(0),
            TBA_SALT, SERVICE_ID, address(usdc), SERVICE_PRICE
        );

        vm.prank(creator);
        vm.expectRevert(bytes("Cannot review own agent"));
        reputation.giveFeedback(agentId, int128(1), 0, "", "", "");
    }

    /// @notice Sending USDC to the agent outside the receiver isn't a hire:
    ///         no settlement is recorded, so there's nothing to attest to.
    function test_FullLifecycle_DirectTransferIsNotAHire() public {
        vm.prank(creator);
        (uint256 agentId, address tba) = identity.mintWithFullStack(
            "Pixel", "ipfs://pixel", 500, address(0),
            TBA_SALT, SERVICE_ID, address(usdc), SERVICE_PRICE
        );
        vm.prank(hirer);
        usdc.transfer(tba, HIRE_PAYMENT);
        vm.prank(hirer);
        vm.expectRevert(AgentReputationRegistry.NotAPayingClient.selector);
        reputation.giveFeedback(agentId, int128(1), 0, "", "", "");
    }

    /// @notice Duplicate feedback from the same client must be rejected. The
    ///         MCP `attest_delivery_tx` note documents this.
    function test_FullLifecycle_RejectsDuplicateFeedback() public {
        vm.prank(creator);
        (uint256 agentId, ) = identity.mintWithFullStack(
            "Pixel", "ipfs://pixel", 500, address(0),
            TBA_SALT, SERVICE_ID, address(usdc), SERVICE_PRICE
        );

        _hire(agentId, keccak256("dup-1"));
        vm.prank(hirer);
        reputation.giveFeedback(agentId, 1, 0, "", "", "");

        vm.prank(hirer);
        vm.expectRevert(bytes("Already gave feedback"));
        reputation.giveFeedback(agentId, 1, 0, "", "", "");
    }

    /// @notice Validates the same ABI-encoded calldata an MCP client would
    ///         submit for `agent_vims_attest_delivery_tx` lands a feedback.
    ///         This is the closest in-process check that the marketplace
    ///         worker's encoding is wire-compatible with the contract.
    function test_FullLifecycle_GiveFeedback_CalldataRoundtrip() public {
        vm.prank(creator);
        (uint256 agentId, ) = identity.mintWithFullStack(
            "Pixel", "ipfs://pixel", 500, address(0),
            TBA_SALT, SERVICE_ID, address(usdc), SERVICE_PRICE
        );

        _hire(agentId, keccak256("raw-1"));
        bytes memory data = abi.encodeWithSignature(
            "giveFeedback(uint256,int128,uint8,string,string,string)",
            agentId,
            int128(1),
            uint8(0),
            "quality",
            "speed",
            "ipfs://r/1"
        );

        vm.prank(hirer);
        (bool ok,) = address(reputation).call(data);
        assertTrue(ok, "giveFeedback via raw calldata succeeded");

        (uint256 total,,) = reputation.getReputationSummary(agentId);
        assertEq(total, 1, "feedback recorded via raw calldata");
    }

    /// @dev A real settlement: the hirer signs the receiver's payment
    ///      commitment; the receiver pulls USDC and records the hire.
    function _hire(uint256 agentId, bytes32 nonce) internal {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(
            HIRER_PK, x402.hashPaymentCommitment(agentId, SERVICE_ID, address(usdc), SERVICE_PRICE, nonce, deadline)
        );
        x402.payForService(agentId, SERVICE_ID, hirer, 0, deadline, nonce, 27, bytes32(0), bytes32(0), cv, cr, cs);
    }
}
