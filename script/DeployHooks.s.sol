// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {TransferRecolorHook} from "../src/hooks/TransferRecolorHook.sol";
import {GenerationHook}      from "../src/hooks/GenerationHook.sol";
import {SoulboundHook}       from "../src/hooks/SoulboundHook.sol";
import {TimeOfDayHook}       from "../src/hooks/TimeOfDayHook.sol";
import {SeasonalHook}        from "../src/hooks/SeasonalHook.sol";
import {HueRotateHook}       from "../src/hooks/HueRotateHook.sol";
import {RevenueLevelHook}    from "../src/hooks/RevenueLevelHook.sol";
import {TipJarHook}          from "../src/hooks/TipJarHook.sol";
import {OracleHook}          from "../src/hooks/OracleHook.sol";
import {ReputationLevelHook} from "../src/hooks/ReputationLevelHook.sol";
import {EvolutionStagesHook} from "../src/hooks/EvolutionStagesHook.sol";
import {VoteGatedHook}       from "../src/hooks/VoteGatedHook.sol";
import {AgentStatusHook}     from "../src/hooks/AgentStatusHook.sol";

/**
 * @title DeployHooks
 * @notice Deploys the evolution hook library. Hooks are immutable, so a new
 *         version is a new set of addresses: record them in
 *         deployments/<network>.json#evolutionHooks and the SDK's
 *         src/v7/evolution-hooks.ts. Collections pick them up only when their
 *         creator (or a token owner, per token) calls setCollectionHook/setHook.
 *
 *   DEPLOYER_PRIVATE_KEY=0x… forge script script/DeployHooks.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC --broadcast
 *
 * Env overrides: X402_RECEIVER, REPUTATION_REGISTRY, USDC, PRICE_FEED,
 * PRICE_FEED_BEAR_THRESHOLD, PRICE_FEED_BULL_THRESHOLD, VOTE_GOVERNOR,
 * VOTE_MAX_STAGE, SOULBOUND_UNLOCKS_AT, HUE_SECONDS_PER_STEP,
 * STAGE_MIN_SECONDS.
 */
contract DeployHooksScript is Script {
    // Base Sepolia (deployments/base-sepolia.json)
    address constant DEFAULT_RECEIVER   = 0xd180DC89270Df505F5d4B7B36e83318f330014A7;
    address constant DEFAULT_REPUTATION = 0x5563EE2939F6839CE82B3cA6E50AA285e8d1C316;
    address constant DEFAULT_USDC       = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    // Chainlink ETH/USD on Base Sepolia (8 decimals)
    address constant DEFAULT_PRICE_FEED     = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    int256  constant DEFAULT_BEAR_THRESHOLD = 2000_00000000;
    int256  constant DEFAULT_BULL_THRESHOLD = 3500_00000000;

    function run() public {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address receiver   = vm.envOr("X402_RECEIVER", DEFAULT_RECEIVER);
        address reputation = vm.envOr("REPUTATION_REGISTRY", DEFAULT_REPUTATION);
        address usdc       = vm.envOr("USDC", DEFAULT_USDC);

        // Revenue levels: 1, 10, 100, 1k, 10k USDC earned.
        uint256[] memory revenue = new uint256[](5);
        for (uint256 i; i < 5; ++i) revenue[i] = 10 ** (6 + i);
        // Reputation tiers: 1, 5, 25, 100, 500 paid hires.
        uint256[] memory hires = new uint256[](5);
        hires[0] = 1; hires[1] = 5; hires[2] = 25; hires[3] = 100; hires[4] = 500;
        // Sample stages; creators deploy their own with bespoke art.
        bytes[] memory stages = new bytes[](4);
        stages[0] = bytes(_egg());
        stages[1] = bytes(_baby());
        stages[2] = bytes(_adult());
        stages[3] = bytes(_elder());

        vm.startBroadcast(pk);
        address[13] memory h = [
            address(new TransferRecolorHook()),
            address(new GenerationHook()),
            address(new SoulboundHook(vm.envOr("SOULBOUND_UNLOCKS_AT", uint256(0)))),
            address(new TimeOfDayHook()),
            address(new SeasonalHook()),
            address(new HueRotateHook(vm.envOr("HUE_SECONDS_PER_STEP", uint256(60)))),
            address(new RevenueLevelHook(receiver, usdc, revenue)),
            address(new TipJarHook()),
            address(new OracleHook(
                vm.envOr("PRICE_FEED", DEFAULT_PRICE_FEED),
                vm.envOr("PRICE_FEED_BEAR_THRESHOLD", DEFAULT_BEAR_THRESHOLD),
                vm.envOr("PRICE_FEED_BULL_THRESHOLD", DEFAULT_BULL_THRESHOLD))),
            address(new ReputationLevelHook(receiver, reputation, hires)),
            address(new EvolutionStagesHook(stages, vm.envOr("STAGE_MIN_SECONDS", uint256(1 hours)))),
            address(new VoteGatedHook(uint8(vm.envOr("VOTE_MAX_STAGE", uint256(4))))),
            address(new AgentStatusHook())
        ];
        vm.stopBroadcast();

        string[13] memory names = [
            "TransferRecolorHook", "GenerationHook", "SoulboundHook", "TimeOfDayHook", "SeasonalHook",
            "HueRotateHook", "RevenueLevelHook", "TipJarHook", "OracleHook", "ReputationLevelHook",
            "EvolutionStagesHook", "VoteGatedHook", "AgentStatusHook"
        ];
        for (uint256 i; i < 13; ++i) console.log(names[i], h[i]);
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
