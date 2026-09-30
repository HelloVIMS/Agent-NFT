// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {IAgentNFTStats}    from "./IAgentNFTStats.sol";
import {Strings}           from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title RevenueLevelHook
 * @notice Levels an agent by what buyers have paid it for services, read live
 *         from the payment contract — so a level can't be granted, only
 *         earned. Level n = number of thresholds its gross revenue has reached.
 * @dev    FLAG_ON_TRIGGER (TRIGGER_SERVICE_X402). One payment `token` (USDC).
 *         Wash trading costs the payment contract's fee on every round trip,
 *         and an owner paying their own agent isn't counted.
 */
contract RevenueLevelHook is BaseEvolutionHook {
    error ZeroAddress();
    error ThresholdsNotIncreasing();

    IAgentNFTStats public immutable receiver;
    address public immutable token;
    uint256[] public levelThresholds;

    constructor(address _receiver, address _token, uint256[] memory _thresholds) {
        if (_receiver == address(0) || _token == address(0)) revert ZeroAddress();
        for (uint256 i = 1; i < _thresholds.length; ++i) {
            if (_thresholds[i] <= _thresholds[i - 1]) revert ThresholdsNotIncreasing();
        }
        receiver = IAgentNFTStats(_receiver);
        token = _token;
        levelThresholds = _thresholds;
    }

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function levelOf(address host, uint256 agentId) public view returns (uint8 lvl, uint256 revenue) {
        revenue = receiver.nftVolume(host, agentId, token);
        while (lvl < levelThresholds.length && revenue >= levelThresholds[lvl]) lvl++;
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        view
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (triggerKind != EvolutionTypes.TRIGGER_SERVICE_X402) return EvolutionTypes.noOp();
        (uint8 lvl, uint256 revenue) = levelOf(msg.sender, agentId);
        uint256 sat = 30 + uint256(lvl) * 15;
        if (sat > 100) sat = 100;
        r.svgChanged   = true;
        r.newSvgInline = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<rect width="200" height="200" fill="#0d0d12"/>',
            '<circle cx="100" cy="100" r="80" fill="none" stroke="hsl(48,', Strings.toString(sat),
            '%,55%)" stroke-width="', Strings.toString(4 + uint256(lvl)), '"/>',
            '<text x="100" y="115" text-anchor="middle" font-family="monospace" font-size="48" fill="#fff">L',
            Strings.toString(uint256(lvl)), '</text></svg>'
        );
        r.newStateHash = keccak256(abi.encode("level", msg.sender, agentId, lvl, revenue));
    }
}
