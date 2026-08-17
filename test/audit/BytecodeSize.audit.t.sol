// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// Production contracts that ship as deployed bytecode.
import {AgentIdentityRegistry}      from "../../src/AgentIdentityRegistry.sol";
import {AgentAccount}               from "../../src/AgentAccount.sol";
import {AgentReputationRegistry}    from "../../src/AgentReputationRegistry.sol";
import {AgentTBARegistry}           from "../../src/AgentTBARegistry.sol";
import {AgentPaymentRouter}         from "../../src/AgentPaymentRouter.sol";
import {AgentContextRegistry}       from "../../src/AgentContextRegistry.sol";
import {AgentMemory}                from "../../src/AgentMemory.sol";
import {AgentX402Receiver}          from "../../src/AgentX402Receiver.sol";
import {AgentLinkedAccountRegistry} from "../../src/AgentLinkedAccountRegistry.sol";
import {AgentEncryptionRegistry}    from "../../src/AgentEncryptionRegistry.sol";
import {AgentCollectionFactory}     from "../../src/AgentCollectionFactory.sol";
import {AgentCollectionImpl}        from "../../src/AgentCollectionImpl.sol";
import {AgentRoyaltySplitter}       from "../../src/AgentRoyaltySplitter.sol";
import {AgentRoyaltySplitterFactory} from "../../src/AgentRoyaltySplitterFactory.sol";
import {AgentRoyaltyVault}          from "../../src/AgentRoyaltyVault.sol";

/// @notice Bytecode-size guardrail: every production contract must stay
/// under the EIP-170 ceiling of 24,576 deployed bytes.
///
/// Why this exists: AgentCollectionImpl was already at ~24,377 B before
/// the VimsProvenance fingerprint shipped. Linking external libraries
/// (AgentCollectionRenderer, AgentCollectionEIP712, AgentCollectionPaymentLib)
/// brought it back to ~23,694 B. This test asserts the margin so a
/// future "small refactor" doesn't silently push us over the cliff.
///
/// `vm.getDeployedCode` reads the runtime bytecode the optimizer emits
/// for each named artifact, accounting for linked libraries.
contract BytecodeSizeAudit is Test {
    uint256 internal constant EIP170_CEILING = 24_576;
    /// @dev Soft warning floor — touching this is a smell even though it's legal.
    uint256 internal constant SOFT_FLOOR = 23_500;

    function _check(string memory artifact, uint256 hardLimit) internal returns (uint256 size) {
        bytes memory code = vm.getDeployedCode(artifact);
        size = code.length;
        emit log_named_uint(string.concat("size: ", artifact), size);
        assertLe(size, hardLimit, string.concat(artifact, " exceeds EIP-170 ceiling"));
    }

    function test_AgentIdentityRegistry_underCeiling() public {
        _check("AgentIdentityRegistry.sol:AgentIdentityRegistry", EIP170_CEILING);
    }

    function test_AgentAccount_underCeiling() public {
        _check("AgentAccount.sol:AgentAccount", EIP170_CEILING);
    }

    function test_AgentReputationRegistry_underCeiling() public {
        _check("AgentReputationRegistry.sol:AgentReputationRegistry", EIP170_CEILING);
    }

    function test_AgentTBARegistry_underCeiling() public {
        _check("AgentTBARegistry.sol:AgentTBARegistry", EIP170_CEILING);
    }

    function test_AgentPaymentRouter_underCeiling() public {
        _check("AgentPaymentRouter.sol:AgentPaymentRouter", EIP170_CEILING);
    }

    function test_AgentContextRegistry_underCeiling() public {
        _check("AgentContextRegistry.sol:AgentContextRegistry", EIP170_CEILING);
    }

    function test_AgentMemory_underCeiling() public {
        _check("AgentMemory.sol:AgentMemory", EIP170_CEILING);
    }

    function test_AgentX402Receiver_underCeiling() public {
        _check("AgentX402Receiver.sol:AgentX402Receiver", EIP170_CEILING);
    }

    function test_AgentLinkedAccountRegistry_underCeiling() public {
        _check("AgentLinkedAccountRegistry.sol:AgentLinkedAccountRegistry", EIP170_CEILING);
    }

    function test_AgentEncryptionRegistry_underCeiling() public {
        _check("AgentEncryptionRegistry.sol:AgentEncryptionRegistry", EIP170_CEILING);
    }

    function test_AgentCollectionFactory_underCeiling() public {
        _check("AgentCollectionFactory.sol:AgentCollectionFactory", EIP170_CEILING);
    }

    /// @dev The tightest-margin contract in the protocol. Failure here is
    /// a real production blocker — see the foundry.toml comment about
    /// optimizer_runs=1 + library extraction.
    function test_AgentCollectionImpl_underCeiling() public {
        uint256 size = _check("AgentCollectionImpl.sol:AgentCollectionImpl", EIP170_CEILING);
        // Surface a non-fatal warning when we are within 500 bytes of the cliff.
        if (size > EIP170_CEILING - 500) {
            emit log_named_uint("WARNING margin <500B AgentCollectionImpl", EIP170_CEILING - size);
        }
    }

    function test_AgentRoyaltySplitter_underCeiling() public {
        _check("AgentRoyaltySplitter.sol:AgentRoyaltySplitter", EIP170_CEILING);
    }

    function test_AgentRoyaltySplitterFactory_underCeiling() public {
        _check("AgentRoyaltySplitterFactory.sol:AgentRoyaltySplitterFactory", EIP170_CEILING);
    }

    function test_AgentRoyaltyVault_underCeiling() public {
        _check("AgentRoyaltyVault.sol:AgentRoyaltyVault", EIP170_CEILING);
    }

    /// @notice Soft check: print the contracts using the most bytecode so
    /// reviewers see the leaderboard during CI. Always passes.
    function test_dumpSizeLeaderboard() public {
        string[16] memory names = [
            "AgentIdentityRegistry.sol:AgentIdentityRegistry",
            "AgentAccount.sol:AgentAccount",
            "AgentReputationRegistry.sol:AgentReputationRegistry",
            "AgentTBARegistry.sol:AgentTBARegistry",
            "AgentPaymentRouter.sol:AgentPaymentRouter",
            "AgentContextRegistry.sol:AgentContextRegistry",
            "AgentMemory.sol:AgentMemory",
            "AgentX402Receiver.sol:AgentX402Receiver",
            "AgentLinkedAccountRegistry.sol:AgentLinkedAccountRegistry",
            "AgentEncryptionRegistry.sol:AgentEncryptionRegistry",
            "AgentCollectionFactory.sol:AgentCollectionFactory",
            "AgentCollectionImpl.sol:AgentCollectionImpl",
            "AgentRoyaltySplitter.sol:AgentRoyaltySplitter",
            "AgentRoyaltySplitterFactory.sol:AgentRoyaltySplitterFactory",
            "AgentRoyaltyVault.sol:AgentRoyaltyVault",
            "AgentIdentityRegistry.sol:AgentIdentityRegistry"
        ];
        for (uint256 i = 0; i < names.length; ++i) {
            uint256 sz = vm.getDeployedCode(names[i]).length;
            emit log_named_uint(names[i], sz);
            // Soft floor warning surfaces in -vv output without failing.
            if (sz > SOFT_FLOOR) emit log_named_uint("APPROACHING_CEILING", sz);
        }
    }
}
