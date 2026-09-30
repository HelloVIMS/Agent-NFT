// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";
import {Strings}           from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title GenerationHook
 * @notice Counts owner-to-owner transfers ("generations") and renders a badge.
 * @dev    FLAG_AFTER_TRANSFER | FLAG_ON_TRIGGER. Observe-only: it can't block
 *         a transfer. Counts are per host collection — see BaseEvolutionHook.
 */
contract GenerationHook is BaseEvolutionHook, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "GenerationHook";
    }

    /// @notice host collection => token id => generation.
    mapping(address => mapping(uint256 => uint32)) public generation;

    event GenerationAdvanced(address indexed host, uint256 indexed agentId, uint32 newGeneration);

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_AFTER_TRANSFER | EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function afterTransfer(uint256 agentId, address from, address to) external override returns (bytes4) {
        if (from != address(0) && to != address(0)) {
            uint32 g = generation[msg.sender][agentId] + 1;
            generation[msg.sender][agentId] = g;
            emit GenerationAdvanced(msg.sender, agentId, g);
        }
        return this.afterTransfer.selector;
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        view
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (triggerKind != EvolutionTypes.TRIGGER_TRANSFER) return EvolutionTypes.noOp();
        uint32 g = generation[msg.sender][agentId];
        string memory hue = Strings.toString((uint256(g) * 37) % 360);
        r.svgChanged   = true;
        r.newSvgInline = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<rect width="200" height="200" fill="hsl(', hue, ',60%,15%)"/>',
            '<circle cx="100" cy="100" r="60" fill="hsl(', hue, ',80%,55%)"/>',
            '<text x="100" y="115" text-anchor="middle" font-family="monospace" font-size="44" fill="#fff">G',
            Strings.toString(uint256(g)), '</text></svg>'
        );
        r.newStateHash = keccak256(abi.encode("gen", msg.sender, agentId, g));
    }
}
