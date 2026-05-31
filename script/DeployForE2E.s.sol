// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../src/AgentIdentityRegistry.sol";
import "../src/AgentX402Receiver.sol";
import "../src/AgentTBARegistry.sol";
import "../src/AgentReputationRegistry.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";

/// @dev Mock USDC used in place of the real Base token. Six decimals so the
///      worker's `parseUnits(amount, 6)` semantics carry over unchanged.
contract MockE2EUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Deploys the entire VIMS marketplace stack onto a clean chain
///         (typically `anvil`) and seeds it with enough state for the MCP
///         worker tests to exercise every read tool. Writes the resulting
///         addresses + seed data to `./deployments/e2e-anvil.json` so the
///         Vitest global setup can read them.
///
///         Usage:
///           forge script script/DeployForE2E.s.sol \
///             --rpc-url $E2E_RPC_URL \
///             --broadcast \
///             --private-key $E2E_PRIVATE_KEY
contract DeployForE2EScript is Script {
    // Anvil default account #0 (the deployer) — used as both governance owner
    // and as the test "creator" who mints the agent. The Vitest tests use
    // accounts #1/#2 as hirer/observer.
    uint256 constant DEPLOYER_PK =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Pre-computed agent-test fixtures: a creator and a hirer drawn from the
    // anvil default mnemonic so Vitest can sign as them without needing more
    // env wiring.
    address constant CREATOR = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // anvil #0
    address constant HIRER   = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // anvil #1
    address constant OWNER   = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // anvil #0 again (deployer = owner)

    bytes32 constant SERVICE_ID    = keccak256("api/chat/v1");
    uint256 constant SERVICE_PRICE = 5e6;  // 5 USDC
    uint256 constant HIRE_PAYMENT  = 5e6;
    bytes32 constant TBA_SALT      = bytes32(0);

    function run() external {
        vm.startBroadcast(DEPLOYER_PK);

        // ── Core registries ──────────────────────────────────────────────
        AgentIdentityRegistry identity = AgentIdentityRegistry(address(new ERC1967Proxy(
            address(new AgentIdentityRegistry()),
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        )));

        AgentX402Receiver x402 = AgentX402Receiver(address(new ERC1967Proxy(
            address(new AgentX402Receiver()),
            abi.encodeCall(AgentX402Receiver.initialize, (address(identity), OWNER, 50))
        )));

        AgentReputationRegistry reputation = AgentReputationRegistry(address(new ERC1967Proxy(
            address(new AgentReputationRegistry()),
            abi.encodeCall(AgentReputationRegistry.initialize, (address(identity)))
        )));

        // ── TBA registry ─────────────────────────────────────────────────
        address mockEntryPoint = address(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);
        AgentTBARegistry tbaRegistry = new AgentTBARegistry(address(identity), mockEntryPoint);

        // ── Collection factory (also deploys the splitter factory inside) ─
        AgentCollectionImpl collectionImpl = new AgentCollectionImpl();
        AgentCollectionFactory collectionFactory = new AgentCollectionFactory(
            address(collectionImpl),
            OWNER // protocol fee recipient
        );

        // ── Mock USDC ────────────────────────────────────────────────────
        MockE2EUSDC usdc = new MockE2EUSDC();

        // ── Wire trust ───────────────────────────────────────────────────
        // Post-audit: Identity↔TBA↔X402 trust is enforced via ownerOf checks
        // and constructor wiring (TBARegistry stores identityRegistry at
        // deploy; X402 stores identityRegistry at initialize). The only
        // remaining runtime setter is the X402 token allowlist.
        x402.setTokenAllowed(address(usdc), true);

        // ── Seed: mint a solo agent + deploy its TBA + register a service ─
        // Audited registry exposes these as three explicit calls. The TBA
        // registry auto-calls identity.setTBAAddress(...) inside createAccount
        // when the caller is the token owner, so no extra wire-up is needed.
        uint256 agentId = identity.registerAgent(
            "Pixel",
            "ipfs://pixel/agent.json",
            500,            // 5% creator royalty
            address(0)      // no reputation anchor override
        );

        address tba = tbaRegistry.createAccount(agentId, TBA_SALT);

        x402.registerService(agentId, SERVICE_ID, address(usdc), SERVICE_PRICE);

        vm.stopBroadcast();

        // ── Seed: fund the hirer + record a hire + leave feedback ────────
        vm.startBroadcast(DEPLOYER_PK);
        usdc.mint(HIRER, 100e6);
        vm.stopBroadcast();

        // The hirer is anvil account #1. Switch broadcast key so we get the
        // right msg.sender for giveFeedback (cannot equal the agent owner).
        uint256 hirerPk = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        vm.startBroadcast(hirerPk);
        usdc.transfer(tba, HIRE_PAYMENT);
        reputation.giveFeedback(
            agentId,
            int128(5),
            uint8(0),
            "quality",
            "speed",
            "ipfs://review/seed.json"
        );
        vm.stopBroadcast();

        // ── Write JSON for the Vitest global setup ───────────────────────
        string memory obj = "deployment";
        vm.serializeUint   (obj, "chainId",            block.chainid);
        vm.serializeAddress(obj, "identityRegistry",   address(identity));
        vm.serializeAddress(obj, "reputationRegistry", address(reputation));
        vm.serializeAddress(obj, "x402Receiver",       address(x402));
        vm.serializeAddress(obj, "tbaRegistry",        address(tbaRegistry));
        vm.serializeAddress(obj, "collectionFactory",  address(collectionFactory));
        vm.serializeAddress(obj, "usdc",               address(usdc));
        vm.serializeAddress(obj, "creator",            CREATOR);
        vm.serializeAddress(obj, "hirer",              HIRER);
        vm.serializeUint   (obj, "agentId",            agentId);
        vm.serializeAddress(obj, "agentTBA",           tba);
        vm.serializeBytes32(obj, "serviceId",          SERVICE_ID);
        string memory json = vm.serializeUint(obj, "servicePrice", SERVICE_PRICE);

        vm.writeJson(json, "./deployments/e2e-anvil.json");
    }
}
