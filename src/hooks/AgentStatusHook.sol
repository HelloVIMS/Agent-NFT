// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";

/**
 * @title AgentStatusHook
 * @notice Shows whether an agent is Offline, on Standby or Running. The
 *         token's owner — or an operator that owner appointed, e.g. the
 *         machine running the agent — sets it; anyone can redraw with
 *         `triggerEvolve(id, keccak256("status.change"), "")`.
 * @dev    FLAG_ON_TRIGGER. Status is per host collection, and operators are
 *         keyed by the owner who appointed them, so a sale drops the previous
 *         owner's operators automatically.
 */
contract AgentStatusHook is BaseEvolutionHook, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "AgentStatusHook";
    }

    error NotAuthorised();
    error UnknownStatus();

    enum Status { Offline, Standby, Running }

    struct State {
        Status status;
        uint64 updatedAt;
    }
    /// @notice host => token id => status.
    mapping(address => mapping(uint256 => State)) public state;
    /// @notice host => token id => appointing owner => operator => allowed.
    mapping(address => mapping(uint256 => mapping(address => mapping(address => bool)))) public operators;

    event StatusChanged(address indexed host, uint256 indexed agentId, Status previous, Status next, address by);
    event OperatorUpdated(address indexed host, uint256 indexed agentId, address indexed operator, address owner, bool allowed);

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function isAuthorised(address host, uint256 agentId, address caller) public view returns (bool) {
        address owner = _tokenOwner(host, agentId);
        return owner != address(0) && (caller == owner || operators[host][agentId][owner][caller]);
    }

    function setStatus(address host, uint256 agentId, Status next) external {
        if (uint8(next) > uint8(Status.Running)) revert UnknownStatus();
        if (!isAuthorised(host, agentId, msg.sender)) revert NotAuthorised();
        State storage st = state[host][agentId];
        Status prev = st.status;
        if (prev == next && st.updatedAt != 0) return;
        st.status = next;
        st.updatedAt = uint64(block.timestamp);
        emit StatusChanged(host, agentId, prev, next, msg.sender);
    }

    function setOperator(address host, uint256 agentId, address operator, bool allowed) external {
        address owner = _tokenOwner(host, agentId);
        if (owner == address(0) || owner != msg.sender) revert NotAuthorised();
        operators[host][agentId][owner][operator] = allowed;
        emit OperatorUpdated(host, agentId, operator, owner, allowed);
    }

    function getStatus(address host, uint256 agentId) external view returns (Status status, uint64 updatedAt) {
        State memory st = state[host][agentId];
        return (st.status, st.updatedAt);
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        view
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (triggerKind != EvolutionTypes.TRIGGER_STATUS_CHANGE) return EvolutionTypes.noOp();
        State memory st = state[msg.sender][agentId];
        (bytes memory color, bytes memory label) =
            st.status == Status.Running ? (bytes("#22c55e"), bytes("RUN")) :
            st.status == Status.Standby ? (bytes("#f59e0b"), bytes("STBY")) :
                                          (bytes("#6b7280"), bytes("OFF"));
        r.svgChanged   = true;
        r.newSvgInline = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<rect width="200" height="200" fill="#0d0d12"/>',
            '<circle cx="100" cy="90" r="36" fill="', color, '"/>',
            '<text x="100" y="160" text-anchor="middle" font-family="monospace" font-size="32" fill="#fff">', label, '</text>',
            '</svg>'
        );
        r.newStateHash = keccak256(abi.encode("status", msg.sender, agentId, st.status, st.updatedAt));
    }
}
