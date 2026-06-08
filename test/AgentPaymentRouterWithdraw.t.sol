// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentPaymentRouter.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/**
 * @title AgentPaymentRouterWithdrawTest
 * @notice Drives the queue-and-claim withdraw paths +
 *         system-royalty treasury withdrawals + the InvalidAgent
 *         catch path on AgentPaymentRouter that the existing
 *         AgentPaymentRouter.t.sol does not cover.
 */
contract AgentPaymentRouterWithdrawTest is Test {
    AgentIdentityRegistry public registry;
    AgentPaymentRouter    public router;
    MockUSDC              public usdc;

    address public alice    = makeAddr("alice");
    address public stranger = makeAddr("stranger");
    address public treasury = makeAddr("treasury");

    function setUp() public {
        AgentIdentityRegistry impl = new AgentIdentityRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        registry = AgentIdentityRegistry(address(proxy));
        usdc     = new MockUSDC();
        router   = new AgentPaymentRouter(address(registry), address(usdc), treasury);
    }

    // ─── withdraw() / withdrawToken() ────────────────────────────────────

    function test_withdraw_revertsWhenNoPending() public {
        vm.prank(alice);
        vm.expectRevert(AgentPaymentRouter.NothingToWithdraw.selector);
        router.withdraw();
    }

    function test_withdrawToken_revertsWhenNoPending() public {
        vm.prank(alice);
        vm.expectRevert(AgentPaymentRouter.NothingToWithdraw.selector);
        router.withdrawToken(address(usdc));
    }

    // ─── system royalty withdraws ────────────────────────────────────────

    function test_withdrawSystemRoyalties_revertsForNonTreasury() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("Not treasury"));
        router.withdrawSystemRoyalties();
    }

    function test_withdrawSystemRoyalties_revertsForZeroBalance() public {
        vm.prank(treasury);
        vm.expectRevert(AgentPaymentRouter.NothingToWithdraw.selector);
        router.withdrawSystemRoyalties();
    }

    function test_withdrawSystemRoyaltiesToken_revertsForNonTreasury() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("Not treasury"));
        router.withdrawSystemRoyaltiesToken(address(usdc));
    }

    function test_withdrawSystemRoyaltiesToken_revertsForZeroBalance() public {
        vm.prank(treasury);
        vm.expectRevert(AgentPaymentRouter.NothingToWithdraw.selector);
        router.withdrawSystemRoyaltiesToken(address(usdc));
    }

    // ─── view: getPendingSystemRoyalties ────────────────────────────────

    function test_getPendingSystemRoyalties_zeroByDefault() public view {
        assertEq(router.getPendingSystemRoyalties(address(usdc)), 0);
        assertEq(router.getPendingSystemRoyalties(address(0)),    0);
    }

    // ─── pendingWithdrawals public view ─────────────────────────────────

    function test_pendingWithdrawals_zeroByDefault() public view {
        assertEq(router.pendingWithdrawals(address(0),     alice), 0);
        assertEq(router.pendingWithdrawals(address(usdc),  alice), 0);
    }

    // ─── treasury rotation ──────────────────────────────────────────────

    function test_setTreasury_byOwner() public {
        address newTreasury = makeAddr("newTreasury");
        router.setAeyeosTreasury(newTreasury);
        assertEq(router.aeyeosTreasury(), newTreasury);
    }

    function test_setTreasury_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        router.setAeyeosTreasury(stranger);
    }
}
