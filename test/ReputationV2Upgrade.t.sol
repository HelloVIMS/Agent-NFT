// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentReputationRegistry.sol";
import "../src/AgentX402Receiver.sol";
import "../src/AgentIdentityRegistry.sol";

interface IUSDC3009 {
    function balanceOf(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/**
 * Upgrades the live Base Sepolia reputation + receiver proxies in a fork and
 * checks nothing already on-chain moved, then runs a real USDC hire through
 * the upgraded receiver: settlement recorded, the payer attests, an outsider
 * can't, and a transfer starts the new owner's era.
 *
 *   BASE_SEPOLIA_RPC=https://sepolia.base.org forge test --match-contract ReputationV2UpgradeFork
 *
 * Skipped without BASE_SEPOLIA_RPC.
 */
contract ReputationV2UpgradeFork is Test {
    AgentReputationRegistry constant REP = AgentReputationRegistry(0x5563EE2939F6839CE82B3cA6E50AA285e8d1C316);
    AgentX402Receiver constant RECV = AgentX402Receiver(0xd180DC89270Df505F5d4B7B36e83318f330014A7);
    AgentIdentityRegistry constant ID = AgentIdentityRegistry(0xfE1ef66Ba95891d3cDf6FB83FE1444Bc3bB9FEeF);
    IUSDC3009 constant USDC = IUSDC3009(0x036CbD53842c5426634e7929541eC2318f3dCF7e);
    bytes32 constant RECEIVE_TYPEHASH = 0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;
    uint256 constant AGENT = 241;
    bytes32 SVC = keccak256("vims-e2e-reason");

    bool noFork;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) { noFork = true; return; }
        vm.createSelectFork(rpc);
    }

    function _upgrade() internal {
        address owner = REP.owner();
        vm.startPrank(owner);
        REP.upgradeToAndCall(address(new AgentReputationRegistry()), "");
        vm.stopPrank();
        vm.startPrank(RECV.owner());
        RECV.upgradeToAndCall(address(new AgentX402Receiver()), "");
        RECV.setReputationRegistry(address(REP));
        vm.stopPrank();
        vm.prank(owner);
        REP.setSettlementRecorder(address(RECV), true);
    }

    function test_UpgradePreservesStateAndRecordsRealHires() public {
        if (noFork) return;

        // ── state before ──
        address treasury = RECV.treasury();
        uint256 feeBps = RECV.systemFeeBps();
        address idReg = address(RECV.identityRegistry());
        AgentX402Receiver.Service memory svcBefore = RECV.getService(AGENT, SVC);
        // Once the live contracts are v2 this re-runs the upgrade on top
        // and checks the same flow by deltas.
        (bool already,) = address(REP).staticcall(abi.encodeWithSignature("eraCount(uint256)", AGENT));
        // Before v2 the live registry keyed attestations by agent id.
        uint256 legacyCount = already ? REP.legacyFeedbackCount(AGENT) : REP.getFeedbackCount(AGENT);
        (uint256 legacyActive, int256 legacyAvg,) = already ? (uint256(0), int256(0), uint256(0)) : REP.getReputationSummary(AGENT);
        address agentOwner = ID.ownerOf(AGENT);
        uint256 era = already ? REP.currentEra(AGENT) : 0;
        AgentReputationRegistry.EraStats memory before = already ? REP.eraStats(AGENT, era) : AgentReputationRegistry.EraStats(0, 0, 0, 0, 0, 0, 0);

        _upgrade();

        // ── nothing moved ──
        assertEq(RECV.treasury(), treasury, "treasury");
        assertEq(RECV.systemFeeBps(), feeBps, "fee");
        assertEq(address(RECV.identityRegistry()), idReg, "identity registry");
        AgentX402Receiver.Service memory svcAfter = RECV.getService(AGENT, SVC);
        assertEq(svcAfter.price, svcBefore.price, "service price");
        assertEq(svcAfter.active, svcBefore.active, "service active");
        assertEq(REP.legacyFeedbackCount(AGENT), legacyCount, "first-deployment history kept");
        if (legacyCount > 0) {
            (address c, int128 v,,,,, uint256 ts,) = REP.legacyFeedbackAt(AGENT, 0);
            assertTrue(c != address(0), "legacy client readable");
            assertGt(ts, 0, "legacy timestamp readable");
            if (legacyActive == 1) assertEq(int256(v), legacyAvg, "legacy value readable");
        }
        (uint256 n,,) = REP.getReputationSummary(AGENT);
        assertEq(n, before.feedbackCount, "upgrade leaves the current era untouched");

        // ── a real hire through the upgraded receiver ──
        uint256 buyerPk = uint256(keccak256("v2-fork-buyer"));
        address buyer = vm.addr(buyerPk);
        deal(address(USDC), buyer, svcBefore.price);
        bytes32 nonce = keccak256("v2-fork-nonce");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 authDigest = keccak256(abi.encodePacked("\x19\x01", USDC.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(RECEIVE_TYPEHASH, buyer, address(RECV), svcBefore.price, uint256(0), deadline, nonce))));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(buyerPk, authDigest);
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(buyerPk, RECV.hashPaymentCommitment(AGENT, SVC, address(USDC), svcBefore.price, nonce, deadline));
        (bool hasStats,) = address(RECV).staticcall(abi.encodeWithSignature("nftSettlements(address,uint256)", address(ID), AGENT));
        uint64 hiresBefore = hasStats ? RECV.nftSettlements(address(ID), AGENT) : 0;
        uint256 volumeBefore = hasStats ? RECV.nftVolume(address(ID), AGENT, address(USDC)) : 0;
        RECV.payForService(AGENT, SVC, buyer, 0, deadline, nonce, v1, r1, s1, cv, cr, cs);
        assertEq(USDC.balanceOf(buyer), 0, "buyer paid");
        // v3: per-NFT paid-hire stats, which the evolution hooks level by.
        assertEq(RECV.nftSettlements(address(ID), AGENT), hiresBefore + 1, "per-NFT hire recorded");
        assertEq(RECV.nftVolume(address(ID), AGENT, address(USDC)), volumeBefore + svcBefore.price, "per-NFT volume recorded");

        AgentReputationRegistry.EraStats memory st = REP.eraStats(AGENT, era);
        assertEq(st.settlements, before.settlements + 1, "settlement recorded");
        assertEq(st.volume, before.volume + uint128(svcBefore.price), "volume recorded");

        vm.prank(address(0xBAD));
        vm.expectRevert(AgentReputationRegistry.NotAPayingClient.selector);
        REP.giveFeedback(AGENT, 1, 0, "x402", "vims-e2e-reason", "");

        vm.prank(buyer);
        REP.giveFeedback(AGENT, 1, 0, "x402", "vims-e2e-reason", "eip155:84532:fork");
        (uint256 n2,,) = REP.getReputationSummary(AGENT);
        assertEq(n2, before.feedbackCount + 1);

        // ── a transfer starts the new owner's era ──
        address next = address(0x1234);
        vm.prank(agentOwner);
        ID.transferFrom(agentOwner, next, AGENT);
        (uint256 n3,,) = REP.getReputationSummary(AGENT);
        assertEq(n3, 0, "new owner, fresh history");
        assertEq(REP.eraStats(AGENT, era).feedbackCount, before.feedbackCount + 1, "previous era kept");
    }
}
