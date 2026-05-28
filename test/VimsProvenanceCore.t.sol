// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AgentRoyaltySplitter}        from "../src/AgentRoyaltySplitter.sol";
import {AgentRoyaltySplitterFactory} from "../src/AgentRoyaltySplitterFactory.sol";
import {AgentRoyaltyVault}           from "../src/AgentRoyaltyVault.sol";
import {AgentTBARegistry}            from "../src/AgentTBARegistry.sol";
import {AgentPaymentRouter}          from "../src/AgentPaymentRouter.sol";
import {AgentReputationRegistry}     from "../src/AgentReputationRegistry.sol";
import {AgentMemory}                 from "../src/AgentMemory.sol";
import {AgentContextRegistry}        from "../src/AgentContextRegistry.sol";
import {AgentX402Receiver}           from "../src/AgentX402Receiver.sol";
import {AgentIdentityRegistry}       from "../src/AgentIdentityRegistry.sol";
import {AgentAccount}                from "../src/AgentAccount.sol";
import {AgentCollectionFactory}      from "../src/AgentCollectionFactory.sol";
import {AgentCollectionImpl}         from "../src/AgentCollectionImpl.sol";

/// @notice Provenance sweep across every core contract that inherits
///         {VimsProvenance}. Each must expose vimsAttest() that returns a
///         32-byte magic carrying the canonical VIMS prefix and a unique
///         per-contract suffix bound to the contract name.
contract VimsProvenanceCoreTest is Test {
    bytes32 internal constant EXPECTED_PREFIX =
        0x56494d5300763100000000000000000000000000000000000000000000000000;
    bytes32 internal constant PREFIX_MASK =
        0xffffffffffffffff000000000000000000000000000000000000000000000000;

    function test_provenance_coreSweep() public {
        // Deploy each fingerprinted core contract and read its attest.
        // Upgradeable contracts: implementation deploy runs the
        // VimsProvenance constructor; the immutable is baked into impl
        // runtime. Proxy deployment + initialize is not required for the
        // fingerprint to be present on the implementation.
        AgentRoyaltyVault vault = new AgentRoyaltyVault(address(this), 0);

        address[] memory payees = new address[](2);
        payees[0] = address(0xAAA1); payees[1] = address(0xAAA2);
        uint256[] memory bps = new uint256[](2);
        bps[0] = 5_000; bps[1] = 5_000;
        AgentRoyaltySplitter splitter = new AgentRoyaltySplitter(payees, bps);

        AgentRoyaltySplitterFactory splitterFactory = new AgentRoyaltySplitterFactory();
        AgentReputationRegistry repReg = new AgentReputationRegistry();
        AgentMemory mem    = new AgentMemory();
        AgentContextRegistry ctx = new AgentContextRegistry();
        AgentX402Receiver  x402  = new AgentX402Receiver();
        AgentIdentityRegistry idReg = new AgentIdentityRegistry();
        AgentAccount acct  = new AgentAccount(address(0xE111));
        AgentTBARegistry tba = new AgentTBARegistry(address(idReg), address(0xE111));

        // Factory needs an impl + treasury; spin up a fresh impl.
        AgentCollectionImpl impl = new AgentCollectionImpl();
        AgentCollectionFactory factory = new AgentCollectionFactory(address(impl), address(0xFEE));

        AgentPaymentRouter router = new AgentPaymentRouter(
            address(idReg), address(0xC0DECAFE), address(this)
        );

        address[] memory all = new address[](13);
        all[0]  = address(vault);
        all[1]  = address(splitter);
        all[2]  = address(splitterFactory);
        all[3]  = address(repReg);
        all[4]  = address(mem);
        all[5]  = address(ctx);
        all[6]  = address(x402);
        all[7]  = address(idReg);
        all[8]  = address(acct);
        all[9]  = address(tba);
        all[10] = address(factory);
        all[11] = address(router);
        all[12] = address(impl);

        bytes32[] memory seen = new bytes32[](all.length);
        for (uint256 i; i < all.length; ++i) {
            (bool ok, bytes memory ret) =
                all[i].staticcall(abi.encodeWithSignature("vimsAttest()"));
            assertTrue(ok, "vimsAttest() missing on a core contract");
            bytes32 magic = abi.decode(ret, (bytes32));

            // Every magic carries the canonical VIMS prefix.
            assertEq(magic & PREFIX_MASK, EXPECTED_PREFIX, "core magic must carry VIMS prefix");

            // Uniqueness across the whole core set.
            for (uint256 j; j < i; ++j) {
                assertTrue(magic != seen[j], "core magics must be globally unique");
            }
            seen[i] = magic;

            // Magic appears verbatim in deployed runtime bytecode.
            bytes memory code = all[i].code;
            bool found;
            for (uint256 k; k + 32 <= code.length; ++k) {
                bytes32 window;
                assembly { window := mload(add(add(code, 0x20), k)) }
                if (window == magic) { found = true; break; }
            }
            assertTrue(found, "magic must appear as PUSH32 immediate in runtime bytecode");
        }
    }

    /// @notice Spot-check that vimsProvenance() round-trips on a representative
    ///         core contract (proves the public-call path works, not just storage).
    function test_provenance_coreBundleRoundtrip() public {
        AgentRoyaltySplitterFactory f = new AgentRoyaltySplitterFactory();
        (bytes32 author, bytes32 repo, bytes32 license, string memory ver, string memory name, bytes32 magic) =
            f.vimsProvenance();
        assertEq(author,  keccak256("vims.protocol.arqonai"));
        assertEq(repo,    keccak256("github.com/arqonai/vimsbot-contracts"));
        assertEq(license, keccak256("MIT"));
        assertEq(ver, "1.0.0");
        assertEq(name, "AgentRoyaltySplitterFactory");
        assertEq(magic, f.vimsAttest());
    }
}
