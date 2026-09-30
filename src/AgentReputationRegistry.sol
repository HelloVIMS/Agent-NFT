// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./AgentIdentityRegistry.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title AgentReputationRegistry
 * @notice ERC-8004 compliant Reputation Registry for Agent agents
 * @dev Tracks feedback/ratings for agents from clients
 * @dev UUPS Upgradeable
 */
import {VimsProvenance} from "./VimsProvenance.sol";

contract AgentReputationRegistry is Initializable, VimsProvenance, OwnableUpgradeable, UUPSUpgradeable {
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentReputationRegistry";
    }

    AgentIdentityRegistry public identityRegistry;
    
    struct Feedback {
        address client;
        int128 value;        // Score (e.g., -100 to 100)
        uint8 decimals;      // Decimal places for value
        string tag1;         // Primary category (e.g., "quality")
        string tag2;         // Secondary category (e.g., "speed")
        string feedbackURI;  // IPFS URI for detailed feedback
        uint256 timestamp;
        bool revoked;
    }
    
    // SECURITY: v2 subject keys are keccak256(abi.encode("ERA", agentId, era))
    // — domain-separated, 32-byte hashes. They can't collide with each other
    // or with the first deployment's keys, which were the raw agent ids
    // (small integers) in these same mappings; see legacyFeedbackAt.

    // subject => feedbacks
    mapping(bytes32 => Feedback[]) public feedbacks;

    // subject => client => hasFeedback (prevent spam)
    mapping(bytes32 => mapping(address => bool)) public clientHasFeedback;

    // subject => tag => running score / count
    mapping(bytes32 => mapping(string => int256)) public tagScores;
    mapping(bytes32 => mapping(string => uint256)) public tagCounts;

    event FeedbackGiven(
        uint256 indexed agentId,
        address indexed client,
        bytes32 indexed subject,
        int128 value,
        string tag1,
        string feedbackURI
    );

    event FeedbackRevoked(
        uint256 indexed agentId,
        address indexed client,
        bytes32 indexed subject,
        uint256 feedbackIndex
    );
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address _identityRegistry) public initializer {
        __Ownable_init(msg.sender);
        identityRegistry = AgentIdentityRegistry(_identityRegistry);
    }
    
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
    
    // ════════════════════════════════════════════════════════════════
    // v2 — owner eras, paid attestations, system reputation.
    //
    // Reputation belongs to an (agent, owner) era, not to the NFT: when an
    // agent changes hands a new era begins with an empty history, and every
    // earlier era stays readable as an artifact of its owner. Only wallets
    // that paid the agent in the current era (recorded by the payment
    // contract through recordSettlement) may attest. Settlements, volume
    // and disputes are the system side of an era's reputation.
    //
    // Storage above is untouched; attestations from the first deployment
    // (keyed by agent id) stay readable through legacyFeedbackAt.
    // ════════════════════════════════════════════════════════════════

    struct Era {
        address owner;
        uint64  startedAt;
    }

    /// @notice An era's running totals — O(1) summaries, no array scans.
    struct EraStats {
        uint64  settlements;      // paid hires by clients other than the owner
        uint64  disputes;
        uint128 volume;           // gross paid, token smallest units
        uint64  lastSettlementAt;
        uint64  feedbackCount;    // active (non-revoked) attestations
        int128  feedbackSum;
        uint64  lastFeedbackAt;
    }

    bytes32 private constant _SUBJECT_ERA = keccak256("ERA");

    mapping(uint256 => Era[]) internal _eras;                               // agentId => eras
    mapping(bytes32 => EraStats) internal _eraStats;                        // era subject => totals
    mapping(bytes32 => mapping(address => uint256)) public paidSettlements; // era subject => client => count
    mapping(address => bool) public settlementRecorders;                    // payment contracts
    mapping(address => bool) public disputeRecorders;                       // escrow contracts

    // ── agents of any ERC-721 (v3) ───────────────────────────────────
    //
    // Every agentId-keyed function also takes the reference of an agent
    // that isn't an identity-registry token: `refOf(nft, tokenId)`, the
    // same top-bit-tagged subject AgentIdentityKeyExtension uses, so it
    // never equals an identity token id. Eras, paid-only attestations and
    // system stats work identically; the owner is the NFT contract's.
    struct NFTRef { address nft; uint256 tokenId; }
    mapping(uint256 => NFTRef) internal _refNFT;                            // tagged ref => agent NFT

    event EraStarted(uint256 indexed agentId, uint256 indexed era, address indexed owner, bytes32 subject);
    event SettlementRecorded(uint256 indexed agentId, uint256 indexed era, address indexed client, bytes32 serviceId, uint256 amount, bool counted);
    event DisputeRecorded(uint256 indexed agentId, uint256 indexed era, address indexed client, bytes32 ref);
    event SettlementRecorderSet(address indexed recorder, bool allowed);
    event DisputeRecorderSet(address indexed recorder, bool allowed);

    error NotSettlementRecorder();
    error NotDisputeRecorder();
    error NotAPayingClient();
    error ScoreOutOfRange();
    error NoSuchEra();

    modifier onlySettlementRecorder() {
        if (!settlementRecorders[msg.sender]) revert NotSettlementRecorder();
        _;
    }

    modifier onlyDisputeRecorder() {
        if (!disputeRecorders[msg.sender]) revert NotDisputeRecorder();
        _;
    }

    function setSettlementRecorder(address recorder, bool allowed) external onlyOwner {
        require(recorder != address(0), "zero recorder");
        settlementRecorders[recorder] = allowed;
        emit SettlementRecorderSet(recorder, allowed);
    }

    function setDisputeRecorder(address recorder, bool allowed) external onlyOwner {
        require(recorder != address(0), "zero recorder");
        disputeRecorders[recorder] = allowed;
        emit DisputeRecorderSet(recorder, allowed);
    }

    uint256 private constant _NFT_REF_TAG = 1 << 255;

    event AgentRefBound(uint256 indexed ref, address indexed nft, uint256 indexed tokenId);

    /// @notice The agentId every function takes for token `tokenId` of `nft`.
    function refOf(address nft, uint256 tokenId) public view returns (uint256) {
        if (nft == address(identityRegistry)) return tokenId;
        return uint256(keccak256(abi.encode(nft, tokenId))) | _NFT_REF_TAG;
    }

    /// @notice The agent NFT a reference names.
    function nftOf(uint256 ref) external view returns (address nft, uint256 tokenId) {
        NFTRef storage r = _refNFT[ref];
        return r.nft == address(0) ? (address(identityRegistry), ref) : (r.nft, r.tokenId);
    }

    function _ownerOfRef(uint256 ref) internal view returns (address) {
        NFTRef storage r = _refNFT[ref];
        if (r.nft == address(0)) return identityRegistry.ownerOf(ref);
        return IERC721(r.nft).ownerOf(r.tokenId);
    }

    /**
     * @notice {recordSettlement} for an agent of any ERC-721 — a collection
     *         agent paid through the payment contract's NFT path. Records
     *         which NFT the reference names on first use.
     */
    function recordSettlementForNFT(address nft, uint256 tokenId, address payer, bytes32 serviceId, uint256 amount)
        external
        onlySettlementRecorder
    {
        uint256 ref = refOf(nft, tokenId);
        if (ref != tokenId && _refNFT[ref].nft == address(0)) {
            _refNFT[ref] = NFTRef(nft, tokenId);
            emit AgentRefBound(ref, nft, tokenId);
        }
        _recordSettlement(ref, payer, serviceId, amount);
    }

    // ── eras ─────────────────────────────────────────────────────────

    function _eraSubject(uint256 agentId, uint256 era) internal pure returns (bytes32) {
        return keccak256(abi.encode(_SUBJECT_ERA, agentId, era));
    }

    /// @dev The current era index: the last recorded era while its owner
    ///      still holds the NFT, otherwise the (not yet recorded) next one.
    function _currentEra(uint256 agentId) internal view returns (uint256 era, bool recorded) {
        return _currentEraOf(agentId, _ownerOfRef(agentId));
    }

    function _currentEraOf(uint256 agentId, address owner) internal view returns (uint256 era, bool recorded) {
        Era[] storage list = _eras[agentId];
        uint256 n = list.length;
        if (n > 0 && list[n - 1].owner == owner) return (n - 1, true);
        return (n, false);
    }

    /// @dev Materialises the current era (writes only).
    function _touchEra(uint256 agentId) internal returns (uint256 era, bytes32 subject) {
        return _touchEraOf(agentId, _ownerOfRef(agentId));
    }

    /// @dev {_touchEra} with the agent's owner already read (one ownerOf
    ///      per call: for collection agents it crosses a proxy).
    function _touchEraOf(uint256 agentId, address owner) internal returns (uint256 era, bytes32 subject) {
        bool recorded;
        (era, recorded) = _currentEraOf(agentId, owner);
        subject = _eraSubject(agentId, era);
        if (!recorded) {
            _eras[agentId].push(Era({owner: owner, startedAt: uint64(block.timestamp)}));
            emit EraStarted(agentId, era, owner, subject);
        }
    }

    /// @dev The current era's subject — what every agentId-keyed view reads.
    function _reputationSubject(uint256 agentId) internal view returns (bytes32 subject) {
        (uint256 era, ) = _currentEra(agentId);
        return _eraSubject(agentId, era);
    }

    /// @dev A payer bound to an agent (its TBA or a subaccount) pays as that
    ///      agent's owner. Paying needs no permission, so no check here.
    function _canonicalPayer(address payer) internal view returns (address) {
        (uint256 boundAgent, bool bound,,,) = identityRegistry.agentIdOf(payer);
        return bound ? identityRegistry.ownerOf(boundAgent) : payer;
    }

    /**
     * @dev Canonicalise a caller into the address that should be recorded as
     *      the client and used for dedup. If `caller` is bound (primary TBA
     *      or subaccount) to some agent in the IdentityRegistry, returns that agent's NFT
     *      owner; otherwise returns `caller` unchanged. Bound callers MUST
     *      hold `PERM_REPUTATION` — this prevents an agent from spamming
     *      reviews by spawning fresh subaccounts.
     */
    function _canonicalClient(address caller) internal view returns (address canonical, uint256 boundAgentId, bool isBound) {
        (uint256 agentId, bool bound,,,) = identityRegistry.agentIdOf(caller);
        if (!bound) return (caller, 0, false);
        require(
            identityRegistry.hasPermission(caller, identityRegistry.PERM_REPUTATION()),
            "Subaccount lacks PERM_REPUTATION"
        );
        return (identityRegistry.ownerOf(agentId), agentId, true);
    }

    // ── system reputation (recorders) ────────────────────────────────

    /**
     * @notice Record a settled hire. Called by the payment contract after it
     *         disbursed `amount` for `serviceId`. The payer becomes a paying
     *         client of the current era (and may attest); the hire counts
     *         toward the era's settlements and volume unless the payer is the
     *         agent's own owner.
     */
    function recordSettlement(uint256 agentId, address payer, bytes32 serviceId, uint256 amount)
        external
        onlySettlementRecorder
    {
        _recordSettlement(agentId, payer, serviceId, amount);
    }

    function _recordSettlement(uint256 agentId, address payer, bytes32 serviceId, uint256 amount) internal {
        address agentOwner = _ownerOfRef(agentId);
        (uint256 era, bytes32 subject) = _touchEraOf(agentId, agentOwner);
        address client = _canonicalPayer(payer);
        bool counted = client != agentOwner;
        if (counted) {
            EraStats storage st = _eraStats[subject];
            st.settlements += 1;
            st.volume += uint128(amount);
            st.lastSettlementAt = uint64(block.timestamp);
            paidSettlements[subject][client] += 1;
        }
        emit SettlementRecorded(agentId, era, client, serviceId, amount, counted);
    }

    /// @notice Record a dispute raised against the agent in its current era.
    function recordDispute(uint256 agentId, address client, bytes32 ref) external onlyDisputeRecorder {
        (uint256 era, bytes32 subject) = _touchEra(agentId);
        _eraStats[subject].disputes += 1;
        emit DisputeRecorded(agentId, era, _canonicalPayer(client), ref);
    }

    // ── attestations ─────────────────────────────────────────────────

    /**
     * @notice Attest to an agent you paid in its current owner's era.
     * @param value  -1 (negative), 0 (neutral) or 1 (positive) — the ERC-8004
     *               tri-state; `decimals` must be 0.
     * @param tag1   Primary tag (e.g. "x402").
     * @param tag2   Secondary tag (e.g. the service id).
     * @param feedbackURI  Evidence, e.g. "eip155:<chain>:<settlementTx>?mandate=<hash>".
     */
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 decimals,
        string calldata tag1,
        string calldata tag2,
        string calldata feedbackURI
    ) external {
        address agentOwner = _ownerOfRef(agentId); // reverts for a missing agent
        if (decimals != 0 || value < -1 || value > 1) revert ScoreOutOfRange();

        (address client, uint256 callerAgentId, bool isBound) = _canonicalClient(msg.sender);
        require(agentOwner != client, "Cannot review own agent");
        if (isBound) require(callerAgentId != agentId, "Cannot review own agent");

        (, bytes32 subject) = _touchEraOf(agentId, agentOwner);
        if (paidSettlements[subject][client] == 0) revert NotAPayingClient();
        require(!clientHasFeedback[subject][client], "Already gave feedback");

        feedbacks[subject].push(Feedback({
            client: client,
            value: value,
            decimals: 0,
            tag1: tag1,
            tag2: tag2,
            feedbackURI: feedbackURI,
            timestamp: block.timestamp,
            revoked: false
        }));
        clientHasFeedback[subject][client] = true;

        EraStats storage st = _eraStats[subject];
        st.feedbackCount += 1;
        st.feedbackSum += value;
        st.lastFeedbackAt = uint64(block.timestamp);

        if (bytes(tag1).length > 0) {
            tagScores[subject][tag1] += int256(value);
            tagCounts[subject][tag1]++;
        }
        if (bytes(tag2).length > 0) {
            tagScores[subject][tag2] += int256(value);
            tagCounts[subject][tag2]++;
        }

        emit FeedbackGiven(agentId, client, subject, value, tag1, feedbackURI);
    }

    /**
     * @notice Revoke your attestation in the agent's current era. Earlier
     *         eras are closed artifacts and can't be changed.
     */
    function revokeFeedback(uint256 agentId) external {
        (address client,, ) = _canonicalClient(msg.sender);
        bytes32 subject = _reputationSubject(agentId);
        require(clientHasFeedback[subject][client], "No feedback to revoke");

        Feedback[] storage list = feedbacks[subject];
        for (uint256 i = list.length; i > 0; i--) {
            Feedback storage fb = list[i - 1];
            if (fb.client != client || fb.revoked) continue;
            fb.revoked = true;
            if (bytes(fb.tag1).length > 0) {
                tagScores[subject][fb.tag1] -= int256(fb.value);
                tagCounts[subject][fb.tag1]--;
            }
            if (bytes(fb.tag2).length > 0) {
                tagScores[subject][fb.tag2] -= int256(fb.value);
                tagCounts[subject][fb.tag2]--;
            }
            EraStats storage st = _eraStats[subject];
            st.feedbackCount -= 1;
            st.feedbackSum -= fb.value;
            clientHasFeedback[subject][client] = false;
            emit FeedbackRevoked(agentId, client, subject, i - 1);
            return;
        }
        revert("Feedback not found");
    }

    // ── views: current era (ERC-8004 surface, unchanged signatures) ──

    /**
     * @notice Current era's summary: active attestations, their average
     *         (tri-state, so -1..1, integer division) and the latest time.
     */
    function getReputationSummary(uint256 agentId) external view returns (
        uint256 totalFeedbacks,
        int256 averageScore,
        uint256 lastFeedbackTime
    ) {
        EraStats storage st = _eraStats[_reputationSubject(agentId)];
        totalFeedbacks = st.feedbackCount;
        averageScore = st.feedbackCount > 0 ? int256(st.feedbackSum) / int256(uint256(st.feedbackCount)) : int256(0);
        lastFeedbackTime = st.lastFeedbackAt;
    }

    function getTagScore(uint256 agentId, string calldata tag) external view returns (
        int256 averageScore,
        uint256 feedbackCount
    ) {
        bytes32 subject = _reputationSubject(agentId);
        feedbackCount = tagCounts[subject][tag];
        averageScore = feedbackCount > 0 ? tagScores[subject][tag] / int256(feedbackCount) : int256(0);
    }

    /// @notice All attestations (including revoked) of the current era.
    function getFeedbacks(uint256 agentId) external view returns (
        address[] memory clients,
        int128[] memory values,
        string[] memory tags,
        uint256[] memory timestamps,
        bool[] memory revoked
    ) {
        Feedback[] storage list = feedbacks[_reputationSubject(agentId)];
        uint256 len = list.length;
        clients = new address[](len);
        values = new int128[](len);
        tags = new string[](len);
        timestamps = new uint256[](len);
        revoked = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            clients[i] = list[i].client;
            values[i] = list[i].value;
            tags[i] = list[i].tag1;
            timestamps[i] = list[i].timestamp;
            revoked[i] = list[i].revoked;
        }
    }

    function getFeedbackCount(uint256 agentId) external view returns (uint256) {
        return feedbacks[_reputationSubject(agentId)].length;
    }

    function getFeedbackAt(uint256 agentId, uint256 index) external view returns (
        address client,
        int128 value,
        uint8 decimals,
        string memory tag1,
        string memory tag2,
        string memory feedbackURI,
        uint256 timestamp,
        bool revoked
    ) {
        return _feedbackAt(_reputationSubject(agentId), index);
    }

    /// @notice The current era's subject key (for indexers).
    function reputationSubjectOf(uint256 agentId) external view returns (bytes32) {
        return _reputationSubject(agentId);
    }

    // ── views: eras (history across owners) ──────────────────────────

    /// @notice Number of eras including the current one (a new owner's era
    ///         counts before anything was recorded in it).
    function eraCount(uint256 agentId) external view returns (uint256) {
        (uint256 era, ) = _currentEra(agentId);
        return era + 1;
    }

    /// @notice The current era's index.
    function currentEra(uint256 agentId) external view returns (uint256) {
        (uint256 era, ) = _currentEra(agentId);
        return era;
    }

    /**
     * @notice An era's owner and span. `endedAt` is the start of the next
     *         recorded era, or 0 for the current era and for the last
     *         recorded era after a transfer nothing has touched yet.
     */
    function eraInfo(uint256 agentId, uint256 era) external view returns (address owner, uint64 startedAt, uint64 endedAt, bool current) {
        (uint256 cur, ) = _currentEra(agentId);
        if (era > cur) revert NoSuchEra();
        current = era == cur;
        Era[] storage list = _eras[agentId];
        if (era < list.length) {
            owner = list[era].owner;
            startedAt = list[era].startedAt;
            if (era + 1 < list.length) endedAt = list[era + 1].startedAt;
        } else {
            owner = _ownerOfRef(agentId); // current era, nothing recorded yet
        }
    }

    /// @notice An era's system reputation and attestation totals.
    function eraStats(uint256 agentId, uint256 era) external view returns (EraStats memory) {
        return _eraStats[_eraSubject(agentId, era)];
    }

    function eraFeedbackCount(uint256 agentId, uint256 era) external view returns (uint256) {
        return feedbacks[_eraSubject(agentId, era)].length;
    }

    function eraFeedbackAt(uint256 agentId, uint256 era, uint256 index) external view returns (
        address client,
        int128 value,
        uint8 decimals,
        string memory tag1,
        string memory tag2,
        string memory feedbackURI,
        uint256 timestamp,
        bool revoked
    ) {
        return _feedbackAt(_eraSubject(agentId, era), index);
    }

    // ── views: history from before eras ──────────────────────────────
    //
    // The first deployment stored attestations in the same `feedbacks`
    // mapping keyed by the agent id itself (mapping(uint256 => Feedback[]),
    // slot of `feedbacks`). Those entries predate eras and paid-only
    // attestation; they stay readable here as the agent's legacy history.

    function _legacyList(uint256 agentId) internal pure returns (Feedback[] storage list) {
        assembly {
            mstore(0x00, agentId)
            mstore(0x20, feedbacks.slot)
            list.slot := keccak256(0x00, 0x40)
        }
    }

    function legacyFeedbackCount(uint256 agentId) external view returns (uint256) {
        return _legacyList(agentId).length;
    }

    function legacyFeedbackAt(uint256 agentId, uint256 index) external view returns (
        address client,
        int128 value,
        uint8 decimals,
        string memory tag1,
        string memory tag2,
        string memory feedbackURI,
        uint256 timestamp,
        bool revoked
    ) {
        Feedback storage fb = _legacyList(agentId)[index];
        return (fb.client, fb.value, fb.decimals, fb.tag1, fb.tag2, fb.feedbackURI, fb.timestamp, fb.revoked);
    }

    function _feedbackAt(bytes32 subject, uint256 index) internal view returns (
        address client,
        int128 value,
        uint8 decimals,
        string memory tag1,
        string memory tag2,
        string memory feedbackURI,
        uint256 timestamp,
        bool revoked
    ) {
        Feedback storage fb = feedbacks[subject][index];
        return (fb.client, fb.value, fb.decimals, fb.tag1, fb.tag2, fb.feedbackURI, fb.timestamp, fb.revoked);
    }
}
