// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";

/**
 * @title RevenueLevelHook
 * @notice Levels up an agent each time it has accumulated enough revenue from
 *         x402 service payments. The hook is a simple stateful counter; the
 *         actual revenue accounting lives in `AgentX402Receiver` /
 *         `AgentPaymentRouter`. Those contracts call `recordRevenue` on this
 *         hook (authorised via `revenueRecorder`) and the hook decides when a
 *         level boundary is crossed.
 *
 * @dev    Permission set: FLAG_ON_TRIGGER. Triggers handled: TRIGGER_SERVICE_X402.
 *         `recordRevenue` is auth-gated to the configured payment router so a
 *         random caller can't spoof level-ups.
 */
contract RevenueLevelHook is BaseEvolutionHook {
    error NotRevenueRecorder();

    /// @notice Authorised contract (payment router / x402 receiver) that may
    ///         call `recordRevenue`. Configured at construction.
    address public immutable revenueRecorder;
    /// @notice Wei thresholds at which a new level is unlocked. Length defines max level.
    uint256[] public levelThresholds;

    /// @notice Cumulative revenue (wei) recorded for an agent.
    mapping(uint256 => uint256) public cumulativeRevenue;
    /// @notice Highest level achieved by an agent so far.
    mapping(uint256 => uint8)   public level;

    event RevenueRecorded(uint256 indexed agentId, uint256 amount, uint256 cumulative);
    event LevelUp(uint256 indexed agentId, uint8 newLevel);

    constructor(address _revenueRecorder, uint256[] memory _thresholds) {
        revenueRecorder = _revenueRecorder;
        levelThresholds = _thresholds;
    }

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    /// @notice Called by the authorised payment router after a service payment settles.
    function recordRevenue(uint256 agentId, uint256 amount) external {
        if (msg.sender != revenueRecorder) revert NotRevenueRecorder();
        uint256 c = cumulativeRevenue[agentId] + amount;
        cumulativeRevenue[agentId] = c;
        emit RevenueRecorded(agentId, amount, c);

        uint8 lvl = level[agentId];
        while (lvl < levelThresholds.length && c >= levelThresholds[lvl]) {
            unchecked { lvl++; }
        }
        if (lvl != level[agentId]) {
            level[agentId] = lvl;
            emit LevelUp(agentId, lvl);
        }
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (!EvolutionTypes.hasFlag(_PERMISSIONS, EvolutionTypes.FLAG_ON_TRIGGER)) {
            revert PermissionNotDeclared(EvolutionTypes.FLAG_ON_TRIGGER);
        }
        if (triggerKind != EvolutionTypes.TRIGGER_SERVICE_X402) {
            return EvolutionTypes.noOp();
        }

        uint8 lvl = level[agentId];
        bytes memory svg = _renderBadge(lvl);

        r.svgChanged   = true;
        r.newSvgInline = svg;
        r.newStateHash = keccak256(abi.encode("level", agentId, lvl, cumulativeRevenue[agentId]));
        return r;
    }

    /// @dev Render a coloured ring whose stroke encodes the level (saturation goes up).
    function _renderBadge(uint8 lvl) internal pure returns (bytes memory) {
        // Saturation ramps 30%, 50%, 70%, 85%, 100% etc.
        uint256 sat = 30 + uint256(lvl) * 15;
        if (sat > 100) sat = 100;
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<rect width="200" height="200" fill="#0d0d12"/>',
            '<circle cx="100" cy="100" r="80" fill="none" ',
            'stroke="hsl(48,', _toString(sat), '%,55%)" stroke-width="', _toString(4 + uint256(lvl)), '"/>',
            '<text x="100" y="115" text-anchor="middle" font-family="monospace" font-size="48" fill="#fff">L',
            _toString(uint256(lvl)), '</text>',
            '</svg>'
        );
    }

    function _toString(uint256 v) internal pure returns (bytes memory) {
        if (v == 0) return bytes("0");
        uint256 tmp = v;
        uint256 digits;
        while (tmp != 0) { digits++; tmp /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) {
            digits -= 1;
            buf[digits] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return buf;
    }
}
