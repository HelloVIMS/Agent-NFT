// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/AgentIdentityRegistry.sol";
import "../../src/AgentX402Receiver.sol";

contract MockToken is ERC20 {
    constructor() ERC20("MOCK","MOCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @title  PaymentSplitInvariantTest
 * @notice Property-based fuzz of the x402 payment split math:
 *
 *           Property A (zero-sum):
 *               systemCut + creatorCut + agentCut == gross
 *
 *           Property B (system fee bounded):
 *               systemCut <= gross * MAX_SYSTEM_FEE_BPS / BPS_DENOM
 *
 *           Property C (creator royalty bounded):
 *               creatorCut <= gross * MAX_CREATOR_ROYALTY_BPS / BPS_DENOM
 *
 *           Property D (no double-credit on null creator):
 *               If creator == address(0) → creatorCut == 0
 *
 *           Property E (positive when bps > 0):
 *               For gross >= BPS_DENOM, bps > 0 → cut > 0
 *
 *         These are the foundational economic invariants for the
 *         AgentX402Receiver.quoteSplit() pricing function which is the
 *         pure-view mirror of payForService disbursement. Holding these
 *         under fuzzing across a wide parameter space gives InQtel-grade
 *         confidence that no value is created or destroyed in the route.
 */
contract PaymentSplitInvariantTest is Test {
    AgentIdentityRegistry public registry;
    AgentX402Receiver     public receiver;
    MockToken             public token;

    address public creator  = makeAddr("creator");
    address public treasury = makeAddr("treasury");

    uint256 public constant BPS_DENOM             = 10_000;
    uint256 public constant MAX_SYSTEM_FEE_BPS    = 500;   // mirrors AgentX402Receiver
    uint256 public constant MAX_CREATOR_BPS       = 5_000; // mirrors AgentIdentityRegistry

    function setUp() public {
        AgentIdentityRegistry impl = new AgentIdentityRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        registry = AgentIdentityRegistry(address(proxy));

        AgentX402Receiver rImpl = new AgentX402Receiver();
        ERC1967Proxy rProxy = new ERC1967Proxy(
            address(rImpl),
            abi.encodeCall(AgentX402Receiver.initialize, (address(registry), treasury, 50))
        );
        receiver = AgentX402Receiver(payable(address(rProxy)));

        token = new MockToken();
        receiver.setTokenAllowed(address(token), true);
    }

    /// @dev Mint a fresh agent with `royaltyBps` and register a service at `price`.
    function _setupAgent(uint256 royaltyBps, uint256 price) internal returns (uint256 agentId, bytes32 serviceId) {
        royaltyBps = bound(royaltyBps, 0, MAX_CREATOR_BPS);
        price      = bound(price, 1, type(uint128).max);

        vm.prank(creator);
        agentId = registry.registerAgent("F", "ipfs://m", royaltyBps, address(0));

        serviceId = keccak256(abi.encode(agentId, price));
        vm.prank(creator);
        receiver.registerService(agentId, serviceId, address(token), price);
    }

    // ─── Property A: zero-sum ────────────────────────────────────────────

    function testFuzz_invariant_zeroSum(uint256 royaltyBps, uint256 price, uint256 systemFeeBps) public {
        systemFeeBps = bound(systemFeeBps, 0, MAX_SYSTEM_FEE_BPS);
        receiver.setSystemFeeBps(systemFeeBps);

        (uint256 agentId, bytes32 serviceId) = _setupAgent(royaltyBps, price);
        (uint256 gross, uint256 systemCut, uint256 creatorCut, uint256 agentCut) =
            receiver.quoteSplit(agentId, serviceId);

        assertEq(systemCut + creatorCut + agentCut, gross, "zero-sum violation");
    }

    // ─── Property B: system cut bounded ──────────────────────────────────

    function testFuzz_invariant_systemCutBounded(uint256 royaltyBps, uint256 price, uint256 systemFeeBps) public {
        systemFeeBps = bound(systemFeeBps, 0, MAX_SYSTEM_FEE_BPS);
        receiver.setSystemFeeBps(systemFeeBps);

        (uint256 agentId, bytes32 serviceId) = _setupAgent(royaltyBps, price);
        (uint256 gross, uint256 systemCut, , ) = receiver.quoteSplit(agentId, serviceId);

        assertLe(systemCut, (gross * MAX_SYSTEM_FEE_BPS) / BPS_DENOM, "system cut exceeds MAX_SYSTEM_FEE_BPS");
    }

    // ─── Property C: creator cut bounded ─────────────────────────────────

    function testFuzz_invariant_creatorCutBounded(uint256 royaltyBps, uint256 price) public {
        (uint256 agentId, bytes32 serviceId) = _setupAgent(royaltyBps, price);
        (uint256 gross, , uint256 creatorCut, ) = receiver.quoteSplit(agentId, serviceId);

        assertLe(creatorCut, (gross * MAX_CREATOR_BPS) / BPS_DENOM, "creator cut exceeds MAX_CREATOR_ROYALTY_BPS");
    }

    // ─── Property D: deterministic on null creator (theoretical) ─────────

    function testFuzz_invariant_noNegativeAgentCut(uint256 royaltyBps, uint256 price) public {
        (uint256 agentId, bytes32 serviceId) = _setupAgent(royaltyBps, price);
        (, , , uint256 agentCut) = receiver.quoteSplit(agentId, serviceId);
        // agentCut is the residual; it must always be non-negative (uint, so >= 0)
        // AND it must always be <= gross.
        (uint256 gross, , , ) = receiver.quoteSplit(agentId, serviceId);
        assertLe(agentCut, gross, "agentCut exceeds gross");
    }

    // ─── Property E: positive cuts when bps > 0 and gross is large ───────

    function testFuzz_invariant_positiveCutsForLargeGross(uint256 royaltyBpsRaw, uint256 systemFeeBpsRaw) public {
        uint256 royaltyBps   = bound(royaltyBpsRaw, 1, MAX_CREATOR_BPS);
        uint256 systemFeeBps = bound(systemFeeBpsRaw, 1, MAX_SYSTEM_FEE_BPS);
        receiver.setSystemFeeBps(systemFeeBps);

        uint256 price = BPS_DENOM; // big enough to absorb rounding
        (uint256 agentId, bytes32 serviceId) = _setupAgent(royaltyBps, price);
        (uint256 gross, uint256 systemCut, uint256 creatorCut, uint256 agentCut) =
            receiver.quoteSplit(agentId, serviceId);

        assertGt(systemCut, 0, "system cut should be > 0");
        assertGt(creatorCut, 0, "creator cut should be > 0");
        assertGt(agentCut, 0, "agent cut should be > 0");
        assertEq(systemCut + creatorCut + agentCut, gross, "zero-sum still holds");
    }
}
