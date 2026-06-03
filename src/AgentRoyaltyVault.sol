// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

    using SafeERC20 for IERC20;

    error NothingToRelease();
    error TransferFailed();
    error ZeroBpsConfig();

    IAgentIdentityRegistry public immutable registry;
    uint256 public immutable agentId;

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
    /// @dev    Permissionless. Anyone may call.
    function release() external nonReentrant {
        uint256 bal = address(this).balance;
        if (bal == 0) revert NothingToRelease();

        (address creator, address treasury, uint256 creatorBps, uint256 systemBps)
            = _splitParams();

        uint256 total = creatorBps + systemBps;
        if (total == 0) revert ZeroBpsConfig();

        uint256 toTreasury = (bal * systemBps) / total;
        uint256 toCreator  = bal - toTreasury;

        (bool s1,) = treasury.call{value: toTreasury}("");
        if (!s1) revert TransferFailed();
        (bool s2,) = creator.call{value: toCreator}("");
        if (!s2) revert TransferFailed();

        emit Released(agentId, address(0), bal, creator, toCreator, treasury, toTreasury);
    }

    /// @notice Push accumulated ERC20 balance to creator + treasury.
    /// @param  token ERC20 token address (USDC, WETH, ...).
    function releaseToken(IERC20 token) external nonReentrant {
        uint256 bal = token.balanceOf(address(this));
        if (bal == 0) revert NothingToRelease();

        (address creator, address treasury, uint256 creatorBps, uint256 systemBps)
            = _splitParams();

        uint256 total = creatorBps + systemBps;
        if (total == 0) revert ZeroBpsConfig();

        uint256 toTreasury = (bal * systemBps) / total;
        uint256 toCreator  = bal - toTreasury;

        token.safeTransfer(treasury, toTreasury);
        token.safeTransfer(creator,  toCreator);

        emit Released(agentId, address(token), bal, creator, toCreator, treasury, toTreasury);
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
