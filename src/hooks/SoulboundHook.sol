// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";

/*
  ─── VIMS Protocol — SoulboundHook ─────────────────────────────────────────
  Source-of-truth: github.com/arqonai/vimsbot-contracts
  Inherits VimsProvenance: vimsAttest() returns a per-contract bytecode
  fingerprint. Forks that strip this attribution still carry the magic
  PUSH32 immediates in deployment bytecode — see VimsProvenance.sol.
  ───────────────────────────────────────────────────────────────────────────
*/

/**
 * @title SoulboundHook
 * @notice Blocks transfers via `beforeTransfer` revert. Optionally unlocks at a
 *         fixed timestamp so the soulbound period can be a sale's lock-up.
 *
 * @dev    Permission set: FLAG_BEFORE_TRANSFER. The collection creator chooses
 *         to install this and can replace it later. Mints (from == address(0))
 *         are always allowed. Burns (to == address(0)) are also allowed so a
 *         holder can always opt out.
 */
contract SoulboundHook is BaseEvolutionHook, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "SoulboundHook";
    }

    error TransferLocked(uint256 unlocksAt);

    /// @notice 0 = soulbound forever, else unix timestamp at which transfers open.
    uint256 public immutable unlocksAt;

    constructor(uint256 _unlocksAt) {
        unlocksAt = _unlocksAt;
    }

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_BEFORE_TRANSFER;
    }

    function beforeTransfer(uint256, address from, address to)
        external
        view
        override
        returns (bytes4)
    {
        // Mints and burns are always allowed.
        if (from == address(0) || to == address(0)) return this.beforeTransfer.selector;
        if (unlocksAt == 0 || block.timestamp < unlocksAt) {
            revert TransferLocked(unlocksAt);
        }
        return this.beforeTransfer.selector;
    }
}
