// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";

/**
 * @title GenerationHook
 * @notice Counts the number of times a token has been transferred between
 *         non-zero addresses ("generations"). Re-renders the SVG with a
 *         generation badge each time the count changes.
 *
 * @dev    Permission set: FLAG_AFTER_TRANSFER | FLAG_ON_TRIGGER. Mints and
 *         burns do NOT increment the counter (only owner-to-owner moves).
 *         The hook is observe-only on transfer; it cannot block one.
 */
contract GenerationHook is BaseEvolutionHook, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "GenerationHook";
    }

    /// @notice Number of owner-to-owner transfers per agentId.
    mapping(uint256 => uint32) public generation;

    event GenerationAdvanced(uint256 indexed agentId, uint32 newGeneration);

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_AFTER_TRANSFER | EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function afterTransfer(uint256 agentId, address from, address to)
        external
        override
        returns (bytes4)
    {
        if (from != address(0) && to != address(0)) {
            unchecked {
                uint32 g = generation[agentId] + 1;
                generation[agentId] = g;
                emit GenerationAdvanced(agentId, g);
            }
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
        uint32 g = generation[agentId];
        r.svgChanged   = true;
        r.newSvgInline = _render(g);
        r.newStateHash = keccak256(abi.encode("gen", agentId, g));
    }

    function _render(uint32 g) internal pure returns (bytes memory) {
        // Saturate hue based on generation count, capped at 360.
        uint256 hue = (uint256(g) * 37) % 360;
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<rect width="200" height="200" fill="hsl(', _u(hue), ',60%,15%)"/>',
            '<circle cx="100" cy="100" r="60" fill="hsl(', _u(hue), ',80%,55%)"/>',
            '<text x="100" y="115" text-anchor="middle" font-family="monospace" font-size="44" fill="#fff">G',
            _u(uint256(g)), '</text>',
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
