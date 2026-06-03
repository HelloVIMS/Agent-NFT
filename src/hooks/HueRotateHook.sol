// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";

/**
 * @title HueRotateHook
 * @notice Smooth time-based hue rotation. The hue is `(block.timestamp /
 *         secondsPerStep) % 360`. Anyone (typically a Gelato/Chainlink cron)
 *         calls `triggerEvolve(id, TRIGGER_TIME_TICK, "")` and the agent's
 *         color rotates one step per `secondsPerStep` seconds.
 *
 * @dev    Permission set: FLAG_ON_TRIGGER. Trigger handled: TRIGGER_TIME_TICK.
 *         Stateless across agents — the rendered hue is purely a function of
 *         block.timestamp and the immutable stride.
 */
contract HueRotateHook is BaseEvolutionHook, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "HueRotateHook";
    }

    error InvalidStep();

    /// @notice Seconds elapsed before the hue advances by 1 degree.
    uint256 public immutable secondsPerStep;

    constructor(uint256 _secondsPerStep) {
        if (_secondsPerStep == 0) revert InvalidStep();
        secondsPerStep = _secondsPerStep;
    }

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function currentHue() public view returns (uint16) {
        return uint16((block.timestamp / secondsPerStep) % 360);
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        view
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (triggerKind != EvolutionTypes.TRIGGER_TIME_TICK) return EvolutionTypes.noOp();
        uint16 h = currentHue();
        r.svgChanged   = true;
        r.newSvgInline = _render(h);
        r.newStateHash = keccak256(abi.encode("hue", agentId, h));
    }

    function _render(uint16 hue) internal pure returns (bytes memory) {
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<defs><radialGradient id="g">',
            '<stop offset="0%" stop-color="hsl(', _u(hue), ',90%,60%)"/>',
            '<stop offset="100%" stop-color="hsl(', _u((uint256(hue) + 60) % 360), ',60%,15%)"/>',
            '</radialGradient></defs>',
            '<rect width="200" height="200" fill="url(#g)"/>',
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
