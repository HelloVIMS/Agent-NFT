// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentPaymentRouter.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC","USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Refusing recipient — drives the TransferFailed branch in withdraw().
contract NoEthRecipient {
    AgentPaymentRouter public router;
    constructor(AgentPaymentRouter r) { router = r; }
    function pull() external { router.withdraw(); }
    receive() external payable { revert("no eth"); }
}

/**
 * @title AgentPaymentRouterClaimTest
 * @notice Drives the withdraw(), withdrawToken(), and
 *         withdrawSystemRoyalties{,Token}() success and failure branches by
 *         seeding pending balances directly into storage.
 */
contract AgentPaymentRouterClaimTest is Test {
    AgentIdentityRegistry public registry;
    AgentPaymentRouter    public router;
    MockUSDC              public usdc;

    address public alice    = makeAddr("alice");
    address public treasury = makeAddr("treasury");

    // Storage slots (verified via `forge inspect AgentPaymentRouter storageLayout`).
    uint256 internal constant SLOT_PENDING_SYSTEM_ROYALTIES = 4;
    uint256 internal constant SLOT_PENDING_WITHDRAWALS      = 11;

    function setUp() public {
        AgentIdentityRegistry impl = new AgentIdentityRegistry();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        registry = AgentIdentityRegistry(address(proxy));
        usdc     = new MockUSDC();
        router   = new AgentPaymentRouter(address(registry), address(usdc), treasury);
    }

    function _seedPendingEth(address recipient, uint256 amount) internal {
        // pendingWithdrawals[address(0)][recipient] = amount
        bytes32 inner = keccak256(abi.encode(address(0), uint256(SLOT_PENDING_WITHDRAWALS)));
        bytes32 slot  = keccak256(abi.encode(recipient, uint256(inner)));
        vm.store(address(router), slot, bytes32(amount));
        vm.deal(address(router), address(router).balance + amount);
    }

    function _seedPendingToken(address token, address recipient, uint256 amount) internal {
        bytes32 inner = keccak256(abi.encode(token, uint256(SLOT_PENDING_WITHDRAWALS)));
        bytes32 slot  = keccak256(abi.encode(recipient, uint256(inner)));
        vm.store(address(router), slot, bytes32(amount));
        usdc.mint(address(router), amount);
    }

    function _seedPendingSystemEth(uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(address(0), uint256(SLOT_PENDING_SYSTEM_ROYALTIES)));
        vm.store(address(router), slot, bytes32(amount));
        vm.deal(address(router), address(router).balance + amount);
    }

    function _seedPendingSystemToken(uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(address(usdc), uint256(SLOT_PENDING_SYSTEM_ROYALTIES)));
        vm.store(address(router), slot, bytes32(amount));
        usdc.mint(address(router), amount);
    }

    // ─── withdraw() ───────────────────────────────────────────────────────

    function test_withdraw_happyPath() public {
        _seedPendingEth(alice, 1 ether);
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        router.withdraw();
        assertEq(alice.balance, balBefore + 1 ether);
        assertEq(router.pendingWithdrawals(address(0), alice), 0);
    }

    function test_withdraw_revertsWhenRecipientRejectsEth() public {
        NoEthRecipient r = new NoEthRecipient(router);
        _seedPendingEth(address(r), 1 ether);
        vm.expectRevert(AgentPaymentRouter.TransferFailed.selector);
        r.pull();
    }

    // ─── withdrawToken() ──────────────────────────────────────────────────

    function test_withdrawToken_happyPath() public {
        _seedPendingToken(address(usdc), alice, 100e6);
        vm.prank(alice);
        router.withdrawToken(address(usdc));
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(router.pendingWithdrawals(address(usdc), alice), 0);
    }

    // ─── withdrawSystemRoyalties (ETH) ────────────────────────────────────

    function test_withdrawSystemRoyalties_happyPath() public {
        _seedPendingSystemEth(2 ether);
        uint256 balBefore = treasury.balance;
        vm.prank(treasury);
        router.withdrawSystemRoyalties();
        assertEq(treasury.balance, balBefore + 2 ether);
        assertEq(router.getPendingSystemRoyalties(address(0)), 0);
    }

    // ─── withdrawSystemRoyaltiesToken (ERC-20) ───────────────────────────

    function test_withdrawSystemRoyaltiesToken_happyPath() public {
        _seedPendingSystemToken(500e6);
        vm.prank(treasury);
        router.withdrawSystemRoyaltiesToken(address(usdc));
        assertEq(usdc.balanceOf(treasury), 500e6);
        assertEq(router.getPendingSystemRoyalties(address(usdc)), 0);
    }
}
