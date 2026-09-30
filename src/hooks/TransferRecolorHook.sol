// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {Strings}           from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title TransferRecolorHook
 * @notice Recolors a token each time it changes hands: hue = (transfers × 47) mod 360.
 * @dev    FLAG_AFTER_TRANSFER | FLAG_ON_TRIGGER. Counts owner-to-owner moves
 *         only (not mints or burns), per host collection — see BaseEvolutionHook.
 */
contract TransferRecolorHook is BaseEvolutionHook {
    uint256 public constant HUE_STEP = 47;

    /// @notice host collection => token id => owner-to-owner transfers.
    mapping(address => mapping(uint256 => uint256)) public transferCount;

    event Recolored(address indexed host, uint256 indexed agentId, uint256 transferCount, uint256 hue);

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_AFTER_TRANSFER | EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function afterTransfer(uint256 agentId, address from, address to) external override returns (bytes4) {
        if (from != address(0) && to != address(0)) transferCount[msg.sender][agentId] += 1;
        return this.afterTransfer.selector;
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (triggerKind != EvolutionTypes.TRIGGER_TRANSFER) return EvolutionTypes.noOp();
        uint256 count = transferCount[msg.sender][agentId];
        uint256 hue = (count * HUE_STEP) % 360;
        r.svgChanged   = true;
        r.newSvgInline = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<circle cx="100" cy="100" r="90" fill="hsl(', Strings.toString(hue), ',70%,55%)"/></svg>'
        );
        r.newStateHash = keccak256(abi.encode("recolor", msg.sender, agentId, count, hue));
        emit Recolored(msg.sender, agentId, count, hue);
    }
}
