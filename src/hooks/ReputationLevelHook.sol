// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {IAgentNFTStats}    from "./IAgentNFTStats.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";
import {Strings}           from "@openzeppelin/contracts/utils/Strings.sol";

interface IReputationEras {
    struct EraStats {
        uint64  settlements;
        uint64  disputes;
        uint128 volume;
        uint64  lastSettlementAt;
        uint64  feedbackCount;
        int128  feedbackSum;
        uint64  lastFeedbackAt;
    }
    function currentEra(uint256 agentId) external view returns (uint256);
    function eraStats(uint256 agentId, uint256 era) external view returns (EraStats memory);
}

/**
 * @title ReputationLevelHook
 * @notice Tiers an agent by its track record of paid hires. Tier n = number
 *         of `hireThresholds` its paid-hire count has reached.
 *
 *         Identity agents are read from the reputation registry's current
 *         owner era — a new owner starts again at tier 0 — and drop to tier 0
 *         while their buyers' ratings are net negative. Collection agents
 *         (no ratings exist for them) are read from the payment contract's
 *         paid-hire count.
 * @dev    FLAG_ON_TRIGGER (TRIGGER_REPUTATION).
 */
contract ReputationLevelHook is BaseEvolutionHook, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "ReputationLevelHook";
    }

    error ZeroAddress();
    error ThresholdsNotIncreasing();

    IAgentNFTStats  public immutable receiver;
    IReputationEras public immutable reputation;
    address public immutable identityRegistry;
    uint256[] public hireThresholds;

    constructor(address _receiver, address _reputation, uint256[] memory _thresholds) {
        if (_receiver == address(0) || _reputation == address(0)) revert ZeroAddress();
        for (uint256 i = 1; i < _thresholds.length; ++i) {
            if (_thresholds[i] <= _thresholds[i - 1]) revert ThresholdsNotIncreasing();
        }
        receiver = IAgentNFTStats(_receiver);
        reputation = IReputationEras(_reputation);
        identityRegistry = IAgentNFTStats(_receiver).identityRegistry();
        hireThresholds = _thresholds;
    }

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function tierOf(address host, uint256 agentId) public view returns (uint8 tier, uint64 hires, int128 ratingSum) {
        if (host == identityRegistry) {
            IReputationEras.EraStats memory st = reputation.eraStats(agentId, reputation.currentEra(agentId));
            hires = st.settlements;
            ratingSum = st.feedbackSum;
            if (ratingSum < 0) return (0, hires, ratingSum);
        } else {
            hires = receiver.nftSettlements(host, agentId);
        }
        while (tier < hireThresholds.length && hires >= hireThresholds[tier]) tier++;
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        view
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (triggerKind != EvolutionTypes.TRIGGER_REPUTATION) return EvolutionTypes.noOp();
        (uint8 tier, uint64 hires, int128 ratingSum) = tierOf(msg.sender, agentId);
        uint256 hue = 30 + uint256(tier) * 30;
        if (hue > 140) hue = 140;
        r.svgChanged   = true;
        r.newSvgInline = abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<rect width="200" height="200" fill="#0d0d12"/>',
            '<polygon points="100,20 180,180 20,180" fill="hsl(', Strings.toString(hue), ',75%,50%)"/>',
            '<text x="100" y="135" text-anchor="middle" font-family="monospace" font-size="42" fill="#fff">T',
            Strings.toString(uint256(tier)), '</text></svg>'
        );
        r.newStateHash = keccak256(abi.encode("rep", msg.sender, agentId, tier, hires, ratingSum));
    }
}
