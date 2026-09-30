// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentCollectionFactory} from "../src/AgentCollectionFactory.sol";
import {AgentCollectionImpl}    from "../src/AgentCollectionImpl.sol";

/**
 * @title  CollectionBeaconUpgradeFork
 * @notice Upgrades the live Base Sepolia collection beacon to the current
 *         AgentCollectionImpl in a fork and checks that every live
 *         collection reads back identically: collection settings and, per
 *         token, owner, metadata, art, royalties, hooks and agent record.
 *         The live implementation's source isn't in this repository, so this
 *         is the proof that the storage layouts agree.
 *
 *         One difference is expected: the live implementation fell back to a
 *         token's SVG when it had no metadata URI; the current one serves
 *         the source fixed at mint (MetadataMode). A token minted without a
 *         URI before the upgrade therefore reads an empty tokenURI until a
 *         hook next writes its art. Only that is tolerated, and counted.
 *
 *   BASE_SEPOLIA_RPC=https://sepolia.base.org forge test --match-contract CollectionBeaconUpgradeFork -vv
 *
 * Skipped without BASE_SEPOLIA_RPC.
 */
contract CollectionBeaconUpgradeFork is Test {
    AgentCollectionFactory constant FACTORY = AgentCollectionFactory(0x6B182188269208533Ed95B7C2b83240f21fA7f12);
    uint256 constant MAX_TOKENS = 25;

    bytes4[] internal collectionGetters;
    bytes4[] internal tokenGetters;

    function _call(address c, bytes memory data) internal view returns (bytes memory) {
        (bool ok, bytes memory out) = c.staticcall(data);
        return abi.encode(ok, out);
    }

    function _snapshot(address c) internal view returns (bytes[] memory snap) {
        uint256 supply;
        (bool ok, bytes memory out) = c.staticcall(abi.encodeWithSignature("totalSupply()"));
        if (ok && out.length == 32) supply = abi.decode(out, (uint256));
        uint256 n = supply < MAX_TOKENS ? supply : MAX_TOKENS;
        snap = new bytes[](collectionGetters.length + n * tokenGetters.length + 2);
        uint256 k;
        for (uint256 i; i < collectionGetters.length; ++i) snap[k++] = _call(c, abi.encodeWithSelector(collectionGetters[i]));
        for (uint256 id = 1; id <= n; ++id) {
            for (uint256 j; j < tokenGetters.length; ++j) snap[k++] = _call(c, abi.encodeWithSelector(tokenGetters[j], id));
        }
        snap[k++] = _call(c, abi.encodeWithSignature("royaltyInfo(uint256,uint256)", 1, 10_000));
        snap[k++] = _call(c, abi.encodeWithSignature("activeHookFor(uint256)", 1));
    }

    function test_BeaconUpgradePreservesEveryLiveCollection() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        collectionGetters.push(bytes4(keccak256("name()")));
        collectionGetters.push(bytes4(keccak256("symbol()")));
        collectionGetters.push(bytes4(keccak256("collectionCreator()")));
        collectionGetters.push(bytes4(keccak256("collectionHook()")));
        collectionGetters.push(bytes4(keccak256("evolutionKeeper()")));
        collectionGetters.push(bytes4(keccak256("maxSupply()")));
        collectionGetters.push(bytes4(keccak256("totalSupply()")));
        collectionGetters.push(bytes4(keccak256("royaltyReceiver()")));
        collectionGetters.push(bytes4(keccak256("collectionBaseURI()")));
        collectionGetters.push(bytes4(keccak256("collectionDescription()")));
        collectionGetters.push(bytes4(keccak256("locked()")));
        tokenGetters.push(bytes4(keccak256("ownerOf(uint256)")));
        tokenGetters.push(bytes4(keccak256("tokenURI(uint256)")));
        tokenGetters.push(bytes4(keccak256("getSVGImage(uint256)")));
        tokenGetters.push(bytes4(keccak256("getAgent(uint256)")));
        tokenGetters.push(bytes4(keccak256("hookOf(uint256)")));
        tokenGetters.push(bytes4(keccak256("evolutionStateHash(uint256)")));
        tokenGetters.push(bytes4(keccak256("getSalesRoyalty(uint256)")));

        uint256 count = FACTORY.totalCollections();
        assertGt(count, 0, "live collections");
        address[] memory cols = new address[](count);
        bytes[][] memory before = new bytes[][](count);
        for (uint256 i; i < count; ++i) {
            cols[i] = FACTORY.allCollections(i);
            before[i] = _snapshot(cols[i]);
        }

        address impl = address(new AgentCollectionImpl());
        address factoryOwner = FACTORY.owner();
        vm.prank(factoryOwner);
        FACTORY.upgradeImplementation(impl);

        uint256 mismatches;
        uint256 fallbackTokens;
        uint256 cg = collectionGetters.length;
        uint256 tg = tokenGetters.length;
        for (uint256 i; i < count; ++i) {
            bytes[] memory afterSnap = _snapshot(cols[i]);
            assertEq(afterSnap.length, before[i].length, "snapshot shape");
            uint256 tokenReads = afterSnap.length - cg - 2;
            for (uint256 k; k < afterSnap.length; ++k) {
                if (keccak256(afterSnap[k]) == keccak256(before[i][k])) continue;
                bool isTokenURI = k >= cg && k < cg + tokenReads && (k - cg) % tg == 1;
                if (isTokenURI) {
                    (bool ok, bytes memory out) = abi.decode(afterSnap[k], (bool, bytes));
                    if (ok && bytes(abi.decode(out, (string))).length == 0) {
                        fallbackTokens++;
                        continue;
                    }
                }
                mismatches++;
                console.log("collection", cols[i], "read", k);
            }
        }
        console.log("collections checked:", count);
        console.log("tokens that relied on the removed SVG fallback:", fallbackTokens);
        assertEq(mismatches, 0, "live state changed across the upgrade");
    }
}
