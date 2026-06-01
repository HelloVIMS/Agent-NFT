// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/AgentIdentityRegistry.sol";
import "../src/AgentX402Receiver.sol";
import "../src/AgentReputationRegistry.sol";
import {RevenueLevelHook}     from "../src/hooks/RevenueLevelHook.sol";
import {ReputationLevelHook, IERC8004Reputation} from "../src/hooks/ReputationLevelHook.sol";
import {AgentStatusHook}      from "../src/hooks/AgentStatusHook.sol";
import {EvolutionTypes}       from "../src/hooks/EvolutionTypes.sol";

/// @dev Minimal ERC-3009-style USDC mock identical in shape to the one used in
///      `AgentX402Receiver.t.sol`. Kept inline so this test file is hermetic.
contract MockUSDC is ERC20 {
    mapping(address => mapping(bytes32 => bool)) public used;
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }

    function receiveWithAuthorization(
        address from, address to, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce,
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

/// @dev Spec-compliant {IERC8004Reputation} oracle. We feed it values
///      directly so the {ReputationLevelHook} branch (it reads the oracle
///      synchronously on `onTrigger`) is exercised without dragging in the
///      legacy adapter's full surface.
contract MockReputationOracle is IERC8004Reputation {
    int128 public summary;
    uint64 public count;
    function set(uint64 c, int128 s) external { count = c; summary = s; }
    function getSummary(uint256, address[] calldata, string calldata, string calldata)
        external view returns (uint64, int128, uint8)
    {
        return (count, summary, 0);
    }
}

/// @dev Hook that always reverts on either entrypoint. Used to prove the
///      defensive try/catch in `AgentX402Receiver` and `AgentReputationRegistry`
///      cannot be griefed by a misbehaving hook.
contract BrokenHook {
    error Boom();
    function recordRevenue(uint256, uint256) external pure { revert Boom(); }
    function onTrigger(uint256, bytes32, bytes calldata) external pure returns (bytes memory) {
        revert Boom();
    }
}

contract EvolutionHookLifecycleTest is Test {
    // ─── Actors ─────────────────────────────────────────────────────────
    address owner    = address(0xA11CE);
    address creator;  uint256 creatorPk = 0xC0FFEE;
    address payer;    uint256 payerPk   = 0xBA5E;
    address treasury = address(0x7E2A);
    address attestor = address(0xA77E);

    // ─── Contracts ──────────────────────────────────────────────────────
    AgentIdentityRegistry   registry;
    AgentX402Receiver       x402;
    AgentReputationRegistry rep;
    MockUSDC                usdc;

    RevenueLevelHook        revHook;
    ReputationLevelHook     repHook;
    AgentStatusHook         statusHook;
    MockReputationOracle    oracle;

    uint256 agentId;
    bytes32 constant SID = keccak256("api/chat/v1");
    uint256 constant DEADLINE = type(uint256).max;

    function setUp() public {
        creator = vm.addr(creatorPk);
        payer   = vm.addr(payerPk);

        // ── Identity + payment receiver ──────────────────────────────
        vm.startPrank(owner);

        AgentIdentityRegistry regImpl = new AgentIdentityRegistry();
        registry = AgentIdentityRegistry(address(new ERC1967Proxy(
            address(regImpl), abi.encodeCall(AgentIdentityRegistry.initialize, ())
        )));

        AgentX402Receiver xImpl = new AgentX402Receiver();
        x402 = AgentX402Receiver(address(new ERC1967Proxy(
            address(xImpl),
            abi.encodeCall(AgentX402Receiver.initialize, (address(registry), treasury, 50))
        )));

        AgentReputationRegistry repImpl = new AgentReputationRegistry();
        rep = AgentReputationRegistry(address(new ERC1967Proxy(
            address(repImpl), abi.encodeCall(AgentReputationRegistry.initialize, (address(registry)))
        )));

        vm.stopPrank();

        usdc = new MockUSDC();
        vm.prank(owner);
        x402.setTokenAllowed(address(usdc), true);

        // Creator mints agent.
        vm.prank(creator);
        agentId = registry.registerAgent("AgentA", "ipfs://meta", 1000, address(0));
        vm.prank(creator);
        x402.registerService(agentId, SID, address(usdc), 100e6);

        usdc.mint(payer, 1_000e6);

        // ── Hooks ─────────────────────────────────────────────────────
        // Revenue thresholds: L1 @ 50 USDC, L2 @ 150 USDC, L3 @ 500 USDC (6 dp).
        uint256[] memory thresholds = new uint256[](3);
        thresholds[0] = 50e6;
        thresholds[1] = 150e6;
        thresholds[2] = 500e6;
        revHook = new RevenueLevelHook(address(x402), thresholds);

        oracle = new MockReputationOracle();
        int128[] memory tiers = new int128[](2);
        tiers[0] = 25;
        tiers[1] = 75;
        address[] memory attestors = new address[](1);
        attestors[0] = attestor;
        repHook = new ReputationLevelHook(address(oracle), attestors, tiers, "", "");

        statusHook = new AgentStatusHook(address(registry));

        // ── Wire hooks ───────────────────────────────────────────────
        vm.prank(owner);
        x402.setRevenueHook(address(revHook));
        vm.prank(owner);
        rep.setReputationHook(address(repHook));
    }

    // ─── helpers ────────────────────────────────────────────────────────
    function _signCommit(bytes32 nonce, uint256 amount) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = x402.hashPaymentCommitment(
            agentId, SID, address(usdc), amount, nonce, DEADLINE
        );
        (v, r, s) = vm.sign(payerPk, digest);
    }

    function _pay(bytes32 nonce) internal {
        uint256 amount = x402.getService(agentId, SID).price;
        (uint8 v, bytes32 r, bytes32 s) = _signCommit(nonce, amount);
        x402.payForService(
            agentId, SID, payer,
            0, DEADLINE, nonce, 0, bytes32(0), bytes32(0),
            v, r, s
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    // RevenueLevelHook wiring
    // ═════════════════════════════════════════════════════════════════════

    function test_RevenueHook_LevelsUpAcrossPayments() public {
        // 1st payment: 100 USDC → crosses L1 (50e6) only.
        _pay(bytes32(uint256(1)));
        assertEq(revHook.cumulativeRevenue(agentId), 100e6);
        assertEq(revHook.level(agentId), 1);

        // 2nd payment: another 100 USDC → total 200 → crosses L2 (150e6).
        _pay(bytes32(uint256(2)));
        assertEq(revHook.cumulativeRevenue(agentId), 200e6);
        assertEq(revHook.level(agentId), 2);

        // Bump price to 400 USDC and pay again → total 600 → crosses L3 (500e6).
        vm.prank(creator);
        x402.updateService(agentId, SID, 400e6, true);
        usdc.mint(payer, 1_000e6);
        _pay(bytes32(uint256(3)));
        assertEq(revHook.level(agentId), 3);
    }

    function test_RevenueHook_OnlyReceiverMayRecord() public {
        // Anyone other than the configured `revenueRecorder` (= the x402
        // receiver) must be rejected — this is what keeps the level system
        // honest against spoofing.
        vm.expectRevert(RevenueLevelHook.NotRevenueRecorder.selector);
        revHook.recordRevenue(agentId, 1e6);
    }

    function test_RevenueHook_NullHook_Disabled_NoCall() public {
        // Disable the hook then pay — settlement must still succeed and the
        // hook's cumulative counter must NOT advance.
        vm.prank(owner);
        x402.setRevenueHook(address(0));

        _pay(bytes32(uint256(42)));
        assertEq(revHook.cumulativeRevenue(agentId), 0);
        assertEq(revHook.level(agentId), 0);
    }

    function test_PayForService_SucceedsEvenWhenHookReverts() public {
        BrokenHook bad = new BrokenHook();
        vm.prank(owner);
        x402.setRevenueHook(address(bad));

        // Capture buyer balance before — settlement MUST go through.
        uint256 balBefore = usdc.balanceOf(payer);

        vm.expectEmit(true, false, false, false, address(x402));
        emit AgentX402Receiver.RevenueHookFailed(agentId, 100e6, hex"");
        _pay(bytes32(uint256(99)));

        // Buyer was debited the full 100 USDC despite the failing hook.
        assertEq(usdc.balanceOf(payer), balBefore - 100e6);
        assertEq(usdc.balanceOf(treasury), 500_000); // 0.5% sys cut still applied
    }

    // ═════════════════════════════════════════════════════════════════════
    // ReputationLevelHook wiring
    // ═════════════════════════════════════════════════════════════════════

    function test_ReputationHook_NotifiedOnFeedback() public {
        // Oracle returns count=1, summary=50 → tier 1 (>=25, <75).
        oracle.set(1, 50);

        // attestor (not the creator) gives feedback. The defensive call
        // path must succeed and the hook's `onTrigger` must execute without
        // reverting (we observe the TierObserved event from the hook).
        vm.expectEmit(true, false, false, true, address(repHook));
        emit ReputationLevelHook.TierObserved(agentId, 1, 50, 1);

        vm.prank(attestor);
        rep.giveFeedback(agentId, 50, 0, "quality", "", "ipfs://r1");
    }

    function test_ReputationHook_NullHook_NoCallNoRevert() public {
        vm.prank(owner);
        rep.setReputationHook(address(0));

        vm.prank(attestor);
        rep.giveFeedback(agentId, 50, 0, "quality", "", "ipfs://r1");
        // No revert; nothing to assert beyond reaching this line.
    }

    function test_GiveFeedback_SucceedsEvenWhenHookReverts() public {
        BrokenHook bad = new BrokenHook();
        vm.prank(owner);
        rep.setReputationHook(address(bad));

        vm.expectEmit(true, false, false, false, address(rep));
        emit AgentReputationRegistry.ReputationHookFailed(agentId, hex"");

        vm.prank(attestor);
        rep.giveFeedback(agentId, 50, 0, "quality", "", "ipfs://r2");

        // Feedback persisted regardless.
        (uint256 total,, ) = rep.getReputationSummary(agentId);
        assertEq(total, 1);
    }

    function test_RevokeFeedback_AlsoNotifiesHook() public {
        oracle.set(1, 80);
        vm.prank(attestor);
        rep.giveFeedback(agentId, 80, 0, "quality", "", "ipfs://r3");

        // After revoke, oracle drops to 0 → tier 0. The hook re-fires.
        oracle.set(0, 0);
        vm.expectEmit(true, false, false, true, address(repHook));
        emit ReputationLevelHook.TierObserved(agentId, 0, 0, 0);

        vm.prank(attestor);
        rep.revokeFeedback(agentId);
    }

    // ═════════════════════════════════════════════════════════════════════
    // AgentStatusHook
    // ═════════════════════════════════════════════════════════════════════

    function test_StatusHook_OwnerCanFlip() public {
        // Default is Offline (== 0).
        (AgentStatusHook.Status s0,) = statusHook.getStatus(agentId);
        assertEq(uint8(s0), uint8(AgentStatusHook.Status.Offline));

        vm.prank(creator);
        statusHook.setStatus(agentId, AgentStatusHook.Status.Running);

        assertTrue(statusHook.isRunning(agentId));
    }

    function test_StatusHook_OperatorCanFlipWhenAuthorised() public {
        address sessionKey = address(0xDEADBEEF);

        // Random caller is blocked.
        vm.prank(sessionKey);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        statusHook.setStatus(agentId, AgentStatusHook.Status.Standby);

        // Owner delegates.
        vm.prank(creator);
        statusHook.setOperator(agentId, sessionKey, true);

        vm.prank(sessionKey);
        statusHook.setStatus(agentId, AgentStatusHook.Status.Standby);
        (AgentStatusHook.Status s,) = statusHook.getStatus(agentId);
        assertEq(uint8(s), uint8(AgentStatusHook.Status.Standby));

        // Revoke and ensure the operator loses the capability.
        vm.prank(creator);
        statusHook.setOperator(agentId, sessionKey, false);
        vm.prank(sessionKey);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        statusHook.setStatus(agentId, AgentStatusHook.Status.Running);
    }

    function test_StatusHook_OperatorCannotDelegateFurther() public {
        address opA = address(0x11);
        address opB = address(0x22);

        vm.prank(creator);
        statusHook.setOperator(agentId, opA, true);

        // opA is authorised to flip status…
        vm.prank(opA);
        statusHook.setStatus(agentId, AgentStatusHook.Status.Running);

        // …but MUST NOT be allowed to authorise opB.
        vm.prank(opA);
        vm.expectRevert(AgentStatusHook.NotAuthorised.selector);
        statusHook.setOperator(agentId, opB, true);
    }

    function test_StatusHook_OnTrigger_RendersFreshSVG() public {
        vm.prank(creator);
        statusHook.setStatus(agentId, AgentStatusHook.Status.Running);

        EvolutionTypes.EvolutionResult memory r = statusHook.onTrigger(
            agentId, EvolutionTypes.TRIGGER_STATUS_CHANGE, ""
        );
        assertTrue(r.svgChanged, "svg must be marked dirty");
        assertGt(r.newSvgInline.length, 0, "svg must be non-empty");
        assertTrue(r.newStateHash != bytes32(0), "state hash must change");
    }

    function test_StatusHook_OnTrigger_WrongKind_NoOp() public {
        EvolutionTypes.EvolutionResult memory r = statusHook.onTrigger(
            agentId, EvolutionTypes.TRIGGER_SERVICE_X402, ""
        );
        assertFalse(r.svgChanged);
        assertEq(r.newSvgInline.length, 0);
    }
}
