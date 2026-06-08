// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {HyperlaneChains} from "../src/hyperlane/HyperlaneChains.sol";

/**
 * @title HyperlaneChainsHarness
 * @dev   Thin wrapper that re-exports the library's `internal pure` functions
 *        as `external pure` so forge can drive them through call rather than
 *        inline-substitution. Without the harness the coverage tool sees zero
 *        execution against HyperlaneChains because internal libraries are
 *        compile-time inlined into their callers.
 */
contract HyperlaneChainsHarness {
    function getMailbox(uint32 domain) external pure returns (address) {
        return HyperlaneChains.getMailbox(domain);
    }

    function getChainName(uint32 domain) external pure returns (string memory) {
        return HyperlaneChains.getChainName(domain);
    }

    function isTestnet(uint32 domain) external pure returns (bool) {
        return HyperlaneChains.isTestnet(domain);
    }
}

contract HyperlaneChainsTest is Test {
    HyperlaneChainsHarness internal h;

    function setUp() public {
        h = new HyperlaneChainsHarness();
    }

    // ── Mailbox lookups ────────────────────────────────────────────────────

    function test_getMailbox_mainnetDomains() public view {
        assertEq(h.getMailbox(HyperlaneChains.ETHEREUM),  HyperlaneChains.ETHEREUM_MAILBOX);
        assertEq(h.getMailbox(HyperlaneChains.OPTIMISM),  HyperlaneChains.OPTIMISM_MAILBOX);
        assertEq(h.getMailbox(HyperlaneChains.POLYGON),   HyperlaneChains.POLYGON_MAILBOX);
        assertEq(h.getMailbox(HyperlaneChains.ARBITRUM),  HyperlaneChains.ARBITRUM_MAILBOX);
        assertEq(h.getMailbox(HyperlaneChains.BASE),      HyperlaneChains.BASE_MAILBOX);
        assertEq(h.getMailbox(HyperlaneChains.AVALANCHE), HyperlaneChains.AVALANCHE_MAILBOX);
        assertEq(h.getMailbox(HyperlaneChains.BSC),       HyperlaneChains.BSC_MAILBOX);
    }

    function test_getMailbox_monadIsZeroPlaceholder() public view {
        // MONAD mailbox is intentionally address(0) until Hyperlane lights up
        // on Monad. Lock the placeholder so a typo in the constant surfaces.
        assertEq(h.getMailbox(HyperlaneChains.MONAD), address(0));
    }

    function test_getMailbox_testnetDomains() public view {
        assertEq(h.getMailbox(HyperlaneChains.SEPOLIA),      HyperlaneChains.SEPOLIA_MAILBOX);
        assertEq(h.getMailbox(HyperlaneChains.BASE_SEPOLIA), HyperlaneChains.BASE_SEPOLIA_MAILBOX);
    }

    function test_getMailbox_unknownDomainReturnsZero() public view {
        assertEq(h.getMailbox(0), address(0));
        assertEq(h.getMailbox(99999), address(0));
        assertEq(h.getMailbox(type(uint32).max), address(0));
        // Optimism Sepolia + Arbitrum Sepolia have IDs but no mailbox constant
        // declared yet — the library returns address(0) for them, which is the
        // documented contract: caller must guard against the zero return.
        assertEq(h.getMailbox(HyperlaneChains.OPTIMISM_SEPOLIA), address(0));
        assertEq(h.getMailbox(HyperlaneChains.ARBITRUM_SEPOLIA), address(0));
    }

    // ── Chain names ────────────────────────────────────────────────────────

    function test_getChainName_mainnetAndTestnet() public view {
        assertEq(h.getChainName(HyperlaneChains.ETHEREUM),     "Ethereum");
        assertEq(h.getChainName(HyperlaneChains.OPTIMISM),     "Optimism");
        assertEq(h.getChainName(HyperlaneChains.POLYGON),      "Polygon");
        assertEq(h.getChainName(HyperlaneChains.ARBITRUM),     "Arbitrum");
        assertEq(h.getChainName(HyperlaneChains.BASE),         "Base");
        assertEq(h.getChainName(HyperlaneChains.AVALANCHE),    "Avalanche");
        assertEq(h.getChainName(HyperlaneChains.BSC),          "BNB Chain");
        assertEq(h.getChainName(HyperlaneChains.MONAD),        "Monad");
        assertEq(h.getChainName(HyperlaneChains.SEPOLIA),      "Sepolia");
        assertEq(h.getChainName(HyperlaneChains.BASE_SEPOLIA), "Base Sepolia");
    }

    function test_getChainName_unknownDomainReturnsLiteralUnknown() public view {
        assertEq(h.getChainName(0),                  "Unknown");
        assertEq(h.getChainName(type(uint32).max),   "Unknown");
        assertEq(h.getChainName(123456),             "Unknown");
    }

    // ── Testnet predicate ──────────────────────────────────────────────────

    function test_isTestnet_recognisedTestnets() public view {
        assertTrue(h.isTestnet(HyperlaneChains.SEPOLIA));
        assertTrue(h.isTestnet(HyperlaneChains.BASE_SEPOLIA));
        assertTrue(h.isTestnet(HyperlaneChains.OPTIMISM_SEPOLIA));
        assertTrue(h.isTestnet(HyperlaneChains.ARBITRUM_SEPOLIA));
    }

    function test_isTestnet_mainnetReturnsFalse() public view {
        assertFalse(h.isTestnet(HyperlaneChains.ETHEREUM));
        assertFalse(h.isTestnet(HyperlaneChains.BASE));
        assertFalse(h.isTestnet(HyperlaneChains.POLYGON));
        assertFalse(h.isTestnet(HyperlaneChains.ARBITRUM));
        assertFalse(h.isTestnet(HyperlaneChains.OPTIMISM));
    }

    function test_isTestnet_unknownDomainReturnsFalse() public view {
        assertFalse(h.isTestnet(0));
        assertFalse(h.isTestnet(type(uint32).max));
    }
}
