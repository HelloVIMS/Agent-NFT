// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentRoyaltySplitter} from "../src/AgentRoyaltySplitter.sol";
import {AgentRoyaltySplitterFactory} from "../src/AgentRoyaltySplitterFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// Reverts on receive() so we can prove pull-based releases isolate failure.
contract RevertingPayee {
    fallback() external payable { revert("nope"); }
    receive() external payable { revert("nope"); }
}

contract AgentRoyaltySplitterTest is Test {
    AgentRoyaltySplitter splitter;
    AgentRoyaltySplitterFactory factory;
    MockERC20 token;

    address constant ALICE = address(0xA11CE);
    address constant BOB   = address(0xB0B);
    address constant CAROL = address(0xCA401);

    function setUp() public {
        factory = new AgentRoyaltySplitterFactory();
        token   = new MockERC20();

        address[] memory payees = new address[](3);
        payees[0] = ALICE; payees[1] = BOB; payees[2] = CAROL;
        uint256[] memory shares = new uint256[](3);
        shares[0] = 5_000; shares[1] = 3_000; shares[2] = 2_000; // 50/30/20

        splitter = AgentRoyaltySplitter(payable(factory.deploySplitter(payees, shares)));
    }

    // ─── Constructor invariants ────────────────────────────────────────────

    function test_RejectsLengthMismatch() public {
        address[] memory p = new address[](2); p[0]=ALICE; p[1]=BOB;
        uint256[] memory s = new uint256[](1); s[0]=10_000;
        vm.expectRevert(AgentRoyaltySplitter.LengthMismatch.selector);
        new AgentRoyaltySplitter(p, s);
    }

    function test_RejectsEmpty() public {
        address[] memory p = new address[](0);
        uint256[] memory s = new uint256[](0);
        vm.expectRevert(AgentRoyaltySplitter.NoPayees.selector);
        new AgentRoyaltySplitter(p, s);
    }

    function test_RejectsTooManyPayees() public {
        address[] memory p = new address[](17);
        uint256[] memory s = new uint256[](17);
        uint256 share = uint256(10_000) / uint256(17);
        for (uint256 i; i < 17; ++i) {
            p[i] = address(uint160(i + 1));
            s[i] = share;
        }
        s[0] += 10_000 - share * 17; // make sum land on 10000
        vm.expectRevert(AgentRoyaltySplitter.TooManyPayees.selector);
        new AgentRoyaltySplitter(p, s);
    }

    function test_RejectsZeroAddress() public {
        address[] memory p = new address[](2); p[0]=address(0); p[1]=BOB;
        uint256[] memory s = new uint256[](2); s[0]=5_000; s[1]=5_000;
        vm.expectRevert(AgentRoyaltySplitter.ZeroAddress.selector);
        new AgentRoyaltySplitter(p, s);
    }

    function test_RejectsZeroShares() public {
        address[] memory p = new address[](2); p[0]=ALICE; p[1]=BOB;
        uint256[] memory s = new uint256[](2); s[0]=10_000; s[1]=0;
        vm.expectRevert(AgentRoyaltySplitter.ZeroShares.selector);
        new AgentRoyaltySplitter(p, s);
    }

    function test_RejectsDuplicate() public {
        address[] memory p = new address[](2); p[0]=ALICE; p[1]=ALICE;
        uint256[] memory s = new uint256[](2); s[0]=5_000; s[1]=5_000;
        vm.expectRevert(AgentRoyaltySplitter.DuplicatePayee.selector);
        new AgentRoyaltySplitter(p, s);
    }

    function test_RejectsBadSum() public {
        address[] memory p = new address[](2); p[0]=ALICE; p[1]=BOB;
        uint256[] memory s = new uint256[](2); s[0]=5_000; s[1]=4_999;
        vm.expectRevert(AgentRoyaltySplitter.SharesMustSumTo10000.selector);
        new AgentRoyaltySplitter(p, s);
    }

    // ─── ETH split ──────────────────────────────────────────────────────────

    function test_SplitsEth() public {
        vm.deal(address(this), 10 ether);
        (bool ok, ) = address(splitter).call{value: 10 ether}("");
        assertTrue(ok);

        assertEq(splitter.releasableEth(ALICE), 5 ether);
        assertEq(splitter.releasableEth(BOB),   3 ether);
        assertEq(splitter.releasableEth(CAROL), 2 ether);

        splitter.release(payable(ALICE));
        splitter.release(payable(BOB));
        splitter.release(payable(CAROL));

        assertEq(ALICE.balance, 5 ether);
        assertEq(BOB.balance,   3 ether);
        assertEq(CAROL.balance, 2 ether);
        assertEq(splitter.totalEthReleased(), 10 ether);
    }

    function test_StreamingEthCorrectsForLaterDeposits() public {
        vm.deal(address(this), 100 ether);
        (bool ok1, ) = address(splitter).call{value: 4 ether}(""); assertTrue(ok1);
        splitter.release(payable(ALICE));        // releases 2 ether
        assertEq(ALICE.balance, 2 ether);

        (bool ok2, ) = address(splitter).call{value: 6 ether}(""); assertTrue(ok2);
        splitter.release(payable(ALICE));        // releases 3 ether more (50% of total 10)
        assertEq(ALICE.balance, 5 ether);
        assertEq(splitter.releasableEth(ALICE), 0);
    }

    function test_RevertsOnNonPayee() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = address(splitter).call{value: 1 ether}(""); assertTrue(ok);
        vm.expectRevert(AgentRoyaltySplitter.NotAPayee.selector);
        splitter.release(payable(address(0xBEEF)));
    }

    function test_RevertsOnZeroBalance() public {
        vm.expectRevert(AgentRoyaltySplitter.NothingToRelease.selector);
        splitter.release(payable(ALICE));
    }

    function test_RevertingPayeeIsolatedByPullPattern() public {
        // Deploy a new splitter containing a reverting payee + a healthy one.
        address bad = address(new RevertingPayee());
        address[] memory p = new address[](2); p[0] = bad; p[1] = BOB;
        uint256[] memory s = new uint256[](2); s[0] = 5_000; s[1] = 5_000;
        AgentRoyaltySplitter sp = new AgentRoyaltySplitter(p, s);

        vm.deal(address(this), 2 ether);
        (bool ok, ) = address(sp).call{value: 2 ether}(""); assertTrue(ok);

        // Bob can pull even though the bad payee can't.
        sp.release(payable(BOB));
        assertEq(BOB.balance, 1 ether);

        vm.expectRevert(AgentRoyaltySplitter.TransferFailed.selector);
        sp.release(payable(bad));
    }

    function test_ReleaseAllSkipsZeroBalances() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = address(splitter).call{value: 1 ether}(""); assertTrue(ok);
        splitter.release(payable(ALICE));
        // Now ALICE has 0 releasable, BOB+CAROL still have. releaseAll must not revert.
        splitter.releaseAll();
        assertEq(BOB.balance,   0.3 ether);
        assertEq(CAROL.balance, 0.2 ether);
    }

    // ─── ERC20 split ────────────────────────────────────────────────────────

    function test_SplitsErc20() public {
        token.mint(address(splitter), 1_000e18);
        assertEq(splitter.releasableErc20(token, ALICE), 500e18);
        splitter.release(token, ALICE);
        assertEq(token.balanceOf(ALICE), 500e18);

        token.mint(address(splitter), 1_000e18); // another inflow
        assertEq(splitter.releasableErc20(token, ALICE), 500e18);
        splitter.releaseAll(token);
        assertEq(token.balanceOf(ALICE), 1_000e18);
        assertEq(token.balanceOf(BOB),   600e18);
        assertEq(token.balanceOf(CAROL), 400e18);
    }

    // ─── Fuzz invariant: sum of releases == totalReceived (modulo dust) ─────

    function testFuzz_SumOfReleasesMatchesInflow(uint96 inflow) public {
        vm.assume(inflow >= 10_000); // avoid integer-truncation noise on tiny inflows
        token.mint(address(splitter), inflow);
        splitter.releaseAll(token);
        uint256 paid = token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(CAROL);
        // Up to (payees - 1) wei dust allowed from per-payee floor division.
        assertLe(uint256(inflow) - paid, 2);
    }

    // ─── Factory ────────────────────────────────────────────────────────────

    function test_FactoryDeterministicPredict() public {
        address[] memory p = new address[](2); p[0]=ALICE; p[1]=BOB;
        uint256[] memory s = new uint256[](2); s[0]=6_000; s[1]=4_000;
        address predicted = factory.predictSplitterAddress(address(this), p, s);
        address actual    = factory.deploySplitter(p, s);
        assertEq(predicted, actual);
    }

    function test_FactoryRejectsRedeploy() public {
        address[] memory p = new address[](2); p[0]=ALICE; p[1]=BOB;
        uint256[] memory s = new uint256[](2); s[0]=6_000; s[1]=4_000;
        factory.deploySplitter(p, s);
        vm.expectRevert(AgentRoyaltySplitterFactory.AlreadyDeployed.selector);
        factory.deploySplitter(p, s);
    }

    function test_FactoryIndexesByDeployer() public {
        address user = address(0xDEAD);
        address[] memory p = new address[](2); p[0]=ALICE; p[1]=BOB;
        uint256[] memory s = new uint256[](2); s[0]=6_000; s[1]=4_000;

        vm.prank(user);
        address sp = factory.deploySplitter(p, s);

        address[] memory list = factory.splittersByDeployer(user);
        assertEq(list.length, 1);
        assertEq(list[0], sp);
        assertEq(factory.splitterDeployer(sp), user);
    }
}
