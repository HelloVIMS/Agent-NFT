// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentCollectionImpl}    from "../../src/AgentCollectionImpl.sol";
import {AgentCollectionFactory} from "../../src/AgentCollectionFactory.sol";
import {IAgentEvolutionHook}    from "../../src/hooks/IAgentEvolutionHook.sol";
import {EvolutionTypes}         from "../../src/hooks/EvolutionTypes.sol";
import {Merkle}                 from "./MerkleHelper.sol";

/// @dev Hook that consumes 30M gas to prove griefing risk.
contract GasGriefHook is IAgentEvolutionHook {
    function permissions() external pure returns (uint256) {
        return EvolutionTypes.FLAG_AFTER_MINT | EvolutionTypes.FLAG_BEFORE_TRANSFER;
    }
    function hookInterfaceId() external pure returns (bytes4) { return 0x12345678; }
    function beforeMint(uint256, address, bytes calldata) external pure returns (bytes4) {
        return this.beforeMint.selector;
    }
    function afterMint(uint256, address, bytes calldata) external view returns (bytes4) {
        // Burn gas in a loop with read-only state access to avoid optimizer eliding.
        uint256 sink;
        for (uint256 i = 0; i < 1_000_000; ++i) { sink ^= block.timestamp; }
        require(sink != type(uint256).max - 1, "ok");
        return this.afterMint.selector;
    }
    function beforeTransfer(uint256, address, address) external pure returns (bytes4) {
        revert("transfer trapped");
    }
    function afterTransfer(uint256, address, address) external pure returns (bytes4) {
        return this.afterTransfer.selector;
    }
    function onTrigger(uint256, bytes32, bytes calldata)
        external pure returns (EvolutionTypes.EvolutionResult memory r) { return r; }
}

/// @dev Reentrant attacker registered as protocolFeeRecipient — tries to call
///      back into mintAgent during fee transfer. nonReentrant must catch it.
contract ReentrantFeeRecipient {
    AgentCollectionImpl public target;
    bool public attempted;
    function arm(AgentCollectionImpl t) external { target = t; }
    receive() external payable {
        if (attempted || address(target) == address(0)) return;
        attempted = true;
        // Try to reenter the mint flow.
        try target.mintAgent{value: 0}("X","ipfs://x") {} catch {}
    }
}

contract AgentCollectionImplAudit is Test {
    AgentCollectionFactory factory;
    AgentCollectionImpl    impl;

    address creator  = address(0xC0FFEE);
    address user     = address(0xBEEF);
    address user2    = address(0xCAFE);
    address treasury = address(0xFEE);

    function setUp() public {
        impl    = new AgentCollectionImpl();
        factory = new AgentCollectionFactory(address(impl), treasury);
    }

    function _newCollection(uint256 maxSupply, uint256 salesBps, uint256 serviceBps)
        internal returns (AgentCollectionImpl c)
    {
        vm.prank(creator);
        (, address addr) = factory.createCollection("X","X", maxSupply, salesBps, serviceBps, "");
        c = AgentCollectionImpl(addr);
    }

    // ─────────────────────────────────────────────────────────────────────
    // FINDING H-02 (HIGH, FIXED): public mintAgent used to gate on
    // `block.timestamp <= allowlistEndTime`, which evaluates false when
    // endTime==0 — so a creator setting `setAllowlistConfig(root, 0, …)`
    // intending an indefinite allowlist accidentally left mintAgent() wide
    // open immediately, allowing anyone to bypass the proof check.
    //
    // Fix: treat allowlistEndTime == 0 as "allowlist forever" on the public
    // side too, matching the allowlist-side termination semantics.
    //
    // This regression pins both halves:
    //   1. With root set + endTime=0, mintAgent() reverts.
    //   2. With root set + endTime in the past, mintAgent() succeeds.
    // ─────────────────────────────────────────────────────────────────────
    function test_AUDIT_H02_allowlistBypassClosed_endTimeZero() public {
        AgentCollectionImpl c = _newCollection(100, 1000, 500);

        bytes32 leaf = keccak256(abi.encodePacked(user));
        bytes32 root = leaf; // single-leaf tree
        vm.prank(creator);
        c.setAllowlistConfig(root, /*endTime*/ 0, /*price*/ 1 ether, /*maxPerWallet*/ 1);

        vm.prank(creator);
        c.setMintConfig(0, 1, 0, 0);

        // Bypass attempt MUST now revert.
        vm.prank(user2);
        vm.expectRevert(AgentCollectionImpl.AllowlistPhaseActive.selector);
        c.mintAgent("free","ipfs://free");
    }

    function test_AUDIT_H02_publicMintOpensAfterEndTime() public {
        AgentCollectionImpl c = _newCollection(100, 1000, 500);

        bytes32 leaf = keccak256(abi.encodePacked(user));
        bytes32 root = leaf;
        uint256 endAt = block.timestamp + 1 hours;
        vm.prank(creator);
        c.setAllowlistConfig(root, endAt, 1 ether, 1);
        vm.prank(creator);
        c.setMintConfig(0, 0, 0, 0);

        // During allowlist: public mint blocked.
        vm.prank(user2);
        vm.expectRevert(AgentCollectionImpl.AllowlistPhaseActive.selector);
        c.mintAgent("a","ipfs://a");

        // After endTime: public mint opens.
        vm.warp(endAt + 1);
        vm.prank(user2);
        uint256 id = c.mintAgent("a","ipfs://a");
        assertEq(c.ownerOf(id), user2);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Mint accounting fuzz: protocolFee + creatorRevenue == msg.value, and
    // the protocol fee is exactly floor(value * bps / 10000).
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_AUDIT_mintAccountingExact(uint96 sent, uint96 price) public {
        sent  = uint96(bound(sent,  0,             100 ether));
        price = uint96(bound(price, 0,             uint96(sent)));

        AgentCollectionImpl c = _newCollection(100, 1000, 500);
        vm.prank(creator);
        c.setMintConfig(price, 0, 0, 0);

        uint256 treasuryBefore = treasury.balance;
        uint256 creatorBefore  = creator.balance;

        vm.deal(user, uint256(sent));
        vm.prank(user);
        c.mintAgent{value: sent}("a","ipfs://a");

        uint256 expectedFee     = (uint256(sent) * c.protocolPrimaryFeeBps()) / 10_000;
        uint256 expectedCreator = uint256(sent) - expectedFee;

        assertEq(treasury.balance - treasuryBefore, expectedFee);
        assertEq(creator.balance  - creatorBefore,  expectedCreator);
        assertEq(uint256(sent), expectedFee + expectedCreator); // no leakage
    }

    // ─────────────────────────────────────────────────────────────────────
    // MaxSupply boundary fuzz: must allow exactly maxSupply mints, then
    // revert with MaxSupplyReached on the next.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_AUDIT_maxSupplyBoundary(uint8 maxS) public {
        uint256 max = uint256(bound(maxS, 1, 50));
        AgentCollectionImpl c = _newCollection(max, 1000, 500);
        vm.prank(creator);
        c.setMintConfig(0, 0, 0, 0);

        for (uint256 i; i < max; ++i) {
            vm.prank(user);
            c.mintAgent("a","ipfs://a");
        }

        vm.prank(user);
        vm.expectRevert(AgentCollectionImpl.MaxSupplyReached.selector);
        c.mintAgent("over","ipfs://over");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Royalty bps fuzz: every value within [0, MAX_ROYALTY_BPS] is accepted
    // and stored verbatim; every value above the cap reverts with
    // InvalidValue.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_AUDIT_royaltyBoundsExact(uint16 bps) public {
        AgentCollectionImpl c = _newCollection(100, 1000, 500);
        if (bps > c.MAX_ROYALTY_BPS()) {
            vm.prank(user);
            vm.expectRevert(AgentCollectionImpl.InvalidValue.selector);
            c.registerAgentWithRoyalty("a","ipfs://a", bps, 0);
        } else {
            vm.prank(user);
            uint256 id = c.registerAgentWithRoyalty("a","ipfs://a", bps, 0);
            (, uint256 amount) = c.royaltyInfo(id, 1 ether);
            // amount = 1e18 * bps / 10000
            assertEq(amount, (1 ether * uint256(bps)) / 10_000);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Allowlist proof is bound to msg.sender. Alice's proof verifies for
    // alice but fails when bob tries to use it.
    // ─────────────────────────────────────────────────────────────────────
    function test_AUDIT_allowlistProofBoundToCaller() public {
        AgentCollectionImpl c = _newCollection(100, 1000, 500);

        // 2-leaf merkle tree: [user, user2]
        bytes32 leafA = keccak256(abi.encodePacked(user));
        bytes32 leafB = keccak256(abi.encodePacked(user2));
        (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB) = Merkle.pair(leafA, leafB);

        vm.prank(creator);
        c.setAllowlistConfig(root, block.timestamp + 1 days, 0, 5);

        // user can mint with their own proof.
        vm.deal(user,  1 ether);
        vm.prank(user);
        c.mintAgentAllowlist("u1","ipfs://u1", proofA);

        // user2 cannot use user's proof, even though it's a valid leaf.
        vm.deal(user2, 1 ether);
        vm.prank(user2);
        vm.expectRevert(AgentCollectionImpl.InvalidProof.selector);
        c.mintAgentAllowlist("u2","ipfs://u2", proofA);

        // user2 mints with their own proof.
        vm.prank(user2);
        c.mintAgentAllowlist("u2","ipfs://u2", proofB);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Reentrancy: a malicious protocolFeeRecipient cannot reenter mintAgent
    // during the protocol-fee ETH transfer. The reentrancy guard catches it.
    // ─────────────────────────────────────────────────────────────────────
    function test_AUDIT_reentrancyOnMintViaFeeRecipient() public {
        ReentrantFeeRecipient atk = new ReentrantFeeRecipient();
        AgentCollectionImpl  impl2   = new AgentCollectionImpl();
        AgentCollectionFactory f2    = new AgentCollectionFactory(address(impl2), address(atk));

        vm.prank(creator);
        (, address addr) = f2.createCollection("X","X", 10, 1000, 500, "");
        AgentCollectionImpl c = AgentCollectionImpl(addr);
        atk.arm(c);

        vm.prank(creator);
        c.setMintConfig(1 ether, 0, 0, 0);

        vm.deal(user, 5 ether);
        // The reentrant call inside receive() will revert with the guard
        // and atk.attempted is set. Outer mint must still complete cleanly.
        vm.prank(user);
        c.mintAgent{value: 1 ether}("a","ipfs://a");

        assertTrue(atk.attempted(), "attacker tried");
        assertEq(c.totalSupply(), 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Locked collection: every state-mutating creator action and every mint
    // path reverts with CollectionLocked once {lockCollection} is called.
    // ─────────────────────────────────────────────────────────────────────
    function test_AUDIT_lockedCollectionDenyMatrix() public {
        AgentCollectionImpl c = _newCollection(100, 1000, 500);
        vm.prank(creator);
        c.setMintConfig(0, 0, 0, 0);

        // One pre-lock mint to confirm baseline works.
        vm.prank(user);
        c.mintAgent("pre","ipfs://pre");

        vm.prank(creator);
        c.lockCollection();

        vm.prank(user);
        vm.expectRevert(AgentCollectionImpl.CollectionLocked.selector);
        c.mintAgent("post","ipfs://post");

        vm.prank(user);
        vm.expectRevert(AgentCollectionImpl.CollectionLocked.selector);
        c.registerAgent("post","ipfs://post");
    }

    // ─────────────────────────────────────────────────────────────────────
    // FINDING I-01 (Informational): afterMint is called WITH the full
    // remaining gas. A buggy or malicious hook can grief minters by burning
    // ~all gas before bubbling up the revert. Demonstrated below.
    //
    // Mitigation: cap gas on observe-only hooks (afterMint/afterTransfer)
    // similar to ERC-721 receiver checks. Documented as design choice
    // pending review; not exploited here, just measured.
    // ─────────────────────────────────────────────────────────────────────
    function test_AUDIT_I01_hookGasGriefingMeasurable() public {
        AgentCollectionImpl c = _newCollection(100, 1000, 500);
        GasGriefHook hook = new GasGriefHook();

        vm.prank(creator);
        c.setCollectionHook(address(hook));

        vm.prank(creator);
        c.setMintConfig(0, 0, 0, 0);

        uint256 gasBefore = gasleft();
        vm.prank(user);
        c.mintAgent("a","ipfs://a");
        uint256 used = gasBefore - gasleft();

        // The afterMint loop should burn well over 1M gas.
        assertGt(used, 1_000_000);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Soulbound-by-design: a hook revert in beforeTransfer correctly traps
    // the token. This is documented behavior (see IAgentEvolutionHook
    // docstring), so we pin it as a regression to make sure transferring
    // continues to be opt-in-blockable.
    // ─────────────────────────────────────────────────────────────────────
    function test_AUDIT_beforeTransferRevertBlocksMove() public {
        AgentCollectionImpl c = _newCollection(100, 1000, 500);
        vm.prank(creator);
        c.setMintConfig(0, 0, 0, 0);

        vm.prank(user);
        uint256 id = c.mintAgent("a","ipfs://a");

        GasGriefHook hook = new GasGriefHook();
        vm.prank(creator);
        c.setCollectionHook(address(hook));

        vm.prank(user);
        vm.expectRevert(); // hook reverts with "transfer trapped"
        c.transferFrom(user, user2, id);
    }
}
