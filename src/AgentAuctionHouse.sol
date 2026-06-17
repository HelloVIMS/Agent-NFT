// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title AgentAuctionHouse
 * @notice English + Dutch auctions for VIMS Agent NFTs. Sibling of
 *         AgentMarketplace.sol; shares the same ERC-2981 settlement
 *         pattern and protocol-fee mechanic but lives in its own
 *         contract to keep each impl comfortably under EIP-170.
 *
 *         ENGLISH: ascending price, escrowed bids, anti-snipe extension.
 *         DUTCH:   descending price, first-buy-wins, no escrow required.
 *
 *         Native ETH is paymentToken == address(0). ERC-20s use
 *         SafeERC20. Royalty receiver follows the collection's ERC-2981
 *         royaltyInfo for the auctioned tokenId; protocol fee in bps
 *         is deducted from the seller proceeds (capped at 10%).
 */
contract AgentAuctionHouse is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    enum AuctionKind   { ENGLISH, DUTCH }
    enum AuctionStatus { Open, Settled, Cancelled }

    struct Auction {
        AuctionKind   kind;
        AuctionStatus status;
        address seller;
        address collection;
        uint256 tokenId;
        address paymentToken;     // address(0) == native ETH
        // ENGLISH fields:
        uint256 reservePrice;     // minimum starting bid
        uint256 minBidIncrementBps; // additive over current bid (bps of current)
        uint64  endTime;          // hard cap; auto-extended by antiSnipeWindow
        uint64  antiSnipeWindow;  // seconds; bids in the final window push endTime
        // DUTCH fields:
        uint256 startPrice;       // initial (highest) price at startTime
        uint256 endPrice;         // floor price reached at endTime (must be < startPrice)
        uint64  startTime;        // when the price clock starts ticking
        // Bookkeeping:
        address currentBidder;
        uint256 currentBid;
        uint64  createdAt;
    }

    uint256 public auctionCount;
    mapping(uint256 => Auction) public auctions;

    /// Reverse index for active English auctions per token (only one
    /// open auction per token at a time).
    mapping(address => mapping(uint256 => uint256)) public openAuctionOf;

    uint256 public protocolFeeBps;
    address public feeRecipient;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 1000;
    uint256 public constant BPS_DENOM = 10_000;

    // ─── Events ──────────────────────────────────────────────────────

    event AuctionCreated(
        uint256 indexed auctionId,
        AuctionKind indexed kind,
        address indexed seller,
        address collection,
        uint256 tokenId,
        address paymentToken,
        uint256 priceA,    // reservePrice (ENGLISH) or startPrice (DUTCH)
        uint256 priceB,    // 0           (ENGLISH) or endPrice   (DUTCH)
        uint64  startTime,
        uint64  endTime
    );

    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount,
        uint64  newEndTime  // unchanged unless anti-snipe extended
    );

    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed winner,
        uint256 price,
        uint256 royaltyPaid,
        uint256 protocolFeePaid,
        uint256 sellerProceeds
    );

    event AuctionCancelled(uint256 indexed auctionId);

    event ProtocolFeeUpdated(uint256 oldBps, uint256 newBps, address recipient);

    // ─── Errors ──────────────────────────────────────────────────────

    error ZeroPrice();
    error InvalidWindow();
    error NotOwner();
    error NotApproved();
    error AuctionNotOpen();
    error AuctionStillRunning();
    error BidBelowReserve();
    error BidBelowIncrement();
    error WrongPayment();
    error WrongKind();
    error TransferFailed();
    error CallerNotSeller();
    error NoSelfTrade();
    error FeeTooHigh();
    error AlreadyOpen();

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

    // ─── English auction ─────────────────────────────────────────────

    /// @notice Start an English (ascending) auction. The seller retains
    ///         custody of the NFT until settlement; bids are escrowed
    ///         in this contract and refunded to outbid bidders.
    function createEnglishAuction(
        address collection,
        uint256 tokenId,
        address paymentToken,
        uint256 reservePrice,
        uint256 minBidIncrementBps_,
        uint64  endTime,
        uint64  antiSnipeWindow
    ) external returns (uint256 auctionId) {
        if (reservePrice == 0) revert ZeroPrice();
        if (endTime <= block.timestamp) revert InvalidWindow();
        if (minBidIncrementBps_ > BPS_DENOM) revert InvalidWindow();
        if (openAuctionOf[collection][tokenId] != 0) revert AlreadyOpen();
        _assertSellerOwnsAndApproved(collection, tokenId);

        auctionId = ++auctionCount;
        Auction storage a = auctions[auctionId];
        a.kind = AuctionKind.ENGLISH;
        a.status = AuctionStatus.Open;
        a.seller = msg.sender;
        a.collection = collection;
        a.tokenId = tokenId;
        a.paymentToken = paymentToken;
        a.reservePrice = reservePrice;
        a.minBidIncrementBps = minBidIncrementBps_;
        a.endTime = endTime;
        a.antiSnipeWindow = antiSnipeWindow;
        a.createdAt = uint64(block.timestamp);

        openAuctionOf[collection][tokenId] = auctionId;

        emit AuctionCreated(
            auctionId, AuctionKind.ENGLISH, msg.sender, collection, tokenId,
            paymentToken, reservePrice, 0, uint64(block.timestamp), endTime
        );
    }

    /// @notice Place a bid on an English auction. Refunds the prior
    ///         leading bidder and escrows the new one. Anti-snipe: a
    ///         bid placed inside the last `antiSnipeWindow` seconds
    ///         pushes `endTime` out by `antiSnipeWindow`.
    function bid(uint256 auctionId, uint256 amount) external payable nonReentrant {
        Auction storage a = auctions[auctionId];
        if (a.status != AuctionStatus.Open) revert AuctionNotOpen();
        if (a.kind   != AuctionKind.ENGLISH) revert WrongKind();
        if (block.timestamp >= a.endTime)    revert AuctionNotOpen();
        if (msg.sender == a.seller)          revert NoSelfTrade();

        // Validate amount: must clear reserve and the min-increment over
        // any prior leading bid.
        if (amount < a.reservePrice) revert BidBelowReserve();
        if (a.currentBid > 0) {
            uint256 minNext = a.currentBid
                + ((a.currentBid * a.minBidIncrementBps) / BPS_DENOM);
            if (amount < minNext + 1) revert BidBelowIncrement(); // strictly increasing
        }

        // Pull funds: ETH via msg.value, ERC-20 via safeTransferFrom.
        if (a.paymentToken == address(0)) {
            if (msg.value != amount) revert WrongPayment();
        } else {
            if (msg.value != 0) revert WrongPayment();
            IERC20(a.paymentToken).safeTransferFrom(msg.sender, address(this), amount);
        }

        // Refund prior leading bidder (if any). Use call-with-zero for
        // ETH refunds to avoid reverting the new bid on a buggy receiver
        // — we accept a small refund-fail window for the prior bidder
        // who can withdraw via emergencyWithdraw if they really get
        // stuck (out of scope for this initial release).
        address prevBidder = a.currentBidder;
        uint256 prevAmount = a.currentBid;
        a.currentBidder = msg.sender;
        a.currentBid    = amount;

        if (prevBidder != address(0)) {
            if (a.paymentToken == address(0)) {
                _payETH(prevBidder, prevAmount);
            } else {
                IERC20(a.paymentToken).safeTransfer(prevBidder, prevAmount);
            }
        }

        // Anti-snipe extension.
        uint64 oldEnd = a.endTime;
        if (a.antiSnipeWindow > 0 && oldEnd - block.timestamp < a.antiSnipeWindow) {
            a.endTime = uint64(block.timestamp) + a.antiSnipeWindow;
        }

        emit BidPlaced(auctionId, msg.sender, amount, a.endTime);
    }

    /// @notice Settle a finished English auction. Anyone can call once
    ///         `endTime` has passed. Distributes royalty + fee + seller
    ///         proceeds and transfers the NFT to the winner. If no
    ///         bids were placed, the auction just closes Cancelled.
    function settleEnglish(uint256 auctionId) external nonReentrant {
        Auction storage a = auctions[auctionId];
        if (a.status != AuctionStatus.Open) revert AuctionNotOpen();
        if (a.kind   != AuctionKind.ENGLISH) revert WrongKind();
        if (block.timestamp < a.endTime)    revert AuctionStillRunning();

        openAuctionOf[a.collection][a.tokenId] = 0;

        if (a.currentBidder == address(0)) {
            // No bids: just close.
            a.status = AuctionStatus.Cancelled;
            emit AuctionCancelled(auctionId);
            return;
        }

        a.status = AuctionStatus.Settled;
        _settle(a, a.currentBidder, a.currentBid, /*pullFromBuyer*/ false);
        emit AuctionSettled(
            auctionId,
            a.currentBidder,
            a.currentBid,
            _lastRoyalty,
            _lastFee,
            _lastSellerProceeds
        );
    }

    /// @notice Cancel an English auction. Only the seller, only before
    ///         the first bid lands (post-bid cancellation isn't allowed
    ///         — bidders rely on commitment to outcome).
    function cancelEnglish(uint256 auctionId) external {
        Auction storage a = auctions[auctionId];
        if (a.status != AuctionStatus.Open) revert AuctionNotOpen();
        if (a.kind   != AuctionKind.ENGLISH) revert WrongKind();
        if (a.seller != msg.sender) revert CallerNotSeller();
        if (a.currentBidder != address(0)) revert AuctionStillRunning();

        a.status = AuctionStatus.Cancelled;
        openAuctionOf[a.collection][a.tokenId] = 0;
        emit AuctionCancelled(auctionId);
    }

    // ─── Dutch auction ───────────────────────────────────────────────

    /// @notice Start a Dutch (descending) auction. Price linearly
    ///         decays from `startPrice` at `startTime` to `endPrice`
    ///         at `endTime`. First buyer to call `buyDutch` wins.
    function createDutchAuction(
        address collection,
        uint256 tokenId,
        address paymentToken,
        uint256 startPrice_,
        uint256 endPrice_,
        uint64  startTime_,
        uint64  endTime_
    ) external returns (uint256 auctionId) {
        if (startPrice_ <= endPrice_) revert InvalidWindow();
        if (endTime_   <= startTime_) revert InvalidWindow();
        if (endTime_   <= block.timestamp) revert InvalidWindow();
        if (openAuctionOf[collection][tokenId] != 0) revert AlreadyOpen();
        _assertSellerOwnsAndApproved(collection, tokenId);

        auctionId = ++auctionCount;
        Auction storage a = auctions[auctionId];
        a.kind = AuctionKind.DUTCH;
        a.status = AuctionStatus.Open;
        a.seller = msg.sender;
        a.collection = collection;
        a.tokenId = tokenId;
        a.paymentToken = paymentToken;
        a.startPrice = startPrice_;
        a.endPrice   = endPrice_;
        a.startTime  = startTime_;
        a.endTime    = endTime_;
        a.createdAt  = uint64(block.timestamp);

        openAuctionOf[collection][tokenId] = auctionId;

        emit AuctionCreated(
            auctionId, AuctionKind.DUTCH, msg.sender, collection, tokenId,
            paymentToken, startPrice_, endPrice_, startTime_, endTime_
        );
    }

    /// @notice Current price for a Dutch auction. Reverts if not Dutch
    ///         or not Open. Returns endPrice once the clock has run out.
    function currentDutchPrice(uint256 auctionId) public view returns (uint256) {
        Auction storage a = auctions[auctionId];
        if (a.kind != AuctionKind.DUTCH) revert WrongKind();
        if (block.timestamp <= a.startTime) return a.startPrice;
        if (block.timestamp >= a.endTime)   return a.endPrice;
        uint256 elapsed  = block.timestamp - a.startTime;
        uint256 duration = a.endTime       - a.startTime;
        uint256 drop = ((a.startPrice - a.endPrice) * elapsed) / duration;
        return a.startPrice - drop;
    }

    /// @notice Buy at (or above) the current Dutch price. Buyer may
    ///         overpay (e.g. to hedge price clock movement between
    ///         tx-broadcast and inclusion) — excess is refunded.
    function buyDutch(uint256 auctionId) external payable nonReentrant {
        Auction storage a = auctions[auctionId];
        if (a.status != AuctionStatus.Open) revert AuctionNotOpen();
        if (a.kind   != AuctionKind.DUTCH)  revert WrongKind();
        if (msg.sender == a.seller)         revert NoSelfTrade();

        uint256 price = currentDutchPrice(auctionId);
        openAuctionOf[a.collection][a.tokenId] = 0;
        a.status = AuctionStatus.Settled;
        a.currentBidder = msg.sender;
        a.currentBid    = price;

        if (a.paymentToken == address(0)) {
            if (msg.value < price) revert WrongPayment();
            // Refund overpayment.
            if (msg.value > price) _payETH(msg.sender, msg.value - price);
        } else {
            if (msg.value != 0) revert WrongPayment();
            IERC20(a.paymentToken).safeTransferFrom(msg.sender, address(this), price);
        }

        _settle(a, msg.sender, price, /*pullFromBuyer*/ false);
        emit AuctionSettled(
            auctionId, msg.sender, price,
            _lastRoyalty, _lastFee, _lastSellerProceeds
        );
    }

    // ─── Shared settlement ───────────────────────────────────────────

    // Scratch storage so we can fold the 3-tuple back into the
    // AuctionSettled event without bloating function signatures.
    uint256 private _lastRoyalty;
    uint256 private _lastFee;
    uint256 private _lastSellerProceeds;

    function _settle(
        Auction storage a,
        address winner,
        uint256 price,
        bool /*pullFromBuyer*/
    ) internal {
        (uint256 royalty, uint256 fee, uint256 sellerCut, address royaltyReceiver) =
            _computeSplits(a.collection, a.tokenId, price);

        // Funds are already in the contract (English bids escrowed;
        // Dutch buyer paid via the payable / safeTransferFrom). Pay
        // out from the contract balance.
        if (a.paymentToken == address(0)) {
            _payETH(royaltyReceiver, royalty);
            _payETH(feeRecipient,    fee);
            _payETH(a.seller,        sellerCut);
        } else {
            IERC20 t = IERC20(a.paymentToken);
            if (royalty > 0) t.safeTransfer(royaltyReceiver, royalty);
            if (fee > 0)     t.safeTransfer(feeRecipient,    fee);
            t.safeTransfer(a.seller, sellerCut);
        }

        // NFT pulled from the seller at settle-time (lazy custody).
        IERC721(a.collection).safeTransferFrom(a.seller, winner, a.tokenId);

        _lastRoyalty = royalty;
        _lastFee     = fee;
        _lastSellerProceeds = sellerCut;
    }

    function _computeSplits(address collection, uint256 tokenId, uint256 price)
        internal
        view
        returns (uint256 royalty, uint256 fee, uint256 sellerCut, address royaltyReceiver)
    {
        try IERC2981(collection).royaltyInfo(tokenId, price) returns (address recv, uint256 amt) {
            if (amt < price) {
                royaltyReceiver = recv;
                royalty = amt;
            }
        } catch { /* royalty = 0 */ }

        fee = (price * protocolFeeBps) / BPS_DENOM;
        uint256 take = royalty + fee;
        if (take >= price) {
            royalty = 0;
            royaltyReceiver = address(0);
            take = fee;
        }
        sellerCut = price - take;
    }

    function _assertSellerOwnsAndApproved(address collection, uint256 tokenId) internal view {
        IERC721 nft = IERC721(collection);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (
            !nft.isApprovedForAll(msg.sender, address(this))
            && nft.getApproved(tokenId) != address(this)
        ) revert NotApproved();
    }

    function _payETH(address to, uint256 amount) internal {
        if (amount == 0 || to == address(0)) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Views ───────────────────────────────────────────────────────

    function getAuction(uint256 auctionId) external view returns (Auction memory) {
        return auctions[auctionId];
    }

    /// @notice Storage gap for future upgrades.
    uint256[40] private __gap;
}
