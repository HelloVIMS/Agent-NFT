// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {GenerationHook}        from "../src/hooks/GenerationHook.sol";
import {SoulboundHook}         from "../src/hooks/SoulboundHook.sol";
import {SeasonalHook}          from "../src/hooks/SeasonalHook.sol";
import {HueRotateHook}         from "../src/hooks/HueRotateHook.sol";
import {TipJarHook}            from "../src/hooks/TipJarHook.sol";
import {ReputationLevelHook}   from "../src/hooks/ReputationLevelHook.sol";
import {VoteGatedHook}         from "../src/hooks/VoteGatedHook.sol";
import {IdentityTipBeneficiaryResolver} from "../src/adapters/IdentityTipBeneficiaryResolver.sol";

/**
 * @title DeployMissingHooks
 * @notice Deploys the six reference hooks that were marked
 *         "(not yet deployed)" in the marketplace picker, with sensible
 *         Base Sepolia defaults. These are *reference* deployments — the
 *         frontend's "Customize & deploy" flow lets creators ship their own
 *         instances with bespoke parameters.
 *
 * Layout:
 *   1. IdentityTipBeneficiaryResolver  — wraps AgentIdentityRegistry so
 *                                        TipJarHook can resolve TBA addresses.
 *   2. GenerationHook                  — no constructor args.
 *   3. SoulboundHook(0)                — locked forever by default.
 *   4. SeasonalHook                    — no constructor args.
 *   5. HueRotateHook(60)               — 1° per minute drift.
 *   6. TipJarHook(resolver)            — wired to (1).
 *   7. ReputationLevelHook(...)        — wired to AgentReputationRegistry.
 *   8. VoteGatedHook(deployer, 4)      — deployer as default governor.
 *
 * Run:
 *   forge script script/DeployMissingHooks.s.sol:DeployMissingHooksScript \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --slow
 */
contract DeployMissingHooksScript is Script {
    // Base Sepolia canonical addresses (deployments/base-sepolia.json#proxies).
    address constant DEFAULT_IDENTITY_REGISTRY   = 0xfE1ef66Ba95891d3cDf6FB83FE1444Bc3bB9FEeF;
    address constant DEFAULT_REPUTATION_REGISTRY = 0x5563EE2939F6839CE82B3cA6E50AA285e8d1C316;

    function run() public {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address identityRegistry   = vm.envOr("IDENTITY_REGISTRY",   DEFAULT_IDENTITY_REGISTRY);
        address reputationRegistry = vm.envOr("REPUTATION_REGISTRY", DEFAULT_REPUTATION_REGISTRY);

        // ── Reputation tier thresholds (scaled int128, decimals depend on
        //    the registry — using 18 decimals as the canonical scale). ────
        int128[] memory repThresholds = new int128[](4);
        repThresholds[0] = int128(int256(10  * 1e18));
        repThresholds[1] = int128(int256(50  * 1e18));
        repThresholds[2] = int128(int256(100 * 1e18));
        repThresholds[3] = int128(int256(500 * 1e18));

        // Reference attestor list = deployer. Creators using the "Customize &
        // deploy" flow should override this with their actual reviewer set.
        address[] memory attestors = new address[](1);
        attestors[0] = deployer;

        vm.startBroadcast(pk);

        IdentityTipBeneficiaryResolver tipResolver =
            new IdentityTipBeneficiaryResolver(identityRegistry);

        GenerationHook      generation = new GenerationHook();
        SoulboundHook       soulbound  = new SoulboundHook(0);                       // locked forever
        SeasonalHook        seasonal   = new SeasonalHook();
        HueRotateHook       hueRotate  = new HueRotateHook(60);                      // 1°/min
        TipJarHook          tipJar     = new TipJarHook(address(tipResolver));
        ReputationLevelHook reputation = new ReputationLevelHook(
            reputationRegistry, attestors, repThresholds, "", ""
        );
        VoteGatedHook       voteGated  = new VoteGatedHook(deployer, 4);             // deployer governor, 4 stages

        vm.stopBroadcast();

        console.log("\n=== MISSING HOOKS DEPLOYED ===");
        console.log("Paste into vimsbot-marketplace/src/lib/evolution-hooks.ts:");
        console.log("");
        console.log("  generation       :", address(generation));
        console.log("  soulbound        :", address(soulbound));
        console.log("  seasonal         :", address(seasonal));
        console.log("  hue-rotate       :", address(hueRotate));
        console.log("  tip-jar          :", address(tipJar));
        console.log("  reputation-level :", address(reputation));
        console.log("  vote-gated       :", address(voteGated));
        console.log("");
        console.log("Adapters:");
        console.log("  tipResolver      :", address(tipResolver));
        console.log("");
        console.log("Config used:");
        console.log("  identityRegistry :", identityRegistry);
        console.log("  reputationOracle :", reputationRegistry);
        console.log("  voteGovernor     :", deployer);
    }
}
