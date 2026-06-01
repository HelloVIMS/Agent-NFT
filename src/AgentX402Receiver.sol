// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAgentIdentityRegistry.sol";
import "./interfaces/IERC3009.sol";

/**
 * @title AgentX402Receiver
 * @notice Atomic on-chain settler for Agent NFT services paid via the
 *         [x402](https://github.com/coinbase/x402) HTTP payment protocol.
 *
 * @dev Two signatures are required to settle a payment, and **both** are
 *      bound to the same `(payer → this contract, amount, nonce, deadline)`
 *      tuple plus the explicit `(agentId, serviceId, token)` purpose:
 *
 *        1. **EIP-3009 `receiveWithAuthorization`** — pulls the token. Bound
 *           to `(from, to=this, value, validAfter, validBefore, nonce)` by
 *           the token contract.
 *        2. **EIP-712 `PaymentCommitment`** — purpose binding. Signed by the
 *           same `from` address; commits to `(agentId, serviceId, token,
 *           amount, nonce, validBefore)`. Without this, an attacker who
 *           observes the EIP-3009 authorization in the mempool could redirect
 *           it to a different `(agentId', serviceId')` pair with the same
 *           `(token, price)`. The commit closes audit finding **M-1**.
 *
 *      The `nonce` is shared between the two signatures: EIP-3009 enforces
 *      single-use (replay protection); the commitment is therefore also
 *      single-use because consuming the EIP-3009 nonce burns the binding.
 *
 * Settlement flow:
 *   1. Pulls funds via `IERC3009.receiveWithAuthorization`.
 *   2. Verifies the EIP-712 commitment was signed by `from`.
 *   3. Splits per ERC-2981 creator royalty + system fee.
 *   4. Transfers the remainder to the agent's TBA (or `ownerOf(agentId)`).
 *   5. Emits `ServicePaid` reflecting the actual on-chain disbursement.
 *
 * UUPS upgradeable. Pausable. Reentrancy-guarded.
 *
 * Token policy: `registerService` is constrained to allowlisted tokens
 * (audit finding **L-3**). Owner manages the allowlist (USDC seed at deploy).
 */
import {VimsProvenance} from "./VimsProvenance.sol";

contract AgentX402Receiver is
    Initializable,
    VimsProvenance,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable
{
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentX402Receiver";
    }

    using SafeERC20 for IERC20;

    // ============ Errors ============
    error NotOwner();
    error ZeroAddress();
    error ServiceInactive();
    error ServiceAlreadyExists();
    error InvalidPrice();
    error InvalidFee();
    error TokenNotAllowed();
    error InvalidCommitment();

    // ============ Constants ============
    uint256 public constant BPS_DENOM          = 10_000;
    uint256 public constant MAX_SYSTEM_FEE_BPS = 500; // 5%

    /// @notice EIP-712 typehash for the off-chain payment commitment.
    /// @dev    keccak256("PaymentCommitment(uint256 agentId,bytes32 serviceId,address token,uint256 amount,bytes32 nonce,uint256 validBefore)")
    bytes32 public constant PAYMENT_COMMITMENT_TYPEHASH =
        keccak256("PaymentCommitment(uint256 agentId,bytes32 serviceId,address token,uint256 amount,bytes32 nonce,uint256 validBefore)");

    // ============ Storage ============
    IAgentIdentityRegistry public identityRegistry;
    address public treasury;
    uint256 public systemFeeBps;

    struct Service {
        address token;
        uint256 price;
        bool    active;
    }

    /// @dev agentId => serviceId => Service
    mapping(uint256 => mapping(bytes32 => Service)) public services;

    /// @dev token => allowed (audit L-3)
    mapping(address => bool) public allowedTokens;

    // ============ Events ============
    event ServiceRegistered(uint256 indexed agentId, bytes32 indexed serviceId, address token, uint256 price);
    event ServiceUpdated(uint256 indexed agentId, bytes32 indexed serviceId, uint256 price, bool active);
    event ServicePaid(
        uint256 indexed agentId,
        bytes32 indexed serviceId,
        address indexed payer,
        address token,
        uint256 gross,
        uint256 systemCut,
        uint256 creatorCut,
        uint256 agentCut,
        address agentRecipient
    );
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event SystemFeeUpdated(uint256 oldBps, uint256 newBps);
    event IdentityRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event TokenAllowedUpdated(address indexed token, bool allowed);

    // ============ Init ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _identityRegistry,
        address _treasury,
        uint256 _systemFeeBps
    ) public initializer {
        if (_identityRegistry == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_systemFeeBps > MAX_SYSTEM_FEE_BPS) revert InvalidFee();
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();
        __EIP712_init("AgentX402Receiver", "1");
        identityRegistry = IAgentIdentityRegistry(_identityRegistry);
        treasury         = _treasury;
        systemFeeBps     = _systemFeeBps;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ============ Owner admin ============
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setSystemFeeBps(uint256 _bps) external onlyOwner {
        if (_bps > MAX_SYSTEM_FEE_BPS) revert InvalidFee();
        emit SystemFeeUpdated(systemFeeBps, _bps);
        systemFeeBps = _bps;
    }

    function setIdentityRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert ZeroAddress();
        emit IdentityRegistryUpdated(address(identityRegistry), _registry);
        identityRegistry = IAgentIdentityRegistry(_registry);
    }

    /// @notice Allowlist (or remove) a token for use in `registerService`.
    /// @dev    Existing services retain their token even if it is later
    ///         delisted; only future registrations are blocked.
    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedTokens[token] = allowed;
        emit TokenAllowedUpdated(token, allowed);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ============ Agent-owner service management ============
    modifier onlyAgentOwner(uint256 agentId) {
        if (identityRegistry.ownerOf(agentId) != msg.sender) revert NotOwner();
        _;
    }

    /**
     * @notice Register a new priced service for an agent.
     * @param serviceId Any unique 32-byte id — recommended: `keccak256("endpoint/name/v1")`.
     */
    function registerService(
        uint256 agentId,
        bytes32 serviceId,
        address token,
        uint256 price
    ) external onlyAgentOwner(agentId) whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (!allowedTokens[token]) revert TokenNotAllowed();
        if (price == 0) revert InvalidPrice();
        if (services[agentId][serviceId].token != address(0)) revert ServiceAlreadyExists();
        services[agentId][serviceId] = Service({token: token, price: price, active: true});
        emit ServiceRegistered(agentId, serviceId, token, price);
    }

    /// @notice Update price / active flag on an existing service. Token is immutable.
    function updateService(
        uint256 agentId,
        bytes32 serviceId,
        uint256 newPrice,
        bool    active
    ) external onlyAgentOwner(agentId) whenNotPaused {
        Service storage svc = services[agentId][serviceId];
        if (svc.token == address(0)) revert ServiceInactive();
        if (newPrice == 0) revert InvalidPrice();
        svc.price  = newPrice;
        svc.active = active;
        emit ServiceUpdated(agentId, serviceId, newPrice, active);
    }

    // ============ x402 settlement ============
    /**
     * @notice Compute the EIP-712 digest the payer must sign as the
     *         purpose-binding commitment. Off-chain wallets / SDKs call this
     *         (or replicate it) before signing.
     */
    function hashPaymentCommitment(
        uint256 agentId,
        bytes32 serviceId,
        address token,
        uint256 amount,
        bytes32 nonce,
        uint256 validBefore
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            PAYMENT_COMMITMENT_TYPEHASH,
            agentId, serviceId, token, amount, nonce, validBefore
        ));
        return _hashTypedDataV4(structHash);
    }

    /// @notice Convenience getter for the EIP-712 domain separator.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Settle an x402 payment for a registered service with the
     *         dual-signature scheme (EIP-3009 + EIP-712 commitment).
     *
     * @param agentId      Target agent NFT.
     * @param serviceId    Service key registered under that agent.
     * @param from         Payer (signer of both signatures).
     * @param validAfter   EIP-3009 validity window start.
     * @param validBefore  EIP-3009 validity window end (also used as commit deadline).
     * @param nonce        EIP-3009 nonce; doubles as commit nonce.
     * @param v,r,s        EIP-3009 signature.
     * @param cv,cr,cs     EIP-712 PaymentCommitment signature by `from`.
     * @return gross       Amount transferred in token smallest units.
     */
    function payForService(
        uint256 agentId,
        bytes32 serviceId,
        address from,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8   v,  bytes32 r,  bytes32 s,
        uint8   cv, bytes32 cr, bytes32 cs
    ) external nonReentrant whenNotPaused returns (uint256 gross) {
        Service memory svc = services[agentId][serviceId];
        if (!svc.active || svc.price == 0) revert ServiceInactive();
        gross = svc.price;

        // 1. Verify EIP-712 purpose binding (audit M-1).
        bytes32 digest = hashPaymentCommitment(
            agentId, serviceId, svc.token, gross, nonce, validBefore
        );
        if (ECDSA.recover(digest, cv, cr, cs) != from) revert InvalidCommitment();

        // 2. Pull funds via EIP-3009 (USDC-style). `to` must be this contract.
        IERC3009(svc.token).receiveWithAuthorization(
            from, address(this), gross, validAfter, validBefore, nonce, v, r, s
        );

        // 3. Compute splits (audit L-4: zero-out before emit so the event
        //    accurately reflects on-chain disbursement).
        uint256 systemCut  = (gross * systemFeeBps) / BPS_DENOM;
        (address creator, uint256 creatorBps) = identityRegistry.getCreatorRoyalty(agentId);
        uint256 creatorCut = (gross * creatorBps) / BPS_DENOM;
        uint256 agentCut   = gross - systemCut - creatorCut;

        if (creatorCut > 0 && creator == address(0)) {
            agentCut  += creatorCut;
            creatorCut = 0;
        }

        // 4. Resolve agent recipient: prefer TBA, fall back to NFT owner.
        (,address tba,,,) = identityRegistry.agents(agentId);
        address agentRecipient = tba != address(0) ? tba : identityRegistry.ownerOf(agentId);

        // 5. Disburse.
        IERC20 token = IERC20(svc.token);
        if (systemCut  > 0) token.safeTransfer(treasury,        systemCut);
        if (creatorCut > 0) token.safeTransfer(creator,         creatorCut);
        if (agentCut   > 0) token.safeTransfer(agentRecipient,  agentCut);

        emit ServicePaid(
            agentId, serviceId, from, svc.token, gross,
            systemCut, creatorCut, agentCut, agentRecipient
        );
    }

    // ============ View helpers ============
    function getService(uint256 agentId, bytes32 serviceId) external view returns (Service memory) {
        return services[agentId][serviceId];
    }

    /// @notice Quote the split for a hypothetical payment of `svc.price` units.
    function quoteSplit(uint256 agentId, bytes32 serviceId)
        external
        view
        returns (uint256 gross, uint256 systemCut, uint256 creatorCut, uint256 agentCut)
    {
        Service memory svc = services[agentId][serviceId];
        if (!svc.active || svc.price == 0) revert ServiceInactive();
        gross      = svc.price;
        systemCut  = (gross * systemFeeBps) / BPS_DENOM;
        (address creator, uint256 creatorBps) = identityRegistry.getCreatorRoyalty(agentId);
        creatorCut = (gross * creatorBps) / BPS_DENOM;
        agentCut   = gross - systemCut - creatorCut;
        if (creatorCut > 0 && creator == address(0)) {
            agentCut  += creatorCut;
            creatorCut = 0;
        }
    }

    // ============ Trusted-registrar atomic mint path =====================

    /// @notice The `AgentIdentityRegistry` allowed to register services for
    ///         freshly minted agents on behalf of the owner during the
    ///         atomic `mintWithFullStack` flow. address(0) disables.
    address public trustedAgentRegistry;

    /// @notice Emitted when the trusted agent registry pointer changes.
    event TrustedAgentRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    /// @notice Emitted when a service is registered via the identity-trusted
    ///         path (distinct event so off-chain indexers can distinguish
    ///         user-initiated from mint-bundled registrations).
    event ServiceRegisteredViaIdentity(
        uint256 indexed agentId,
        bytes32 indexed serviceId,
        address indexed agentOwner,
        address token,
        uint256 price
    );

    error NotTrustedRegistry();

    /// @notice Owner-only setter for the trusted agent registry.
    function setTrustedAgentRegistry(address newRegistry) external onlyOwner {
        address old = trustedAgentRegistry;
        trustedAgentRegistry = newRegistry;
        emit TrustedAgentRegistryUpdated(old, newRegistry);
    }

    /// @notice Register a service on behalf of an agent owner. Only callable
    ///         by `trustedAgentRegistry` — the identity contract uses this
    ///         during `mintWithFullStack` so the atomic mint can include a
    ///         priced service without a second tx.
    /// @dev    Validates `agentOwner` matches the on-chain `ownerOf` so a
    ///         compromised registry cannot register for an unrelated owner.
    function registerServiceFromIdentity(
        uint256 agentId,
        address agentOwner,
        bytes32 serviceId,
        address token,
        uint256 price
    ) external whenNotPaused {
        if (msg.sender != trustedAgentRegistry) revert NotTrustedRegistry();
        if (token == address(0)) revert ZeroAddress();
        if (!allowedTokens[token]) revert TokenNotAllowed();
        if (price == 0) revert InvalidPrice();
        // Defence in depth: the registry should always pass the true owner,
        // but we re-derive the check via identityRegistry to fail closed if
        // the linked registry is ever swapped without a corresponding
        // trusted-registry update.
        if (identityRegistry.ownerOf(agentId) != agentOwner) revert NotOwner();
        if (services[agentId][serviceId].token != address(0)) revert ServiceAlreadyExists();

        services[agentId][serviceId] = Service({token: token, price: price, active: true});
        emit ServiceRegistered(agentId, serviceId, token, price);
        emit ServiceRegisteredViaIdentity(agentId, serviceId, agentOwner, token, price);
    }
}
