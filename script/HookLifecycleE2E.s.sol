// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {AgentCollectionFactory} from "../src/AgentCollectionFactory.sol";
import {AgentCollectionImpl}    from "../src/AgentCollectionImpl.sol";
import {EvolutionTypes}         from "../src/hooks/EvolutionTypes.sol";
import {TransferRecolorHook}    from "../src/hooks/TransferRecolorHook.sol";
import {TipJarHook}             from "../src/hooks/TipJarHook.sol";
import {ReputationLevelHook}    from "../src/hooks/ReputationLevelHook.sol";

/**
 * @title  HookLifecycleE2E
 * @notice Drives the deployed hooks through a real collection on chain:
 *         a new collection → two agents with on-chain art → a collection
 *         hook (TransferRecolor) → a sale → triggerEvolve redraws from the
 *         collection's own transfer count, which a direct call to the hook
 *         can't move, and tokenURI serves the new art → a per-agent override
 *         (ReputationLevel, reading the payment contract) that stops
 *         applying once the token is sold → a tip that reaches the owner.
 *         Every step is asserted; the run reverts on the first mismatch.
 *
 *   DEPLOYER_PRIVATE_KEY=0x… forge script script/HookLifecycleE2E.s.sol \
 *     --rpc-url $BASE_SEPOLIA_RPC --broadcast --slow
 *
 * Env: COLLECTION_FACTORY, TRANSFER_RECOLOR_HOOK, TIP_JAR_HOOK,
 * REPUTATION_LEVEL_HOOK (defaults: deployments/base-sepolia.json).
 */
contract HookLifecycleE2EScript is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        address buyer = address(uint160(uint256(keccak256(abi.encode("hook-e2e-buyer", block.timestamp)))));
        AgentCollectionFactory factory = AgentCollectionFactory(vm.envOr("COLLECTION_FACTORY", address(0x6B182188269208533Ed95B7C2b83240f21fA7f12)));
        TransferRecolorHook recolor = TransferRecolorHook(vm.envOr("TRANSFER_RECOLOR_HOOK", address(0x0C817c57A11F3106cb5A1849a54E89a953B57198)));
        TipJarHook tipJar = TipJarHook(vm.envOr("TIP_JAR_HOOK", address(0x8f0C2EE384fdC230862859a873798d00938A78dA)));
        ReputationLevelHook tiers = ReputationLevelHook(vm.envOr("REPUTATION_LEVEL_HOOK", address(0xC5cD42f6f104F2D8f3272bbEF12D654D8e687406)));

        uint256 directBefore;
        vm.startBroadcast(pk);
        (, address addr) = factory.createCollection("Hook E2E", "HOOK", 10, 500, 500, "Evolution hooks on a live collection");
        AgentCollectionImpl c = AgentCollectionImpl(addr);
        string memory art = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200"><rect width="200" height="200" fill="#111"/></svg>';
        uint256 a = c.mintAgentWithSVG("Recolor", art, "");
        uint256 b = c.mintAgentWithSVG("Tiered", art, "");
        c.setCollectionHook(address(recolor));

        // A sale, then a redraw from the collection's own count.
        c.transferFrom(me, buyer, a);
        c.triggerEvolve(a, EvolutionTypes.TRIGGER_TRANSFER, "");
        // A direct call only counts in the caller's own namespace.
        directBefore = recolor.transferCount(me, a);
        recolor.afterTransfer(a, me, buyer);

        // Per-agent override: token b levels from paid hires.
        c.setHook(b, address(tiers));
        c.triggerEvolve(b, EvolutionTypes.TRIGGER_REPUTATION, "");
        (address overrideHook,) = c.activeHookFor(b);
        require(overrideHook == address(tiers), "per-agent override while the setter owns it");
        // Selling b ends the seller's override: the collection hook governs it.
        c.transferFrom(me, buyer, b);

        // A tip reaches token a's current owner (the buyer), not the creator.
        tipJar.tip{value: 1 gwei}(address(c), a);
        vm.stopBroadcast();

        require(recolor.transferCount(address(c), a) == 1, "collection transfer count");
        require(recolor.transferCount(me, a) == directBefore + 1, "direct call counted in the caller's namespace");
        require(keccak256(bytes(c.getSVGImage(a))) == keccak256(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200"><circle cx="100" cy="100" r="90" fill="hsl(47,70%,55%)"/></svg>'
        )), "recolored after one sale");
        (address hook,) = c.activeHookFor(b);
        require(hook == address(recolor) && c.hookOf(b) == address(tiers), "sale ended the override without deleting it");
        require(bytes(c.tokenURI(a)).length > 100, "tokenURI serves the evolved art");
        (uint8 tier,,) = tiers.tierOf(address(c), b);
        require(tier == 0 && bytes(c.getSVGImage(b)).length > 0, "tier 0 drawn");
        (uint256 tipped,, uint32 count) = tipJar.jars(address(c), a);
        require(tipped == 1 gwei && count == 1 && buyer.balance >= 1 gwei, "tip reached the owner");

        console.log("collection", address(c));
        console.log("buyer", buyer);
    }
}
