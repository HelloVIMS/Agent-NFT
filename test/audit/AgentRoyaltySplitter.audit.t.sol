// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentRoyaltySplitter}        from "../../src/AgentRoyaltySplitter.sol";
import {AgentRoyaltySplitterFactory} from "../../src/AgentRoyaltySplitterFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20}  from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC20 with optional fee-on-transfer + optional rebase to model
///      adversarial / non-standard tokens.
contract WeirdERC20 is ERC20 {
    bool public feeOn;
    uint256 public feeBps; // bps deducted on every transfer
    constructor() ERC20("Weird", "W") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function setFee(bool on, uint256 bps) external { feeOn = on; feeBps = bps; }
    function _update(address from, address to, uint256 v) internal override {
        if (feeOn && from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (v * feeBps) / 10_000;
            super._update(from, address(this), fee);
            super._update(from, to, v - fee);
        } else {
            super._update(from, to, v);
        }
    }
}

/// @dev Reverts on receive — used to confirm pull-based isolation
///      and to demonstrate the releaseAll DoS finding.
contract RevertingPayee {
    receive() external payable { revert("nope"); }
    fallback() external payable { revert("nope"); }
}

/// @dev Reentrant attacker: on receive() tries to call back into the splitter.
contract Reenterer {
    AgentRoyaltySplitter public target;
    bool public attacked;
    constructor(AgentRoyaltySplitter t) { target = t; }
    receive() external payable {
        if (attacked) return;
        attacked = true;
        // Attempt to drain by re-entering — should compute releasable=0.
        try target.release(payable(address(this))) {} catch {}
    }
}

/// @dev Stateful handler for invariant fuzzing.
contract SplitterHandler is Test {
    AgentRoyaltySplitter public splitter;
    WeirdERC20  public token;
    address[3]  public payeeArr;

    uint256 public totalEthIn;
    uint256 public totalErc20In;

    constructor(AgentRoyaltySplitter s, WeirdERC20 t, address a, address b, address c) {
        splitter   = s;
        token      = t;
        payeeArr[0]=a; payeeArr[1]=b; payeeArr[2]=c;
    }

    function depositEth(uint96 amt) external {
        amt = uint96(bound(amt, 1, 100 ether));
        vm.deal(address(this), amt);
        (bool ok,) = address(splitter).call{value: amt}("");
        if (ok) totalEthIn += amt;
    }

    function depositErc20(uint96 amt) external {
        amt = uint96(bound(amt, 1, 1_000_000e18));
        token.mint(address(splitter), amt);
        totalErc20In += amt;
    }

    function releaseEth(uint8 idx) external {
        address acct = payeeArr[idx % 3];
        try splitter.release(payable(acct)) {} catch {}
    }

    function releaseErc20(uint8 idx) external {
        address acct = payeeArr[idx % 3];
        try splitter.release(IERC20(address(token)), acct) {} catch {}
    }

    function releaseAll() external {
        try splitter.releaseAll() {} catch {}
        try splitter.releaseAll(IERC20(address(token))) {} catch {}
    }
}

contract AgentRoyaltySplitterAudit is Test {
    AgentRoyaltySplitter splitter;
    AgentRoyaltySplitterFactory factory;
    WeirdERC20 weird;

    address constant ALICE = address(0xA11CE);
    address constant BOB   = address(0xB0B);
    address constant CAROL = address(0xCA401);

    function setUp() public {
        factory = new AgentRoyaltySplitterFactory();
        weird   = new WeirdERC20();

        address[] memory p = new address[](3);
        p[0]=ALICE; p[1]=BOB; p[2]=CAROL;
        uint256[] memory s = new uint256[](3);
        s[0]=5_000; s[1]=3_000; s[2]=2_000;
        splitter = AgentRoyaltySplitter(payable(factory.deploySplitter(p, s)));
    }

    // ──────────────────────────────────────────────────────────────────────
    // FINDING M-01 (FIXED): releaseAll used to revert the entire batch on
    // any failing payee. Fix: skip-on-failure with rollback so healthy
    // payees are paid in the same tx. Failed payee remains fully pullable.
    //
    // This regression test pins both halves of the contract:
    //   1. releaseAll does NOT revert when one payee is a contract that
    //      rejects ETH.
    //   2. The healthy payees ARE paid in that same call.
    //   3. The bad payee's accounting is rolled back (releasable still > 0)
    //      and they revert with TransferFailed when pulled individually
    //      until they fix their receiver.
    // ──────────────────────────────────────────────────────────────────────
    function test_AUDIT_M01_releaseAllSkipsRevertingPayee() public {
        address bad = address(new RevertingPayee());
        address[] memory p = new address[](3);
        p[0]=bad; p[1]=BOB; p[2]=CAROL;
        uint256[] memory s = new uint256[](3);
        s[0]=4_000; s[1]=4_000; s[2]=2_000;
        AgentRoyaltySplitter sp = AgentRoyaltySplitter(payable(factory.deploySplitter(p, s)));

        vm.deal(address(this), 10 ether);
        (bool ok,) = address(sp).call{value: 10 ether}(""); assertTrue(ok);

        // releaseAll succeeds despite the bad payee.
        sp.releaseAll();
        assertEq(BOB.balance,   4 ether);
        assertEq(CAROL.balance, 2 ether);

        // Bad payee's funds still pending (rolled back).
        assertEq(sp.releasableEth(bad), 4 ether);
        // Total released only counts the two healthy payees.
        assertEq(sp.totalEthReleased(), 6 ether);

        // Pulling individually still reverts loudly so the caller knows.
        vm.expectRevert(AgentRoyaltySplitter.TransferFailed.selector);
        sp.release(payable(bad));
    }

    // ──────────────────────────────────────────────────────────────────────
    // Reentrancy: release() must be safe under CEI (state-before-call).
    // A reentrant payee attempting to re-enter release() must compute
    // releasableEth=0 on the second call and not double-pay.
    // ──────────────────────────────────────────────────────────────────────
    function test_AUDIT_reentrancySafe_release() public {
        Reenterer atk = new Reenterer(AgentRoyaltySplitter(payable(0)));
        // Build a fresh splitter where the attacker is a payee.
        address[] memory p = new address[](2);
        p[0]=address(atk); p[1]=BOB;
        uint256[] memory s = new uint256[](2);
        s[0]=5_000; s[1]=5_000;
        AgentRoyaltySplitter sp = AgentRoyaltySplitter(payable(factory.deploySplitter(p, s)));

        // Wire the reenterer to the new splitter.
        bytes32 slot = bytes32(uint256(0)); // immutable target — set via low-level write
        vm.store(address(atk), slot, bytes32(uint256(uint160(address(sp)))));

        vm.deal(address(this), 2 ether);
        (bool ok,) = address(sp).call{value: 2 ether}(""); assertTrue(ok);

        // Attacker pulls — reentrancy attempt happens inside receive().
        sp.release(payable(address(atk)));

        // Attacker must end with exactly its 50% share, not more.
        assertEq(address(atk).balance, 1 ether);
        // Splitter still owes BOB his 50%.
        assertEq(sp.releasableEth(BOB), 1 ether);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Multi-token isolation: releases of one ERC20 must not affect the
    // accounting of another (or of native ETH).
    // ──────────────────────────────────────────────────────────────────────
    function test_AUDIT_multiTokenIsolation() public {
        WeirdERC20 t2 = new WeirdERC20();
        weird.mint(address(splitter), 1_000e18);
        t2.mint   (address(splitter), 2_000e18);
        vm.deal(address(this), 5 ether);
        (bool ok,) = address(splitter).call{value: 5 ether}(""); assertTrue(ok);

        splitter.release(IERC20(address(weird)), ALICE);
        assertEq(weird.balanceOf(ALICE),  500e18);
        assertEq(t2.balanceOf(ALICE),     0);
        assertEq(splitter.releasableErc20(IERC20(address(t2)), ALICE), 1_000e18);
        assertEq(splitter.releasableEth(ALICE), 2.5 ether);
    }

    // ──────────────────────────────────────────────────────────────────────
    // FINDING L-01: Fee-on-transfer / rebasing tokens systematically
    // under-deliver to later payees because totalErc20Released accounting
    // is based on "amount the splitter intended to send", not "amount
    // received by payee". Documented behavior: the splitter is intentionally
    // not FoT-compatible. We assert this loud-and-clear with a regression.
    // ──────────────────────────────────────────────────────────────────────
    function test_AUDIT_L01_feeOnTransferUnderDelivers() public {
        weird.setFee(true, 500); // 5% fee on every transfer
        weird.mint(address(splitter), 1_000e18);

        splitter.release(IERC20(address(weird)), ALICE); // expects 500
        // ALICE gets 500 - 25 (5% fee) = 475
        assertEq(weird.balanceOf(ALICE), 475e18);
        // Splitter accounting still believes it has paid 500 to ALICE.
        assertEq(splitter.erc20Released(IERC20(address(weird)), ALICE), 500e18);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Donation attack: sending raw ETH via selfdestruct should NOT corrupt
    // accounting. _pendingPayment uses balance + totalReleased so a forced
    // top-up just becomes pending payment for everyone pro-rata. Confirm.
    // ──────────────────────────────────────────────────────────────────────
    function test_AUDIT_donationAttackSafe() public {
        // Initial split: 4 ether legit inflow.
        vm.deal(address(this), 100 ether);
        (bool ok1,) = address(splitter).call{value: 4 ether}(""); assertTrue(ok1);
        splitter.release(payable(ALICE));
        assertEq(ALICE.balance, 2 ether);

        // Forced donation via low-level send (simulates selfdestruct push).
        // (vm.deal directly mutates balance.)
        vm.deal(address(splitter), address(splitter).balance + 6 ether);

        // Pending must reflect new balance. ALICE's share of total 10 ether
        // is 5 ether, of which 2 already paid → 3 still pending.
        assertEq(splitter.releasableEth(ALICE), 3 ether);
        splitter.release(payable(ALICE));
        assertEq(ALICE.balance, 5 ether);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Fuzz: any valid (payees, shares) triple sums correctly and never
    // pays more than the inflow.
    // ──────────────────────────────────────────────────────────────────────
    function testFuzz_AUDIT_arbitrarySplitConserves(
        uint16 sa, uint16 sb, uint96 inflow
    ) public {
        sa = uint16(bound(sa, 1, 9_998));
        sb = uint16(bound(sb, 1, 10_000 - sa - 1));
        uint16 sc = uint16(10_000 - sa - sb);
        inflow = uint96(bound(inflow, 10_000, type(uint96).max / 2));

        address[] memory p = new address[](3);
        p[0]=address(0xA1); p[1]=address(0xB1); p[2]=address(0xC1);
        uint256[] memory s = new uint256[](3);
        s[0]=sa; s[1]=sb; s[2]=sc;
        AgentRoyaltySplitter sp = new AgentRoyaltySplitter(p, s);

        weird.mint(address(sp), inflow);
        sp.releaseAll(IERC20(address(weird)));

        uint256 paid = weird.balanceOf(address(0xA1))
                     + weird.balanceOf(address(0xB1))
                     + weird.balanceOf(address(0xC1));
        assertLe(paid, inflow);
        assertGe(paid + 3, inflow); // ≤ (payees-1)+1 wei rounding dust
    }

    // ──────────────────────────────────────────────────────────────────────
    // Invariant fuzz: across arbitrary deposit / release sequences, the
    // splitter's balance + total released == total inflow (modulo dust),
    // and no payee can receive more than their bps share of total inflow.
    // ──────────────────────────────────────────────────────────────────────
    SplitterHandler handler;
    function _setUpInvariant() internal {
        handler = new SplitterHandler(splitter, weird, ALICE, BOB, CAROL);
        targetContract(address(handler));
    }
    function invariant_TotalReleasedNeverExceedsInflow() public {
        if (address(handler) == address(0)) _setUpInvariant();
        // ETH conservation
        assertLe(splitter.totalEthReleased(), handler.totalEthIn());
        // ERC20 conservation
        assertLe(splitter.totalErc20Released(IERC20(address(weird))), handler.totalErc20In());
    }
    function invariant_PayeeSharesBoundedByBps() public {
        if (address(handler) == address(0)) _setUpInvariant();
        uint256 totalIn = handler.totalEthIn();
        // Each payee's released ETH ≤ ceil(totalIn * sharesBps / 10000).
        for (uint256 i; i < 3; ++i) {
            address acct = i==0?ALICE:i==1?BOB:CAROL;
            uint256 cap  = (totalIn * splitter.sharesBps(acct)) / 10_000 + 1;
            assertLe(splitter.ethReleased(acct), cap);
        }
    }
}
