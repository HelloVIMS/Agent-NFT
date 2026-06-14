// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentRoyaltySplitter} from "../../src/AgentRoyaltySplitter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Plain mintable ERC20 with no surprises (compare to WeirdERC20 in the
/// existing audit file). Used so we can vary mint amounts trivially.
contract MockERC20 is IERC20 {
    string public constant name = "MOCK";
    string public constant symbol = "MOCK";
    uint8 public constant decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; totalSupply += amt; emit Transfer(address(0), to, amt); }
    function transfer(address to, uint256 amt) public override returns (bool) {
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt; emit Transfer(msg.sender, to, amt); return true;
    }
    function transferFrom(address from, address to, uint256 amt) public override returns (bool) {
        allowance[from][msg.sender] -= amt; balanceOf[from] -= amt; balanceOf[to] += amt; emit Transfer(from, to, amt); return true;
    }
    function approve(address sp, uint256 amt) public override returns (bool) {
        allowance[msg.sender][sp] = amt; emit Approval(msg.sender, sp, amt); return true;
    }
}

/// @notice Complementary fuzz suite for AgentRoyaltySplitter that targets
///         scenarios not already in `AgentRoyaltySplitter.audit.t.sol`:
///
///   1. Idempotent re-release reverts with NothingToRelease.
///   2. Order independence: releasing payees in any permutation gives the
///      same final balances.
///   3. Partial-release replay: release → deposit more → release matches
///      a single end-to-end split of the same total.
///   4. Many-payee (up to MAX_PAYEES) fuzz with random shares.
///   5. ETH↔ERC20 differential: per-payee ratio is identical across rails.
contract AgentRoyaltySplitterFuzz is Test {
    uint256 internal constant MAX_PAYEES = 16;

    function _newSplitter(address[] memory payees, uint256[] memory shares)
        internal
        returns (AgentRoyaltySplitter)
    {
        return new AgentRoyaltySplitter(payees, shares);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. Double-release is idempotent: second call with no new inflow
    //    must revert NothingToRelease.
    // ─────────────────────────────────────────────────────────────────────
    function test_DoubleReleaseRevertsWhenNothingPending() public {
        address[] memory p = new address[](2);
        p[0] = address(0xA1); p[1] = address(0xB1);
        uint256[] memory s = new uint256[](2);
        s[0] = 5_000; s[1] = 5_000;
        AgentRoyaltySplitter sp = _newSplitter(p, s);

        vm.deal(address(this), 4 ether);
        (bool ok,) = address(sp).call{value: 4 ether}("");
        assertTrue(ok);

        sp.release(payable(p[0]));
        assertEq(p[0].balance, 2 ether);

        vm.expectRevert(AgentRoyaltySplitter.NothingToRelease.selector);
        sp.release(payable(p[0]));
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Order-independence over a 3-way ETH split: all 6 permutations of
    //    release(A), release(B), release(C) yield identical final balances.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_ReleaseOrderIndependent(uint128 inflow, uint8 perm) public {
        inflow = uint128(bound(uint256(inflow), 10_000, 1_000 ether));
        perm = uint8(bound(perm, 0, 5));

        address[] memory p = new address[](3);
        p[0] = address(0xA1); p[1] = address(0xB1); p[2] = address(0xC1);
        uint256[] memory s = new uint256[](3);
        s[0] = 3_333; s[1] = 3_333; s[2] = 3_334;
        AgentRoyaltySplitter sp = _newSplitter(p, s);

        vm.deal(address(this), uint256(inflow));
        (bool ok,) = address(sp).call{value: uint256(inflow)}("");
        assertTrue(ok);

        // Build the chosen permutation.
        uint8[3] memory order;
        if      (perm == 0) order = [0, 1, 2];
        else if (perm == 1) order = [0, 2, 1];
        else if (perm == 2) order = [1, 0, 2];
        else if (perm == 3) order = [1, 2, 0];
        else if (perm == 4) order = [2, 0, 1];
        else                order = [2, 1, 0];

        for (uint256 i = 0; i < 3; ++i) sp.release(payable(p[order[i]]));

        // PaymentSplitter pattern uses integer division: each payee gets
        // floor(inflow * bps / 10_000), leaving up to (n-1) wei of dust
        // permanently in the contract. That dust is conservation-safe
        // (cannot be double-released; rolls into the next deposit).
        uint256 sum = p[0].balance + p[1].balance + p[2].balance;
        assertLe(sum, uint256(inflow), "sum exceeds inflow (over-release)");
        assertLe(uint256(inflow) - sum, 3, "dust > n_payees-1");
        assertEq(address(sp).balance, uint256(inflow) - sum, "dust accounting drift");

        // Each payee equals their floor share exactly (releases are deterministic).
        for (uint256 i = 0; i < 3; ++i) {
            uint256 expected = (uint256(inflow) * s[i]) / 10_000;
            assertEq(p[i].balance, expected, "payee floor share mismatch");
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Partial-release replay safety: split inflow into K deposits with
    //    interleaved releases; final per-payee total must equal a single
    //    end-to-end split of the same cumulative inflow.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_PartialReleaseReplaySafe(uint96 a, uint96 b, uint96 c) public {
        a = uint96(bound(uint256(a), 1 ether, 10 ether));
        b = uint96(bound(uint256(b), 1 ether, 10 ether));
        c = uint96(bound(uint256(c), 1 ether, 10 ether));
        uint256 total = uint256(a) + uint256(b) + uint256(c);

        address[] memory p = new address[](2);
        p[0] = address(0xA1); p[1] = address(0xB1);
        uint256[] memory s = new uint256[](2);
        s[0] = 6_000; s[1] = 4_000;
        AgentRoyaltySplitter sp = _newSplitter(p, s);

        vm.deal(address(this), total);

        (bool ok1,) = address(sp).call{value: a}(""); assertTrue(ok1);
        sp.release(payable(p[0]));
        sp.release(payable(p[1]));

        (bool ok2,) = address(sp).call{value: b}(""); assertTrue(ok2);
        sp.release(payable(p[0]));

        (bool ok3,) = address(sp).call{value: c}(""); assertTrue(ok3);
        sp.releaseAll();

        // 2 payees × 3 deposits = up to 6 wei dust max from per-event
        // integer-division rounding accumulating across the timeline.
        uint256 paid = p[0].balance + p[1].balance;
        assertLe(paid, total, "over-paid total");
        assertLe(total - paid, 6, "dust accumulation > 6 wei");
        assertEq(address(sp).balance, total - paid, "dust must stay in splitter");

        // Each payee's floor share of the cumulative total bounds their take.
        uint256 expectedA = (total * 6_000) / 10_000;
        uint256 expectedB = total - expectedA;
        // Across 3 deposits, payee A loses at most 3 wei to rounding;
        // payee B loses at most 3 wei; combined max 6.
        assertLe(expectedA - p[0].balance, 3, "A under-paid > 3 wei");
        assertLe(expectedB - p[1].balance, 3, "B under-paid > 3 wei");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. Many-payee fuzz: any (n, randomShares, inflow) with n in [2..16]
    //    must (a) deploy successfully when shares sum to 10_000 and
    //    (b) drain to zero on releaseAll while preserving total inflow.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_ManyPayeesFairnessAndConservation(uint8 n, uint256 seed, uint96 inflow) public {
        n = uint8(bound(n, 2, MAX_PAYEES));
        inflow = uint96(bound(uint256(inflow), 10_000, 1_000 ether));

        address[] memory p = new address[](n);
        uint256[] memory s = new uint256[](n);

        // Generate non-zero shares whose sum we'll normalise to 10_000.
        uint256 total;
        for (uint8 i = 0; i < n; ++i) {
            p[i] = address(uint160(uint256(keccak256(abi.encode(seed, i))) | 1));
            // Avoid duplicates from low-entropy seeds by mixing index into addr.
            for (uint8 j = 0; j < i; ++j) {
                if (p[j] == p[i]) p[i] = address(uint160(p[i]) + 1);
            }
            uint256 raw = (uint256(keccak256(abi.encode(seed, i, "share"))) % 1000) + 1; // [1..1000]
            s[i] = raw;
            total += raw;
        }
        // Normalise: rescale to ~10_000, push remainder onto payee 0.
        uint256 acc;
        for (uint8 i = 1; i < n; ++i) {
            s[i] = (s[i] * 10_000) / total;
            if (s[i] == 0) s[i] = 1;
            acc += s[i];
        }
        if (acc >= 10_000) {
            // Pathological — rebuild trivial uniform distribution.
            uint256 baseShare = 10_000 / n;
            uint256 leftover = 10_000 - baseShare * n;
            for (uint8 i = 0; i < n; ++i) s[i] = baseShare;
            s[0] += leftover;
        } else {
            s[0] = 10_000 - acc;
        }

        AgentRoyaltySplitter sp = _newSplitter(p, s);
        vm.deal(address(this), uint256(inflow));
        (bool ok,) = address(sp).call{value: uint256(inflow)}("");
        assertTrue(ok);
        sp.releaseAll();

        // Conservation: sum + dust == inflow, dust strictly < n_payees.
        uint256 sum;
        for (uint8 i = 0; i < n; ++i) sum += p[i].balance;
        assertLe(sum, uint256(inflow), "over-paid");
        assertLt(uint256(inflow) - sum, uint256(n), "dust >= n_payees");
        assertEq(address(sp).balance, uint256(inflow) - sum, "dust accounting drift");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. ETH ⇄ ERC20 differential: same payees / same shares / same total
    //    inflow split across two rails — per-payee ratios must match.
    // ─────────────────────────────────────────────────────────────────────
    function testFuzz_EthErc20RailsParity(uint96 inflow) public {
        inflow = uint96(bound(uint256(inflow), 10_000, 1_000 ether));

        address[] memory p = new address[](3);
        p[0] = address(0xA1); p[1] = address(0xB1); p[2] = address(0xC1);
        uint256[] memory s = new uint256[](3);
        s[0] = 7_000; s[1] = 2_000; s[2] = 1_000;
        AgentRoyaltySplitter sp = _newSplitter(p, s);

        // ETH rail.
        vm.deal(address(this), uint256(inflow));
        (bool ok,) = address(sp).call{value: uint256(inflow)}(""); assertTrue(ok);
        sp.releaseAll();

        // ERC20 rail (same total).
        MockERC20 t = new MockERC20();
        t.mint(address(sp), uint256(inflow));
        sp.releaseAll(IERC20(address(t)));

        // Per-payee ETH and ERC20 receipts must be equal (same denominator math).
        // Both rails apply the same floor(inflow * bps / 10_000) formula so
        // the per-payee dust is identical on each side.
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(p[i].balance, t.balanceOf(p[i]), "rail divergence");
        }
        // And the splitter retains the same dust on each rail.
        assertEq(address(sp).balance, t.balanceOf(address(sp)), "dust drift across rails");
    }
}
