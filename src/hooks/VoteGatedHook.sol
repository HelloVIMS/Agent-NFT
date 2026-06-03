// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";

/**
 * @title VoteGatedHook
 * @notice Renders an SVG that advances through governance-approved stages.
 *         A configurable `governor` address is the only entity that may
 *         advance the stage (typically the executor of an OZ Governor or a
 *         multisig). Anyone may then call `triggerEvolve(id, TRIGGER_CUSTOM, "")`
 *         to redraw with the current stage.
 *
 * @dev    Permission set: FLAG_ON_TRIGGER. Trigger handled: TRIGGER_CUSTOM
 *         (kind == keccak256("vote.gated")). The hook holds no funds and
 *         declares no transfer permissions, so a stuck governor cannot
 *         soft-rug holders.
 */
contract VoteGatedHook is BaseEvolutionHook, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "VoteGatedHook";
    }

    bytes32 public constant TRIG_VOTE_GATED = keccak256("vote.gated");

    error NotGovernor();
    error ZeroGovernor();
    error StageNotIncreasing();

    address public immutable governor;
    uint8   public immutable maxStage;

    /// @notice Current visual stage per agent. Monotonically non-decreasing.
    mapping(uint256 => uint8) public stage;

    event StageAdvanced(uint256 indexed agentId, uint8 stage);

    constructor(address _governor, uint8 _maxStage) {
        if (_governor == address(0)) revert ZeroGovernor();
        governor = _governor;
        maxStage = _maxStage;
    }

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    /// @notice Governance-only call to push an agent to a new stage. Must
    ///         strictly exceed the current stage and never exceed `maxStage`.
    function setStage(uint256 agentId, uint8 newStage) external {
        if (msg.sender != governor) revert NotGovernor();
        uint8 cur = stage[agentId];
        if (newStage <= cur || newStage > maxStage) revert StageNotIncreasing();
        stage[agentId] = newStage;
        emit StageAdvanced(agentId, newStage);
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        view
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (triggerKind != TRIG_VOTE_GATED) return EvolutionTypes.noOp();
        uint8 s = stage[agentId];
        r.svgChanged   = true;
        r.newSvgInline = _render(s);
        r.newStateHash = keccak256(abi.encode("vote", agentId, s));
    }

    function _render(uint8 s) internal pure returns (bytes memory) {
        // Stages mapped to a 5-color palette.
        string[5] memory palette = [
            "#3a3a3a", "#3a72a8", "#48a872", "#c8a23c", "#cc4848"
        ];
        uint256 idx = uint256(s) % 5;
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<rect width="200" height="200" fill="', palette[idx], '"/>',
            '<text x="100" y="115" text-anchor="middle" font-family="monospace" font-size="48" fill="#fff">S',
            _u(uint256(s)), '</text>',
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
