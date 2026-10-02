// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {VimsProvenance} from "./VimsProvenance.sol";

interface IStreamReceiver {
    function agentOwnerOf(address nft, uint256 tokenId) external view returns (address);
    function distributeFromStream(address token, uint256 amount, address nft, uint256 tokenId, bytes32 serviceId) external;
}

/**
 * @title  AgentServiceStream
 * @notice Pays for a service delivered over time as a stream: the buyer's
 *         payment vests to the seller every second of the term, the seller
 *         withdraws what has vested whenever it suits (the payout goes
 *         through the receiver's split), and either side can cancel at any
 *         moment — the buyer gets back what hasn't vested, the seller keeps
 *         what has. Nobody judges whether the service was delivered: a buyer
 *         who stops getting it stops paying.
 *
 *         - Terms. An agent's owner fixes a service's term (any length from
 *           one hour) and an optional minimum commitment (at most a day, and
 *           at most a tenth of the term) once; they never change, so a
 *           buyer's signature over the service binds them.
 *         - Open. AgentX402Receiver.payForServiceStreamed takes the buyer's
 *           usual two signatures, pulls the payment and opens the stream,
 *           keyed by the payment nonce.
 *         - Cancel. By the buyer (or anyone holding the buyer's signed
 *           cancel, e.g. a guardian watching the seller while the buyer is
 *           away): the minimum commitment, if not yet reached, is still the
 *           seller's. By the agent's owner: vesting stops now, no minimum.
 *
 *         Invariant: withdrawn + refunded + held == amount, per stream.
 */
contract AgentServiceStream is
    Initializable,
    VimsProvenance,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712Upgradeable
{
    using SafeERC20 for IERC20;

    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentServiceStream";
    }

    struct Terms {
        uint32 duration;   // seconds
        uint32 minCommit;  // seconds the buyer pays for even if it cancels sooner
    }

    struct Stream {
        address buyer;
        address nft;
        uint256 tokenId;
        bytes32 serviceId;
        address token;
        uint128 amount;
        uint128 withdrawn;
        uint64 start;
        uint64 end;
        uint64 minCommitEnd;
        uint64 stoppedAt; // 0 while running; set by a cancel
    }

    bytes32 public constant CANCEL_TYPEHASH = keccak256("Cancel(bytes32 streamId,uint256 deadline)");
    uint32 public constant MIN_DURATION = 1 hours;
    uint32 public constant MAX_MIN_COMMIT = 1 days;

    IStreamReceiver public receiver;
    mapping(bytes32 => Terms) internal _terms; // keccak(nft, tokenId, serviceId)
    mapping(bytes32 => Stream) internal _streams;

    event TermsSet(address indexed nft, uint256 indexed tokenId, bytes32 indexed serviceId, uint32 duration, uint32 minCommit);
    event Opened(bytes32 indexed streamId, address indexed buyer, address indexed nft, uint256 tokenId, bytes32 serviceId,
        address token, uint256 amount, uint64 start, uint64 end, uint64 minCommitEnd);
    event Withdrawn(bytes32 indexed streamId, uint256 amount);
    event Cancelled(bytes32 indexed streamId, address indexed by, bool bySeller, uint64 stoppedAt, uint256 paidToSeller, uint256 refunded);

    error NotReceiver();
    error NotAgentOwner();
    error TermsAlreadySet();
    error InvalidTerms();
    error NoTerms();
    error StreamExists();
    error UnknownStream();
    error NotParty();
    error AlreadyStopped();
    error Expired();
    error InvalidSignature();
    error NothingToWithdraw();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address receiver_) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __EIP712_init("AgentServiceStream", "1");
        receiver = IStreamReceiver(receiver_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ─── terms ──────────────────────────────────────────────────────

    /// @notice Fix a service's stream terms. Once only, by the agent's owner.
    function setTerms(address nft, uint256 tokenId, bytes32 serviceId, uint32 duration, uint32 minCommit) external {
        if (receiver.agentOwnerOf(nft, tokenId) != msg.sender) revert NotAgentOwner();
        bytes32 key = _key(nft, tokenId, serviceId);
        if (_terms[key].duration != 0) revert TermsAlreadySet();
        if (duration < MIN_DURATION || minCommit > MAX_MIN_COMMIT || uint256(minCommit) * 10 > duration) revert InvalidTerms();
        _terms[key] = Terms(duration, minCommit);
        emit TermsSet(nft, tokenId, serviceId, duration, minCommit);
    }

    // ─── lifecycle ──────────────────────────────────────────────────

    /// @notice Open a stream for a payment the receiver just forwarded.
    function open(bytes32 streamId, address buyer, address nft, uint256 tokenId, bytes32 serviceId, address token, uint256 amount) external {
        if (msg.sender != address(receiver)) revert NotReceiver();
        Terms memory t = _terms[_key(nft, tokenId, serviceId)];
        if (t.duration == 0) revert NoTerms();
        if (_streams[streamId].buyer != address(0)) revert StreamExists();
        uint64 start = uint64(block.timestamp);
        _streams[streamId] = Stream({
            buyer: buyer, nft: nft, tokenId: tokenId, serviceId: serviceId, token: token,
            amount: uint128(amount), withdrawn: 0, start: start, end: start + t.duration,
            minCommitEnd: start + t.minCommit, stoppedAt: 0
        });
        emit Opened(streamId, buyer, nft, tokenId, serviceId, token, amount, start, start + t.duration, start + t.minCommit);
    }

    /// @notice Pay the seller what has vested and not been withdrawn.
    ///         Anyone may call (the seller's daemon does, when the fee is
    ///         worth it); the money only ever goes through the split.
    function withdraw(bytes32 streamId) external nonReentrant returns (uint256 amount) {
        Stream storage s = _stream(streamId);
        amount = _vested(s) - s.withdrawn;
        if (amount == 0) revert NothingToWithdraw();
        _paySeller(s, streamId, amount);
    }

    /// @notice Cancel as the buyer or as the agent's owner.
    function cancel(bytes32 streamId) external nonReentrant {
        Stream storage s = _stream(streamId);
        if (msg.sender == s.buyer) _cancel(s, streamId, msg.sender, false);
        else if (msg.sender == receiver.agentOwnerOf(s.nft, s.tokenId)) _cancel(s, streamId, msg.sender, true);
        else revert NotParty();
    }

    /// @notice Cancel with the buyer's signature, submitted by anyone — a
    ///         guardian acting on the buyer's behalf while it's away. The
    ///         only effect is the buyer's own cancel: the refund goes to the
    ///         buyer.
    function cancelBySig(bytes32 streamId, uint256 deadline, bytes calldata signature) external nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        Stream storage s = _stream(streamId);
        if (!SignatureChecker.isValidSignatureNow(s.buyer, cancelDigest(streamId, deadline), signature)) revert InvalidSignature();
        _cancel(s, streamId, s.buyer, false);
    }

    // ─── views ──────────────────────────────────────────────────────

    function terms(address nft, uint256 tokenId, bytes32 serviceId) external view returns (Terms memory) {
        return _terms[_key(nft, tokenId, serviceId)];
    }

    function streamOf(bytes32 streamId) external view returns (Stream memory) {
        return _streams[streamId];
    }

    /// @notice Vested so far (withdrawn included).
    function vested(bytes32 streamId) external view returns (uint256) {
        return _vested(_stream(streamId));
    }

    /// @notice Vested and not yet withdrawn.
    function withdrawable(bytes32 streamId) external view returns (uint256) {
        Stream storage s = _stream(streamId);
        return _vested(s) - s.withdrawn;
    }

    /// @notice The digest a buyer signs to authorise a cancel by anyone.
    function cancelDigest(bytes32 streamId, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(CANCEL_TYPEHASH, streamId, deadline)));
    }

    // ─── internals ──────────────────────────────────────────────────

    function _key(address nft, uint256 tokenId, bytes32 serviceId) internal pure returns (bytes32) {
        return keccak256(abi.encode(nft, tokenId, serviceId));
    }

    function _stream(bytes32 streamId) internal view returns (Stream storage s) {
        s = _streams[streamId];
        if (s.buyer == address(0)) revert UnknownStream();
    }

    /// @dev amount × elapsed ÷ term. A cancelled stream is settled at its
    ///      stop (which a buyer's cancel inside the minimum commitment sets
    ///      ahead of now); a running one up to now, capped at the end.
    ///      Rounds down, so a running stream never over-pays the seller; at
    ///      the end it reaches the full amount exactly.
    function _vested(Stream storage s) internal view returns (uint256) {
        uint256 at = s.stoppedAt != 0 ? s.stoppedAt : (block.timestamp < s.end ? block.timestamp : s.end);
        if (at >= s.end) return s.amount;
        return (uint256(s.amount) * (at - s.start)) / (s.end - s.start);
    }

    function _cancel(Stream storage s, bytes32 streamId, address by, bool bySeller) internal {
        if (s.stoppedAt != 0) revert AlreadyStopped();
        if (block.timestamp >= s.end) revert Expired();
        uint64 stop = uint64(block.timestamp);
        // A buyer cancelling inside the minimum commitment still pays it.
        if (!bySeller && stop < s.minCommitEnd) stop = s.minCommitEnd;
        s.stoppedAt = stop;
        uint256 total = _vested(s);
        uint256 toSeller = total - s.withdrawn;
        uint256 refund = uint256(s.amount) - total;
        if (toSeller > 0) _paySeller(s, streamId, toSeller);
        if (refund > 0) IERC20(s.token).safeTransfer(s.buyer, refund);
        emit Cancelled(streamId, by, bySeller, stop, toSeller, refund);
    }

    function _paySeller(Stream storage s, bytes32 streamId, uint256 amount) internal {
        s.withdrawn += uint128(amount);
        IERC20(s.token).safeTransfer(address(receiver), amount);
        receiver.distributeFromStream(s.token, amount, s.nft, s.tokenId, s.serviceId);
        emit Withdrawn(streamId, amount);
    }

    uint256[47] private __gap;
}
