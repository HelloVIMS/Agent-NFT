// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IAgentIdentityRegistry.sol";

/**
 * @title AgentPaymentRouter
 * @notice Routes payments to Agent agents with creator + system royalty enforcement
 * @dev V1: Service royalties only (gross on x402 payments)
 * 
 * Features:
 * - Automatic creator royalty split on all service payments (dynamic 1-50%)
 * - System royalty (0.5%) for AEyeOS treasury
 * - Hardcoded infrastructure exemptions (Uniswap, Chainlink, etc.)
 * - Creator-controlled whitelist for custom operational addresses
 * - Buyers can check whitelist before purchasing an agent
 * 
 * Payment Flow:
 * 1. User pays via payAgent(agentId) or payAgentUSDC(agentId, amount)
 * 2. Contract deducts system royalty (0.5%) for AEyeOS
 * 3. Contract queries creator royalty from IdentityRegistry
 * 4. Creator receives their % of remainder
 * 5. Rest goes to agent's TBA (or owner if no TBA)
 * 
 * Exemption Flow (for whitelisted operational payments):
 * 1. Whitelisted address pays via payAgentExempt(agentId)
 * 2. No royalty taken - full amount to TBA/owner
 * 3. Only works if sender is whitelisted by creator
 */
import {VimsProvenance} from "./VimsProvenance.sol";

contract AgentPaymentRouter is ReentrancyGuard, Ownable, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentPaymentRouter";
    }

    using SafeERC20 for IERC20;

    IAgentIdentityRegistry public immutable identityRegistry;
    
    // Common payment tokens
    address public immutable USDC;
    
    // ============ SYSTEM ROYALTY (AEyeOS) ============
    
    // System royalty for AEyeOS platform sustainability
    uint256 public constant SYSTEM_ROYALTY_BPS = 50;  // 0.5%
    address public aeyeosTreasury;
    uint256 public totalSystemRoyalties;  // Total collected for AEyeOS
    mapping(address => uint256) public pendingSystemRoyalties;  // token => pending amount
    
    // ============ WHITELIST SYSTEM ============
    
    // Hardcoded infrastructure addresses (exempt from royalties globally)
    // These are major DeFi protocols that agents interact with operationally
    mapping(address => bool) public infrastructureWhitelist;
    
    // Creator-controlled whitelist per agent
    // Only the soulbound creator can add/remove addresses
    // Buyers can check this before purchasing to understand operational exemptions
    mapping(uint256 => mapping(address => bool)) public creatorWhitelist;
    mapping(uint256 => address[]) internal _creatorWhitelistArray; // For enumeration
    
    // ============ GAS THRESHOLD SYSTEM ============
    
    // Minimum amounts for auto-transfer (below this, royalties accumulate)
    // This prevents gas costs from exceeding small royalty payments
    // 
    // Recommended thresholds by chain:
    // - Ethereum L1: 0.01 ETH (~$25), $10 USDC - high gas costs
    // - Base/L2s:    0.0001 ETH (~$0.25), $0.10 USDC - ~100x cheaper gas
    // - Arbitrum:    0.0001 ETH, $0.10 USDC
    // - Optimism:    0.0001 ETH, $0.10 USDC
    //
    // Defaults set for Base L2 (where Agent deploys)
    uint256 public minAutoTransferETH = 0.0001 ether;   // ~$0.25 at $2500/ETH (Base L2)
    uint256 public minAutoTransferUSDC = 100000;        // $0.10 USDC (Base L2)
    
    // Pending royalties for creators (accumulated when below threshold)
    // creator => token => amount
    mapping(address => mapping(address => uint256)) public pendingRoyalties;
    
    // ============ PAYMENT TRACKING ============
    
    // Accumulated balances for withdrawal (gas optimization for failed transfers)
    mapping(address => mapping(address => uint256)) public pendingWithdrawals; // token => recipient => amount
    
    // Stats
    mapping(uint256 => uint256) public totalPaidToAgent;      // agentId => total received
    mapping(uint256 => uint256) public totalCreatorEarnings;  // agentId => total creator earnings
    mapping(uint256 => uint256) public totalExemptPayments;   // agentId => total exempt (no royalty)
    mapping(address => uint256) public creatorLifetimeEarnings; // creator => total lifetime earnings
    
    event PaymentReceived(
        uint256 indexed agentId,
        address indexed payer,
        address indexed token,  // address(0) for ETH
        uint256 amount,
        bool exempt
    );
    
    event PaymentSplit(
        uint256 indexed agentId,
        address indexed creator,
        address indexed recipient,  // TBA or owner
        uint256 creatorAmount,
        uint256 recipientAmount
    );
    
    event ExemptPayment(
        uint256 indexed agentId,
        address indexed payer,
        address indexed token,
        uint256 amount,
        string reason  // "infrastructure" or "creator_whitelist"
    );
    
    event WhitelistUpdated(
        uint256 indexed agentId,
        address indexed addr,
        bool added,
        address indexed updatedBy
    );
    
    event InfrastructureWhitelistUpdated(
        address indexed addr,
        bool added
    );
    
    event Withdrawal(
        address indexed recipient,
        address indexed token,
        uint256 amount
    );
    
    event RoyaltyAccumulated(
        address indexed creator,
        address indexed token,
        uint256 amount,
        uint256 totalPending
    );
    
    event RoyaltyWithdrawn(
        address indexed creator,
        address indexed token,
        uint256 amount
    );
    
    event SystemRoyaltyCollected(
        uint256 indexed agentId,
        address indexed token,
        uint256 amount
    );
    
    event SystemRoyaltyWithdrawn(
        address indexed treasury,
        address indexed token,
        uint256 amount
    );
    
    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );
    
    event ThresholdUpdated(
        address indexed token,
        uint256 oldThreshold,
        uint256 newThreshold
    );
    
    event TransferQueued(
        address indexed recipient,
        address indexed token,
        uint256 amount,
        string reason
    );
    
    // EmergencyWithdrawal event removed - see audit notes in EMERGENCY RECOVERY section
    
    error InvalidAgent();
    error InactiveAgent();
    error ZeroPayment();
    error TransferFailed();
    error NothingToWithdraw();
    error NotCreator();
    error NotExempt();
    error AlreadyWhitelisted();
    error NotWhitelisted();
    // Subaccount routing
    error SubaccountNotPermitted();
    error InvalidThreshold();
    
    constructor(address _identityRegistry, address _usdc, address _treasury) Ownable(msg.sender) {
        identityRegistry = IAgentIdentityRegistry(_identityRegistry);
        USDC = _usdc;
        aeyeosTreasury = _treasury;
        
        // Initialize hardcoded infrastructure whitelist
        // These are Base Sepolia addresses - update for mainnet
        _initInfrastructureWhitelist();
    }
    
    function _initInfrastructureWhitelist() internal {
        // Base Mainnet addresses (also work on Sepolia for testing)
        // Uniswap V3
        infrastructureWhitelist[0x2626664c2603336E57B271c5C0b26F421741e481] = true; // SwapRouter02
        infrastructureWhitelist[0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1] = true; // UniversalRouter
        
        // Chainlink
        infrastructureWhitelist[0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70] = true; // Price Feed Registry
        
        // WETH
        infrastructureWhitelist[0x4200000000000000000000000000000000000006] = true; // WETH on Base
        
        // Common stablecoins (transfers from these are likely refunds/operational)
        infrastructureWhitelist[0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = true; // USDC on Base
        infrastructureWhitelist[0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb] = true; // DAI on Base
    }
    
    // ============ INFRASTRUCTURE WHITELIST (Owner only) ============
    
    /**
     * @notice Add address to infrastructure whitelist (owner only)
     * @dev Use for adding new major protocols
     */
    function addInfrastructure(address addr) external onlyOwner {
        infrastructureWhitelist[addr] = true;
        emit InfrastructureWhitelistUpdated(addr, true);
    }
    
    /**
     * @notice Remove address from infrastructure whitelist (owner only)
     */
    function removeInfrastructure(address addr) external onlyOwner {
        infrastructureWhitelist[addr] = false;
        emit InfrastructureWhitelistUpdated(addr, false);
    }
    
    // ============ CREATOR WHITELIST ============
    
    /**
     * @notice Add address to creator whitelist for an agent
     * @dev Only the soulbound creator can call this
     * @param agentId The agent token ID
     * @param addr The address to whitelist
     */
    function addToCreatorWhitelist(uint256 agentId, address addr) external {
        (address creator,) = identityRegistry.getCreatorRoyalty(agentId);
        if (msg.sender != creator) revert NotCreator();
        if (creatorWhitelist[agentId][addr]) revert AlreadyWhitelisted();
        
        creatorWhitelist[agentId][addr] = true;
        _creatorWhitelistArray[agentId].push(addr);
        
        emit WhitelistUpdated(agentId, addr, true, msg.sender);
    }
    
    /**
     * @notice Remove address from creator whitelist for an agent
     * @dev Only the soulbound creator can call this
     */
    function removeFromCreatorWhitelist(uint256 agentId, address addr) external {
        (address creator,) = identityRegistry.getCreatorRoyalty(agentId);
        if (msg.sender != creator) revert NotCreator();
        if (!creatorWhitelist[agentId][addr]) revert NotWhitelisted();
        
        creatorWhitelist[agentId][addr] = false;
        // Note: We don't remove from array to save gas, just mark as false
        
        emit WhitelistUpdated(agentId, addr, false, msg.sender);
    }
    
    /**
     * @notice Get all whitelisted addresses for an agent
     * @dev Buyers can call this before purchasing to see operational exemptions
     */
    function getCreatorWhitelist(uint256 agentId) external view returns (address[] memory) {
        address[] memory all = _creatorWhitelistArray[agentId];
        
        // Count active entries
        uint256 count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (creatorWhitelist[agentId][all[i]]) count++;
        }
        
        // Build result array
        address[] memory result = new address[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (creatorWhitelist[agentId][all[i]]) {
                result[idx++] = all[i];
            }
        }
        
        return result;
    }
    
    /**
     * @notice Check if an address is exempt from royalties for an agent
     */
    function isExempt(uint256 agentId, address addr) public view returns (bool) {
        return infrastructureWhitelist[addr] || creatorWhitelist[agentId][addr];
    }
    
    /**
     * @notice Pay an agent in ETH with automatic creator royalty split
     * @param agentId The Agent agent token ID
     */
    function payAgent(uint256 agentId) external payable nonReentrant {
        if (msg.value == 0) revert ZeroPayment();
        
        _processPayment(agentId, address(0), msg.value);
    }
    
    /**
     * @notice Pay an agent in USDC with automatic creator royalty split
     * @param agentId The Agent agent token ID
     * @param amount The USDC amount (6 decimals)
     */
    function payAgentUSDC(uint256 agentId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroPayment();
        
        // Transfer USDC from sender
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        
        _processPayment(agentId, USDC, amount);
    }

    // ============ Pay-to-Subaccount ============

    /**
     * @notice Pay an agent in ETH but route the recipient share to a
     *         specific registered subaccount (which must hold `PERM_PAY` for
     *         this agent) instead of the primary TBA. Creator + system cuts
     *         are unchanged. Enables 1:Many revenue routing: e.g. a
     *         sub-TBA dedicated to x402 receipts isolated from the main
     *         operating TBA.
     */
    function payAgentTo(uint256 agentId, address subaccount) external payable nonReentrant {
        if (msg.value == 0) revert ZeroPayment();
        _assertSubaccountPermitted(agentId, subaccount);
        _processPayment(agentId, address(0), msg.value, subaccount);
    }

    /**
     * @notice USDC variant of `payAgentTo`.
     */
    function payAgentToUSDC(uint256 agentId, uint256 amount, address subaccount) external nonReentrant {
        if (amount == 0) revert ZeroPayment();
        _assertSubaccountPermitted(agentId, subaccount);
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        _processPayment(agentId, USDC, amount, subaccount);
    }

    /**
     * @dev Verify `subaccount` is bound to `agentId` and holds `PERM_PAY`.
     *      Reverts otherwise. The IdentityRegistry's `agentIdOf` already
     *      collapses primary TBA + subaccounts into one resolution, and
     *      `hasPermission` returns true for the primary TBA implicitly.
     */
    function _assertSubaccountPermitted(uint256 agentId, address subaccount) internal view {
        (uint256 boundId, bool bound,,,) = identityRegistry.agentIdOf(subaccount);
        if (!bound || boundId != agentId) revert SubaccountNotPermitted();
        if (!identityRegistry.hasPermission(subaccount, identityRegistry.PERM_PAY())) {
            revert SubaccountNotPermitted();
        }
    }

    /**
     * @dev Internal payment processing with system + creator royalty split
     * Split order: System (0.5%) -> Creator (1-50% of remainder) -> Recipient (rest)
     */
    function _processPayment(uint256 agentId, address token, uint256 amount) internal {
        _processPayment(agentId, token, amount, address(0));
    }

    /**
     * @dev Routed variant: if `recipientOverride != address(0)`, recipient
     *      cut goes there instead of the primary TBA. Caller is responsible
     *      for verifying the override is permitted (see
     *      `_assertSubaccountPermitted`).
     */
    function _processPayment(
        uint256 agentId,
        address token,
        uint256 amount,
        address recipientOverride
    ) internal {
        // Validate and get agent info
        (address owner, address recipient, address creator, uint256 royaltyBps) = _validateAndGetAgentInfo(agentId);
        if (recipientOverride != address(0)) recipient = recipientOverride;
        
        // Calculate splits
        uint256 systemCut = (amount * SYSTEM_ROYALTY_BPS) / 10000;
        uint256 afterSystem = amount - systemCut;
        uint256 creatorCut = (afterSystem * royaltyBps) / 10000;
        uint256 recipientCut = afterSystem - creatorCut;
        
        // Update stats
        totalPaidToAgent[agentId] += amount;
        totalCreatorEarnings[agentId] += creatorCut;
        creatorLifetimeEarnings[creator] += creatorCut;
        totalSystemRoyalties += systemCut;
        
        // Accumulate system royalty (treasury withdraws in batches)
        pendingSystemRoyalties[token] += systemCut;
        emit SystemRoyaltyCollected(agentId, token, systemCut);
        
        // Process creator royalty
        _processCreatorRoyalty(creator, token, creatorCut);
        
        // Transfer recipient cut
        _transferToRecipient(recipient, token, recipientCut);
        
        emit PaymentReceived(agentId, msg.sender, token, amount, false);
        emit PaymentSplit(agentId, creator, recipient, creatorCut, recipientCut);
    }
    
    /**
     * @dev Validate agent and return all needed addresses
     */
    function _validateAndGetAgentInfo(uint256 agentId) internal view returns (
        address owner,
        address recipient,
        address creator,
        uint256 royaltyBps
    ) {
        try identityRegistry.ownerOf(agentId) returns (address _owner) {
            owner = _owner;
        } catch {
            revert InvalidAgent();
        }
        if (owner == address(0)) revert InvalidAgent();
        
        (, address tbaAddress,, bool active,) = identityRegistry.agents(agentId);
        if (!active) revert InactiveAgent();

        recipient = tbaAddress != address(0) ? tbaAddress : owner;
        (creator, royaltyBps) = identityRegistry.getCreatorRoyalty(agentId);
    }
    
    /**
     * @dev Process creator royalty with threshold logic
     */
    function _processCreatorRoyalty(address creator, address token, uint256 creatorCut) internal {
        uint256 threshold = token == address(0) ? minAutoTransferETH : minAutoTransferUSDC;
        uint256 pendingAmount = pendingRoyalties[creator][token] + creatorCut;
        
        if (pendingAmount >= threshold) {
            pendingRoyalties[creator][token] = 0;
            if (token == address(0)) {
                (bool success,) = creator.call{value: pendingAmount}("");
                if (!success) {
                    pendingWithdrawals[address(0)][creator] += pendingAmount;
                    emit TransferQueued(creator, address(0), pendingAmount, "creator_royalty");
                }
            } else {
                IERC20(token).safeTransfer(creator, pendingAmount);
            }
        } else {
            pendingRoyalties[creator][token] = pendingAmount;
            emit RoyaltyAccumulated(creator, token, creatorCut, pendingAmount);
        }
    }
    
    /**
     * @dev Transfer to recipient (TBA or owner)
     */
    function _transferToRecipient(address recipient, address token, uint256 recipientCut) internal {
        if (token == address(0)) {
            (bool success,) = recipient.call{value: recipientCut}("");
            if (!success) {
                pendingWithdrawals[address(0)][recipient] += recipientCut;
                emit TransferQueued(recipient, address(0), recipientCut, "recipient_payment");
            }
        } else {
            IERC20(token).safeTransfer(recipient, recipientCut);
        }
    }
    
    // ============ EXEMPT PAYMENTS (Whitelisted addresses only) ============
    
    /**
     * @notice Pay an agent in ETH WITHOUT royalty (for whitelisted operational addresses)
     * @dev Only callable by infrastructure or creator-whitelisted addresses
     * @param agentId The Agent agent token ID
     */
    function payAgentExempt(uint256 agentId) external payable nonReentrant {
        if (msg.value == 0) revert ZeroPayment();
        if (!isExempt(agentId, msg.sender)) revert NotExempt();
        
        _processExemptPayment(agentId, address(0), msg.value);
    }
    
    /**
     * @notice Pay an agent in USDC WITHOUT royalty (for whitelisted operational addresses)
     * @dev Only callable by infrastructure or creator-whitelisted addresses
     */
    function payAgentExemptUSDC(uint256 agentId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroPayment();
        if (!isExempt(agentId, msg.sender)) revert NotExempt();
        
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        _processExemptPayment(agentId, USDC, amount);
    }
    
    /**
     * @dev Internal exempt payment processing - no royalty split
     */
    function _processExemptPayment(uint256 agentId, address token, uint256 amount) internal {
        // Validate agent exists
        address owner;
        try identityRegistry.ownerOf(agentId) returns (address _owner) {
            owner = _owner;
        } catch {
            revert InvalidAgent();
        }
        
        if (owner == address(0)) revert InvalidAgent();
        
        // Check agent is active
        (, address tbaAddress,, bool active,) = identityRegistry.agents(agentId);
        if (!active) revert InactiveAgent();
        
        // Determine recipient (TBA if exists, otherwise owner)
        address recipient = tbaAddress != address(0) ? tbaAddress : owner;
        
        // Update stats (no creator earnings for exempt payments)
        totalPaidToAgent[agentId] += amount;
        totalExemptPayments[agentId] += amount;
        
        // Determine reason for exemption
        string memory reason = infrastructureWhitelist[msg.sender] ? "infrastructure" : "creator_whitelist";
        
        // Transfer full amount to recipient (no split)
        if (token == address(0)) {
            (bool success,) = recipient.call{value: amount}("");
            if (!success) {
                pendingWithdrawals[address(0)][recipient] += amount;
                emit TransferQueued(recipient, address(0), amount, "exempt_payment");
            }
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
        
        emit PaymentReceived(agentId, msg.sender, token, amount, true);
        emit ExemptPayment(agentId, msg.sender, token, amount, reason);
    }
    
    /**
     * @notice Withdraw pending ETH (for failed direct transfers)
     */
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[address(0)][msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        
        pendingWithdrawals[address(0)][msg.sender] = 0;
        
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit Withdrawal(msg.sender, address(0), amount);
    }
    
    /**
     * @notice Withdraw pending ERC20 tokens (for failed direct transfers)
     */
    function withdrawToken(address token) external nonReentrant {
        uint256 amount = pendingWithdrawals[token][msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        
        pendingWithdrawals[token][msg.sender] = 0;
        
        IERC20(token).safeTransfer(msg.sender, amount);
        
        emit Withdrawal(msg.sender, token, amount);
    }
    
    /**
     * @notice Preview the payment split for an agent (includes system royalty)
     * @param agentId The Agent agent token ID
     * @param amount The payment amount
     * @return systemCut Amount going to AEyeOS treasury (0.5%)
     * @return creator The creator address
     * @return creatorCut Amount going to creator
     * @return recipient The TBA or owner address
     * @return recipientCut Amount going to recipient
     */
    function previewSplit(uint256 agentId, uint256 amount) external view returns (
        uint256 systemCut,
        address creator,
        uint256 creatorCut,
        address recipient,
        uint256 recipientCut
    ) {
        // System royalty first (0.5% of gross)
        systemCut = (amount * SYSTEM_ROYALTY_BPS) / 10000;
        uint256 afterSystem = amount - systemCut;
        
        // Creator royalty from remainder
        uint256 royaltyBps;
        (creator, royaltyBps) = identityRegistry.getCreatorRoyalty(agentId);
        
        creatorCut = (afterSystem * royaltyBps) / 10000;
        recipientCut = afterSystem - creatorCut;
        
        (, address tbaAddress,,,) = identityRegistry.agents(agentId);
        recipient = tbaAddress != address(0) ? tbaAddress : identityRegistry.ownerOf(agentId);
    }
    
    /**
     * @notice Get agent payment stats
     */
    function getAgentStats(uint256 agentId) external view returns (
        uint256 totalReceived,
        uint256 creatorEarnings,
        address creator,
        uint256 royaltyBps
    ) {
        totalReceived = totalPaidToAgent[agentId];
        creatorEarnings = totalCreatorEarnings[agentId];
        (creator, royaltyBps) = identityRegistry.getCreatorRoyalty(agentId);
    }
    
    // ============ ROYALTY WITHDRAWAL (for accumulated royalties below threshold) ============
    
    /**
     * @notice Withdraw accumulated ETH royalties (for creators)
     * @dev Allows creators to withdraw royalties that were below auto-transfer threshold
     */
    function withdrawRoyalties() external nonReentrant {
        uint256 amount = pendingRoyalties[msg.sender][address(0)];
        if (amount == 0) revert NothingToWithdraw();
        
        pendingRoyalties[msg.sender][address(0)] = 0;
        
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit RoyaltyWithdrawn(msg.sender, address(0), amount);
    }
    
    /**
     * @notice Withdraw accumulated ERC20 royalties (for creators)
     * @param token The token address to withdraw
     */
    function withdrawRoyaltiesToken(address token) external nonReentrant {
        uint256 amount = pendingRoyalties[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();
        
        pendingRoyalties[msg.sender][token] = 0;
        
        IERC20(token).safeTransfer(msg.sender, amount);
        
        emit RoyaltyWithdrawn(msg.sender, token, amount);
    }
    
    /**
     * @notice Get pending royalties for a creator
     * @param creator The creator address
     * @param token The token address (address(0) for ETH)
     */
    function getPendingRoyalties(address creator, address token) external view returns (uint256) {
        return pendingRoyalties[creator][token];
    }
    
    // ============ SYSTEM ROYALTY MANAGEMENT (Owner/Treasury only) ============
    
    /**
     * @notice Withdraw accumulated system royalties (ETH) to treasury
     * @dev Only treasury address can withdraw
     */
    function withdrawSystemRoyalties() external nonReentrant {
        require(msg.sender == aeyeosTreasury, "Not treasury");
        uint256 amount = pendingSystemRoyalties[address(0)];
        if (amount == 0) revert NothingToWithdraw();
        
        pendingSystemRoyalties[address(0)] = 0;
        
        (bool success,) = aeyeosTreasury.call{value: amount}("");
        if (!success) revert TransferFailed();
        
        emit SystemRoyaltyWithdrawn(aeyeosTreasury, address(0), amount);
    }
    
    /**
     * @notice Withdraw accumulated system royalties (ERC20) to treasury
     * @dev Only treasury address can withdraw
     * @param token The token address to withdraw
     */
    function withdrawSystemRoyaltiesToken(address token) external nonReentrant {
        require(msg.sender == aeyeosTreasury, "Not treasury");
        uint256 amount = pendingSystemRoyalties[token];
        if (amount == 0) revert NothingToWithdraw();
        
        pendingSystemRoyalties[token] = 0;
        
        IERC20(token).safeTransfer(aeyeosTreasury, amount);
        
        emit SystemRoyaltyWithdrawn(aeyeosTreasury, token, amount);
    }
    
    /**
     * @notice Update the AEyeOS treasury address
     * @dev Only owner can update
     * @param newTreasury The new treasury address
     */
    function setAeyeosTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury");
        address oldTreasury = aeyeosTreasury;
        aeyeosTreasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }
    
    /**
     * @notice Get pending system royalties for a token
     * @param token The token address (address(0) for ETH)
     */
    function getPendingSystemRoyalties(address token) external view returns (uint256) {
        return pendingSystemRoyalties[token];
    }
    
    // ============ THRESHOLD MANAGEMENT (Owner only) ============
    
    /**
     * @notice Update the minimum auto-transfer threshold for ETH
     * @dev Only owner can update. Must be > 0 to prevent dust attacks
     */
    function setMinAutoTransferETH(uint256 newThreshold) external onlyOwner {
        if (newThreshold == 0) revert InvalidThreshold();
        
        uint256 oldThreshold = minAutoTransferETH;
        minAutoTransferETH = newThreshold;
        
        emit ThresholdUpdated(address(0), oldThreshold, newThreshold);
    }
    
    /**
     * @notice Update the minimum auto-transfer threshold for USDC
     * @dev Only owner can update. Must be > 0 to prevent dust attacks
     */
    function setMinAutoTransferUSDC(uint256 newThreshold) external onlyOwner {
        if (newThreshold == 0) revert InvalidThreshold();
        
        uint256 oldThreshold = minAutoTransferUSDC;
        minAutoTransferUSDC = newThreshold;
        
        emit ThresholdUpdated(USDC, oldThreshold, newThreshold);
    }
    
    /**
     * @notice Get current thresholds
     */
    function getThresholds() external view returns (uint256 ethThreshold, uint256 usdcThreshold) {
        return (minAutoTransferETH, minAutoTransferUSDC);
    }
    
    // ============ EMERGENCY RECOVERY (Owner only) ============
    // 
    // NOTE: Emergency withdraw functions removed in audit.
    // Reason: They would drain ALL balance including pending royalties/withdrawals.
    // Users can always recover funds via:
    // - withdraw() for pending ETH withdrawals
    // - withdrawToken() for pending ERC20 withdrawals  
    // - withdrawRoyalties() for accumulated ETH royalties
    // - withdrawRoyaltiesToken() for accumulated ERC20 royalties
    //
    // If ETH is accidentally sent via receive(), it becomes protocol revenue.
    // Consider adding accounting in V2 to track stuck vs pending amounts.
    
    // Allow receiving ETH directly (becomes protocol revenue if not via payAgent)
    receive() external payable {}
}
