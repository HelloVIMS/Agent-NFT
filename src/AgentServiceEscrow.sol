// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {VimsProvenance} from "./VimsProvenance.sol";

interface IEscrowReceiver {
    function agentOwnerOf(address nft, uint256 tokenId) external view returns (address);
    function distributeFromEscrow(address token, uint256 amount, address nft, uint256 tokenId, bytes32 serviceId) external;
}

/**
 * @title  AgentServiceEscrow
 * @notice Holds the payment for a service delivered over time (an access
 *         block: N days of calls or model tokens on the seller's machine)
 *         and releases it as the service is actually up; what wasn't
 *         delivered goes back to the buyer.
 *
 *         - Terms. An agent's owner fixes a service's terms once: how many
 *           epochs it runs, how long an epoch is, and an SLA allowance.
 *           They can't change afterwards (a new serviceId is a new offer),
 *           so a buyer's signature over the service binds its terms.
 *         - Funding. AgentX402Receiver.payForServiceEscrowed takes the
 *           buyer's usual two signatures, pulls the payment and opens the
 *           escrow here, keyed by the payment nonce.
 *         - Release. Watchers probe the seller and sign which epochs it was
 *           up (EIP-712 Uptime over a 256-epoch bitmap). An epoch is
 *           payable once a majority of the escrow's watcher set signed it
 *           up; anyone may submit, the seller usually does. Its share goes
 *           through the receiver's split (fee, royalty, agent).
 *         - Close. After the term plus the claim window, anyone closes: the
 *           SLA allowance (down epochs that count as up) goes to the seller,
 *           the rest of what wasn't claimed is refunded to the buyer.
 *
 *         Watcher sets are append-only and each escrow keeps the set it
 *         opened with. A set needs a strict majority to sign, so two
 *         conflicting quorums need a watcher to sign both ways.
 *
 *         Invariant: claimed + refunded + held == funded, per escrow.
 */
contract AgentServiceEscrow is
    Initializable,
    VimsProvenance,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712Upgradeable
{
    using SafeERC20 for IERC20;

    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentServiceEscrow";
    }

    struct Terms {
        uint32 termEpochs;
        uint32 epochSeconds;
        uint16 slaBps; // share of epochs that count as up when down: 100 = 99% uptime promised
    }

    struct WatcherSet {
        address[] watchers;
        uint8 threshold;
    }

    struct Escrow {
        address buyer;
        address nft;
        uint256 tokenId;
        bytes32 serviceId;
        address token;
        uint128 amount;
        uint128 released;
        uint64 start;
        uint32 termEpochs;
        uint32 epochSeconds;
        uint16 slaBps;
        uint32 watcherSet;
        uint32 claimedEpochs;
        bool closed;
    }

    bytes32 public constant UPTIME_TYPEHASH =
        keccak256("Uptime(bytes32 escrowId,uint32 fromEpoch,uint32 count,uint256 upBitmap)");
    uint16 public constant MAX_SLA_BPS = 500;          // at most 5% of a term may be forgiven
    uint32 public constant MIN_EPOCH_SECONDS = 300;    // watchers probe every few minutes
    uint32 public constant MAX_TERM_EPOCHS = 100_000;

    IEscrowReceiver public receiver;
    uint64 public claimWindow;
    mapping(bytes32 => Terms) internal _terms;          // keccak(nft, tokenId, serviceId)
    WatcherSet[] internal _watcherSets;
    mapping(bytes32 => Escrow) internal _escrows;
    mapping(bytes32 => mapping(uint256 => uint256)) internal _claimedBits; // escrow => word => bits

    event TermsSet(address indexed nft, uint256 indexed tokenId, bytes32 indexed serviceId, uint32 termEpochs, uint32 epochSeconds, uint16 slaBps);
    event WatcherSetAdded(uint32 indexed id, address[] watchers, uint8 threshold);
    event Opened(bytes32 indexed escrowId, address indexed buyer, address indexed nft, uint256 tokenId, bytes32 serviceId,
        address token, uint256 amount, uint64 start, uint32 termEpochs, uint32 epochSeconds, uint32 watcherSet);
    event Claimed(bytes32 indexed escrowId, uint32 epochs, uint256 amount);
    event Closed(bytes32 indexed escrowId, uint256 slaReleased, uint256 refunded);
    event ClaimWindowUpdated(uint64 claimWindow);

    error NotReceiver();
    error NotAgentOwner();
    error TermsAlreadySet();
    error InvalidTerms();
    error NoTerms();
    error EscrowExists();
    error UnknownEscrow();
    error InvalidWatcherSet();
    error NoWatcherSet();
    error InvalidClaim();
    error ClaimWindowOver();
    error AlreadyClosed();
    error TooEarly();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address receiver_, uint64 claimWindow_) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __EIP712_init("AgentServiceEscrow", "1");
        receiver = IEscrowReceiver(receiver_);
        claimWindow = claimWindow_;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ─── configuration ──────────────────────────────────────────────

    /// @notice Add a watcher set and make it the one new escrows use. Sets
    ///         are never edited, so open escrows keep theirs.
    function addWatcherSet(address[] calldata watchers, uint8 threshold) external onlyOwner returns (uint32 id) {
        uint256 n = watchers.length;
        if (n == 0 || n > 32 || uint256(threshold) * 2 <= n || threshold > n) revert InvalidWatcherSet();
        for (uint256 i = 0; i < n; i++) {
            if (watchers[i] == address(0)) revert InvalidWatcherSet();
            for (uint256 j = 0; j < i; j++) if (watchers[j] == watchers[i]) revert InvalidWatcherSet();
        }
        _watcherSets.push(WatcherSet(watchers, threshold));
        id = uint32(_watcherSets.length - 1);
        emit WatcherSetAdded(id, watchers, threshold);
    }

    function setClaimWindow(uint64 claimWindow_) external onlyOwner {
        claimWindow = claimWindow_;
        emit ClaimWindowUpdated(claimWindow_);
    }

    /// @notice Fix a service's escrow terms. Once only.
    function setTerms(address nft, uint256 tokenId, bytes32 serviceId, uint32 termEpochs, uint32 epochSeconds, uint16 slaBps) external {
        if (receiver.agentOwnerOf(nft, tokenId) != msg.sender) revert NotAgentOwner();
        bytes32 key = _key(nft, tokenId, serviceId);
        if (_terms[key].termEpochs != 0) revert TermsAlreadySet();
        if (termEpochs == 0 || termEpochs > MAX_TERM_EPOCHS || epochSeconds < MIN_EPOCH_SECONDS || slaBps > MAX_SLA_BPS) revert InvalidTerms();
        _terms[key] = Terms(termEpochs, epochSeconds, slaBps);
        emit TermsSet(nft, tokenId, serviceId, termEpochs, epochSeconds, slaBps);
    }

    // ─── lifecycle ──────────────────────────────────────────────────

    /// @notice Open an escrow for a payment the receiver just forwarded.
    function open(bytes32 escrowId, address buyer, address nft, uint256 tokenId, bytes32 serviceId, address token, uint256 amount) external {
        if (msg.sender != address(receiver)) revert NotReceiver();
        Terms memory t = _terms[_key(nft, tokenId, serviceId)];
        if (t.termEpochs == 0) revert NoTerms();
        if (_watcherSets.length == 0) revert NoWatcherSet();
        if (_escrows[escrowId].buyer != address(0)) revert EscrowExists();
        uint32 ws = uint32(_watcherSets.length - 1);
        _escrows[escrowId] = Escrow({
            buyer: buyer, nft: nft, tokenId: tokenId, serviceId: serviceId, token: token,
            amount: uint128(amount), released: 0, start: uint64(block.timestamp),
            termEpochs: t.termEpochs, epochSeconds: t.epochSeconds, slaBps: t.slaBps,
            watcherSet: ws, claimedEpochs: 0, closed: false
        });
        emit Opened(escrowId, buyer, nft, tokenId, serviceId, token, amount, uint64(block.timestamp), t.termEpochs, t.epochSeconds, ws);
    }

    /// @notice Release the epochs in [fromEpoch, fromEpoch+count) that a
    ///         majority of the escrow's watchers signed up. Each watcher's
    ///         bitmap is independent; an epoch needs `threshold` of them.
    ///         Epochs must be over, unclaimed, and within the claim window.
    function claim(bytes32 escrowId, uint32 fromEpoch, uint32 count, uint256[] calldata bitmaps, bytes[] calldata signatures)
        external nonReentrant returns (uint256 amount)
    {
        Escrow storage e = _escrows[escrowId];
        if (e.buyer == address(0)) revert UnknownEscrow();
        if (e.closed) revert AlreadyClosed();
        if (count == 0 || count > 256 || bitmaps.length != signatures.length) revert InvalidClaim();
        if (uint256(fromEpoch) + count > e.termEpochs) revert InvalidClaim();
        if (block.timestamp > _end(e) + claimWindow) revert ClaimWindowOver();
        if (e.start + (uint256(fromEpoch) + count) * e.epochSeconds > block.timestamp) revert TooEarly();

        uint256 payable_ = _quorumBitmap(escrowId, e.watcherSet, fromEpoch, count, bitmaps, signatures);
        uint32 newly;
        for (uint256 i = 0; i < count; i++) {
            if (payable_ & (1 << i) == 0) continue;
            uint256 epoch = uint256(fromEpoch) + i;
            uint256 word = epoch >> 8;
            uint256 bit = 1 << (epoch & 255);
            if (_claimedBits[escrowId][word] & bit != 0) continue;
            _claimedBits[escrowId][word] |= bit;
            amount += _epochShare(e, epoch);
            newly++;
        }
        if (newly == 0) revert InvalidClaim();
        e.claimedEpochs += newly;
        e.released += uint128(amount);
        _release(e, amount);
        emit Claimed(escrowId, newly, amount);
    }

    /// @notice After the term and claim window: pay the SLA allowance out of
    ///         the unclaimed epochs and refund the buyer the rest.
    function close(bytes32 escrowId) external nonReentrant returns (uint256 refunded) {
        Escrow storage e = _escrows[escrowId];
        if (e.buyer == address(0)) revert UnknownEscrow();
        if (e.closed) revert AlreadyClosed();
        if (block.timestamp <= _end(e) + claimWindow) revert TooEarly();
        e.closed = true;

        uint256 unclaimed = e.termEpochs - e.claimedEpochs;
        uint256 allowance = (uint256(e.termEpochs) * e.slaBps) / 10_000;
        uint256 sla = (allowance < unclaimed ? allowance : unclaimed) * (uint256(e.amount) / e.termEpochs);
        if (sla > 0) {
            e.released += uint128(sla);
            _release(e, sla);
        }
        refunded = uint256(e.amount) - e.released;
        if (refunded > 0) IERC20(e.token).safeTransfer(e.buyer, refunded);
        emit Closed(escrowId, sla, refunded);
    }

    // ─── views ──────────────────────────────────────────────────────

    function terms(address nft, uint256 tokenId, bytes32 serviceId) external view returns (Terms memory) {
        return _terms[_key(nft, tokenId, serviceId)];
    }

    function escrowOf(bytes32 escrowId) external view returns (Escrow memory) {
        return _escrows[escrowId];
    }

    function watcherSet(uint32 id) external view returns (address[] memory watchers, uint8 threshold) {
        WatcherSet storage ws = _watcherSets[id];
        return (ws.watchers, ws.threshold);
    }

    function watcherSetCount() external view returns (uint256) {
        return _watcherSets.length;
    }

    function isClaimed(bytes32 escrowId, uint32 epoch) external view returns (bool) {
        return _claimedBits[escrowId][epoch >> 8] & (1 << (epoch & 255)) != 0;
    }

    /// @notice The digest a watcher signs for an uptime report.
    function uptimeDigest(bytes32 escrowId, uint32 fromEpoch, uint32 count, uint256 upBitmap) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(UPTIME_TYPEHASH, escrowId, fromEpoch, count, upBitmap)));
    }

    // ─── internals ──────────────────────────────────────────────────

    function _key(address nft, uint256 tokenId, bytes32 serviceId) internal pure returns (bytes32) {
        return keccak256(abi.encode(nft, tokenId, serviceId));
    }

    function _end(Escrow storage e) internal view returns (uint256) {
        return uint256(e.start) + uint256(e.termEpochs) * e.epochSeconds;
    }

    /// @dev Equal shares; the last epoch takes the rounding remainder, so
    ///      a fully delivered term releases exactly the amount.
    function _epochShare(Escrow storage e, uint256 epoch) internal view returns (uint256) {
        uint256 base = uint256(e.amount) / e.termEpochs;
        return epoch == e.termEpochs - 1 ? uint256(e.amount) - base * (e.termEpochs - 1) : base;
    }

    /// @dev Bits set where at least `threshold` distinct watchers of the
    ///      set signed the epoch up.
    function _quorumBitmap(bytes32 escrowId, uint32 setId, uint32 fromEpoch, uint32 count,
        uint256[] calldata bitmaps, bytes[] calldata signatures) internal view returns (uint256 quorum)
    {
        WatcherSet storage ws = _watcherSets[setId];
        uint256 n = ws.watchers.length;
        uint256 seen; // bit i: watcher i already counted
        uint8[256] memory votes;
        for (uint256 k = 0; k < bitmaps.length; k++) {
            address signer = ECDSA.recover(uptimeDigest(escrowId, fromEpoch, count, bitmaps[k]), signatures[k]);
            uint256 idx = n;
            for (uint256 j = 0; j < n; j++) if (ws.watchers[j] == signer) { idx = j; break; }
            if (idx == n || seen & (1 << idx) != 0) revert InvalidClaim();
            seen |= 1 << idx;
            uint256 b = bitmaps[k];
            for (uint256 i = 0; i < count; i++) if (b & (1 << i) != 0) votes[i]++;
        }
        for (uint256 i = 0; i < count; i++) if (votes[i] >= ws.threshold) quorum |= 1 << i;
    }

    function _release(Escrow storage e, uint256 amount) internal {
        IERC20(e.token).safeTransfer(address(receiver), amount);
        receiver.distributeFromEscrow(e.token, amount, e.nft, e.tokenId, e.serviceId);
    }

    uint256[44] private __gap;
}
