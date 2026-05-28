// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";

/**
 * @title EvolutionStagesHook
 * @notice Fully on-chain generative evolution. The collection creator registers
 *         an ordered list of stage SVGs at deploy time; each trigger advances
 *         the agent to the next stage (egg → baby → adult → elder …).
 *
 * @dev    Permission set: FLAG_ON_TRIGGER. Trigger kinds handled:
 *         TRIGGER_TRANSFER, TRIGGER_TIME_TICK, TRIGGER_CUSTOM. The hook does NOT
 *         call back into the host; it returns an EvolutionResult and the host
 *         applies it inline (v4 semantics — no keepers, no off-chain compute).
 *
 *         Stages are registered by the deployer and are immutable per hook
 *         instance. To use different stage sets per collection, deploy a new
 *         hook instance with that stage set.
 */
contract EvolutionStagesHook is BaseEvolutionHook {
    error NoStages();
    error BadStageIndex();

    /// @notice Immutable ordered list of stage SVG bodies (full `<svg>…</svg>`).
    ///         Indexed from 0 = initial stage. Length = number of stages.
    bytes[] private _stageSvgs;
    /// @notice Current stage index per agent. Starts at 0 on first trigger;
    ///         advances by 1 each trigger until it reaches the last stage.
    mapping(uint256 => uint8) public stage;
    /// @notice Whether an agent has been touched by this hook at least once.
    mapping(uint256 => bool) public seeded;

    event Advanced(uint256 indexed agentId, uint8 indexed newStage, uint256 totalStages);

    constructor(bytes[] memory stageSvgs) {
        if (stageSvgs.length == 0) revert NoStages();
        if (stageSvgs.length > 64) revert BadStageIndex(); // sanity cap
        _stageSvgs = stageSvgs;
    }

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    /// @notice Number of stages this hook advertises.
    function totalStages() external view returns (uint256) {
        return _stageSvgs.length;
    }

    /// @notice Read a stage SVG (for UIs / explorers).
    function stageSvg(uint8 index) external view returns (bytes memory) {
        if (index >= _stageSvgs.length) revert BadStageIndex();
        return _stageSvgs[index];
    }

    function onTrigger(uint256 agentId, bytes32 /*triggerKind*/, bytes calldata)
        external
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (!EvolutionTypes.hasFlag(_PERMISSIONS, EvolutionTypes.FLAG_ON_TRIGGER)) {
            revert PermissionNotDeclared(EvolutionTypes.FLAG_ON_TRIGGER);
        }

        uint8 cur = stage[agentId];
        uint256 last = _stageSvgs.length - 1;

        // Seed stage 0 on the very first trigger; advance on every subsequent one.
        if (!seeded[agentId]) {
            seeded[agentId] = true;
        } else if (cur < last) {
            unchecked { cur += 1; }
            stage[agentId] = cur;
        } else {
            // Already at final stage — no-op but still emit so consumers can
            // record the event. svgChanged = false → host skips the write.
            return EvolutionTypes.noOp();
        }

        r.svgChanged   = true;
        r.newSvgInline = _stageSvgs[cur];
        r.newStateHash = keccak256(abi.encode("stage", agentId, cur));
        emit Advanced(agentId, cur, _stageSvgs.length);
        return r;
    }
}
