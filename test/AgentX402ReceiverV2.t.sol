// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentX402Receiver.sol";
import "../src/interfaces/IAgentNFTAdapter.sol";

/// @dev Minimal ERC-3009 USDC mock. Same shape as MockUSDC in the V1 test file
///      but lives in its own contract here to keep the two suites independent
///      and avoid file-scope name clashes when forge compiles them together.
contract MockUSDC2 is ERC20 {
    mapping(address => mapping(bytes32 => bool)) public used;
    constructor() ERC20("Mock USDC V2", "mUSDC2") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8, bytes32, bytes32
    ) external {
        require(to == msg.sender, "3009: to != msg.sender");
        require(block.timestamp > validAfter, "3009: too early");
        require(block.timestamp < validBefore, "3009: expired");
        require(!used[from][nonce], "3009: nonce used");
        used[from][nonce] = true;
        _transfer(from, to, value);
    }
}

/// @dev Minimal NFT that doubles as its own {IAgentNFTAdapter}. Models the
///      production case where {AgentCollectionImpl} self-adapts: ownerOf
///      from ERC-721, a per-collection service royalty fixed at deploy time,
///      and a manually-set TBA per tokenId.
/// @dev Mirrors {AgentCollectionImpl.collectionCreator} so the receiver's
///      permissionless `selfRegisterCollection` path can verify creator
///      identity in tests without spinning up the full collection deploy.
interface IMockCollectionCreator {
    function collectionCreator() external view returns (address);
}

contract MockCollectionNFT is ERC721, IAgentNFTAdapter, IMockCollectionCreator {
    address public immutable override(IMockCollectionCreator) collectionCreator;
    uint256 public immutable serviceRoyaltyBps;
    mapping(uint256 => address) public tba;
    uint256 public nextId = 1;

    constructor(address creator_, uint256 bps_) ERC721("Mock Coll", "MC") {
        collectionCreator = creator_;
        serviceRoyaltyBps = bps_;
    }

    function mintTo(address to) external returns (uint256 id) {
        id = nextId++;
        _safeMint(to, id);
    }

    function setTba(uint256 id, address acct) external { tba[id] = acct; }

    // IAgentNFTAdapter
    function ownerOf(uint256 tokenId)
        public
        view
        override(ERC721, IAgentNFTAdapter)
        returns (address)
    {
        return ERC721.ownerOf(tokenId);
    }

    function serviceRoyaltyOf(uint256 /*tokenId*/) external view returns (address, uint256) {
        return (collectionCreator, serviceRoyaltyBps);
    }

    function tbaOf(uint256 tokenId) external view returns (address) {
        return tba[tokenId];
    }
}

contract AgentX402ReceiverV2Test is Test {
    AgentIdentityRegistry public registry;
    AgentX402Receiver     public x402;
    MockUSDC2             public usdc;
    MockCollectionNFT     public nft;

    address public owner    = address(0xA11CE);
    address public collectionCreator = address(0xC0FFEE);
    address public minter;
    uint256 public minterPk = 0xBA5E;
    address public payer;
    uint256 public payerPk  = 0xBA5E_BA5E;
    address public treasury = address(0x7E2A);
    address public stranger = address(0xDEADBEEF);

    uint256 public tokenId;
    bytes32 public constant SID = keccak256("api/chat/v1");
    uint256 public constant DEADLINE = type(uint256).max;
    uint256 public constant PRICE = 100e6;

    function setUp() public {
        minter = vm.addr(minterPk);
        payer  = vm.addr(payerPk);

        vm.startPrank(owner);
        // Identity registry only needed because the receiver init requires it.
        AgentIdentityRegistry regImpl = new AgentIdentityRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        );
        registry = AgentIdentityRegistry(address(regProxy));

        AgentX402Receiver x402Impl = new AgentX402Receiver();
        ERC1967Proxy x402Proxy = new ERC1967Proxy(
            address(x402Impl),
            abi.encodeCall(
                AgentX402Receiver.initialize,
                (address(registry), treasury, 50) // 0.5% system fee
            )
        );
        x402 = AgentX402Receiver(address(x402Proxy));
        vm.stopPrank();

        usdc = new MockUSDC2();
        // Collection-level 10% creator royalty
        nft  = new MockCollectionNFT(collectionCreator, 1000);

        vm.prank(owner);
        x402.setTokenAllowed(address(usdc), true);
        // Wire the collection on the receiver via the permissionless self-
        // registration path. This is the *only* onboarding entrypoint —
        // there are no admin shortcuts.
        vm.prank(collectionCreator);
        x402.selfRegisterCollection(address(nft));

        // Mint a token to `minter`. NFT owner != creator — important for the
        // royalty-routing semantic check.
        tokenId = nft.mintTo(minter);
        usdc.mint(payer, 1_000e6);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _register(uint256 price) internal {
        vm.prank(minter);
        x402.registerServiceForNFT(address(nft), tokenId, SID, address(usdc), price);
    }

    function _signCommit(bytes32 _nonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = x402.hashPaymentCommitmentForNFT(
            address(nft), tokenId, SID, address(usdc), PRICE, _nonce, DEADLINE
        );
        (v, r, s) = vm.sign(payerPk, digest);
    }

    function _pay(bytes32 nonce) internal returns (uint256) {
        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(nonce);
        return x402.payForServiceForNFT(
            address(nft), tokenId, SID, payer,
            0, DEADLINE,
            nonce, 0, bytes32(0), bytes32(0),
            cv, cr, cs
        );
    }

    // ─── auth: token owner vs trusted registrar vs stranger ──────────────────

    function test_RegisterServiceForNFT_TokenOwnerAllowed() public {
        _register(PRICE);
        AgentX402Receiver.Service memory svc =
            x402.getServiceForNFT(address(nft), tokenId, SID);
        assertEq(svc.price, PRICE);
        assertTrue(svc.active);
    }

    function test_RegisterServiceForNFT_StrangerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(AgentX402Receiver.NotOwner.selector);
        x402.registerServiceForNFT(address(nft), tokenId, SID, address(usdc), PRICE);
    }

    function test_RegisterServiceForNFT_TrustedRegistrarAllowed() public {
        // After self-onboarding, the collection contract itself is the trusted
        // registrar (used by the V3 atomic-mint path on AgentCollectionImpl).
        // We simulate that by pranking as `address(nft)` and bypassing the
        // ownerOf check.
        vm.prank(address(nft));
        x402.registerServiceForNFT(address(nft), tokenId, SID, address(usdc), PRICE);
        assertEq(
            x402.getServiceForNFT(address(nft), tokenId, SID).price,
            PRICE
        );
    }

    function test_RegisterServiceForNFT_AdapterNotSetReverts() public {
        // A fresh, un-onboarded collection has no adapter. A non-registrar
        // call must revert with AdapterNotSet rather than NotOwner. There is
        // no admin-clear path anymore; the only way to land in this state is
        // before a collection has called selfRegisterCollection.
        MockCollectionNFT fresh = new MockCollectionNFT(collectionCreator, 1000);
        uint256 freshId = fresh.mintTo(minter);
        vm.prank(minter);
        vm.expectRevert(AgentX402Receiver.AdapterNotSet.selector);
        x402.registerServiceForNFT(address(fresh), freshId, SID, address(usdc), PRICE);
    }

    function test_RegisterServiceForNFT_TokenNotAllowedReverts() public {
        ERC20 randomToken = new MockUSDC2();
        vm.prank(minter);
        vm.expectRevert(AgentX402Receiver.TokenNotAllowed.selector);
        x402.registerServiceForNFT(address(nft), tokenId, SID, address(randomToken), PRICE);
    }

    function test_RegisterServiceForNFT_ZeroPriceReverts() public {
        vm.prank(minter);
        vm.expectRevert(AgentX402Receiver.InvalidPrice.selector);
        x402.registerServiceForNFT(address(nft), tokenId, SID, address(usdc), 0);
    }

    function test_RegisterServiceForNFT_DuplicateReverts() public {
        _register(PRICE);
        vm.prank(minter);
        vm.expectRevert(AgentX402Receiver.ServiceAlreadyExists.selector);
        x402.registerServiceForNFT(address(nft), tokenId, SID, address(usdc), PRICE);
    }

    // ─── service updates ─────────────────────────────────────────────────────

    function test_UpdateServiceForNFT_OwnerCanChangePriceAndActive() public {
        _register(PRICE);
        vm.prank(minter);
        x402.updateServiceForNFT(address(nft), tokenId, SID, 50e6, false);
        AgentX402Receiver.Service memory svc =
            x402.getServiceForNFT(address(nft), tokenId, SID);
        assertEq(svc.price, 50e6);
        assertFalse(svc.active);
    }

    function test_UpdateServiceForNFT_StrangerReverts() public {
        _register(PRICE);
        vm.prank(stranger);
        vm.expectRevert(AgentX402Receiver.NotOwner.selector);
        x402.updateServiceForNFT(address(nft), tokenId, SID, 50e6, false);
    }

    function test_UpdateServiceForNFT_MissingServiceReverts() public {
        vm.prank(minter);
        vm.expectRevert(AgentX402Receiver.ServiceInactive.selector);
        x402.updateServiceForNFT(address(nft), tokenId, SID, 50e6, false);
    }

    // ─── settlement happy path ───────────────────────────────────────────────

    function test_PayForServiceForNFT_RoutesToOwner_NoTBA() public {
        _register(PRICE);
        _pay(bytes32(uint256(1)));

        // Owner of the NFT is `minter` (NOT collectionCreator). With no TBA,
        // agent payout flows to the NFT owner, and the creator royalty flows
        // to the collection creator. This is the key semantic difference
        // versus the legacy single-source path.
        assertEq(usdc.balanceOf(treasury),          500_000);     // 0.5%
        assertEq(usdc.balanceOf(collectionCreator), 10_000_000);  // 10%
        assertEq(usdc.balanceOf(minter),            89_500_000);  // 89.5%
        assertEq(usdc.balanceOf(payer),             900_000_000);
        assertEq(usdc.balanceOf(address(x402)),     0);
    }

    function test_PayForServiceForNFT_RoutesToTBA_WhenSet() public {
        address tba = address(0xBADCAFE);
        nft.setTba(tokenId, tba);

        _register(PRICE);
        _pay(bytes32(uint256(2)));

        assertEq(usdc.balanceOf(treasury),          500_000);
        assertEq(usdc.balanceOf(collectionCreator), 10_000_000);
        assertEq(usdc.balanceOf(tba),               89_500_000);
        assertEq(usdc.balanceOf(minter),            0);
    }

    function test_PayForServiceForNFT_EmitsServicePaidForNFT() public {
        _register(PRICE);
        vm.expectEmit(true, true, true, true, address(x402));
        emit AgentX402Receiver.ServicePaidForNFT(
            address(nft), tokenId, SID, payer, address(usdc),
            PRICE, 500_000, 10_000_000, 89_500_000, minter
        );
        _pay(bytes32(uint256(3)));
    }

    function test_QuoteSplitForNFT_MatchesPayout() public {
        _register(PRICE);
        (uint256 gross, uint256 sys, uint256 cr, uint256 ag) =
            x402.quoteSplitForNFT(address(nft), tokenId, SID);
        assertEq(gross, PRICE);
        assertEq(sys,    500_000);
        assertEq(cr,     10_000_000);
        assertEq(ag,     89_500_000);
    }

    // ─── settlement safety: typehash isolation, replay, missing adapter ──────

    function test_PayForServiceForNFT_V1SignatureRejected() public {
        // Sign with the V1 typehash via the legacy hash function — should
        // NOT validate against the V2 path even with matching nominal fields.
        _register(PRICE);
        bytes32 nonce = bytes32(uint256(0xDEAD));
        bytes32 v1Digest = x402.hashPaymentCommitment(
            tokenId, SID, address(usdc), PRICE, nonce, DEADLINE
        );
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(payerPk, v1Digest);
        vm.expectRevert(AgentX402Receiver.InvalidCommitment.selector);
        x402.payForServiceForNFT(
            address(nft), tokenId, SID, payer,
            0, DEADLINE,
            nonce, 0, bytes32(0), bytes32(0),
            cv, cr, cs
        );
    }

    // NOTE: An "adapter cleared after register" test previously lived here.
    // After removing `setNFTAdapter`, that state is unreachable: registration
    // requires the adapter (`AdapterNotSet` in `_requireTokenOwnerOrRegistrar`),
    // so an active service + missing adapter cannot coexist. Coverage of the
    // {AdapterNotSet} branch is preserved by
    // `test_RegisterServiceForNFT_AdapterNotSetReverts`.

    function test_PayForServiceForNFT_InactiveServiceReverts() public {
        _register(PRICE);
        vm.prank(minter);
        x402.updateServiceForNFT(address(nft), tokenId, SID, PRICE, false);

        bytes32 nonce = bytes32(uint256(8));
        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(nonce);
        vm.expectRevert(AgentX402Receiver.ServiceInactive.selector);
        x402.payForServiceForNFT(
            address(nft), tokenId, SID, payer,
            0, DEADLINE,
            nonce, 0, bytes32(0), bytes32(0),
            cv, cr, cs
        );
    }

    function test_PayForServiceForNFT_NoncesAreSingleUse() public {
        _register(PRICE);
        bytes32 nonce = bytes32(uint256(99));
        _pay(nonce);
        // Same nonce — EIP-3009 mock rejects.
        (uint8 cv, bytes32 cr, bytes32 cs) = _signCommit(nonce);
        vm.expectRevert(bytes("3009: nonce used"));
        x402.payForServiceForNFT(
            address(nft), tokenId, SID, payer,
            0, DEADLINE,
            nonce, 0, bytes32(0), bytes32(0),
            cv, cr, cs
        );
    }

    // ─── keyspace isolation: V2 services don't bleed into legacy storage ─────

    function test_RegisterServiceForNFT_DoesNotPopulateLegacyServices() public {
        _register(PRICE);
        // Legacy `services[tokenId][SID]` must remain empty even though the
        // tokenId numeric value matches an entry in `servicesByNFT`.
        AgentX402Receiver.Service memory legacy = x402.getService(tokenId, SID);
        assertEq(legacy.token, address(0));
        assertEq(legacy.price, 0);
        assertFalse(legacy.active);
    }

    // ─── ownership transfer changes payout target ────────────────────────────

    function test_PayForServiceForNFT_PaysNewOwnerAfterTransfer() public {
        _register(PRICE);
        address newOwner = address(0xFEED);
        vm.prank(minter);
        nft.transferFrom(minter, newOwner, tokenId);

        _pay(bytes32(uint256(10)));

        assertEq(usdc.balanceOf(newOwner),          89_500_000);
        assertEq(usdc.balanceOf(minter),            0);
        assertEq(usdc.balanceOf(collectionCreator), 10_000_000);
        assertEq(usdc.balanceOf(treasury),          500_000);
    }

    // ─── permissionless onboarding: selfRegisterCollection ───────────────────

    function test_SelfRegisterCollection_CreatorWiresAdapterAndRegistrar() public {
        // Fresh receiver state for this collection: no admin wiring at all.
        MockCollectionNFT fresh = new MockCollectionNFT(collectionCreator, 1000);
        // Adapter must be unset before the call.
        assertEq(address(x402.nftAdapters(address(fresh))), address(0));
        assertEq(x402.trustedRegistrarFor(address(fresh)), address(0));

        vm.prank(collectionCreator);
        x402.selfRegisterCollection(address(fresh));

        assertEq(address(x402.nftAdapters(address(fresh))), address(fresh));
        assertEq(x402.trustedRegistrarFor(address(fresh)), address(fresh));
    }

    function test_SelfRegisterCollection_NonCreatorReverts() public {
        MockCollectionNFT fresh = new MockCollectionNFT(collectionCreator, 1000);
        vm.prank(stranger);
        vm.expectRevert(AgentX402Receiver.NotCollectionCreator.selector);
        x402.selfRegisterCollection(address(fresh));
    }

    function test_SelfRegisterCollection_ZeroAddressReverts() public {
        vm.prank(collectionCreator);
        vm.expectRevert(AgentX402Receiver.ZeroAddress.selector);
        x402.selfRegisterCollection(address(0));
    }

    function test_SelfRegisterCollection_DoublyRegisteredReverts() public {
        // The setUp() helper already wired the suite-wide `nft` via admin.
        // A second self-register on the same address must revert so a
        // compromised creator cannot rotate adapters without admin.
        vm.prank(collectionCreator);
        vm.expectRevert(AgentX402Receiver.ServiceAlreadyExists.selector);
        x402.selfRegisterCollection(address(nft));
    }

    function test_SelfRegisterCollection_EmitsCollectionAutoRegistered() public {
        MockCollectionNFT fresh = new MockCollectionNFT(collectionCreator, 1000);
        vm.expectEmit(true, true, true, true, address(x402));
        emit AgentX402Receiver.CollectionAutoRegistered(address(fresh), collectionCreator);
        vm.prank(collectionCreator);
        x402.selfRegisterCollection(address(fresh));
    }

    function test_SelfRegisterCollection_BlockedWhenPaused() public {
        MockCollectionNFT fresh = new MockCollectionNFT(collectionCreator, 1000);
        vm.prank(owner);
        x402.pause();
        vm.prank(collectionCreator);
        // OZ Pausable revert: bytes("Pausable: paused") wasn't used in OZ v5.
        // The selector EnforcedPause()(0xd93c0665) is what gets emitted; we
        // assert any revert here so the test stays robust to OZ patches.
        vm.expectRevert();
        x402.selfRegisterCollection(address(fresh));
    }

    function test_SelfRegisterCollection_RevertsForContractWithoutCreatorGetter() public {
        // Use an arbitrary EOA-shaped address — calling `collectionCreator()`
        // on a non-contract reverts inside viem-style call decoding. The
        // exact selector is staticcall-revert with no data, so we just
        // assert any revert.
        vm.prank(collectionCreator);
        vm.expectRevert();
        x402.selfRegisterCollection(address(0xDEAD));
    }
}
