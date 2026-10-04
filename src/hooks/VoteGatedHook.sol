// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";
import {Strings}           from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title VoteGatedHook
 * @notice Stages that only a collection's governor can advance; anyone may
 *         then redraw with `triggerEvolve(id, keccak256("vote.gated"), "")`.
 * @dev    One deployment serves every collection, each with its own
 *         governor: the collection's creator until it hands the role on (to
 *         an OZ Governor executor, a DAO, a multisig). Only the current
 *         governor can hand it on, so a creator that gave it to its DAO
 *         can't take it back. FLAG_ON_TRIGGER; holds no funds and declares
 *         no transfer permissions, so a stuck governor can't freeze holders.
 */
interface ICollectionCreator {
    function collectionCreator() external view returns (address);
}

contract VoteGatedHook is BaseEvolutionHook, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "VoteGatedHook";
    }

    bytes32 public constant TRIG_VOTE_GATED = keccak256("vote.gated");

    error NotGovernor();
    error ZeroGovernor();
    error StageNotIncreasing();

    uint8 public immutable maxStage;

    /// @notice host collection => token id => stage.
    mapping(address => mapping(uint256 => uint8)) public stage;
    /// @notice host collection => governor it was handed to (unset: its creator).
    mapping(address => address) internal _governor;

    event StageAdvanced(address indexed host, uint256 indexed agentId, uint8 stage);
    event GovernorSet(address indexed host, address indexed previous, address indexed governor);

    constructor(uint8 _maxStage) {
        maxStage = _maxStage;
    }

    /// @notice Who advances `host`'s stages: the governor it was handed to,
    ///         else the collection's creator (zero for a host without one).
    function governorOf(address host) public view returns (address g) {
        g = _governor[host];
        if (g != address(0) || host.code.length == 0) return g;
        try ICollectionCreator(host).collectionCreator() returns (address c) { g = c; } catch {}
    }

    /// @notice The current governor hands the role on (never to zero).
    function setGovernor(address host, address next) external {
        address current = governorOf(host);
        if (current == address(0) || msg.sender != current) revert NotGovernor();
        if (next == address(0)) revert ZeroGovernor();
        _governor[host] = next;
        emit GovernorSet(host, current, next);
    }

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function setStage(address host, uint256 agentId, uint8 newStage) external {
        address g = governorOf(host);
        if (g == address(0) || msg.sender != g) revert NotGovernor();
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
