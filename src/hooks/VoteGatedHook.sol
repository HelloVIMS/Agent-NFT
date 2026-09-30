// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";
import {Strings}           from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title VoteGatedHook
 * @notice Stages that only a `governor` (an OZ Governor executor or a
 *         multisig) can advance; anyone may then redraw with
 *         `triggerEvolve(id, keccak256("vote.gated"), "")`.
 * @dev    FLAG_ON_TRIGGER. Holds no funds and declares no transfer
 *         permissions, so a stuck governor can't freeze holders. Stages are
 *         per host collection: the governor names the collection.
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

    /// @notice host collection => token id => stage.
    mapping(address => mapping(uint256 => uint8)) public stage;

    event StageAdvanced(address indexed host, uint256 indexed agentId, uint8 stage);

    constructor(address _governor, uint8 _maxStage) {
        if (_governor == address(0)) revert ZeroGovernor();
        governor = _governor;
        maxStage = _maxStage;
    }

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function setStage(address host, uint256 agentId, uint8 newStage) external {
        if (msg.sender != governor) revert NotGovernor();
        if (newStage <= stage[host][agentId] || newStage > maxStage) revert StageNotIncreasing();
        stage[host][agentId] = newStage;
        emit StageAdvanced(host, agentId, newStage);
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        view
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (triggerKind != TRIG_VOTE_GATED) return EvolutionTypes.noOp();
        uint8 s = stage[msg.sender][agentId];
        string[5] memory palette = ["#3a3a3a", "#3a72a8", "#48a872", "#c8a23c", "#cc4848"];
        r.svgChanged   = true;
        r.newSvgInline = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<rect width="200" height="200" fill="', palette[uint256(s) % 5], '"/>',
            '<text x="100" y="115" text-anchor="middle" font-family="monospace" font-size="48" fill="#fff">S',
            Strings.toString(uint256(s)), '</text></svg>'
        );
        r.newStateHash = keccak256(abi.encode("vote", msg.sender, agentId, s));
    }
}
