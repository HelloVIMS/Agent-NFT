// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {TransferRecolorHook}  from "../src/hooks/TransferRecolorHook.sol";
import {TimeOfDayHook}        from "../src/hooks/TimeOfDayHook.sol";
import {RevenueLevelHook}     from "../src/hooks/RevenueLevelHook.sol";
import {OracleHook}           from "../src/hooks/OracleHook.sol";
import {EvolutionStagesHook}  from "../src/hooks/EvolutionStagesHook.sol";

/**
 * @title DeployHooks
 * @notice Deploys all five reference IAgentEvolutionHook contracts on the
 *         active chain and prints their addresses in a format ready to paste
 *         into `vimsbot-marketplace/src/lib/evolution-hooks.ts`.
 *
 * Required env:
 *   DEPLOYER_PRIVATE_KEY        — broadcaster
 *
 * Optional env (with sensible Base Sepolia defaults):
 *   PAYMENT_ROUTER              — auth recorder for RevenueLevelHook
 *                                 (default: AgentPaymentRouter on Base Sepolia)
 *   PRICE_FEED                  — Chainlink AggregatorV3 for OracleHook
 *                                 (default: ETH/USD on Base Sepolia)
 *   PRICE_FEED_BEAR_THRESHOLD   — int256 (default 200000000000   = $2000)
 *   PRICE_FEED_BULL_THRESHOLD   — int256 (default 350000000000   = $3500)
 *
 * Run:
 *   forge script script/DeployHooks.s.sol:DeployHooksScript \
 *     --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
 */
contract DeployHooksScript is Script {
    // Base Sepolia AgentPaymentRouter (deployments/base-sepolia.json#proxies.AgentPaymentRouter)
    address constant DEFAULT_PAYMENT_ROUTER = 0x1d4320d0cdcbA7d60dc1A76cE63AA13a2Cd43b97;
    // Chainlink ETH/USD on Base Sepolia
    address constant DEFAULT_PRICE_FEED     = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    int256  constant DEFAULT_BEAR_THRESHOLD = 2000_00000000;  // $2000 with 8 decimals
    int256  constant DEFAULT_BULL_THRESHOLD = 3500_00000000;  // $3500 with 8 decimals

    function run() public {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address paymentRouter = vm.envOr("PAYMENT_ROUTER", DEFAULT_PAYMENT_ROUTER);
        address priceFeed     = vm.envOr("PRICE_FEED", DEFAULT_PRICE_FEED);
        int256  bearThreshold = vm.envOr("PRICE_FEED_BEAR_THRESHOLD", DEFAULT_BEAR_THRESHOLD);
        int256  bullThreshold = vm.envOr("PRICE_FEED_BULL_THRESHOLD", DEFAULT_BULL_THRESHOLD);

        // ── RevenueLevel thresholds (cumulative wei) ───────────────────────
        uint256[] memory thresholds = new uint256[](5);
        thresholds[0] = 0.01 ether;
        thresholds[1] = 0.10 ether;
        thresholds[2] = 1.00 ether;
        thresholds[3] = 10.0 ether;
        thresholds[4] = 100  ether;

        // ── Demo stages for EvolutionStagesHook (creators should deploy
        //    their own with bespoke art; this is a public sample). ─────────
        bytes[] memory stages = new bytes[](4);
        stages[0] = bytes(_egg());
        stages[1] = bytes(_baby());
        stages[2] = bytes(_adult());
        stages[3] = bytes(_elder());

        vm.startBroadcast(pk);

        TransferRecolorHook  recolor   = new TransferRecolorHook();
        TimeOfDayHook        timeOfDay = new TimeOfDayHook();
        RevenueLevelHook     revenue   = new RevenueLevelHook(paymentRouter, thresholds);
        OracleHook           oracle    = new OracleHook(priceFeed, bearThreshold, bullThreshold);
        EvolutionStagesHook  staged    = new EvolutionStagesHook(stages);

        vm.stopBroadcast();

        console.log("\n=== EVOLUTION HOOKS DEPLOYED ===");
        console.log("Paste into vimsbot-marketplace/src/lib/evolution-hooks.ts:");
        console.log("");
        console.log("  transfer-recolor :", address(recolor));
        console.log("  time-of-day      :", address(timeOfDay));
        console.log("  revenue-level    :", address(revenue));
        console.log("  oracle           :", address(oracle));
        console.log("  evolution-stages :", address(staged));
        console.log("");
        console.log("Config:");
        console.log("  paymentRouter    :", paymentRouter);
        console.log("  priceFeed        :", priceFeed);
        console.log("  bearThreshold    :", uint256(bearThreshold));
        console.log("  bullThreshold    :", uint256(bullThreshold));
    }

    // ── Sample stage SVGs (kept tiny — under 200 bytes each). ─────────────
    function _egg()   internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
                '<rect width="200" height="200" fill="#0d0d12"/>',
                '<ellipse cx="100" cy="110" rx="46" ry="58" fill="#f5f0d6"/>',
                '</svg>'
            )
        );
    }
    function _baby()  internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
                '<rect width="200" height="200" fill="#0d0d12"/>',
                '<circle cx="100" cy="115" r="46" fill="#9aaaff"/>',
                '<circle cx="86" cy="105" r="4" fill="#0d0d12"/>',
                '<circle cx="114" cy="105" r="4" fill="#0d0d12"/>',
                '</svg>'
            )
        );
    }
    function _adult() internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
                '<rect width="200" height="200" fill="#0d0d12"/>',
                '<circle cx="100" cy="105" r="62" fill="#5fcf83"/>',
                '<rect x="80" y="100" width="40" height="6" fill="#0d0d12"/>',
                '</svg>'
            )
        );
    }
    function _elder() internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
                '<rect width="200" height="200" fill="#0d0d12"/>',
                '<circle cx="100" cy="105" r="74" fill="#cf5fbb"/>',
                '<circle cx="100" cy="105" r="74" fill="none" stroke="#ffd29b" stroke-width="3"/>',
                '</svg>'
            )
        );
    }
}
