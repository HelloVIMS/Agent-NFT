// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/AgentIdentityRegistry.sol";
import "../src/AgentX402Receiver.sol";

/// @dev Minimal ERC-3009 USDC mock. Records nonces, transfers balance.
///      Skips ECDSA verification — the unit tests focus on the receiver's
///      split + commit + event semantics, which is what x402 cares about.
contract MockUSDC is ERC20 {
    mapping(address => mapping(bytes32 => bool)) public used;
    constructor() ERC20("Mock USDC", "mUSDC") {}
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

    function authorizationState(address from, bytes32 nonce) external view returns (bool) {
        return used[from][nonce];
    }
}

contract AgentX402ReceiverTest is Test {
    AgentIdentityRegistry public registry;
    AgentX402Receiver     public x402;
    MockUSDC              public usdc;

    address public owner    = address(0xA11CE);
    address public creator;
    uint256 public creatorPk = 0xC0FFEE;
    address public payer;
    uint256 public payerPk   = 0xBA5E;
    address public treasury  = address(0x7E2A);

    uint256 public agentId;
    bytes32 public constant SID = keccak256("api/chat/v1");
    uint256 public constant DEADLINE = type(uint256).max;

    function setUp() public {
        creator = vm.addr(creatorPk);
        payer   = vm.addr(payerPk);

        vm.startPrank(owner);

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

        usdc = new MockUSDC();

        // Owner allowlists USDC.
        vm.prank(owner);
        x402.setTokenAllowed(address(usdc), true);

        // Creator mints an agent (10% creator royalty).
        vm.prank(creator);
        agentId = registry.registerAgent("AgentA", "ipfs://meta", 1000, address(0));

        usdc.mint(payer, 1_000e6);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _register(uint256 price) internal {
        vm.prank(creator);
        x402.registerService(agentId, SID, address(usdc), price);
    }

    function _registerWithId(bytes32 sid, uint256 price) internal {
        vm.prank(creator);
        x402.registerService(agentId, sid, address(usdc), price);
    }

    /// @dev Sign the EIP-712 PaymentCommitment with `payerPk`.
    function _signCommit(
        uint256 _agentId,
        bytes32 _sid,
        uint256 _amount,
        bytes32 _nonce,
        uint256 _validBefore
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = x402.hashPaymentCommitment(
            _agentId, _sid, address(usdc), _amount, _nonce, _validBefore
        );
        (v, r, s) = vm.sign(payerPk, digest);
    }

    function _pay(bytes32 nonce) internal returns (uint256) {
        return _payAs(agentId, SID, nonce);
    }

    function _payAs(uint256 _agentId, bytes32 _sid, bytes32 _nonce) internal returns (uint256) {
        uint256 amount = x402.getService(_agentId, _sid).price;
        (uint8 cv, bytes32 cr, bytes32 cs) =
            _signCommit(_agentId, _sid, amount, _nonce, DEADLINE);
        return x402.payForService(
            _agentId, _sid, payer,
            0, DEADLINE,
            _nonce, 0, bytes32(0), bytes32(0),
            cv, cr, cs
        );
    }

    // ─── happy path ──────────────────────────────────────────────────────────

    function test_Initialize_Fields() public view {
        assertEq(address(x402.identityRegistry()), address(registry));
        assertEq(x402.treasury(), treasury);
        assertEq(x402.systemFeeBps(), 50);
        assertTrue(x402.allowedTokens(address(usdc)));
    }

    function test_RegisterService_Stores() public {
        _register(10e6);
        AgentX402Receiver.Service memory svc = x402.getService(agentId, SID);
        assertEq(svc.token, address(usdc));
        assertEq(svc.price, 10e6);
        assertTrue(svc.active);
    }

    function test_QuoteSplit_ComputesRoyalties() public {
        _register(100e6);
        (uint256 gross, uint256 sysCut, uint256 creatorCut, uint256 agentCut) =
            x402.quoteSplit(agentId, SID);
        assertEq(gross, 100e6);
        assertEq(sysCut,     500_000);
        assertEq(creatorCut, 10_000_000);
        assertEq(agentCut,   89_500_000);
    }

    function test_PayForService_SplitsAtomically_NoTBA() public {
        _register(100e6);
        _pay(bytes32(uint256(1)));

        // No TBA → agent recipient = ownerOf = creator. So creator
        // accumulates BOTH the 10% royalty and the 89.5% agent cut.
        assertEq(usdc.balanceOf(treasury), 500_000);
        assertEq(usdc.balanceOf(creator),  99_500_000);
        assertEq(usdc.balanceOf(payer),    900_000_000);
        assertEq(usdc.balanceOf(address(x402)), 0);
    }

    function test_PayForService_RoutesToTBA_WhenSet() public {
        address tba = address(0xBADCAFE);
        vm.prank(creator);
        registry.setTBAAddress(agentId, tba);

        _register(100e6);
        _pay(bytes32(uint256(2)));

        assertEq(usdc.balanceOf(treasury), 500_000);
        assertEq(usdc.balanceOf(creator),  10_000_000);
        assertEq(usdc.balanceOf(tba),      89_500_000);
    }

    function test_PayForService_EmitsServicePaid() public {
        address tba = address(0xBADCAFE);
        vm.prank(creator);
        registry.setTBAAddress(agentId, tba);
        _register(100e6);

        vm.expectEmit(true, true, true, true, address(x402));
        emit AgentX402Receiver.ServicePaid(
            agentId, SID, payer, address(usdc),
            100e6, 500_000, 10_000_000, 89_500_000, tba
        );
        _pay(bytes32(uint256(3)));
    }

    function test_UpdateService_ChangesPriceAndActive() public {
        _register(100e6);
        vm.prank(creator);
        x402.updateService(agentId, SID, 50e6, false);
        AgentX402Receiver.Service memory svc = x402.getService(agentId, SID);
        assertEq(svc.price, 50e6);
        assertFalse(svc.active);
    }

    // ─── M-1: EIP-712 commitment ─────────────────────────────────────────────

    function test_RevertWhen_CommitmentSignedByWrongKey() public {
        _register(10e6);
        // Sign with a different key.
        bytes32 digest = x402.hashPaymentCommitment(
            agentId, SID, address(usdc), 10e6, bytes32(uint256(99)), DEADLINE
        );
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(0xDEADBEEF, digest);
        vm.expectRevert(AgentX402Receiver.InvalidCommitment.selector);
        x402.payForService(
            agentId, SID, payer,
            0, DEADLINE,
            bytes32(uint256(99)), 0, bytes32(0), bytes32(0),
            cv, cr, cs
        );
    }

    function test_RevertWhen_CommitmentRedirectsToOtherService() public {
        // Two services at the same price.
        _register(10e6);
        bytes32 SID2 = keccak256("api/something_else/v1");
        _registerWithId(SID2, 10e6);

        // Commit signed for SID — but caller tries to apply it to SID2.
        bytes32 nonce = bytes32(uint256(123));
        (uint8 cv, bytes32 cr, bytes32 cs) =
            _signCommit(agentId, SID, 10e6, nonce, DEADLINE);

        vm.expectRevert(AgentX402Receiver.InvalidCommitment.selector);
        x402.payForService(
            agentId, SID2, payer,
            0, DEADLINE,
            nonce, 0, bytes32(0), bytes32(0),
            cv, cr, cs
        );
    }

    function test_RevertWhen_CommitmentReusesNonce() public {
        _register(10e6);
        bytes32 nonce = bytes32(uint256(7));
        _pay(nonce);

        // Second attempt with the same nonce — pre-compute everything so
        // `vm.expectRevert` immediately precedes the reverting call.
        (uint8 cv, bytes32 cr, bytes32 cs) =
            _signCommit(agentId, SID, 10e6, nonce, DEADLINE);
        vm.expectRevert(bytes("3009: nonce used"));
        x402.payForService(
            agentId, SID, payer,
            0, DEADLINE, nonce,
            0, bytes32(0), bytes32(0),
            cv, cr, cs
        );
    }

    // ─── L-3: token allowlist ────────────────────────────────────────────────

    function test_RevertWhen_RegisterDisallowedToken() public {
        MockUSDC other = new MockUSDC();
        vm.prank(creator);
        vm.expectRevert(AgentX402Receiver.TokenNotAllowed.selector);
        x402.registerService(agentId, SID, address(other), 1e6);
    }

    function test_SetTokenAllowed_OwnerOnly() public {
        MockUSDC other = new MockUSDC();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        x402.setTokenAllowed(address(other), true);

        vm.prank(owner);
        x402.setTokenAllowed(address(other), true);
        assertTrue(x402.allowedTokens(address(other)));
    }

    // ─── I-1: pause ──────────────────────────────────────────────────────────

    function test_Pause_BlocksRegisterAndPay() public {
        _register(10e6);
        vm.prank(owner);
        x402.pause();

        bytes32 SID2 = keccak256("api/x/v1");
        vm.prank(creator);
        vm.expectRevert(); // PausableUpgradeable.EnforcedPause
        x402.registerService(agentId, SID2, address(usdc), 1e6);

        (uint8 cv, bytes32 cr, bytes32 cs) =
            _signCommit(agentId, SID, 10e6, bytes32(uint256(8)), DEADLINE);
        vm.expectRevert();
        x402.payForService(
            agentId, SID, payer,
            0, DEADLINE,
            bytes32(uint256(8)), 0, bytes32(0), bytes32(0),
            cv, cr, cs
        );

        vm.prank(owner);
        x402.unpause();
        _pay(bytes32(uint256(9))); // works again
    }

    // ─── admin ───────────────────────────────────────────────────────────────

    function test_SetTreasury_OwnerOnly() public {
        address newT = address(0xDEAD);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        x402.setTreasury(newT);

        vm.prank(owner);
        x402.setTreasury(newT);
        assertEq(x402.treasury(), newT);
    }

    function test_SetSystemFeeBps_Capped() public {
        vm.prank(owner);
        x402.setSystemFeeBps(500);
        assertEq(x402.systemFeeBps(), 500);

        vm.prank(owner);
        vm.expectRevert(AgentX402Receiver.InvalidFee.selector);
        x402.setSystemFeeBps(501);
    }

    function test_SetIdentityRegistry_OwnerOnly() public {
        vm.prank(owner);
        x402.setIdentityRegistry(address(0xBEEF));
        assertEq(address(x402.identityRegistry()), address(0xBEEF));
    }

    // ─── access control ──────────────────────────────────────────────────────

    function test_RevertWhen_NonOwner_RegistersService() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(AgentX402Receiver.NotOwner.selector);
        x402.registerService(agentId, SID, address(usdc), 1e6);
    }

    function test_RevertWhen_DoubleRegister() public {
        _register(1e6);
        vm.prank(creator);
        vm.expectRevert(AgentX402Receiver.ServiceAlreadyExists.selector);
        x402.registerService(agentId, SID, address(usdc), 2e6);
    }

    function test_RevertWhen_PayInactiveService() public {
        _register(10e6);
        vm.prank(creator);
        x402.updateService(agentId, SID, 10e6, false);

        (uint8 cv, bytes32 cr, bytes32 cs) =
            _signCommit(agentId, SID, 10e6, bytes32(uint256(4)), DEADLINE);
        vm.expectRevert(AgentX402Receiver.ServiceInactive.selector);
        x402.payForService(
            agentId, SID, payer, 0, DEADLINE,
            bytes32(uint256(4)), 0, bytes32(0), bytes32(0),
            cv, cr, cs
        );
    }

    function test_RevertWhen_RegisterZeroPrice() public {
        vm.prank(creator);
        vm.expectRevert(AgentX402Receiver.InvalidPrice.selector);
        x402.registerService(agentId, SID, address(usdc), 0);
    }

    function test_RevertWhen_PayUnknownService() public {
        bytes32 missing = keccak256("missing");
        // Sign a valid-shape commit; service inactive check fires before commit verify.
        (uint8 cv, bytes32 cr, bytes32 cs) =
            _signCommit(agentId, missing, 0, bytes32(uint256(5)), DEADLINE);
        vm.expectRevert(AgentX402Receiver.ServiceInactive.selector);
        x402.payForService(
            agentId, missing, payer, 0, DEADLINE,
            bytes32(uint256(5)), 0, bytes32(0), bytes32(0),
            cv, cr, cs
        );
    }

    function test_RevertWhen_AuthorizationExpired() public {
        _register(10e6);
        // Force commit to use the same expired deadline so verification passes.
        uint256 expired = 1;
        (uint8 cv, bytes32 cr, bytes32 cs) =
            _signCommit(agentId, SID, 10e6, bytes32(uint256(8)), expired);
        vm.expectRevert(bytes("3009: expired"));
        x402.payForService(
            agentId, SID, payer, 0, expired,
            bytes32(uint256(8)), 0, bytes32(0), bytes32(0),
            cv, cr, cs
        );
    }

    // ─── fuzz: split invariant ───────────────────────────────────────────────

    function testFuzz_Splits_SumToGross(uint256 price, uint256 feeBps) public {
        price  = bound(price,  1, 1_000_000e6);
        feeBps = bound(feeBps, 0, 500);
        vm.prank(owner);
        x402.setSystemFeeBps(feeBps);

        bytes32 sid = keccak256(abi.encode(price, feeBps));
        _registerWithId(sid, price);

        (uint256 gross, uint256 sysCut, uint256 creatorCut, uint256 agentCut) =
            x402.quoteSplit(agentId, sid);
        assertEq(sysCut + creatorCut + agentCut, gross);
    }

    // Local copy of the event for vm.expectEmit.
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
}
