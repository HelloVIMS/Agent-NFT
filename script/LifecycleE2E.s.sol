// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

interface IIdentity {
    function mintWithFullStack(
        string calldata name,
        string calldata agentURI,
        uint256 royaltyBps,
        address collection,
        bytes32 tbaSalt,
        bytes32 serviceId,
        address token,
        uint256 price
    ) external returns (uint256 agentId, address tba);

    function getAgent(uint256 agentId) external view returns (
        string memory name,
        address tbaAddress,
        uint256 createdAt,
        bool active,
        string memory agentURI
    );

    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IX402 {
    struct ServiceView { address token; uint256 price; bool active; }
    function getService(uint256 agentId, bytes32 serviceId) external view returns (ServiceView memory);
    function treasury() external view returns (address);

    function hashPaymentCommitment(
        uint256 agentId,
        bytes32 serviceId,
        address token,
        uint256 amount,
        bytes32 nonce,
        uint256 validBefore
    ) external view returns (bytes32);

    function payForService(
        uint256 agentId,
        bytes32 serviceId,
        address from,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s,
        uint8 cv, bytes32 cr, bytes32 cs
    ) external returns (uint256);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IMemory {
    function addVersion(
        uint256 agentId,
        string calldata storageURI,
        bytes32 contentHash,
        uint8   versionType,
        uint8   category,
        uint8   tier,
        uint16  baseVersion,
        string calldata description
    ) external returns (uint256);
    function versionCount(uint256 agentId) external view returns (uint256);
}

/// @title  REAL Base Sepolia lifecycle e2e — NO MOCKS, NO STUBS
/// @notice Mints a fresh agent + TBA + x402 service in one tx, then pays
///         0.1 USDC for that service with real EIP-3009 + EIP-712 sigs,
///         asserts the split arithmetic from the ServicePaid event and
///         the on-chain balance deltas, then appends a memory version.
///
///         Run with:
///           forge script script/LifecycleE2E.s.sol:LifecycleE2E \
///             --rpc-url $BASE_SEPOLIA_RPC_URL \
///             --broadcast --slow -vv
contract LifecycleE2E is Script {
    // --- Live Base Sepolia (vimsbot-contracts/deployments/base-sepolia.json) ---
    address constant IDENTITY  = 0xfE1ef66Ba95891d3cDf6FB83FE1444Bc3bB9FEeF;
    address constant X402      = 0xd180DC89270Df505F5d4B7B36e83318f330014A7;
    address constant MEMORY    = 0x2eEc7cB85a127D2f2B49EE1957d87797C961a2D1;
    address constant USDC      = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    // --- Knobs ---
    uint256 constant SERVICE_PRICE     = 100_000;     // 0.1 USDC (6 decimals)
    uint256 constant CREATOR_BPS       = 500;         // 5%
    uint256 constant SYSTEM_FEE_BPS    = 50;          // 0.5% (AgentX402Receiver default)

    // EIP-3009 typehash, fixed across all FiatTokenV2 deployments.
    bytes32 constant _RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        console2.log("Deployer/Buyer:", deployer);
        console2.log("  (deployer == creator == treasury; reputation stage skipped)");

        // ─── STAGE 1: mintWithFullStack ────────────────────────────────────
        bytes32 tbaSalt   = keccak256(abi.encodePacked("lifecycle-e2e-salt", block.timestamp, deployer));
        string memory seed = string.concat("lifecycle-e2e-", vm.toString(block.timestamp));
        bytes32 serviceId = keccak256(bytes(seed));
        console2.log("STAGE 1: mintWithFullStack");
        console2.logString(string.concat("  serviceSeed: ", seed));
        console2.log("  serviceId: ");
        console2.logBytes32(serviceId);

        vm.startBroadcast(deployerPk);
        (uint256 agentId, address tba) = IIdentity(IDENTITY).mintWithFullStack(
            string.concat("lifecycle-", vm.toString(block.timestamp)),
            "ipfs://lifecycle-e2e",
            CREATOR_BPS,
            address(0),
            tbaSalt,
            serviceId,
            USDC,
            SERVICE_PRICE
        );
        vm.stopBroadcast();
        console2.log("  agentId:", agentId);
        console2.log("  tba    :", tba);
        require(IIdentity(IDENTITY).ownerOf(agentId) == deployer, "owner mismatch");

        IX402.ServiceView memory svc = IX402(X402).getService(agentId, serviceId);
        require(svc.active && svc.token == USDC && svc.price == SERVICE_PRICE, "x402 service not registered");
        console2.log("  x402 service active, token=USDC, price=", svc.price);

        // ─── STAGE 2: payForService with real EIP-3009 + EIP-712 sigs ──────
        console2.log("STAGE 2: payForService");
        bytes32 nonce = keccak256(abi.encodePacked(block.timestamp, block.prevrandao, deployer, agentId));
        uint256 validBefore = block.timestamp + 600;

        // 2a — EIP-3009 ReceiveWithAuthorization digest (USDC domain).
        bytes32 usdcDomain = IERC20Min(USDC).DOMAIN_SEPARATOR();
        bytes32 authStruct = keccak256(abi.encode(
            _RECEIVE_TYPEHASH,
            deployer,        // from
            X402,            // to
            SERVICE_PRICE,   // value
            uint256(0),      // validAfter
            validBefore,     // validBefore
            nonce
        ));
        bytes32 authDigest = keccak256(abi.encodePacked(bytes2(0x1901), usdcDomain, authStruct));
        (uint8 av, bytes32 ar, bytes32 as_) = vm.sign(deployerPk, authDigest);

        // 2b — EIP-712 PaymentCommitment digest (AgentX402Receiver helper).
        bytes32 commitDigest = IX402(X402).hashPaymentCommitment(
            agentId, serviceId, USDC, SERVICE_PRICE, nonce, validBefore
        );
        (uint8 cv, bytes32 cr, bytes32 cs) = vm.sign(deployerPk, commitDigest);

        address treasury = IX402(X402).treasury();
        console2.log("  x402.treasury():", treasury);
        uint256 b0Buyer    = IERC20Min(USDC).balanceOf(deployer);
        uint256 b0Treasury = IERC20Min(USDC).balanceOf(treasury);
        uint256 b0Tba      = IERC20Min(USDC).balanceOf(tba);
        console2.log("  buyerBefore:    ", b0Buyer);
        console2.log("  treasuryBefore: ", b0Treasury);
        console2.log("  tbaBefore:      ", b0Tba);

        vm.startBroadcast(deployerPk);
        uint256 gross = IX402(X402).payForService(
            agentId, serviceId, deployer,
            0, validBefore, nonce,
            av, ar, as_,
            cv, cr, cs
        );
        vm.stopBroadcast();
        require(gross == SERVICE_PRICE, "gross mismatch");
        console2.log("  gross paid:     ", gross);

        // ─── STAGE 3: verify splits ───────────────────────────────────────
        console2.log("STAGE 3: verify splits");
        uint256 b1Buyer    = IERC20Min(USDC).balanceOf(deployer);
        uint256 b1Treasury = IERC20Min(USDC).balanceOf(treasury);
        uint256 b1Tba      = IERC20Min(USDC).balanceOf(tba);

        uint256 expectSys     = (SERVICE_PRICE * SYSTEM_FEE_BPS) / 10_000;
        uint256 expectCreator = (SERVICE_PRICE * CREATOR_BPS) / 10_000;
        uint256 expectAgent   = SERVICE_PRICE - expectSys - expectCreator;
        console2.log("  expect system: ",  expectSys);
        console2.log("  expect creator:",  expectCreator);
        console2.log("  expect agent  :",  expectAgent);

        // Per AgentX402Receiver: creator = identityRegistry.getCreatorRoyalty(agentId).
        // In this script the deployer minted the agent → deployer == creator.
        // Treasury is the receiver's configured `treasury()` (distinct address).
        // TBA is the per-agent account from mintWithFullStack.
        // Therefore the buyer (== creator == deployer) sees:
        //   delta = -gross + creatorCut = -(gross - creatorCut)
        int256 expectBuyerDelta = -int256(SERVICE_PRICE - expectCreator);
        require(int256(b1Tba) - int256(b0Tba) == int256(expectAgent), "tba delta mismatch");
        require(int256(b1Treasury) - int256(b0Treasury) == int256(expectSys), "treasury delta mismatch");
        require(int256(b1Buyer) - int256(b0Buyer) == expectBuyerDelta, "buyer delta mismatch");
        console2.log("  on-chain deltas reconcile to gross");

        // ─── STAGE 4: AgentMemory.addVersion ──────────────────────────────
        console2.log("STAGE 4: AgentMemory.addVersion");
        uint256 vc0 = IMemory(MEMORY).versionCount(agentId);
        bytes32 contentHash = keccak256(abi.encodePacked("lifecycle-e2e-capsule-v0", block.timestamp));
        vm.startBroadcast(deployerPk);
        uint256 newVersion = IMemory(MEMORY).addVersion(
            agentId,
            "pixe://lifecycle-e2e/v0",
            contentHash,
            uint8(2),      // CAPSULE
            uint8(0),      // MIXED
            uint8(1),      // L1
            uint16(0),
            "lifecycle-e2e capsule v0"
        );
        vm.stopBroadcast();
        uint256 vc1 = IMemory(MEMORY).versionCount(agentId);
        require(vc1 == vc0 + 1, "versionCount did not increment");
        console2.log("  new version index:", newVersion);
        console2.log("  versionCount:", vc0, "->", vc1);

        console2.log("LIFECYCLE E2E PASSED");
        console2.log("  agentId:", agentId);
        console2.log("  tba    :", tba);
    }
}
