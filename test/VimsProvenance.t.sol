// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {SoulboundHook}        from "../src/hooks/SoulboundHook.sol";
import {GenerationHook}       from "../src/hooks/GenerationHook.sol";
import {SeasonalHook}         from "../src/hooks/SeasonalHook.sol";
import {HueRotateHook}        from "../src/hooks/HueRotateHook.sol";
import {TipJarHook}           from "../src/hooks/TipJarHook.sol";
import {ReputationLevelHook}  from "../src/hooks/ReputationLevelHook.sol";
import {VoteGatedHook}        from "../src/hooks/VoteGatedHook.sol";

/// @dev Minimal stub TBA resolver for the TipJarHook constructor.
contract _StubResolver {
    function tipBeneficiary(uint256) external pure returns (address) { return address(0xBEEF); }
}
/// @dev Minimal stub ERC-8004 oracle for the ReputationLevelHook constructor.
contract _StubRep {
    function getSummary(uint256, address[] calldata, string calldata, string calldata)
        external pure returns (uint64, int128, uint8) { return (0, 0, 0); }
}

contract VimsProvenanceTest is Test {
    /// @dev ASCII "VIMS\x00v1\x00" — the prefix every VIMS contract carries.
    bytes32 internal constant EXPECTED_PREFIX =
        0x56494d5300763100000000000000000000000000000000000000000000000000;

    SoulboundHook hook;

    function setUp() public {
        hook = new SoulboundHook(0);
    }

    // Layer 2: public constants must match the documented keccak preimages.
    function test_provenance_constantsMatchKeccak() public view {
        assertEq(hook.VIMS_AUTHOR(),  keccak256("vims.protocol.arqonai"));
        assertEq(hook.VIMS_REPO(),    keccak256("github.com/arqonai/vimsbot-contracts"));
        assertEq(hook.VIMS_LICENSE(), keccak256("MIT"));
        assertEq(hook.VIMS_VERSION(), "1.0.0");
    }

    // Layer 3: the steganographic magic must carry the canonical prefix
    // and a unique per-contract suffix.
    function test_provenance_magicCarriesVIMSPrefix() public view {
        bytes32 m = hook.vimsAttest();
        bytes32 prefix = m & 0xffffffffffffffff000000000000000000000000000000000000000000000000;
        assertEq(prefix, EXPECTED_PREFIX, "magic must start with ASCII VIMS\\0v1\\0");

        bytes32 suffix = m & 0x0000000000000000ffffffffffffffffffffffffffffffffffffffffffffffff;
        assertTrue(suffix != bytes32(0), "magic suffix must bind to contract identity");
    }

    // The full provenance struct must round-trip and bind to the same magic.
    function test_provenance_bundleConsistent() public view {
        (bytes32 author, bytes32 repo, bytes32 license, string memory ver, string memory name, bytes32 magic) =
            hook.vimsProvenance();
        assertEq(author,  keccak256("vims.protocol.arqonai"));
        assertEq(repo,    keccak256("github.com/arqonai/vimsbot-contracts"));
        assertEq(license, keccak256("MIT"));
        assertEq(ver, "1.0.0");
        assertEq(name, "SoulboundHook");
        assertEq(magic, hook.vimsAttest());
    }

    // The magic is recomputable from the contract name. This is the
    // off-chain verification recipe an explorer can run to confirm a
    // given deployed address really came from a canonical VIMS build.
    function test_provenance_magicRecomputableFromName() public view {
        bytes32 nameHash = keccak256(abi.encodePacked("vims.protocol.arqonai/v1/", "SoulboundHook"));
        bytes32 prefix   = EXPECTED_PREFIX;
        bytes32 suffix   = nameHash & 0x0000000000000000ffffffffffffffffffffffffffffffffffffffffffffffff;
        bytes32 expected = prefix | suffix;
        assertEq(hook.vimsAttest(), expected);
    }

    // The magic must appear in deployed runtime bytecode as PUSH32 immediates.
    // This is the property that prevents trivial forks from stripping
    // attribution without altering the bytecode hash.
    function test_provenance_magicPresentInRuntimeBytecode() public view {
        _assertMagicInBytecode(address(hook), hook.vimsAttest());
    }

    // ─────────────────────────────────────────────────────────────────────
    // Sweep: every fingerprinted hook must (a) carry the VIMS prefix,
    // (b) have a unique per-contract magic, and (c) embed that magic in
    // its runtime bytecode.
    // ─────────────────────────────────────────────────────────────────────
    function test_provenance_sweepAllFingerprintedHooks() public {
        address[] memory deployments = new address[](7);
        deployments[0] = address(new SoulboundHook(0));
        deployments[1] = address(new GenerationHook());
        deployments[2] = address(new SeasonalHook());
        deployments[3] = address(new HueRotateHook(60));
        deployments[4] = address(new TipJarHook(address(new _StubResolver())));
        {
            address[] memory att = new address[](1); att[0] = address(0xAA1);
            int128[]  memory th  = new int128[](1);  th[0]  = 50;
            deployments[5] = address(new ReputationLevelHook(address(new _StubRep()), att, th, "", ""));
        }
        deployments[6] = address(new VoteGatedHook(address(0xC0DE), 5));

        bytes32 prefixMask = 0xffffffffffffffff000000000000000000000000000000000000000000000000;
        bytes32[] memory seen = new bytes32[](7);

        for (uint256 i; i < deployments.length; ++i) {
            // Read magic via vimsAttest() — works on any VIMS contract.
            (bool ok, bytes memory ret) = deployments[i].staticcall(abi.encodeWithSignature("vimsAttest()"));
            assertTrue(ok, "vimsAttest() must succeed");
            bytes32 magic = abi.decode(ret, (bytes32));

            // Layer-3 prefix invariant.
            assertEq(magic & prefixMask, EXPECTED_PREFIX, "every hook carries VIMS prefix");

            // Uniqueness — no two hooks share the same magic.
            for (uint256 j; j < i; ++j) {
                assertTrue(magic != seen[j], "per-contract magic must be unique");
            }
            seen[i] = magic;

            // Bytecode-embedding invariant.
            _assertMagicInBytecode(deployments[i], magic);
        }
    }

    function _assertMagicInBytecode(address target, bytes32 magic) internal view {
        bytes memory code = target.code;
        bool found;
        for (uint256 i; i + 32 <= code.length; ++i) {
            bytes32 window;
            assembly { window := mload(add(add(code, 0x20), i)) }
            if (window == magic) { found = true; break; }
        }
        assertTrue(found, "magic must appear as PUSH32 immediate in runtime bytecode");
    }
}
