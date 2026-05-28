// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";

/// @notice Minimal slice of {AgentIdentityRegistry} used for owner / operator
///         resolution. Defined inline so the hook does not pull in the full
///         registry surface (and the type-import chain that comes with it).
interface IAgentRegistryMin {
    function ownerOf(uint256 agentId) external view returns (address);
    function getAgentOwner(uint256 agentId) external view returns (address);
}

/**
 * @title AgentStatusHook
 * @notice Tracks a 3-state liveness flag (Offline / Standby / Running) per
 *         agent and surfaces it both as on-chain state and as a renderable
 *         SVG indicator. The only writers are the agent's NFT owner or an
 *         operator address the owner has explicitly delegated.
 *
 * @dev    Permission set: FLAG_ON_TRIGGER. Trigger handled: TRIGGER_STATUS_CHANGE.
 *
 *         Why this matters in the marketplace flow:
 *           - Buyers should see whether an agent is actually online before
 *             they sign a PaymentCommitment. Returning a 200 from an HTTP
 *             health probe is not enough; we want the operator's signed
 *             intent that the agent is currently serving requests.
 *           - The receiver / payment router can refuse to register or settle
 *             services for agents in `Offline` (left to higher-level policy
 *             contracts; this hook is the source of truth, not the gate).
 *
 *         Storage / state-hash discipline:
 *           - `currentStatus[agentId]` is the canonical state.
 *           - `lastUpdate[agentId]` (seconds) lets callers reason about
 *             staleness off-chain.
 *           - `newStateHash` is keccak256(agentId, status, timestamp) so the
 *             collection's state-continuity check sees a fresh commitment on
 *             each transition.
 */
contract AgentStatusHook is BaseEvolutionHook, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentStatusHook";
    }

    // ─── Errors ─────────────────────────────────────────────────────────
    error ZeroRegistry();
    error NotAuthorised();
    error UnknownStatus();

    // ─── Status enum ────────────────────────────────────────────────────
    /// @dev Encoded as uint8 on-chain so it stays cheap to read in calldata
    ///      and easy to widen later (e.g. Maintenance, Disabled) without a
    ///      breaking storage migration. New values MUST be appended.
    enum Status { Offline, Standby, Running }

    // ─── Storage ────────────────────────────────────────────────────────
    IAgentRegistryMin public immutable registry;

    /// @dev agentId => current status. Defaults to Offline (== 0) for
    ///      uninitialised agents, matching the safest assumption.
    mapping(uint256 => Status)  public currentStatus;

    /// @dev agentId => unix seconds of last `setStatus` call.
    mapping(uint256 => uint64)  public lastUpdate;

    /// @dev agentId => operator => allowed. Operators may flip status on
    ///      behalf of the NFT owner without holding the NFT itself
    ///      (typical pattern: a session key signed by the TBA owner).
    mapping(uint256 => mapping(address => bool)) public operators;

    // ─── Events ─────────────────────────────────────────────────────────
    event StatusChanged(
        uint256 indexed agentId,
        Status  indexed previous,
        Status  indexed next,
        address by,
        uint64  at
    );
    event OperatorUpdated(uint256 indexed agentId, address indexed operator, bool allowed);

    constructor(address _registry) {
        if (_registry == address(0)) revert ZeroRegistry();
        registry = IAgentRegistryMin(_registry);
    }

    // ─── IAgentEvolutionHook permission surface ─────────────────────────

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    // ─── Authorisation ──────────────────────────────────────────────────

    /// @dev True iff `caller` is the agent's NFT owner or an approved operator.
    function _isAuthorisedFor(uint256 agentId, address caller) internal view returns (bool) {
        if (operators[agentId][caller]) return true;
        // Try ownerOf first (canonical ERC-721); fall back to the registry's
        // explicit getter for non-721 anchors.
        try registry.ownerOf(agentId) returns (address ownr) {
            if (ownr == caller) return true;
        } catch {
            // ownerOf may revert for non-existent tokens; ignore and fall through.
        }
        try registry.getAgentOwner(agentId) returns (address ownr) {
            if (ownr == caller) return true;
        } catch {
            // some registries don't expose this getter — ignore.
        }
        return false;
    }

    // ─── State mutators ─────────────────────────────────────────────────

    /// @notice Flip an agent's status. Callable by the NFT owner or an
    ///         operator the owner has authorised via {setOperator}.
    function setStatus(uint256 agentId, Status next) external {
        if (uint8(next) > uint8(Status.Running)) revert UnknownStatus();
        if (!_isAuthorisedFor(agentId, msg.sender)) revert NotAuthorised();

        Status prev = currentStatus[agentId];
        if (prev == next) return; // no-op; cheaper than a full SSTORE+event

        currentStatus[agentId] = next;
        lastUpdate[agentId]    = uint64(block.timestamp);
        emit StatusChanged(agentId, prev, next, msg.sender, uint64(block.timestamp));
    }

    /// @notice Allow / disallow `operator` to set `agentId`'s status. Only
    ///         the NFT owner may delegate; operators cannot delegate further.
    function setOperator(uint256 agentId, address operator, bool allowed) external {
        // Strictly the NFT owner — operators may not delegate further so a
        // compromised session key cannot mint persistent operator slots.
        bool isOwner;
        try registry.ownerOf(agentId) returns (address ownr) { isOwner = ownr == msg.sender; } catch {}
        if (!isOwner) {
            try registry.getAgentOwner(agentId) returns (address ownr) { isOwner = ownr == msg.sender; } catch {}
        }
        if (!isOwner) revert NotAuthorised();

        operators[agentId][operator] = allowed;
        emit OperatorUpdated(agentId, operator, allowed);
    }

    // ─── Hook trigger ───────────────────────────────────────────────────

    /// @notice Re-renders the indicator SVG when the host emits a
    ///         status-change trigger. The hook never mutates state from
    ///         {onTrigger}; mutations happen in {setStatus}.
    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (triggerKind != EvolutionTypes.TRIGGER_STATUS_CHANGE) {
            return EvolutionTypes.noOp();
        }
        Status s = currentStatus[agentId];
        r.svgChanged   = true;
        r.newSvgInline = _render(s);
        r.newStateHash = keccak256(abi.encode("status", agentId, s, lastUpdate[agentId]));
    }

    // ─── Views ──────────────────────────────────────────────────────────

    function getStatus(uint256 agentId) external view returns (Status status, uint64 updatedAt) {
        return (currentStatus[agentId], lastUpdate[agentId]);
    }

    function isRunning(uint256 agentId) external view returns (bool) {
        return currentStatus[agentId] == Status.Running;
    }

    // ─── Rendering ──────────────────────────────────────────────────────
    //
    // Three distinct visual states the marketplace UI can read directly:
    //
    //   Offline  — grey dot, "OFF"
    //   Standby  — amber dot, "STBY"
    //   Running  — green dot, "RUN"

    function _render(Status s) internal pure returns (bytes memory) {
        bytes memory color;
        bytes memory label;
        if (s == Status.Running) {
            color = bytes("#22c55e"); // green-500
            label = bytes("RUN");
        } else if (s == Status.Standby) {
            color = bytes("#f59e0b"); // amber-500
            label = bytes("STBY");
        } else {
            color = bytes("#6b7280"); // gray-500
            label = bytes("OFF");
        }
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<rect width="200" height="200" fill="#0d0d12"/>',
            '<circle cx="100" cy="90" r="36" fill="', color, '"/>',
            '<text x="100" y="160" text-anchor="middle" font-family="monospace" ',
            'font-size="32" fill="#fff">', label, '</text>',
            '</svg>'
        );
    }
}
