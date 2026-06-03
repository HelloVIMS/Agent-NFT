// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";

/// @notice Resolves the address that receives tips for a given agentId.
///         Production wires this to AgentIdentityRegistry / AgentTBARegistry.
interface ITipBeneficiary {
    function tipBeneficiary(uint256 agentId) external view returns (address);
}

/**
 * @title TipJarHook
 * @notice Lets anyone send ETH to a specific agentId; the cumulative tip total
 *         is rendered onto the SVG. Funds are forwarded immediately to a
 *         `beneficiary` resolver (typically the agent's TBA) — the hook itself
 *         never holds funds.
 *
 * @dev    Permission set: FLAG_ON_TRIGGER. Trigger handled: TRIGGER_CUSTOM
 *         (kind == keccak256("tip.jar")). The `tip(agentId)` function is the
 *         actual payment entry-point; on-chain accounting is updated there
 *         and the SVG state is re-rendered through `onTrigger` either by the
 *         host's permissionless `triggerEvolve` path or directly inline by
 *         the marketplace.
 */
contract TipJarHook is BaseEvolutionHook, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "TipJarHook";
    }

    bytes32 public constant TRIG_TIP_JAR = keccak256("tip.jar");

    error ZeroBeneficiary();
    error ZeroAmount();
    error TransferFailed();

    ITipBeneficiary public immutable resolver;

    /// @notice Cumulative ETH tipped per agent (in wei).
    mapping(uint256 => uint256) public tipped;
    /// @notice Most recent individual tip per agent (in wei) for SVG rendering.
    mapping(uint256 => uint256) public lastTip;
    /// @notice Number of tips received per agent.
    mapping(uint256 => uint32)  public tipCount;

    event Tipped(uint256 indexed agentId, address indexed from, uint256 amount, uint256 cumulative);

    constructor(address _resolver) {
        if (_resolver == address(0)) revert ZeroBeneficiary();
        resolver = ITipBeneficiary(_resolver);
    }

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    /// @notice Send ETH as a tip to `agentId`. Forwards to the agent's TBA.
    function tip(uint256 agentId) external payable {
        if (msg.value == 0) revert ZeroAmount();
        address beneficiary = resolver.tipBeneficiary(agentId);
        if (beneficiary == address(0)) revert ZeroBeneficiary();

        unchecked {
            tipped[agentId]   += msg.value;
            lastTip[agentId]   = msg.value;
            tipCount[agentId] += 1;
        }
        emit Tipped(agentId, msg.sender, msg.value, tipped[agentId]);

        (bool ok, ) = beneficiary.call{value: msg.value}("");
        if (!ok) revert TransferFailed();
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        view
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (triggerKind != TRIG_TIP_JAR) return EvolutionTypes.noOp();
        r.svgChanged   = true;
        r.newSvgInline = _render(tipped[agentId], tipCount[agentId]);
        r.newStateHash = keccak256(abi.encode("tip", agentId, tipped[agentId], tipCount[agentId]));
    }

    function _render(uint256 cumWei, uint32 count) internal pure returns (bytes memory) {
        // Display cumulative tips in milliETH (1e15 wei).
        uint256 milli = cumWei / 1e15;
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<rect width="200" height="200" fill="#10101a"/>',
            '<text x="100" y="60"  text-anchor="middle" font-family="monospace" font-size="22" fill="#888">tips</text>',
            '<text x="100" y="115" text-anchor="middle" font-family="monospace" font-size="36" fill="#ffd54a">',
            _u(milli), unicode' m\u039E', '</text>',
            '<text x="100" y="160" text-anchor="middle" font-family="monospace" font-size="16" fill="#666">x',
            _u(uint256(count)), '</text>',
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
