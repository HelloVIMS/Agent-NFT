// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentReputationRegistry} from "../src/AgentReputationRegistry.sol";
import {AgentIdentityKeyExtension} from "../src/AgentIdentityKeyExtension.sol";
import {AgentMemory} from "../src/AgentMemory.sol";
import {AgentAvatarExtension} from "../src/AgentAvatarExtension.sol";

/**
 * Upgrades the four live contracts to AgentNFTRefs in a fork: identity
 * agents' reputation (#241), keys (#1) and memory (#1, #2) read back
 * identically, then a live collection agent gets a key, memory and avatars.
 *   BASE_SEPOLIA_RPC=https://sepolia.base.org forge test --match-contract AgentNFTRefsUpgradeFork
 */
contract AgentNFTRefsUpgradeFork is Test {
    AgentReputationRegistry constant REP = AgentReputationRegistry(0x5563EE2939F6839CE82B3cA6E50AA285e8d1C316);
    AgentIdentityKeyExtension constant KEYS = AgentIdentityKeyExtension(0xC6d25a28430eFfD9953250f5BDAC5Ab26228E974);
    AgentMemory constant MEM = AgentMemory(0x2eEc7cB85a127D2f2B49EE1957d87797C961a2D1);
    AgentAvatarExtension constant AV = AgentAvatarExtension(0x132A0d33aC8040A81E5a3A865Ca2D5238D2Bdbc1);
    address constant COLLECTION = 0x6d8b83f2A0c8184Fd7940AdbeaD757818aCA2c00;

    function _snapshot() internal view returns (bytes32) {
        uint256 n = REP.eraCount(241);
        (uint256 total, int256 avg, uint256 last) = REP.getReputationSummary(241);
        (uint256 v1, ) = MEM.getLatest(1);
        (uint256 v2, ) = MEM.getLatest(2);
        return keccak256(abi.encode(
            n, REP.eraStats(241, n - 1), total, avg, last,
            KEYS.getKeys(1), KEYS.keysStale(1),
            MEM.versionCount(1), MEM.versionCount(2), v1, v2, MEM.getVersion(1, 0), MEM.getVersion(2, 3)
        ));
    }

    function test_upgradeKeepsIdentityAgentsAndServesCollectionAgents() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        bytes32 before = _snapshot();

        address owner = REP.owner();
        address rep = address(new AgentReputationRegistry());
        address keys = address(new AgentIdentityKeyExtension());
        address mem = address(new AgentMemory());
        address av = address(new AgentAvatarExtension());
        vm.startPrank(owner);
        REP.upgradeToAndCall(rep, "");
        KEYS.upgradeToAndCall(keys, "");
        MEM.upgradeToAndCall(mem, "");
        AV.upgradeToAndCall(av, "");
        vm.stopPrank();
        assertEq(_snapshot(), before, "identity agents unchanged");

        (bool ok, bytes memory out) = COLLECTION.staticcall(abi.encodeWithSignature("ownerOf(uint256)", 1));
        require(ok, "collection token");
        address holder = abi.decode(out, (address));
        vm.startPrank(holder);
        KEYS.registerPrimaryKeyFor(COLLECTION, 1, keccak256("refs-fork"), "nostr", "", 0);
        MEM.addVersionFor(COLLECTION, 1, "ipfs://fork", keccak256("fork"), 3, 0, 0, 0, "fork");
        AV.setAvatarManifestFor(COLLECTION, 1, "ipfs://avatars", keccak256("avatars"), 1);
        vm.stopPrank();
        assertEq(KEYS.getKeysFor(COLLECTION, 1).length, 1);
        assertEq(MEM.versionCount(MEM.refOf(COLLECTION, 1)), 1);
        assertTrue(AV.hasAvatarManifest(AV.refOf(COLLECTION, 1)));
    }
}
