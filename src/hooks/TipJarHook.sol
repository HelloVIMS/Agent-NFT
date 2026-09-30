// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";
import {Strings}           from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title TipJarHook
 * @notice ETH tips for an agent NFT, forwarded straight to its current owner;
 *         the art shows the running total. `tip(host, tokenId)` names the
 *         collection, so a tip can only reach the owner of that exact token.
 * @dev    FLAG_ON_TRIGGER (kind keccak256("tip.jar")). Holds no funds: each
 *         tip is forwarded in the same call, after the totals are updated.
 */
contract TipJarHook is BaseEvolutionHook, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "TipJarHook";
    }

    bytes32 public constant TRIG_TIP_JAR = keccak256("tip.jar");

    error NoSuchToken();
    error ZeroAmount();
    error TransferFailed();

    struct Jar {
        uint256 total;
        uint256 last;
        uint32  count;
    }
    /// @notice host collection => token id => tips.
    mapping(address => mapping(uint256 => Jar)) public jars;

    event Tipped(address indexed host, uint256 indexed agentId, address indexed from, address to, uint256 amount, uint256 total);

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function tip(address host, uint256 agentId) external payable {
        if (msg.value == 0) revert ZeroAmount();
        address owner = _tokenOwner(host, agentId);
        if (owner == address(0)) revert NoSuchToken();
        Jar storage j = jars[host][agentId];
        j.total += msg.value;
        j.last = msg.value;
        j.count += 1;
        emit Tipped(host, agentId, msg.sender, owner, msg.value, j.total);
        (bool ok, ) = owner.call{value: msg.value}("");
        if (!ok) revert TransferFailed();
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        view
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (triggerKind != TRIG_TIP_JAR) return EvolutionTypes.noOp();
        Jar memory j = jars[msg.sender][agentId];
        r.svgChanged   = true;
        r.newSvgInline = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<rect width="200" height="200" fill="#10101a"/>',
            '<text x="100" y="60" text-anchor="middle" font-family="monospace" font-size="22" fill="#888">tips</text>',
            '<text x="100" y="115" text-anchor="middle" font-family="monospace" font-size="36" fill="#ffd54a">',
            Strings.toString(j.total / 1e15), unicode' m\u039E', '</text>',
            '<text x="100" y="160" text-anchor="middle" font-family="monospace" font-size="16" fill="#666">x',
            Strings.toString(uint256(j.count)), '</text></svg>'
        );
        r.newStateHash = keccak256(abi.encode("tip", msg.sender, agentId, j.total, j.count));
    }
}
