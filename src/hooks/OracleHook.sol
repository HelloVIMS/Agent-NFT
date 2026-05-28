// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";

/**
 * @title IPriceFeed
 * @notice Minimal Chainlink AggregatorV3 surface used by {OracleHook}.
 */
interface IPriceFeed {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

/**
 * @title OracleHook
 * @notice Mutates the SVG based on a Chainlink-style price feed answer. The
 *         payload to `triggerEvolve` selects which threshold band the agent
 *         currently sits in (e.g., bull / neutral / bear). Demonstrates the
 *         oracle-driven branch of the hook system.
 *
 * @dev    Permission set: FLAG_ON_TRIGGER. Triggers handled: TRIGGER_ORACLE_UPDATE.
 *         Stale-data protection: revert if the feed hasn't updated within
 *         {STALENESS_LIMIT}. The price feed contract is immutable.
 */
contract OracleHook is BaseEvolutionHook {
    error StalePrice();
    error InvalidPrice();

    enum Band { Bear, Neutral, Bull }

    IPriceFeed public immutable feed;
    int256 public immutable bearThreshold;
    int256 public immutable bullThreshold;
    uint256 public constant STALENESS_LIMIT = 1 hours;

    event Bucketed(uint256 indexed agentId, int256 price, Band band);

    constructor(address _feed, int256 _bearThreshold, int256 _bullThreshold) {
        feed = IPriceFeed(_feed);
        bearThreshold = _bearThreshold;
        bullThreshold = _bullThreshold;
    }

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function readBand() public view returns (Band band, int256 price) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        // Future-dated rounds (misconfigured feed / replay across forks) are
        // also stale from this contract's perspective; treat as such instead
        // of underflowing into a panic.
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > STALENESS_LIMIT) {
            revert StalePrice();
        }
        price = answer;
        if      (answer <  bearThreshold) band = Band.Bear;
        else if (answer >= bullThreshold) band = Band.Bull;
        else                              band = Band.Neutral;
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (!EvolutionTypes.hasFlag(_PERMISSIONS, EvolutionTypes.FLAG_ON_TRIGGER)) {
            revert PermissionNotDeclared(EvolutionTypes.FLAG_ON_TRIGGER);
        }
        if (triggerKind != EvolutionTypes.TRIGGER_ORACLE_UPDATE) {
            return EvolutionTypes.noOp();
        }

        (Band band, int256 price) = readBand();
        bytes memory svg = _renderBand(band);

        r.svgChanged   = true;
        r.newSvgInline = svg;
        r.newStateHash = keccak256(abi.encode("oracle", agentId, band, price));
        emit Bucketed(agentId, price, band);
        return r;
    }

    function _renderBand(Band b) internal pure returns (bytes memory) {
        string memory color =
            b == Band.Bull    ? "#1bd96a" :
            b == Band.Bear    ? "#ff4f5e" :
                                "#9aa0a6";
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<rect width="200" height="200" fill="#0d0d12"/>',
            '<polygon points="', _polygon(b), '" fill="', color, '"/>',
            '</svg>'
        );
    }

    function _polygon(Band b) internal pure returns (string memory) {
        if (b == Band.Bull)    return "30,160 100,40 170,160";   // up arrow
        if (b == Band.Bear)    return "30,40 100,160 170,40";    // down arrow
        return "30,90 170,90 170,110 30,110";                    // bar (neutral)
    }
}
