// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";

/**
 * @title TimeOfDayHook
 * @notice Mutates the SVG to reflect the current Unix-time-of-day bucket.
 *         Stateless, fully on-chain. Anyone (typically a Gelato/Chainlink cron)
 *         calls `triggerEvolve(id, TRIGGER_TIME_TICK, "")` and the agent's
 *         background fades through dawn → noon → dusk → night.
 *
 * @dev    Permission set: FLAG_ON_TRIGGER. Trigger kinds handled: TRIGGER_TIME_TICK.
 *         Buckets are derived from `block.timestamp % 1 days` so behaviour is
 *         deterministic and replayable across chains with the same wall clock.
 */
contract TimeOfDayHook is BaseEvolutionHook {
    enum Phase { Dawn, Noon, Dusk, Night }

    event PhaseChanged(uint256 indexed agentId, Phase phase);

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function currentPhase() public view returns (Phase) {
        uint256 sec = block.timestamp % 1 days;
        if (sec <  6 hours) return Phase.Night;
        if (sec < 11 hours) return Phase.Dawn;
        if (sec < 17 hours) return Phase.Noon;
        if (sec < 21 hours) return Phase.Dusk;
        return Phase.Night;
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (!EvolutionTypes.hasFlag(_PERMISSIONS, EvolutionTypes.FLAG_ON_TRIGGER)) {
            revert PermissionNotDeclared(EvolutionTypes.FLAG_ON_TRIGGER);
        }
        if (triggerKind != EvolutionTypes.TRIGGER_TIME_TICK) {
            return EvolutionTypes.noOp();
        }

        Phase p = currentPhase();
        bytes memory svg = _renderPhase(p);

        r.svgChanged   = true;
        r.newSvgInline = svg;
        r.newStateHash = keccak256(abi.encode("time", agentId, p));
        emit PhaseChanged(agentId, p);
        return r;
    }

    function _renderPhase(Phase p) internal pure returns (bytes memory) {
        // Two-stop linear gradient per phase. All visual constants are pure.
        (string memory a, string memory b) = _phaseColors(p);
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">',
            '<stop offset="0%" stop-color="', a, '"/>',
            '<stop offset="100%" stop-color="', b, '"/>',
            '</linearGradient></defs>',
            '<rect width="200" height="200" fill="url(#g)"/>',
            '</svg>'
        );
    }

    function _phaseColors(Phase p) internal pure returns (string memory, string memory) {
        if (p == Phase.Dawn)  return ("#ffd29b", "#ff7e9d");
        if (p == Phase.Noon)  return ("#7fc8ff", "#dff3ff");
        if (p == Phase.Dusk)  return ("#ff7e54", "#5a3d8a");
        return ("#1a1a3e", "#04040d"); // Night
    }
}
