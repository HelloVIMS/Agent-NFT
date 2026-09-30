// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentIdentityKeyExtension} from "../src/AgentIdentityKeyExtension.sol";

/**
 * Upgrades the live Base Sepolia AgentIdentityKeyExtension in a fork and
 * checks the keys already registered read back identically, then binds a
 * key to a live collection agent.
 *   BASE_SEPOLIA_RPC=https://sepolia.base.org forge test --match-contract IdentityKeyExtensionUpgradeFork
 */
contract IdentityKeyExtensionUpgradeFork is Test {
    AgentIdentityKeyExtension constant EXT = AgentIdentityKeyExtension(0xC6d25a28430eFfD9953250f5BDAC5Ab26228E974);
    address constant COLLECTION = 0x6d8b83f2A0c8184Fd7940AdbeaD757818aCA2c00;

    function test_upgradeKeepsKeysAndAddsCollectionAgents() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        bytes memory before = abi.encode(EXT.getKeys(1), EXT.keysStale(1), EXT.boundOwner(1));
        (uint256 aid, uint256 idx, bool bound, bool active, uint96 perms) = EXT.resolveKey(EXT.getKeys(1)[0].pubkey);

        AgentIdentityKeyExtension impl = new AgentIdentityKeyExtension();
        address owner = EXT.owner();
        vm.prank(owner);
        EXT.upgradeToAndCall(address(impl), "");

        assertEq(keccak256(abi.encode(EXT.getKeys(1), EXT.keysStale(1), EXT.boundOwner(1))), keccak256(before), "identity keys unchanged");
        (uint256 aid2, uint256 idx2, bool bound2, bool active2, uint96 perms2) = EXT.resolveKey(EXT.getKeys(1)[0].pubkey);
        assertEq(abi.encode(aid, idx, bound, active, perms), abi.encode(aid2, idx2, bound2, active2, perms2));

        // A live collection agent gets a key.
        (bool ok, bytes memory out) = COLLECTION.staticcall(abi.encodeWithSignature("ownerOf(uint256)", 1));
        require(ok, "collection token");
        address collectionOwner = abi.decode(out, (address));
        vm.prank(collectionOwner);
        EXT.registerPrimaryKeyFor(COLLECTION, 1, keccak256("fork-key"), "nostr", "", 0);
        (address nft, uint256 tokenId,,,,) = EXT.resolveKeyFor(keccak256("fork-key"));
        assertEq(nft, COLLECTION);
        assertEq(tokenId, 1);
    }
}
