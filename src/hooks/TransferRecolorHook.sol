// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes} from "./EvolutionTypes.sol";

/**
 * @title TransferRecolorHook
 * @notice Reference fully-on-chain hook. Each transfer rotates the agent's hue by
 *         a fixed step. Demonstrates the lifecycle path that does NOT require an
 *         off-chain keeper: the result struct is applied inline by the host.
 *
 * @dev    Permission set: FLAG_AFTER_TRANSFER | FLAG_ON_TRIGGER
 *         Triggers handled: TRIGGER_TRANSFER (mutates), all others → no-op.
 *
 *         The new SVG is a 200x200 circle whose `fill` is `hsl(H, 70%, 55%)` where
 *         H = (transferCount * 47) % 360. Cheap to compute, deterministic, and
 *         small enough for fully on-chain storage.
 */
contract TransferRecolorHook is BaseEvolutionHook {
    /// @notice Cumulative transfer count observed for each agent.
    mapping(uint256 => uint256) public transferCount;
    /// @notice Hue degree step per transfer. Coprime with 360 → cycles all values.
    uint256 public constant HUE_STEP = 47;

    event Recolored(uint256 indexed agentId, uint256 transferCount, uint256 hue);

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_AFTER_TRANSFER | EvolutionTypes.FLAG_ON_TRIGGER;
    }

    /// @inheritdoc BaseEvolutionHook
    /// @dev On every transfer, bump the local counter and let the host re-trigger
    ///      via `triggerEvolve` (or have a UI tx do so). We don't try to reach
    ///      back into the host here because that would require a stateful host
    ///      reference; keeping the hook stateless w.r.t. the host preserves
    ///      composability across multiple collections.
    function afterTransfer(uint256 agentId, address /*from*/, address /*to*/)
        external
        override
        returns (bytes4)
    {
        if (!EvolutionTypes.hasFlag(_PERMISSIONS, EvolutionTypes.FLAG_AFTER_TRANSFER)) {
            revert PermissionNotDeclared(EvolutionTypes.FLAG_AFTER_TRANSFER);
        }
        transferCount[agentId] += 1;
        return this.afterTransfer.selector;
    }

    /// @inheritdoc BaseEvolutionHook
    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata /*payload*/)
        external
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (!EvolutionTypes.hasFlag(_PERMISSIONS, EvolutionTypes.FLAG_ON_TRIGGER)) {
            revert PermissionNotDeclared(EvolutionTypes.FLAG_ON_TRIGGER);
        }
        if (triggerKind != EvolutionTypes.TRIGGER_TRANSFER) {
            return EvolutionTypes.noOp();
        }

        uint256 hue = (transferCount[agentId] * HUE_STEP) % 360;
        bytes memory svg = _renderCircle(hue);

        r.svgChanged    = true;
        r.newSvgInline  = svg;
        r.newStateHash  = keccak256(abi.encode("recolor", agentId, transferCount[agentId], hue));
        // r.requiresKeeper stays false — fully on-chain.

        emit Recolored(agentId, transferCount[agentId], hue);
        return r;
    }

    /// @dev Build a `<svg>` containing a single coloured circle. Pure, no allocation
    ///      of dynamic-size strings beyond what's strictly needed.
    function _renderCircle(uint256 hue) internal pure returns (bytes memory) {
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<circle cx="100" cy="100" r="90" fill="hsl(',
            _toString(hue),
            ',70%,55%)"/></svg>'
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
