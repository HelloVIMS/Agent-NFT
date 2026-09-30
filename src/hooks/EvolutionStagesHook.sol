// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";

/**
 * @title EvolutionStagesHook
 * @notice Walks a token through a fixed list of stage SVGs: the first trigger
 *         shows stage 0, each later one advances a stage until the last.
 * @dev    FLAG_ON_TRIGGER. Hosts expose triggerEvolve to anyone, so a stage
 *         advances at most once per `minSecondsPerStage` — otherwise a
 *         stranger could fast-forward any agent to its final stage in a few
 *         calls. State is per host collection (see BaseEvolutionHook).
 */
contract EvolutionStagesHook is BaseEvolutionHook {
    error NoStages();
    error BadStageIndex();

    bytes[] private _stageSvgs;
    uint256 public immutable minSecondsPerStage;

    struct Progress {
        uint8  stage;
        bool   seeded;
        uint64 advancedAt;
    }
    /// @notice host collection => token id => progress.
    mapping(address => mapping(uint256 => Progress)) public progress;

    event Advanced(address indexed host, uint256 indexed agentId, uint8 indexed newStage, uint256 totalStages);

    constructor(bytes[] memory stageSvgs, uint256 _minSecondsPerStage) {
        if (stageSvgs.length == 0) revert NoStages();
        if (stageSvgs.length > 64) revert BadStageIndex(); // sanity cap
        _stageSvgs = stageSvgs;
        minSecondsPerStage = _minSecondsPerStage;
    }

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function totalStages() external view returns (uint256) {
        return _stageSvgs.length;
    }

    function stageSvg(uint8 index) external view returns (bytes memory) {
        if (index >= _stageSvgs.length) revert BadStageIndex();
        return _stageSvgs[index];
    }

    /// @notice When `agentId` in `host` can next advance (0 = now or never
    ///         again — check `stage` against `totalStages`).
    function nextAdvanceAt(address host, uint256 agentId) external view returns (uint256) {
        Progress memory p = progress[host][agentId];
        if (!p.seeded || p.stage + 1 >= _stageSvgs.length) return 0;
        uint256 at = uint256(p.advancedAt) + minSecondsPerStage;
        return at > block.timestamp ? at : 0;
    }

    function onTrigger(uint256 agentId, bytes32, bytes calldata)
        external
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        Progress storage p = progress[msg.sender][agentId];
        if (!p.seeded) {
            p.seeded = true;
        } else if (p.stage + 1 < _stageSvgs.length && block.timestamp >= uint256(p.advancedAt) + minSecondsPerStage) {
            p.stage += 1;
        } else {
            return EvolutionTypes.noOp();
        }
        p.advancedAt = uint64(block.timestamp);
        r.svgChanged   = true;
        r.newSvgInline = _stageSvgs[p.stage];
        r.newStateHash = keccak256(abi.encode("stage", msg.sender, agentId, p.stage));
        emit Advanced(msg.sender, agentId, p.stage, _stageSvgs.length);
    }
}
