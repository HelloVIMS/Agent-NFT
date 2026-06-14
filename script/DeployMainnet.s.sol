// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/AgentIdentityRegistry.sol";
import "../src/AgentTBARegistry.sol";
import "../src/AgentReputationRegistry.sol";
import "../src/AgentPaymentRouter.sol";
import "../src/AgentContextRegistry.sol";
import "../src/AgentMemory.sol";
import "../src/AgentX402Receiver.sol";
import "../src/AgentCollectionImpl.sol";
import "../src/AgentCollectionFactory.sol";

/**
 * @title  DeployMainnetScript
 * @notice Single chain-parameterised entry point for production deploys.
 *
 * Reads the active chain id from `block.chainid` and looks up:
 *   - canonical USDC address
 *   - canonical ERC-4337 EntryPoint v0.7
 *   - protocol fee recipient (treasury)
 * from environment variables, with sensible per-chain defaults baked in.
 *
 * Outputs a json-shaped log block to stdout that can be redirected into
 * `deployments/<chain>.json` and fed straight into `pnpm sync-abi`.
 *
 * Required env (every chain):
 *   DEPLOYER_PRIVATE_KEY        — broadcaster
 *   TREASURY                    — Safe / multisig that owns proceeds
 *
 * Optional env (chain-overridable):
 *   USDC                        — overrides the per-chain default below
 *   ENTRYPOINT                  — overrides the canonical 4337 v0.7
 *   PROTOCOL_FEE_RECIPIENT      — defaults to TREASURY
 *
 * Run:
 *   forge script script/DeployMainnet.s.sol:DeployMainnetScript \
 *     --rpc-url $RPC_URL --broadcast --verify
 *
 * Safety:
 *   - The script asserts that `block.chainid` is one of the supported
 *     chains. Catches accidental mainnet vs testnet deploys.
 *   - The script reverts before any state if TREASURY is the zero address.
 *   - 0.5% system fee is hard-coded; do NOT change without a governance
 *     review per `docs/MAINNET_READINESS.md` P1.
 */
contract DeployMainnetScript is Script {
    // ───────── canonical infrastructure ────────────────────────────
    address constant ENTRYPOINT_V0_7 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    // Per-chain canonical USDC (verified against Circle's published list).
    function _defaultUSDC(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453)  return 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;  // Base mainnet
        if (chainId == 84532) return 0x036CbD53842c5426634e7929541eC2318f3dCF7e;  // Base Sepolia
        if (chainId == 1)     return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;  // Ethereum mainnet
        if (chainId == 11155111) return 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // Sepolia
        if (chainId == 10)    return 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;  // Optimism mainnet
        if (chainId == 42161) return 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;  // Arbitrum One
        if (chainId == 137)   return 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;  // Polygon mainnet
        revert("DeployMainnet: no canonical USDC for this chain");
    }

    function _chainName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 8453)     return "base";
        if (chainId == 84532)    return "base-sepolia";
        if (chainId == 1)        return "ethereum";
        if (chainId == 11155111) return "sepolia";
        if (chainId == 10)       return "optimism";
        if (chainId == 42161)    return "arbitrum";
        if (chainId == 137)      return "polygon";
        revert("DeployMainnet: unsupported chain");
    }

    struct Deployed {
        address identityImpl;
        address identityProxy;
        address tbaRegistry;
        address tbaImpl;
        address reputationImpl;
        address reputationProxy;
        address paymentRouter;
        address contextImpl;
        address contextProxy;
        address memoryImpl;
        address memoryProxy;
        address x402Impl;
        address x402Proxy;
        address collectionImpl;
        address collectionFactory;
    }

    function run() external {
        uint256 pk        = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address treasury  = vm.envAddress("TREASURY");
        require(treasury != address(0), "DeployMainnet: TREASURY is zero");

        uint256 chainId   = block.chainid;
        string memory name = _chainName(chainId);
        address usdc      = vm.envOr("USDC",       _defaultUSDC(chainId));
        address entryPoint = vm.envOr("ENTRYPOINT", ENTRYPOINT_V0_7);
        address feeReceiver = vm.envOr("PROTOCOL_FEE_RECIPIENT", treasury);

        console.log("=== vimsbot mainnet deploy ===");
        console.log("chain:     ", name, "(id", chainId);
        console.log("treasury:  ", treasury);
        console.log("usdc:      ", usdc);
        console.log("entryPoint:", entryPoint);
        console.log("feeRecv:   ", feeReceiver);

        Deployed memory d;

        vm.startBroadcast(pk);

        // 1. Identity (UUPS).
        d.identityImpl = address(new AgentIdentityRegistry());
        d.identityProxy = address(new ERC1967Proxy(
            d.identityImpl,
            abi.encodeCall(AgentIdentityRegistry.initialize, ())
        ));

        // 2. TBA Registry (non-upgradeable, ERC-6551 + EntryPoint v0.7).
        AgentTBARegistry tba = new AgentTBARegistry(d.identityProxy, entryPoint);
        d.tbaRegistry = address(tba);
        d.tbaImpl     = tba.implementation();

        // 3. Reputation Registry (UUPS, bound to identity).
        d.reputationImpl = address(new AgentReputationRegistry());
        d.reputationProxy = address(new ERC1967Proxy(
            d.reputationImpl,
            abi.encodeCall(AgentReputationRegistry.initialize, (d.identityProxy))
        ));

        // 4. Payment Router (non-upgradeable; treasury → multisig).
        d.paymentRouter = address(new AgentPaymentRouter(d.identityProxy, usdc, treasury));

        // 5. Context Registry (UUPS).
        d.contextImpl = address(new AgentContextRegistry());
        d.contextProxy = address(new ERC1967Proxy(
            d.contextImpl,
            abi.encodeCall(AgentContextRegistry.initialize, (d.identityProxy))
        ));

        // 6. Memory (UUPS).
        d.memoryImpl = address(new AgentMemory());
        d.memoryProxy = address(new ERC1967Proxy(
            d.memoryImpl,
            abi.encodeCall(AgentMemory.initialize, (d.identityProxy))
        ));

        // 7. x402 Receiver (UUPS, 0.5% system fee).
        d.x402Impl = address(new AgentX402Receiver());
        d.x402Proxy = address(new ERC1967Proxy(
            d.x402Impl,
            abi.encodeCall(AgentX402Receiver.initialize, (d.identityProxy, treasury, 50))
        ));
        AgentX402Receiver(d.x402Proxy).setTokenAllowed(usdc, true);

        // 8. Collection factory + impl (linked libraries auto-deploy).
        d.collectionImpl = address(new AgentCollectionImpl());
        d.collectionFactory = address(new AgentCollectionFactory(d.collectionImpl, feeReceiver));

        vm.stopBroadcast();

        // ───────── post-deploy sanity asserts ───────────────────────
        require(d.identityProxy   != address(0), "identity proxy not deployed");
        require(d.collectionImpl  != address(0), "collection impl not deployed");
        require(d.collectionFactory != address(0), "collection factory not deployed");
        require(AgentX402Receiver(d.x402Proxy).allowedTokens(usdc), "x402: USDC not allowlisted");

        // ───────── deployments/<chain>.json shape (manual paste) ─────
        // Print as JSON-ish pairs so `pnpm sync-abi` consumers can paste.
        console.log("");
        console.log("=== JSON OUTPUT (paste into deployments/", name, ".json) ===");
        console.log("\"chainId\":", chainId, ",");
        console.log("\"network\":", name, ",");
        console.log("\"deployedAt\": <ISO-8601>");
        console.log("\"proxies\": {");
        console.log("  \"AgentIdentityRegistry\":  ", d.identityProxy);
        console.log("  \"AgentTBARegistry\":       ", d.tbaRegistry);
        console.log("  \"AgentReputationRegistry\":", d.reputationProxy);
        console.log("  \"AgentPaymentRouter\":     ", d.paymentRouter);
        console.log("  \"AgentContextRegistry\":   ", d.contextProxy);
        console.log("  \"AgentMemory\":            ", d.memoryProxy);
        console.log("  \"AgentX402Receiver\":      ", d.x402Proxy);
        console.log("  \"AgentCollectionImpl\":    ", d.collectionImpl);
        console.log("}");
        console.log("\"agentCollectionFactory\": {");
        console.log("  \"factory\":               ", d.collectionFactory);
        console.log("  \"implementation\":        ", d.collectionImpl);
        console.log("  \"protocolFeeRecipient\":  ", feeReceiver);
        console.log("}");
        console.log("\"implementations\": {");
        console.log("  \"AgentIdentityRegistry\":  ", d.identityImpl);
        console.log("  \"AgentReputationRegistry\":", d.reputationImpl);
        console.log("  \"AgentContextRegistry\":   ", d.contextImpl);
        console.log("  \"AgentMemory\":            ", d.memoryImpl);
        console.log("  \"AgentX402Receiver\":      ", d.x402Impl);
        console.log("  \"AgentTBAImpl\":           ", d.tbaImpl);
        console.log("}");
        console.log("");
        console.log("=== POST-DEPLOY CHECKLIST ===");
        console.log("[ ] Hand `Ownable.transferOwnership` of all UUPS proxies to the Safe + Timelock.");
        console.log("[ ] Run `pnpm sync-abi` from vimsbot-sdk to regenerate ABI bundle.");
        console.log("[ ] Update vimsbot-sdk/src/core/contracts.ts to remove this chain from PLACEHOLDER_CHAINS.");
        console.log("[ ] Etherscan-verify every contract listed above.");
        console.log("[ ] Run forge fork tests against the new RPC.");
    }
}
