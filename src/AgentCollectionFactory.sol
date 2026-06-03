// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./AgentCollectionImpl.sol";
import "./AgentRoyaltySplitterFactory.sol";

/**
 * @title AgentCollectionFactory
 * @notice Factory for deploying Agent collections via Beacon Proxy pattern
 * @dev Each collection gets its own contract address = separate OpenSea collection
 * @dev All collections share the same upgradeable implementation via beacon
 * @dev Protocol fees: 2% on primary sales, 0.5% on secondary sales
 */
import {VimsProvenance} from "./VimsProvenance.sol";

contract AgentCollectionFactory is Ownable, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentCollectionFactory";
    }

    
    UpgradeableBeacon public immutable beacon;

    // Protocol fee configuration (immutable for trust)
    address public immutable protocolFeeRecipient;
    uint256 public constant PROTOCOL_PRIMARY_FEE_BPS = 200;   // 2% on primary sales
    uint256 public constant PROTOCOL_SECONDARY_FEE_BPS = 50;  // 0.5% on secondary sales

    // Royalty splitter factory (deployed alongside this factory in the same tx).
    // Used by {createCollectionWithSplits} so creators can split their royalty
    // across multiple wallets without leaving the mint flow.
    AgentRoyaltySplitterFactory public immutable splitterFactory;

    // splitter contract => collection contract that uses it as its creator.
    mapping(address => address) public collectionForSplitter;
    
    uint256 private _nextCollectionId;
    
    struct CollectionInfo {
        address contractAddress;
        address creator;
        string name;
        string symbol;
        uint256 maxSupply;
        uint256 createdAt;
    }
    
    mapping(uint256 => CollectionInfo) public collections;
    mapping(address => uint256[]) public creatorCollections;
    address[] public allCollections;
    
    event CollectionCreated(
        uint256 indexed collectionId,
        address indexed contractAddress,
        address indexed creator,
        string name,
        string symbol,
        uint256 maxSupply
    );
    
    event BeaconUpgraded(address indexed newImplementation);
    
    error InvalidName();
    error InvalidSymbol();
    error InvalidFeeRecipient();
    
    event CollectionCreatedWithSplits(
        uint256 indexed collectionId,
        address indexed contractAddress,
        address indexed creator,
        address splitter,
        address[] payees,
        uint256[] sharesBps
    );

    constructor(address implementation_, address protocolFeeRecipient_) Ownable(msg.sender) {
        if (protocolFeeRecipient_ == address(0)) revert InvalidFeeRecipient();
        beacon = new UpgradeableBeacon(implementation_, address(this));
        protocolFeeRecipient = protocolFeeRecipient_;
        splitterFactory = new AgentRoyaltySplitterFactory();
    }
    
    /**
     * @notice Create a new Agent collection
     * @param name_ Collection name (appears on OpenSea)
     * @param symbol_ Token symbol
     * @param maxSupply_ Maximum number of agents (0 = unlimited)
     * @param salesRoyaltyBps_ Default royalty for secondary sales (0-5000 = 0-50%)
     * @param serviceRoyaltyBps_ Default royalty for x402 service payments (0-5000 = 0-50%)
     * @param description_ Collection description
     * @return collectionId The ID of the new collection
     * @return contractAddress The deployed contract address
     */
    function createCollection(
        string calldata name_,
        string calldata symbol_,
        uint256 maxSupply_,
        uint256 salesRoyaltyBps_,
        uint256 serviceRoyaltyBps_,
        string calldata description_
    ) external returns (uint256 collectionId, address contractAddress) {
        return _createCollection(
            name_, symbol_, maxSupply_, salesRoyaltyBps_, serviceRoyaltyBps_,
            description_, msg.sender
        );
    }

    /**
     * @notice Create a new Agent collection whose creator-of-record is a
     *         freshly deployed {AgentRoyaltySplitter}. All primary mint
     *         revenue and ERC-2981 secondary royalty flow into the splitter,
     *         which can then be {release}d pro-rata to `payees`.
     *
     * @dev    Use this when the creator wants to split royalties across
     *         multiple wallets in a way that's enforceable on-chain. The
     *         splitter is immutable and pull-based.
     *
     * @param  payees     Recipient addresses (max {AgentRoyaltySplitter.MAX_PAYEES}).
     * @param  sharesBps  Per-payee basis points; must sum to 10_000.
     */
    function createCollectionWithSplits(
        string calldata name_,
        string calldata symbol_,
        uint256 maxSupply_,
        uint256 salesRoyaltyBps_,
        uint256 serviceRoyaltyBps_,
        string calldata description_,
        address[] calldata payees,
        uint256[] calldata sharesBps
    ) external returns (uint256 collectionId, address contractAddress, address splitter) {
        // Deploys + validates payee/bps arrays. Reverts on any malformed input.
        splitter = splitterFactory.deploySplitter(payees, sharesBps);

        // Governance (hooks, mint config, allowlist, lock) stays with the
        // deploying user. The splitter is wired in as the financial
        // recipient via {AgentCollectionImpl.setRoyaltyReceiverOnce}, which
        // takes effect for primary mint revenue, contractURI fee_recipient,
        // and ERC-2981 royaltyInfo. ERC-2981 marketplaces will therefore
        // remit secondary royalties straight into the splitter for every
        // token in the collection regardless of who minted it.
        (collectionId, contractAddress) = _createCollection(
            name_, symbol_, maxSupply_, salesRoyaltyBps_, serviceRoyaltyBps_,
            description_, msg.sender
        );
        AgentCollectionImpl(contractAddress).setRoyaltyReceiverOnce(splitter);

        collectionForSplitter[splitter] = contractAddress;
        emit CollectionCreatedWithSplits(
            collectionId, contractAddress, msg.sender, splitter, payees, sharesBps
        );
    }

    function _createCollection(
        string calldata name_,
        string calldata symbol_,
        uint256 maxSupply_,
        uint256 salesRoyaltyBps_,
        uint256 serviceRoyaltyBps_,
        string calldata description_,
        address creator_
    ) internal returns (uint256 collectionId, address contractAddress) {
        if (bytes(name_).length == 0) revert InvalidName();
        if (bytes(symbol_).length == 0) revert InvalidSymbol();

        collectionId = ++_nextCollectionId;

        bytes memory initData = abi.encodeWithSelector(
            AgentCollectionImpl.initialize.selector,
            name_,
            symbol_,
            maxSupply_,
            salesRoyaltyBps_,
            serviceRoyaltyBps_,
            creator_,
            description_,
            protocolFeeRecipient,
            PROTOCOL_PRIMARY_FEE_BPS,
            PROTOCOL_SECONDARY_FEE_BPS
        );

        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        contractAddress = address(proxy);

        collections[collectionId] = CollectionInfo({
            contractAddress: contractAddress,
            creator: creator_,
            name: name_,
            symbol: symbol_,
            maxSupply: maxSupply_,
            createdAt: block.timestamp
        });

        // Index the *deployer* (msg.sender) so getCollectionsByCreator() still
        // returns the user's collections even when the on-chain creator-of-
        // record is a splitter contract they deployed.
        creatorCollections[msg.sender].push(collectionId);
        allCollections.push(contractAddress);

        emit CollectionCreated(collectionId, contractAddress, creator_, name_, symbol_, maxSupply_);
    }
    
    /**
     * @notice Upgrade all collections to a new implementation
     * @dev Only factory owner can upgrade
     * @param newImplementation The new implementation address
     */
    function upgradeImplementation(address newImplementation) external onlyOwner {
        beacon.upgradeTo(newImplementation);
        emit BeaconUpgraded(newImplementation);
    }
    
    /**
     * @notice Get current implementation address
     */
    function implementation() external view returns (address) {
        return beacon.implementation();
    }
    
    /**
     * @notice Get all collections created by an address
     * @param creator The creator address
     * @return Array of collection IDs
     */
    function getCollectionsByCreator(address creator) external view returns (uint256[] memory) {
        return creatorCollections[creator];
    }
    
    /**
     * @notice Get total number of collections
     */
    function totalCollections() external view returns (uint256) {
        return _nextCollectionId;
    }
    
    /**
     * @notice Get all collection contract addresses
     */
    function getAllCollectionAddresses() external view returns (address[] memory) {
        return allCollections;
    }
    
    /**
     * @notice Get collection info by contract address
     * @param contractAddress The collection contract address
     * @return Collection info if found
     */
    function getCollectionByAddress(address contractAddress) external view returns (CollectionInfo memory) {
        for (uint256 i = 1; i <= _nextCollectionId; i++) {
            if (collections[i].contractAddress == contractAddress) {
                return collections[i];
            }
        }
        revert("Collection not found");
    }
}
