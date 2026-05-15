// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";

/// @notice ERC-8004 Reputation Registry surface consumed by this hook.
///         Mirrors the canonical EIP-8004 `getSummary` signature so the hook
///         can read directly from any spec-compliant Reputation Registry — and
///         from a thin adapter when the deployed registry diverges from spec.
/// @dev    `clientAddresses` MUST be non-empty per ERC-8004 (Sybil protection).
///         The hook caller passes the trusted attestor set; the hook does not
///         hard-code a Sybil-vulnerable "all clients" view.
interface IERC8004Reputation {
    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);
}

/**
 * @title ReputationLevelHook
 * @notice Renders a tier badge based on the agent's current on-chain reputation
 *         score. The score is read live from a configurable reputation oracle
 *         each time the SVG is regenerated.
 *
 * @dev    Permission set: FLAG_ON_TRIGGER. Trigger handled: TRIGGER_REPUTATION.
 *         Stateless within this hook — all source-of-truth lives in the
 *         oracle. Tier thresholds are immutable for predictability.
 */
contract ReputationLevelHook is BaseEvolutionHook, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "ReputationLevelHook";
    }

    error ZeroOracle();
    error ThresholdsNotIncreasing();

    IERC8004Reputation public immutable oracle;
    /// @notice Trusted attestor set passed to ERC-8004 `getSummary` for Sybil protection.
    ///         Immutable per-deployment so the visible tier cannot be re-targeted to a
    ///         friendlier reviewer pool by anyone but a redeploy.
    address[] public attestors;
    /// @notice Optional ERC-8004 `tag1` filter ("" = no filter).
    string public tag1;
    /// @notice Optional ERC-8004 `tag2` filter ("" = no filter).
    string public tag2;
    /// @notice Score thresholds for tiers, strictly increasing in **scaled int128 units**
    ///         where the scale is `summaryValueDecimals`. Length = number of tiers above tier-0.
    int128[] public thresholds;

    event TierObserved(uint256 indexed agentId, uint8 tier, int128 summaryValue, uint64 count);

    constructor(
        address _oracle,
        address[] memory _attestors,
        int128[] memory _thresholds,
        string memory _tag1,
        string memory _tag2
    ) {
        if (_oracle == address(0)) revert ZeroOracle();
        for (uint256 i = 1; i < _thresholds.length; ++i) {
            if (_thresholds[i] <= _thresholds[i - 1]) revert ThresholdsNotIncreasing();
        }
        oracle = IERC8004Reputation(_oracle);
        attestors = _attestors;
        thresholds = _thresholds;
        tag1 = _tag1;
        tag2 = _tag2;
    }

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function tierOf(uint256 agentId)
        public
        view
        returns (uint8 tier, int128 summaryValue, uint64 count)
    {
        (count, summaryValue, ) = oracle.getSummary(agentId, attestors, tag1, tag2);
        if (count == 0) return (0, 0, 0);
        for (uint256 i; i < thresholds.length; ++i) {
            if (summaryValue >= thresholds[i]) tier = uint8(i + 1);
            else break;
        }
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (triggerKind != EvolutionTypes.TRIGGER_REPUTATION) return EvolutionTypes.noOp();
        (uint8 tier, int128 summaryValue, uint64 count) = tierOf(agentId);
        r.svgChanged   = true;
        r.newSvgInline = _render(tier);
        r.newStateHash = keccak256(abi.encode("rep", agentId, tier, summaryValue, count));
        emit TierObserved(agentId, tier, summaryValue, count);
    }

    function _render(uint8 tier) internal pure returns (bytes memory) {
        // Hue ramps from red (low) → green (high).
        uint256 hue = 30 + uint256(tier) * 30;
        if (hue > 140) hue = 140;
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<rect width="200" height="200" fill="#0d0d12"/>',
            '<polygon points="100,20 180,180 20,180" fill="hsl(', _u(hue), ',75%,50%)"/>',
            '<text x="100" y="135" text-anchor="middle" font-family="monospace" font-size="42" fill="#fff">T',
            _u(uint256(tier)), '</text>',
            '</svg>'
        );
    }

    function _u(uint256 v) internal pure returns (bytes memory) {
        if (v == 0) return bytes("0");
        uint256 tmp = v; uint256 d;
        while (tmp != 0) { d++; tmp /= 10; }
        bytes memory b = new bytes(d);
        while (v != 0) { d--; b[d] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return b;
    }
}
