// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title AgentMarketplace
 * @notice On-chain ERC-721 marketplace for VIMS Agent NFTs. Supports
 *         fixed-price listings (no NFT escrow — seller approves the
 *         marketplace) and escrowed offers (bidder funds locked at
 *         make-offer time, refunded on cancel/expire). Settlement
 *         honours ERC-2981 royaltyInfo so creator royalties flow to
 *         the per-agent royalty vault automatically.
 *
 *         Native ETH is represented by paymentToken == address(0).
 *         All ERC-20 transfers go through SafeERC20.
 *
 *         The contract is intentionally NFT-collection-agnostic — it
 *         accepts any ERC-721 that implements IERC2981. Each listing /
 *         offer carries the (collection, tokenId) pair so the
 *         marketplace can serve every agent collection minted on the
 *         identity registry.
 */
contract AgentMarketplace is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712Upgradeable
{
    using SafeERC20 for IERC20;

    // ─── EIP-712 signed orders ───────────────────────────────────────
    //
    // Seaport-style off-chain orderbook: sellers sign listings (ASK)
    // and bidders sign collection bids (BID) without paying gas. Fills
    // verify the EIP-712 signature, royalty & fee splits run identical
    // to the on-chain `purchase` / `acceptOffer` paths.
    //
    // Smart-contract wallets (Safe, Argent, AA) are supported via
    // ERC-1271 through `SignatureChecker.isValidSignatureNow`.
    //
    // Bulk-cancel: incrementing `counters[offerer]` invalidates every
    // signature whose `counter` field doesn't match.
    //
    // Per-order cancel: `cancelOrder(o)` flips `orderCancelled[hash]`.
    // Filled orders flip `orderFilled[hash]`; both block re-fills.

    enum OrderSide { ASK, BID }

    struct Order {
        OrderSide side;
        address   offerer;
        address   collection;
        uint256   tokenId;        // ignored when criteriaRoot != 0
        address   paymentToken;  // address(0) == ETH (ASK only)
        uint256   price;
        uint64    startTime;
        uint64    endTime;       // 0 == no expiry
        uint256   salt;
        uint256   counter;
        bytes32   criteriaRoot;  // 0 == concrete order; non-zero == Merkle root over allowed tokenIds
    }

    /// @dev keccak256 of the canonical Order EIP-712 type string.
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(uint8 side,address offerer,address collection,uint256 tokenId,address paymentToken,uint256 price,uint64 startTime,uint64 endTime,uint256 salt,uint256 counter,bytes32 criteriaRoot)"
    );

    mapping(address => uint256) public counters;
    mapping(bytes32 => bool)    public orderFilled;
    mapping(bytes32 => bool)    public orderCancelled;

    // ─── Storage ─────────────────────────────────────────────────────

    enum ListingStatus { Open, Sold, Cancelled }
    enum OfferStatus   { Open, Accepted, Cancelled }

    struct Listing {
        address seller;
        address collection;
        uint256 tokenId;
        address paymentToken;   // address(0) == native ETH
        uint256 price;          // base units of paymentToken
        uint64  expiresAt;      // unix seconds; 0 == no expiry
        uint64  createdAt;
        ListingStatus status;
    }

    struct Offer {
        address bidder;
        address collection;
        uint256 tokenId;
        address paymentToken;   // address(0) == native ETH
        uint256 price;
        uint64  expiresAt;      // 0 == no expiry
        uint64  createdAt;
        OfferStatus status;
    }

    /// Marketplace protocol fee in bps (100 = 1%, max 1000 = 10%).
    uint256 public protocolFeeBps;
    address public feeRecipient;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 1000;
    uint256 public constant BPS_DENOM = 10_000;

    uint256 public listingCount;
    uint256 public offerCount;

    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Offer)   public offers;

    /// Reverse index: collection => tokenId => most recent open listing id (0 == none).
    mapping(address => mapping(uint256 => uint256)) public openListingOf;

    // ─── Events ──────────────────────────────────────────────────────

    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        address indexed collection,
        uint256 tokenId,
        address paymentToken,
        uint256 price,
        uint64  expiresAt
    );
    event ListingCancelled(uint256 indexed listingId);
    event ListingFilled(
        uint256 indexed listingId,
        address indexed buyer,
        uint256 royaltyPaid,
        uint256 protocolFeePaid,
        uint256 sellerProceeds
    );

    event OfferCreated(
        uint256 indexed offerId,
        address indexed bidder,
        address indexed collection,
        uint256 tokenId,
        address paymentToken,
        uint256 price,
        uint64  expiresAt
    );
    event OfferCancelled(uint256 indexed offerId);
    event OfferAccepted(
        uint256 indexed offerId,
        address indexed seller,
        uint256 royaltyPaid,
        uint256 protocolFeePaid,
        uint256 sellerProceeds
    );

    event ProtocolFeeUpdated(uint256 oldBps, uint256 newBps, address recipient);

    // ─── Errors ──────────────────────────────────────────────────────

    error ZeroPrice();
    error InvalidExpiry();
    error NotOwner();
    error NotApproved();
    error ListingNotOpen();
    error OfferNotOpen();
    error Expired();
    error WrongPayment();
    error TransferFailed();
    error CallerNotSeller();
    error CallerNotBidder();
    error NoSelfTrade();
    error FeeTooHigh();

    // ─── Init ────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address admin, address feeRecipient_, uint256 protocolFeeBps_)
        external
        initializer
    {
        if (protocolFeeBps_ > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh();
        __Ownable_init(admin);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __EIP712_init("AgentMarketplace", "1");
        feeRecipient = feeRecipient_;
        protocolFeeBps = protocolFeeBps_;
        emit ProtocolFeeUpdated(0, protocolFeeBps_, feeRecipient_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setProtocolFee(uint256 newBps, address recipient) external onlyOwner {
        if (newBps > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh();
        emit ProtocolFeeUpdated(protocolFeeBps, newBps, recipient);
        protocolFeeBps = newBps;
        feeRecipient = recipient;
    }

    // ─── Listings ────────────────────────────────────────────────────

    function createListing(
        address collection,
        uint256 tokenId,
        address paymentToken,
        uint256 price,
        uint64  expiresAt
    ) external returns (uint256 listingId) {
        if (price == 0) revert ZeroPrice();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert InvalidExpiry();
        IERC721 nft = IERC721(collection);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (
            !nft.isApprovedForAll(msg.sender, address(this))
            && nft.getApproved(tokenId) != address(this)
        ) revert NotApproved();

        // Auto-cancel any prior open listing for this token by the
        // same seller so subgraph state stays consistent.
        uint256 prior = openListingOf[collection][tokenId];
        if (prior != 0 && listings[prior].status == ListingStatus.Open) {
            listings[prior].status = ListingStatus.Cancelled;
            emit ListingCancelled(prior);
        }

        listingId = ++listingCount;
        listings[listingId] = Listing({
            seller: msg.sender,
            collection: collection,
            tokenId: tokenId,
            paymentToken: paymentToken,
            price: price,
            expiresAt: expiresAt,
            createdAt: uint64(block.timestamp),
            status: ListingStatus.Open
        });
        openListingOf[collection][tokenId] = listingId;
        emit ListingCreated(listingId, msg.sender, collection, tokenId, paymentToken, price, expiresAt);
    }

    function cancelListing(uint256 listingId) external {
        Listing storage l = listings[listingId];
        if (l.status != ListingStatus.Open) revert ListingNotOpen();
        if (l.seller != msg.sender) revert CallerNotSeller();
        l.status = ListingStatus.Cancelled;
        if (openListingOf[l.collection][l.tokenId] == listingId) {
            openListingOf[l.collection][l.tokenId] = 0;
        }
        emit ListingCancelled(listingId);
    }

    function purchase(uint256 listingId) external payable nonReentrant {
        Listing storage l = listings[listingId];
        if (l.status != ListingStatus.Open) revert ListingNotOpen();
        if (l.expiresAt != 0 && l.expiresAt <= block.timestamp) revert Expired();
        if (l.seller == msg.sender) revert NoSelfTrade();

        l.status = ListingStatus.Sold;
        if (openListingOf[l.collection][l.tokenId] == listingId) {
            openListingOf[l.collection][l.tokenId] = 0;
        }

        (uint256 royalty, uint256 fee, uint256 sellerCut, address royaltyReceiver) =
            _computeSplits(l.collection, l.tokenId, l.price);

        if (l.paymentToken == address(0)) {
            if (msg.value != l.price) revert WrongPayment();
            _payETH(royaltyReceiver, royalty);
            _payETH(feeRecipient, fee);
            _payETH(l.seller, sellerCut);
        } else {
            if (msg.value != 0) revert WrongPayment();
            IERC20 t = IERC20(l.paymentToken);
            if (royalty > 0) t.safeTransferFrom(msg.sender, royaltyReceiver, royalty);
            if (fee > 0)     t.safeTransferFrom(msg.sender, feeRecipient,    fee);
            t.safeTransferFrom(msg.sender, l.seller, sellerCut);
        }

        IERC721(l.collection).safeTransferFrom(l.seller, msg.sender, l.tokenId);
        emit ListingFilled(listingId, msg.sender, royalty, fee, sellerCut);
    }

    // ─── Offers ──────────────────────────────────────────────────────
    //
    // Bidder funds are escrowed in this contract on make-offer. ETH
    // escrow uses msg.value; ERC-20 escrow uses safeTransferFrom and
    // requires prior approval to this contract. Cancel and accept-
    // offer release the escrow back to the bidder / through to the
    // seller respectively.

    function makeOffer(
        address collection,
        uint256 tokenId,
        address paymentToken,
        uint256 price,
        uint64  expiresAt
    ) external payable nonReentrant returns (uint256 offerId) {
        if (price == 0) revert ZeroPrice();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert InvalidExpiry();
        if (IERC721(collection).ownerOf(tokenId) == msg.sender) revert NoSelfTrade();

        if (paymentToken == address(0)) {
            if (msg.value != price) revert WrongPayment();
        } else {
            if (msg.value != 0) revert WrongPayment();
            IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), price);
        }

        offerId = ++offerCount;
        offers[offerId] = Offer({
            bidder: msg.sender,
            collection: collection,
            tokenId: tokenId,
            paymentToken: paymentToken,
            price: price,
            expiresAt: expiresAt,
            createdAt: uint64(block.timestamp),
            status: OfferStatus.Open
        });
        emit OfferCreated(offerId, msg.sender, collection, tokenId, paymentToken, price, expiresAt);
    }

    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage o = offers[offerId];
        if (o.status != OfferStatus.Open) revert OfferNotOpen();
        // Allow bidder to cancel any time, OR anyone if expired (so
        // funds aren't locked when bidders go dark).
        bool isExpired = o.expiresAt != 0 && o.expiresAt <= block.timestamp;
        if (o.bidder != msg.sender && !isExpired) revert CallerNotBidder();

        o.status = OfferStatus.Cancelled;
        _refundEscrow(o);
        emit OfferCancelled(offerId);
    }

    function acceptOffer(uint256 offerId) external nonReentrant {
        Offer storage o = offers[offerId];
        if (o.status != OfferStatus.Open) revert OfferNotOpen();
        if (o.expiresAt != 0 && o.expiresAt <= block.timestamp) revert Expired();
        IERC721 nft = IERC721(o.collection);
        if (nft.ownerOf(o.tokenId) != msg.sender) revert NotOwner();
        if (
            !nft.isApprovedForAll(msg.sender, address(this))
            && nft.getApproved(o.tokenId) != address(this)
        ) revert NotApproved();

        o.status = OfferStatus.Accepted;
        // Cancel any matching open listing for this token.
        uint256 lid = openListingOf[o.collection][o.tokenId];
        if (lid != 0 && listings[lid].status == ListingStatus.Open) {
            listings[lid].status = ListingStatus.Cancelled;
            openListingOf[o.collection][o.tokenId] = 0;
            emit ListingCancelled(lid);
        }

        (uint256 royalty, uint256 fee, uint256 sellerCut, address royaltyReceiver) =
            _computeSplits(o.collection, o.tokenId, o.price);

        if (o.paymentToken == address(0)) {
            _payETH(royaltyReceiver, royalty);
            _payETH(feeRecipient, fee);
            _payETH(msg.sender, sellerCut);
        } else {
            IERC20 t = IERC20(o.paymentToken);
            if (royalty > 0) t.safeTransfer(royaltyReceiver, royalty);
            if (fee > 0)     t.safeTransfer(feeRecipient,    fee);
            t.safeTransfer(msg.sender, sellerCut);
        }

        nft.safeTransferFrom(msg.sender, o.bidder, o.tokenId);
        emit OfferAccepted(offerId, msg.sender, royalty, fee, sellerCut);
    }

    // ─── Internals ───────────────────────────────────────────────────

    function _computeSplits(address collection, uint256 tokenId, uint256 price)
        internal
        view
        returns (uint256 royalty, uint256 fee, uint256 sellerCut, address royaltyReceiver)
    {
        // ERC-2981 is optional on the collection. If royaltyInfo
        // reverts or returns a malformed split, treat as zero royalty
        // (defensive — never block a sale on a buggy royalty hook).
        try IERC2981(collection).royaltyInfo(tokenId, price) returns (address recv, uint256 amt) {
            if (amt < price) {
                royaltyReceiver = recv;
                royalty = amt;
            }
        } catch { /* royalty = 0 */ }

        fee = (price * protocolFeeBps) / BPS_DENOM;
        // Royalty + fee must not exceed price; ERC-2981 spec says it
        // shouldn't, but cap defensively.
        uint256 take = royalty + fee;
        if (take >= price) {
            // Pathological: skip royalty entirely to keep seller paid.
            royalty = 0;
            royaltyReceiver = address(0);
            take = fee;
        }
        sellerCut = price - take;
    }

    function _refundEscrow(Offer storage o) internal {
        if (o.paymentToken == address(0)) {
            _payETH(o.bidder, o.price);
        } else {
            IERC20(o.paymentToken).safeTransfer(o.bidder, o.price);
        }
    }

    function _payETH(address to, uint256 amount) internal {
        if (amount == 0 || to == address(0)) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Views ───────────────────────────────────────────────────────

    /// @notice Convenience getter that mirrors what the subgraph emits
    ///         so off-chain indexers and unit tests share one schema.
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }

    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return offers[offerId];
    }

    // ─── Signed orders (EIP-712 + EIP-1271) ──────────────────────────

    event OrderFulfilled(
        bytes32 indexed orderHash,
        address indexed offerer,
        address indexed taker,
        OrderSide side,
        address collection,
        uint256 tokenId,
        address paymentToken,
        uint256 price,
        uint256 royaltyPaid,
        uint256 protocolFeePaid,
        uint256 offererProceeds
    );
    event OrderCancelled(bytes32 indexed orderHash, address indexed offerer);
    event CounterIncremented(address indexed offerer, uint256 newCounter);

    /// @notice Emitted *before* `OrderFulfilled` on a criteria-fill so
    ///         indexers can attribute the resolved tokenId back to the
    ///         signed Merkle root (the standard OrderFulfilled event
    ///         only carries the concrete tokenId).
    event CriteriaOrderResolved(
        bytes32 indexed orderHash,
        bytes32 indexed criteriaRoot,
        uint256 resolvedTokenId
    );

    error InvalidSignature();
    error OrderInactive();
    error OrderConsumed();
    error WrongCounter();
    error WrongSide();
    error CallerNotOfferer();
    error BidPaymentMustBeERC20();
    error NotCriteriaOrder();
    error CriteriaOrderUseCriteriaFulfill();
    error InvalidCriteriaProof();

    /// @notice EIP-712 hash of an order — what the wallet signs.
    function hashOrder(Order calldata o) public view returns (bytes32) {
        return _hashTypedDataV4(_structHash(o));
    }

    /// @notice Increments the caller's counter, invalidating every
    ///         off-chain signature whose `counter` field doesn't match
    ///         the new value. Use as a global "cancel all my orders".
    function incrementCounter() external returns (uint256 newCounter) {
        unchecked { newCounter = ++counters[msg.sender]; }
        emit CounterIncremented(msg.sender, newCounter);
    }

    /// @notice Per-order cancel by the offerer. Cheap (single SSTORE).
    function cancelOrder(Order calldata o) external {
        if (o.offerer != msg.sender) revert CallerNotOfferer();
        bytes32 h = hashOrder(o);
        if (orderFilled[h] || orderCancelled[h]) revert OrderConsumed();
        orderCancelled[h] = true;
        emit OrderCancelled(h, msg.sender);
    }

    /// @notice Bulk per-order cancel.
    function cancelOrders(Order[] calldata os) external {
        uint256 n = os.length;
        for (uint256 i; i < n; ) {
            Order calldata o = os[i];
            if (o.offerer != msg.sender) revert CallerNotOfferer();
            bytes32 h = hashOrder(o);
            if (!orderFilled[h] && !orderCancelled[h]) {
                orderCancelled[h] = true;
                emit OrderCancelled(h, msg.sender);
            }
            unchecked { ++i; }
        }
    }

    /// @notice Fulfill a single signed order.
    /// @dev    For ASK: msg.sender is the buyer; sends ETH/ERC-20.
    ///         For BID: msg.sender is the seller (NFT owner); pulls
    ///         ERC-20 from offerer (must have approved this contract).
    function fulfillOrder(Order calldata o, bytes calldata sig)
        external
        payable
        nonReentrant
    {
        _fulfillOne(o, sig, msg.value);
    }

    /// @notice Bulk-fill multiple orders in a single tx (sweep).
    /// @dev    Pass an array of msg.value-equivalents per order via the
    ///         `ethPerOrder` argument; sum must equal msg.value. ERC-20
    ///         orders carry 0. Failures revert the entire batch.
    function fulfillOrders(
        Order[] calldata orders_,
        bytes[]  calldata sigs,
        uint256[] calldata ethPerOrder
    ) external payable nonReentrant {
        uint256 n = orders_.length;
        require(sigs.length == n && ethPerOrder.length == n, "len");
        uint256 sum;
        for (uint256 i; i < n; ) {
            sum += ethPerOrder[i];
            unchecked { ++i; }
        }
        if (sum != msg.value) revert WrongPayment();
        for (uint256 i; i < n; ) {
            _fulfillOne(orders_[i], sigs[i], ethPerOrder[i]);
            unchecked { ++i; }
        }
    }

    function _fulfillOne(Order calldata o, bytes calldata sig, uint256 ethValue) internal {
        // Concrete orders only — criteria orders go through fulfillCriteriaOrder.
        if (o.criteriaRoot != bytes32(0)) revert CriteriaOrderUseCriteriaFulfill();
        _fulfillCore(o, sig, ethValue, o.tokenId);
    }

    /// @notice Fulfill a criteria-bound signed order by supplying the
    ///         concrete tokenId being traded and a Merkle proof against
    ///         `o.criteriaRoot`. The criteria leaf is
    ///         `keccak256(bytes.concat(keccak256(abi.encode(tokenId))))`
    ///         (OpenZeppelin's standard double-hash convention).
    ///
    /// @dev    Use case: collection-wide bids ("I'll buy any tokenId
    ///         in this whitelist for Y USDC"), seller-side bundle asks,
    ///         trait-filtered bids. Concrete `tokenId` field is ignored
    ///         when criteriaRoot != 0 so signers don't have to
    ///         enumerate every token upfront.
    function fulfillCriteriaOrder(
        Order calldata o,
        bytes calldata sig,
        uint256 resolvedTokenId,
        bytes32[] calldata proof
    ) external payable nonReentrant {
        if (o.criteriaRoot == bytes32(0)) revert NotCriteriaOrder();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(resolvedTokenId))));
        if (!MerkleProof.verify(proof, o.criteriaRoot, leaf)) revert InvalidCriteriaProof();
        emit CriteriaOrderResolved(hashOrder(o), o.criteriaRoot, resolvedTokenId);
        _fulfillCore(o, sig, msg.value, resolvedTokenId);
    }

    /// @notice Bulk criteria-fill — same semantics as fulfillOrders but
    ///         each order gets a `(resolvedTokenId, proof)` pair.
    function fulfillCriteriaOrders(
        Order[]     calldata orders_,
        bytes[]     calldata sigs,
        uint256[]   calldata resolvedTokenIds,
        bytes32[][] calldata proofs,
        uint256[]   calldata ethPerOrder
    ) external payable nonReentrant {
        uint256 n = orders_.length;
        require(
            sigs.length == n &&
            resolvedTokenIds.length == n &&
            proofs.length == n &&
            ethPerOrder.length == n,
            "len"
        );
        uint256 sum;
        for (uint256 i; i < n; ) { sum += ethPerOrder[i]; unchecked { ++i; } }
        if (sum != msg.value) revert WrongPayment();
        for (uint256 i; i < n; ) {
            Order calldata o = orders_[i];
            if (o.criteriaRoot == bytes32(0)) revert NotCriteriaOrder();
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(resolvedTokenIds[i]))));
            if (!MerkleProof.verify(proofs[i], o.criteriaRoot, leaf)) revert InvalidCriteriaProof();
            emit CriteriaOrderResolved(hashOrder(o), o.criteriaRoot, resolvedTokenIds[i]);
            _fulfillCore(o, sigs[i], ethPerOrder[i], resolvedTokenIds[i]);
            unchecked { ++i; }
        }
    }

    /// @dev Shared settlement core. `resolvedTokenId` is the concrete
    ///      tokenId actually transferred — equal to `o.tokenId` for
    ///      concrete orders, Merkle-proof-resolved for criteria orders.
    function _fulfillCore(
        Order calldata o,
        bytes calldata sig,
        uint256 ethValue,
        uint256 resolvedTokenId
    ) internal {
        // 1. Time window.
        if (o.startTime != 0 && block.timestamp < o.startTime) revert OrderInactive();
        if (o.endTime   != 0 && block.timestamp >= o.endTime)  revert Expired();

        // 2. Counter freshness.
        if (o.counter != counters[o.offerer]) revert WrongCounter();

        // 3. Self-trade guard.
        if (o.offerer == msg.sender) revert NoSelfTrade();

        // 4. Order status (hashed over the signed Order, not the resolved id).
        bytes32 h = hashOrder(o);
        if (orderFilled[h] || orderCancelled[h]) revert OrderConsumed();

        // 5. Signature (ECDSA or ERC-1271).
        if (!SignatureChecker.isValidSignatureNow(o.offerer, h, sig)) {
            revert InvalidSignature();
        }

        // 6. Mark filled before any external call. NB: for criteria
        //    orders the order hash is consumed in full on first fill,
        //    so each criteria order is single-use. A signer who wants
        //    a fillable-N criteria order must sign N distinct salts.
        orderFilled[h] = true;

        // 7. Settlement splits (computed on the *resolved* tokenId so
        //    ERC-2981 royaltyInfo reflects the actual traded token).
        (uint256 royalty, uint256 fee, uint256 offererProceeds, address royaltyReceiver) =
            _computeSplits(o.collection, resolvedTokenId, o.price);

        if (o.side == OrderSide.ASK) {
            // offerer is seller, msg.sender is buyer.
            if (o.paymentToken == address(0)) {
                if (ethValue != o.price) revert WrongPayment();
                _payETH(royaltyReceiver, royalty);
                _payETH(feeRecipient,    fee);
                _payETH(o.offerer,       offererProceeds);
            } else {
                if (ethValue != 0) revert WrongPayment();
                IERC20 t = IERC20(o.paymentToken);
                if (royalty > 0) t.safeTransferFrom(msg.sender, royaltyReceiver, royalty);
                if (fee > 0)     t.safeTransferFrom(msg.sender, feeRecipient,    fee);
                t.safeTransferFrom(msg.sender, o.offerer, offererProceeds);
            }
            // Verify NFT ownership at fill time and pull from seller.
            IERC721 nft = IERC721(o.collection);
            if (nft.ownerOf(resolvedTokenId) != o.offerer) revert NotOwner();
            nft.safeTransferFrom(o.offerer, msg.sender, resolvedTokenId);

            // If a matching on-chain listing existed, mark it Cancelled
            // so the subgraph stays consistent.
            uint256 lid = openListingOf[o.collection][resolvedTokenId];
            if (lid != 0 && listings[lid].status == ListingStatus.Open) {
                listings[lid].status = ListingStatus.Cancelled;
                openListingOf[o.collection][resolvedTokenId] = 0;
                emit ListingCancelled(lid);
            }
        } else {
            // BID: offerer is buyer, msg.sender is seller.
            if (o.paymentToken == address(0)) revert BidPaymentMustBeERC20();
            if (ethValue != 0) revert WrongPayment();
            IERC721 nft = IERC721(o.collection);
            if (nft.ownerOf(resolvedTokenId) != msg.sender) revert NotOwner();

            IERC20 t = IERC20(o.paymentToken);
            if (royalty > 0) t.safeTransferFrom(o.offerer, royaltyReceiver, royalty);
            if (fee > 0)     t.safeTransferFrom(o.offerer, feeRecipient,    fee);
            t.safeTransferFrom(o.offerer, msg.sender, offererProceeds);

            nft.safeTransferFrom(msg.sender, o.offerer, resolvedTokenId);
        }

        emit OrderFulfilled(
            h, o.offerer, msg.sender, o.side,
            o.collection, resolvedTokenId, o.paymentToken, o.price,
            royalty, fee, offererProceeds
        );
    }

    function _structHash(Order calldata o) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            ORDER_TYPEHASH,
            uint8(o.side),
            o.offerer,
            o.collection,
            o.tokenId,
            o.paymentToken,
            o.price,
            o.startTime,
            o.endTime,
            o.salt,
            o.counter,
            o.criteriaRoot
        ));
    }

    /// @notice EIP-712 domain separator for off-chain signers.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Storage gap for future upgrades.
    uint256[40] private __gap;
}
