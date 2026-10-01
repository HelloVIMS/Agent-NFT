// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IAgentIdentityRegistry.sol";
import {VimsProvenance} from "./VimsProvenance.sol";

/**
 * @title AgentRoyaltyVault
 * @notice Per-agent ERC-2981 royalty splitter. One vault per agent NFT,
 *         deployed at a deterministic CREATE2 address by AgentIdentityRegistry.
 *
 *         The vault is the receiver address returned by `royaltyInfo()`.
 *         Marketplaces (OpenSea, Blur, etc.) push secondary-sale royalty to
 *         this address; anyone may then call `release()` (ETH) or
 *         `releaseToken()` (ERC20) to push the funds to:
 *
 *           - the soulbound creator (`creatorBps` share)
 *           - the VIMS treasury    (`systemBps` share)
 *
 *         The split ratios are read live from the registry at release-time,
 *         so creator-bps changes apply automatically without redeploying.
 *
 *         Vaults are pre-computable via `IAgentIdentityRegistry.royaltyVaultAddress`
 *         and lazily deployed on first `deployRoyaltyVault` call. ETH that
 *         arrives before deployment is automatically claimable on first
 *         `release` after deployment, since CREATE2 preserves the address.
 */
contract AgentRoyaltyVault is VimsProvenance, ReentrancyGuard {
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentRoyaltyVault";
    }

    error NothingToRelease();
    error TransferFailed();
    error ZeroBpsConfig();

    IAgentIdentityRegistry public immutable registry;
    uint256 public immutable agentId;

    /// @notice Shares a payee couldn't receive at release (a reverting
    ///         receiver, a blocklisted token holder), held for them to pull.
    ///         token address(0) is ETH. They are excluded from later splits.
    mapping(address token => mapping(address payee => uint256)) public owed;
    mapping(address token => uint256) public totalOwed;

    event PaymentDeferred(address indexed token, address indexed payee, uint256 amount);
    event OwedWithdrawn(address indexed token, address indexed payee, uint256 amount);

    event Released(
        uint256 indexed agentId,
        address indexed token,        // address(0) for ETH
        uint256 totalAmount,
        address creator,
        uint256 creatorAmount,
        address treasury,
        uint256 treasuryAmount
    );

    constructor(address _registry, uint256 _agentId) {
        registry = IAgentIdentityRegistry(_registry);
        agentId  = _agentId;
    }

    receive() external payable {}

    /// @notice Push accumulated ETH to creator + treasury per current registry bps.
    /// @dev    Permissionless. A payee that can't receive (reverting
    ///         contract) is credited in `owed` instead, so one bad
    ///         receiver — a misconfigured treasury shared by every vault —
    ///         never blocks the other's payout.
    function release() external nonReentrant {
        _release(address(0));
    }

    /// @notice Push accumulated ERC20 balance to creator + treasury.
    /// @param  token ERC20 token address (USDC, WETH, ...).
    function releaseToken(IERC20 token) external nonReentrant {
        _release(address(token));
    }

    /// @notice Pull your deferred share to `to` — a payee that can't take
    ///         a push (e.g. a contract without receive) names where it goes.
    function withdrawOwed(address token, address to) external nonReentrant {
        uint256 amount = owed[token][msg.sender];
        if (amount == 0) revert NothingToRelease();
        owed[token][msg.sender] = 0;
        totalOwed[token] -= amount;
        if (!_send(token, to, amount)) revert TransferFailed();
        emit OwedWithdrawn(token, msg.sender, amount);
    }

    function _release(address token) internal {
        uint256 held = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        uint256 bal = held - totalOwed[token];
        if (bal == 0) revert NothingToRelease();

        (address creator, address treasury, uint256 creatorBps, uint256 systemBps)
            = _splitParams();

        uint256 total = creatorBps + systemBps;
        if (total == 0) revert ZeroBpsConfig();

        uint256 toTreasury = (bal * systemBps) / total;
        uint256 toCreator  = bal - toTreasury;
        // No creator on record: its share goes to the treasury rather than
        // to address(0), where ETH would burn.
        if (creator == address(0)) {
            toTreasury = bal;
            toCreator = 0;
        }

        _pay(token, treasury, toTreasury);
        _pay(token, creator, toCreator);

        emit Released(agentId, token, bal, creator, toCreator, treasury, toTreasury);
    }

    function _pay(address token, address payee, uint256 amount) internal {
        if (amount == 0) return;
        if (payee == address(0) || !_send(token, payee, amount)) {
            owed[token][payee] += amount;
            totalOwed[token] += amount;
            emit PaymentDeferred(token, payee, amount);
        }
    }

    /// @dev ETH via call, ERC20 via a low-level transfer that tolerates
    ///      tokens returning nothing; false instead of reverting.
    function _send(address token, address to, uint256 amount) internal returns (bool ok) {
        if (to == address(0)) return false;
        if (token == address(0)) {
            (ok,) = to.call{value: amount}("");
            return ok;
        }
        bytes memory ret;
        (ok, ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool))) && token.code.length > 0;
    }

    /// @notice Preview current split ratios (live from registry).
    function pendingSplit(uint256 amount) external view returns (
        uint256 creatorAmount,
        uint256 treasuryAmount
    ) {
        (, , uint256 creatorBps, uint256 systemBps) = _splitParams();
        uint256 total = creatorBps + systemBps;
        if (total == 0) return (0, 0);
        treasuryAmount = (amount * systemBps) / total;
        creatorAmount  = amount - treasuryAmount;
    }

    function _splitParams() internal view returns (
        address creator,
        address treasury,
        uint256 creatorBps,
        uint256 systemBps
    ) {
        (creator, creatorBps) = registry.getCreatorRoyalty(agentId);
        treasury  = registry.secondaryTreasury();
        systemBps = registry.secondarySystemFeeBps();
    }
}
