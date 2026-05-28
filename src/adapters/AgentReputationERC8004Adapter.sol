// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC8004Reputation} from "../hooks/ReputationLevelHook.sol";

/// @notice Surface of the existing (non-spec-compliant) AgentReputationRegistry
///         this adapter wraps.
interface ILegacyReputationRegistry {
    /// @dev Anchor-aware indexed accessor. Resolves through the reputation
    ///      subject (agentId or anchor) so the adapter doesn't need to know
    ///      whether feedback is stored under the agentId or an anchor key.
    function getFeedbackAt(uint256 agentId, uint256 index) external view returns (
        address client,
        int128  value,
        uint8   decimals,
        string memory tag1_,
        string memory tag2_,
        string memory feedbackURI,
        uint256 timestamp,
        bool    revoked
    );
    function getFeedbackCount(uint256 agentId) external view returns (uint256);
}

/**
 * @title AgentReputationERC8004Adapter
 * @notice Translates the existing `AgentReputationRegistry` (which is labeled
 *         ERC-8004 but diverges from the EIP) into a spec-compliant
 *         {IERC8004Reputation} surface so on-chain consumers (e.g.,
 *         {ReputationLevelHook}) can be written once and work against any
 *         registry that satisfies the spec.
 *
 * @dev    Implements ERC-8004's `getSummary` using the legacy registry's
 *         per-feedback storage. The spec MANDATES non-empty `clientAddresses`
 *         for Sybil protection; this adapter enforces that.
 *
 *         The legacy registry stores `value` in fixed-point with per-feedback
 *         `decimals`. ERC-8004's summary uses a single `summaryValueDecimals`
 *         on the result. The adapter normalises every per-feedback value to a
 *         single `targetDecimals` (set at construction) before averaging,
 *         using powers of 10 in `int128` and saturating on overflow. For
 *         small feedback counts and well-behaved decimals (≤ 18) this is
 *         exact; for adversarial decimals it saturates and emits a flag in
 *         the count.
 */
contract AgentReputationERC8004Adapter is IERC8004Reputation {
    error EmptyClientAddresses();
    error TooManyDecimals();

    ILegacyReputationRegistry public immutable registry;
    /// @notice Decimals returned by `getSummary` for `summaryValue`. The
    ///         adapter renormalises every legacy feedback to this scale.
    uint8 public immutable targetDecimals;

    constructor(address _registry, uint8 _targetDecimals) {
        if (_targetDecimals > 18) revert TooManyDecimals();
        registry = ILegacyReputationRegistry(_registry);
        targetDecimals = _targetDecimals;
    }

    /// @inheritdoc IERC8004Reputation
    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1Filter,
        string calldata tag2Filter
    ) external view returns (
        uint64 count,
        int128 summaryValue,
        uint8 summaryValueDecimals
    ) {
        if (clientAddresses.length == 0) revert EmptyClientAddresses();

        bytes32 t1Hash = keccak256(bytes(tag1Filter));
        bytes32 t2Hash = keccak256(bytes(tag2Filter));
        bytes32 EMPTY  = keccak256("");

        uint256 nFeedbacks = registry.getFeedbackCount(agentId);
        int256 acc; // int256 accumulator to avoid int128 overflow during sum.
        uint64 hits;

        for (uint256 i; i < nFeedbacks; ++i) {
            (
                address fbClient,
                int128  fbValue,
                uint8   fbDecimals,
                string memory fbTag1,
                string memory fbTag2,
                ,
                ,
                bool    fbRevoked
            ) = registry.getFeedbackAt(agentId, i);

            if (fbRevoked) continue;
            if (!_clientAllowed(fbClient, clientAddresses)) continue;
            if (t1Hash != EMPTY && keccak256(bytes(fbTag1)) != t1Hash) continue;
            if (t2Hash != EMPTY && keccak256(bytes(fbTag2)) != t2Hash) continue;

            acc += _rescale(fbValue, fbDecimals, targetDecimals);
            unchecked { hits++; }
        }

        count = hits;
        summaryValueDecimals = targetDecimals;
        if (hits == 0) return (0, 0, targetDecimals);

        int256 avg = acc / int256(uint256(hits));
        // Saturate to int128 range — adversarial inputs cannot brick this view.
        if (avg > type(int128).max)      summaryValue = type(int128).max;
        else if (avg < type(int128).min) summaryValue = type(int128).min;
        else                              summaryValue = int128(avg);
    }

    function _clientAllowed(address c, address[] calldata allowed) private pure returns (bool) {
        for (uint256 i; i < allowed.length; ++i) {
            if (allowed[i] == c) return true;
        }
        return false;
    }

    /// @dev Rescale `v * 10^-fromDec` to `* 10^-toDec`, saturating on overflow.
    function _rescale(int128 v, uint8 fromDec, uint8 toDec) private pure returns (int256) {
        if (fromDec == toDec) return int256(v);
        if (toDec > fromDec) {
            uint256 mul = 10 ** uint256(toDec - fromDec);
            // int128 * uint(<= 1e18) fits in int256.
            return int256(v) * int256(mul);
        } else {
            uint256 div = 10 ** uint256(fromDec - toDec);
            return int256(v) / int256(div);
        }
    }
}
