// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VimsProvenance} from "./VimsProvenance.sol";

/**
 * @title  AgentRoyaltySplitter
 * @notice Immutable, pull-based payment splitter used as the creator-of-record
 *         for an Agent collection. Funds (ETH or any ERC20) sent to this
 *         contract are accumulated and released pro-rata to a fixed list of
 *         payees defined at construction time.
 *
 * @dev    Inspired by OpenZeppelin's PaymentSplitter but
 *         (a) bps-denominated rather than abstract shares,
 *         (b) constructor-locked (no addPayee / no admin),
 *         (c) ERC20-aware via SafeERC20.
 *
 *         Release is permissionless and idempotent. Anyone can call
 *         {release} or {release(IERC20)} to flush the per-payee balance.
 */
// Defense-in-depth: ReentrancyGuard. The contract is already CEI-correct
// (state writes precede external calls), but a future maintainer adding
// a side-effect after the call site would silently introduce a re-entrancy
// vector that audit-suite tests aren't guaranteed to catch. Guard the four
// release entry points unconditionally.
contract AgentRoyaltySplitter is VimsProvenance, ReentrancyGuard {
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentRoyaltySplitter";
    }

    using SafeERC20 for IERC20;

    // ─── Immutable state ────────────────────────────────────────────────────

    /// @dev Capped to keep gas predictable and frontend UX sane.
    uint256 public constant MAX_PAYEES   = 16;
    uint256 public constant BPS_DENOM    = 10_000;

    address[] private _payees;
    mapping(address => uint256) public sharesBps;     // payee => bps
    mapping(address => uint256) public ethReleased;   // payee => total ETH released
    mapping(IERC20 => mapping(address => uint256)) public erc20Released; // token => payee => total

    uint256 public totalEthReleased;
    mapping(IERC20 => uint256) public totalErc20Released;

    // ─── Events ─────────────────────────────────────────────────────────────

    event PayeeAdded(address indexed account, uint256 bps);
    event EthReceived(address indexed from, uint256 amount);
    event EthReleased(address indexed to,   uint256 amount);
    event EthReleaseFailed(address indexed to, uint256 amount);
    event Erc20Released(IERC20 indexed token, address indexed to, uint256 amount);

    // ─── Errors ─────────────────────────────────────────────────────────────

    error LengthMismatch();
    error NoPayees();
    error TooManyPayees();
    error ZeroAddress();
    error ZeroShares();
    error DuplicatePayee();
    error SharesMustSumTo10000();
    error NotAPayee();
    error NothingToRelease();
    error TransferFailed();

    /**
     * @param payees_     Recipient addresses. Order is preserved on-chain.
     * @param sharesBps_  Per-payee basis points. Must be the same length as
     *                    `payees_` and sum to exactly 10_000.
     */
    constructor(address[] memory payees_, uint256[] memory sharesBps_) {
        if (payees_.length != sharesBps_.length) revert LengthMismatch();
        if (payees_.length == 0)                 revert NoPayees();
        if (payees_.length > MAX_PAYEES)         revert TooManyPayees();

        uint256 total;
        for (uint256 i = 0; i < payees_.length; ++i) {
            address acct = payees_[i];
            uint256 bps  = sharesBps_[i];
            if (acct == address(0)) revert ZeroAddress();
            if (bps == 0)           revert ZeroShares();
            if (sharesBps[acct] != 0) revert DuplicatePayee();

            sharesBps[acct] = bps;
            _payees.push(acct);
            total += bps;
            emit PayeeAdded(acct, bps);
        }
        if (total != BPS_DENOM) revert SharesMustSumTo10000();
    }

    // ─── Inflows ────────────────────────────────────────────────────────────

    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }

    // ─── Views ──────────────────────────────────────────────────────────────

    function payees() external view returns (address[] memory) {
        return _payees;
    }

    function payeeCount() external view returns (uint256) {
        return _payees.length;
    }

    /// @notice Pending ETH balance for `account` based on lifetime inflow.
    function releasableEth(address account) public view returns (uint256) {
        uint256 totalReceived = address(this).balance + totalEthReleased;
        return _pendingPayment(account, totalReceived, ethReleased[account]);
    }

    /// @notice Pending ERC20 balance for `account` for `token`.
    function releasableErc20(IERC20 token, address account) public view returns (uint256) {
        uint256 totalReceived = token.balanceOf(address(this)) + totalErc20Released[token];
        return _pendingPayment(account, totalReceived, erc20Released[token][account]);
    }

    // ─── Releases (permissionless, pull-based) ──────────────────────────────

    /**
     * @notice Release pending ETH for `account`. Anyone can call.
     * @param  account A registered payee.
     */
    function release(address payable account) public nonReentrant {
        if (sharesBps[account] == 0) revert NotAPayee();

        uint256 payment = releasableEth(account);
        if (payment == 0) revert NothingToRelease();

        ethReleased[account] += payment;
        totalEthReleased     += payment;

        (bool ok, ) = account.call{value: payment}("");
        if (!ok) revert TransferFailed();
        emit EthReleased(account, payment);
    }

    /**
     * @notice Release pending `token` for `account`. Anyone can call.
     * @param  token   ERC20 token to release.
     * @param  account A registered payee.
     */
    function release(IERC20 token, address account) public nonReentrant {
        if (sharesBps[account] == 0) revert NotAPayee();

        uint256 payment = releasableErc20(token, account);
        if (payment == 0) revert NothingToRelease();

        erc20Released[token][account] += payment;
        totalErc20Released[token]     += payment;

        token.safeTransfer(account, payment);
        emit Erc20Released(token, account, payment);
    }

    /**
     * @notice Convenience: release ETH to all payees in one call. Skips payees
     *         with no balance, AND skips payees whose receive call reverts so
     *         a single misbehaving (or contract-with-no-receive) payee cannot
     *         DoS the batch for everyone else. Failed payees can still pull
     *         individually via {release(address)} once they fix their receiver
     *         (e.g., upgrade their wallet contract).
     */
    function releaseAll() external nonReentrant {
        uint256 len = _payees.length;
        for (uint256 i = 0; i < len; ++i) {
            address payable acct = payable(_payees[i]);
            uint256 payment = releasableEth(acct);
            if (payment == 0) continue;
            ethReleased[acct] += payment;
            totalEthReleased  += payment;
            (bool ok, ) = acct.call{value: payment}("");
            if (!ok) {
                // Roll back accounting for this payee so they remain pullable.
                ethReleased[acct] -= payment;
                totalEthReleased  -= payment;
                emit EthReleaseFailed(acct, payment);
                continue;
            }
            emit EthReleased(acct, payment);
        }
    }

    /**
     * @notice Convenience: release `token` to all payees in one call.
     */
    function releaseAll(IERC20 token) external nonReentrant {
        uint256 len = _payees.length;
        for (uint256 i = 0; i < len; ++i) {
            address acct = _payees[i];
            uint256 payment = releasableErc20(token, acct);
            if (payment == 0) continue;
            erc20Released[token][acct] += payment;
            totalErc20Released[token]  += payment;
            token.safeTransfer(acct, payment);
            emit Erc20Released(token, acct, payment);
        }
    }

    // ─── Internal ───────────────────────────────────────────────────────────

    function _pendingPayment(
        address account,
        uint256 totalReceived,
        uint256 alreadyReleased
    ) private view returns (uint256) {
        return (totalReceived * sharesBps[account]) / BPS_DENOM - alreadyReleased;
    }
}
