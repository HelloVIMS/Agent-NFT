// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {VimsProvenance} from "./VimsProvenance.sol";

interface ICurveCollection {
    function factory() external view returns (address);
    function collectionCreator() external view returns (address);
    function royaltyReceiver() external view returns (address);
    function protocolFeeRecipient() external view returns (address);
    function protocolPrimaryFeeBps() external view returns (uint256);
}

/**
 * @title  AgentCurveMarket
 * @notice Sells a collection's agents along a price curve (CurveMath), in
 *         ETH or USDC, buy-only or reserve-backed — each collection's
 *         creator chooses, and the terms lock at the first sale.
 *
 *         The creator stocks agents it minted; each sale is priced by how
 *         many agents this market has out (`sold`). With a reserve, a share
 *         of every sale (`reserveBps` of its price) stays here, and a holder
 *         of an agent bought here can sell it back for that share of the
 *         price of the last one out: exactly what that position added. The
 *         reserve therefore always equals Σ share(price(i)) for i < sold —
 *         every holder can sell back at once — and a returned agent goes back
 *         into stock, identity intact, for the next buyer.
 *
 *         The rest of each sale pays the protocol fee the collection carries
 *         (its primary-sale fee) and the collection's payee, credited here
 *         and withdrawn by them (a payee that refuses ETH can't block sales).
 *
 * @dev    Immutable: no owner, no upgrade path — nobody can change the rules
 *         under a reserve. Only collections created by the VIMS factory
 *         (their proxy's runtime code) can be sold here.
 */
contract AgentCurveMarket is ReentrancyGuard, IERC721Receiver, VimsProvenance {
    using SafeERC20 for IERC20;

    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentCurveMarket";
    }

    struct Sale {
        CurveMath.Curve curve;
        address currency;   // address(0): ETH; else `usdc`
        uint16  reserveBps; // 0: buy-only
        bool    configured;
        bool    started;    // terms are locked
        uint32  sold;       // agents out through this market: the curve position
        uint256 reserve;
    }

    /// @notice Runtime code of the factory's collection proxies.
    bytes32 public immutable collectionCodehash;
    address public immutable collectionFactory;
    address public immutable usdc;

    mapping(address => Sale) internal _sales;
    mapping(address => uint256[]) internal _stock;
    /// @notice collection => token => bought here and not sold back.
    mapping(address => mapping(uint256 => bool)) public outFromHere;
    /// @notice currency (0: ETH) => account => withdrawable.
    mapping(address => mapping(address => uint256)) public credit;

    address private _stocking;

    event SaleConfigured(address indexed collection, CurveMath.Curve curve, address currency, uint16 reserveBps);
    event Stocked(address indexed collection, uint256 indexed tokenId);
    event Unstocked(address indexed collection, uint256 indexed tokenId);
    event Bought(address indexed collection, uint256 indexed tokenId, address indexed buyer, uint256 price, uint256 toReserve, uint32 sold);
    event SoldBack(address indexed collection, uint256 indexed tokenId, address indexed seller, uint256 payout, uint32 sold);
    event Withdrawn(address indexed currency, address indexed account, uint256 amount);

    error NotACollection();
    error NotCreator();
    error TermsLocked();
    error NotConfigured();
    error UnsupportedCurrency();
    error ReserveTooHigh();
    error SoldOut();
    error PriceAboveLimit(uint256 price, uint256 limit);
    error PayoutBelowLimit(uint256 payout, uint256 limit);
    error WrongPayment();
    error NoReserve();
    error NotBoughtHere();
    error AlreadyOutstanding();
    error NotHolder();
    error Unsolicited();
    error NothingToWithdraw();
    error TransferFailed();

    constructor(address usdc_, address referenceCollection) {
        if (usdc_.code.length == 0 || referenceCollection.code.length == 0) revert NotACollection();
        collectionFactory = ICurveCollection(referenceCollection).factory();
        if (collectionFactory.code.length == 0) revert NotACollection();
        usdc = usdc_;
        collectionCodehash = referenceCollection.codehash;
    }

    // ── creator ───────────────────────────────────────────────────────────

    /// @notice Set (or, before the first sale, change) a collection's terms.
    function configure(address collection, CurveMath.Curve calldata curve, address currency, uint16 reserveBps) external nonReentrant {
        _onlyCreator(collection);
        Sale storage s = _sales[collection];
        if (s.started) revert TermsLocked();
        if (currency != address(0) && currency != usdc) revert UnsupportedCurrency();
        if (reserveBps > 10_000) revert ReserveTooHigh();
        CurveMath.validate(curve);
        s.curve = curve;
        s.currency = currency;
        s.reserveBps = reserveBps;
        s.configured = true;
        emit SaleConfigured(collection, curve, currency, reserveBps);
    }

    /// @notice Hand agents over for sale (each approved to this market).
    function stock(address collection, uint256[] calldata tokenIds) external nonReentrant {
        _onlyCreator(collection);
        _stocking = collection;
        for (uint256 i; i < tokenIds.length; ++i) {
            if (outFromHere[collection][tokenIds[i]]) revert AlreadyOutstanding();
            IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenIds[i]);
            _stock[collection].push(tokenIds[i]);
            emit Stocked(collection, tokenIds[i]);
        }
        _stocking = address(0);
    }

    /// @notice Take up to `n` unsold agents back (the reserve stays for holders).
    function unstock(address collection, uint256 n) external nonReentrant {
        _onlyCreator(collection);
        uint256[] storage st = _stock[collection];
        for (uint256 i; i < n && st.length > 0; ++i) {
            uint256 id = st[st.length - 1];
            st.pop();
            IERC721(collection).transferFrom(address(this), msg.sender, id);
            emit Unstocked(collection, id);
        }
    }

    // ── buyers and holders ─────────────────────────────────────────────────

    /// @notice Buy the next agent at no more than `maxPrice`. ETH: send at
    ///         least the price (the rest comes back); USDC: approve it.
    function buy(address collection, uint256 maxPrice) external payable nonReentrant returns (uint256 tokenId, uint256 price) {
        Sale storage s = _sales[collection];
        if (!s.configured) revert NotConfigured();
        uint256[] storage st = _stock[collection];
        if (st.length == 0) revert SoldOut();
        price = CurveMath.priceAt(s.curve, s.sold);
        if (price > maxPrice) revert PriceAboveLimit(price, maxPrice);
        address cur = s.currency;
        if (cur == address(0)) {
            if (msg.value < price) revert WrongPayment();
        } else {
            if (msg.value != 0) revert WrongPayment();
            IERC20(cur).safeTransferFrom(msg.sender, address(this), price);
        }

        uint256 toReserve = _share(price, s.reserveBps);
        s.reserve += toReserve;
        s.started = true;
        uint32 sold = ++s.sold;
        _creditProceeds(collection, cur, price - toReserve);

        tokenId = st[st.length - 1];
        st.pop();
        outFromHere[collection][tokenId] = true;
        emit Bought(collection, tokenId, msg.sender, price, toReserve, sold);

        IERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId);
        if (cur == address(0) && msg.value > price) _sendETH(msg.sender, msg.value - price);
    }

    /// @notice Sell back an agent bought here for its reserve share, no less
    ///         than `minPayout` (approve this market for the agent first).
    function sell(address collection, uint256 tokenId, uint256 minPayout) external nonReentrant returns (uint256 payout) {
        Sale storage s = _sales[collection];
        if (s.reserveBps == 0) revert NoReserve();
        if (!outFromHere[collection][tokenId]) revert NotBoughtHere();
        if (IERC721(collection).ownerOf(tokenId) != msg.sender) revert NotHolder();
        uint32 sold = --s.sold;
        payout = _share(CurveMath.priceAt(s.curve, sold), s.reserveBps);
        if (payout < minPayout) revert PayoutBelowLimit(payout, minPayout);
        s.reserve -= payout;
        outFromHere[collection][tokenId] = false;
        _stock[collection].push(tokenId);
        emit SoldBack(collection, tokenId, msg.sender, payout, sold);

        IERC721(collection).transferFrom(msg.sender, address(this), tokenId);
        _pay(s.currency, msg.sender, payout);
    }

    /// @notice Withdraw what sales credited to you in `currency` (0: ETH).
    function withdraw(address currency) external {
        withdrawFor(currency, msg.sender);
    }

    function withdrawFor(address currency, address account) public nonReentrant {
        uint256 amount = credit[currency][account];
        if (amount == 0) revert NothingToWithdraw();
        credit[currency][account] = 0;
        emit Withdrawn(currency, account, amount);
        _pay(currency, account, amount);
    }

    // ── reads ───────────────────────────────────────────────────────────

    function saleOf(address collection) external view returns (Sale memory) {
        return _sales[collection];
    }

    function stockOf(address collection) external view returns (uint256) {
        return _stock[collection].length;
    }

    /// @notice What the next `n` agents cost, together (ignores stock).
    function quoteBuy(address collection, uint256 n) external view returns (uint256) {
        Sale storage s = _sales[collection];
        if (!s.configured) revert NotConfigured();
        return CurveMath.costOf(s.curve, s.sold, n);
    }

    /// @notice What selling one agent back pays now.
    function quoteSell(address collection) external view returns (uint256) {
        Sale storage s = _sales[collection];
        if (s.reserveBps == 0 || s.sold == 0) return 0;
        return _share(CurveMath.priceAt(s.curve, s.sold - 1), s.reserveBps);
    }

    /// @notice Price of the agent when `sold` are out, for drawing the curve.
    function priceAt(address collection, uint256 sold) external view returns (uint256) {
        Sale storage s = _sales[collection];
        if (!s.configured) revert NotConfigured();
        return CurveMath.priceAt(s.curve, sold);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != _stocking) revert Unsolicited();
        return IERC721Receiver.onERC721Received.selector;
    }

    // ── internal ─────────────────────────────────────────────────────────

    function _onlyCreator(address collection) internal view {
        if (collection.codehash != collectionCodehash || ICurveCollection(collection).factory() != collectionFactory) revert NotACollection();
        if (ICurveCollection(collection).collectionCreator() != msg.sender) revert NotCreator();
    }

    function _share(uint256 price, uint16 bps) internal pure returns (uint256) {
        return (price * bps) / 10_000;
    }

    /// @dev The collection's primary-sale fee to its protocol recipient, the
    ///      rest to its payee (royalty receiver, else creator).
    function _creditProceeds(address collection, address cur, uint256 amount) internal {
        ICurveCollection c = ICurveCollection(collection);
        address protocol = c.protocolFeeRecipient();
        uint256 fee = protocol == address(0) ? 0 : (amount * c.protocolPrimaryFeeBps()) / 10_000;
        if (fee > 0) credit[cur][protocol] += fee;
        address payee = c.royaltyReceiver();
        if (payee == address(0)) payee = c.collectionCreator();
        credit[cur][payee] += amount - fee;
    }

    function _pay(address cur, address to, uint256 amount) internal {
        if (cur == address(0)) _sendETH(to, amount);
        else IERC20(cur).safeTransfer(to, amount);
    }

    function _sendETH(address to, uint256 amount) internal {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
