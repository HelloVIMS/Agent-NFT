// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EvolutionTypes} from "./EvolutionTypes.sol";

/**
 * @title IAgentEvolutionHook
 * @notice Pluggable mutation contract attached to an `AgentCollectionImpl` token (or
 *         the whole collection). The host contract invokes the lifecycle and trigger
 *         callbacks declared via `permissions()`; unimplemented bits are skipped to
 *         save gas (same model as Uniswap v4 hook flags).
 *
 * @dev    Return value contracts:
 *         • Lifecycle callbacks return the function selector on success. Any other
 *           return value (or revert) MUST be treated as a failure by the host and
 *           cause the action that triggered the lifecycle to revert. This mirrors
 *           ERC-721 receiver semantics.
 *         • `onTrigger` returns an `EvolutionResult`. The host applies the result
 *           inline unless `requiresKeeper` is true (or the hook's permission set
 *           includes `FLAG_REQUIRES_KEEPER`), in which case the host emits an
 *           `EvolutionRequested` event and waits for a signed `commitEvolution`
 *           from the configured keeper.
 */
interface IAgentEvolutionHook {
    /// @notice Bitset of {EvolutionTypes.FLAG_*} declaring which lifecycle hooks
    ///         this contract supports. Hosts MUST honor it: callbacks whose flag
    ///         is unset MUST NOT be invoked.
    function permissions() external view returns (uint256);

    /// @notice ERC-165 family identifier for hook discovery.
    ///         keccak256("IAgentEvolutionHook(uint256)") truncated to bytes4.
    function hookInterfaceId() external pure returns (bytes4);

    /// @notice Called by the host BEFORE `_safeMint` for any mint path
    ///         (creator/public/allowlist). Reverting blocks the mint.
    function beforeMint(
        uint256 agentId,
        address to,
        bytes calldata data
    ) external returns (bytes4);

    /// @notice Called by the host AFTER `_safeMint` and `_setTokenURI`. May call back
    ///         into the host (e.g., `setSVGImage`) to seed initial state. The host
    ///         protects against reentrancy on payment functions; hooks SHOULD avoid
    ///         re-entering mint paths.
    function afterMint(
        uint256 agentId,
        address to,
        bytes calldata data
    ) external returns (bytes4);

    /// @notice Called inside `_update` BEFORE the underlying ERC-721 transfer logic
    ///         executes. Reverting blocks the transfer; useful for soulbound modes,
    ///         cooldowns, allowlists.
    function beforeTransfer(
        uint256 agentId,
        address from,
        address to
    ) external returns (bytes4);

    /// @notice Called inside `_update` AFTER the underlying transfer succeeds.
    function afterTransfer(
        uint256 agentId,
        address from,
        address to
    ) external returns (bytes4);

    /// @notice Permissionless evolution entry point. The host wraps user-supplied
    ///         calls and delegates to this. The hook decides whether to mutate
    ///         and how. The host applies the returned result, except when
    ///         `result.requiresKeeper == true` (see contract docstring).
    /// @param  agentId       token id being evolved
    /// @param  triggerKind   keccak256("transfer"|"time.tick"|"service.x402"|"memory.write"|"oracle.update"|<custom>)
    /// @param  payload       ABI-encoded trigger-specific data
    function onTrigger(
        uint256 agentId,
        bytes32 triggerKind,
        bytes calldata payload
    ) external returns (EvolutionTypes.EvolutionResult memory);
}
