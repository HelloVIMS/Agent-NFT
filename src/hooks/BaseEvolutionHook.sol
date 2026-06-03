// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {IAgentEvolutionHook} from "./IAgentEvolutionHook.sol";
import {EvolutionTypes} from "./EvolutionTypes.sol";

/**
 * @title BaseEvolutionHook
 * @notice Abstract base class for SVG evolution hooks. Implements the
 *         IAgentEvolutionHook interface with safe defaults that revert when a
 *         lifecycle method is called whose permission bit is NOT set, and
 *         returns a no-op result for unimplemented triggers.
 *
 * @dev    Subclasses override `getPermissions()` to declare their flag set, and
 *         override only the lifecycle methods they declare. The base ensures
 *         the host can't accidentally call into a hook for a permission it
 *         didn't declare — defense in depth alongside the host-side flag check.
 */
abstract contract BaseEvolutionHook is IAgentEvolutionHook {
    using EvolutionTypes for uint256;

    error PermissionNotDeclared(uint256 flag);

    /// @dev Cached at construction so `permissions()` stays `pure`-equivalent
    ///      from the host's perspective and saves a SLOAD per check.
    uint256 internal immutable _PERMISSIONS;

    constructor() {
        _PERMISSIONS = getPermissions();
    }

    /// @notice Subclasses override to declare lifecycle support.
    function getPermissions() public pure virtual returns (uint256);

    /// @inheritdoc IAgentEvolutionHook
    function permissions() external view returns (uint256) {
        return _PERMISSIONS;
    }

    /// @inheritdoc IAgentEvolutionHook
    function hookInterfaceId() external pure returns (bytes4) {
        // bytes4(keccak256("IAgentEvolutionHook(uint256)"))
        return 0xb1f4f1a3;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lifecycle defaults — guarded by declared flags. Override in subclass.
    // ─────────────────────────────────────────────────────────────────────────

    function beforeMint(uint256, address, bytes calldata) external virtual returns (bytes4) {
        if (!EvolutionTypes.hasFlag(_PERMISSIONS, EvolutionTypes.FLAG_BEFORE_MINT)) {
            revert PermissionNotDeclared(EvolutionTypes.FLAG_BEFORE_MINT);
        }
        return this.beforeMint.selector;
    }

    function afterMint(uint256, address, bytes calldata) external virtual returns (bytes4) {
        if (!EvolutionTypes.hasFlag(_PERMISSIONS, EvolutionTypes.FLAG_AFTER_MINT)) {
            revert PermissionNotDeclared(EvolutionTypes.FLAG_AFTER_MINT);
        }
        return this.afterMint.selector;
    }

    function beforeTransfer(uint256, address, address) external virtual returns (bytes4) {
        if (!EvolutionTypes.hasFlag(_PERMISSIONS, EvolutionTypes.FLAG_BEFORE_TRANSFER)) {
            revert PermissionNotDeclared(EvolutionTypes.FLAG_BEFORE_TRANSFER);
        }
        return this.beforeTransfer.selector;
    }

    function afterTransfer(uint256, address, address) external virtual returns (bytes4) {
        if (!EvolutionTypes.hasFlag(_PERMISSIONS, EvolutionTypes.FLAG_AFTER_TRANSFER)) {
            revert PermissionNotDeclared(EvolutionTypes.FLAG_AFTER_TRANSFER);
        }
        return this.afterTransfer.selector;
    }

    function onTrigger(uint256, bytes32, bytes calldata)
        external
        virtual
        returns (EvolutionTypes.EvolutionResult memory)
    {
        if (!EvolutionTypes.hasFlag(_PERMISSIONS, EvolutionTypes.FLAG_ON_TRIGGER)) {
            revert PermissionNotDeclared(EvolutionTypes.FLAG_ON_TRIGGER);
        }
        return EvolutionTypes.noOp();
    }
}
