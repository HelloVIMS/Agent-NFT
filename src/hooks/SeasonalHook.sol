// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseEvolutionHook} from "./BaseEvolutionHook.sol";
import {EvolutionTypes}    from "./EvolutionTypes.sol";
import {VimsProvenance}    from "../VimsProvenance.sol";

/**
 * @title SeasonalHook
 * @notice Renders one of four seasons based on the calendar month.
 *         Northern-hemisphere semantics (Spring = Mar-May, Summer = Jun-Aug,
 *         Autumn = Sep-Nov, Winter = Dec-Feb).
 *
 * @dev    Permission set: FLAG_ON_TRIGGER. Trigger handled: TRIGGER_TIME_TICK.
 *         Month derivation is the standard {Howard Hinnant} chronology
 *         algorithm specialised to UNIX seconds, so it is correct from
 *         1970-01-01 through 9999-12-31 inclusive.
 */
contract SeasonalHook is BaseEvolutionHook, VimsProvenance {
    function _vimsContractName() internal pure override returns (string memory) {
        return "SeasonalHook";
    }

    enum Season { Winter, Spring, Summer, Autumn }

    event SeasonChanged(uint256 indexed agentId, Season season, uint16 year, uint8 month);

    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_ON_TRIGGER;
    }

    function currentSeason() public view returns (Season s, uint16 year, uint8 month) {
        (year, month, ) = _ymd(block.timestamp);
        if (month == 12 || month <= 2)      s = Season.Winter;
        else if (month <= 5)                s = Season.Spring;
        else if (month <= 8)                s = Season.Summer;
        else                                s = Season.Autumn;
    }

    function onTrigger(uint256 agentId, bytes32 triggerKind, bytes calldata)
        external
        override
        returns (EvolutionTypes.EvolutionResult memory r)
    {
        if (triggerKind != EvolutionTypes.TRIGGER_TIME_TICK) return EvolutionTypes.noOp();
        (Season s, uint16 year, uint8 month) = currentSeason();
        r.svgChanged   = true;
        r.newSvgInline = _render(s);
        r.newStateHash = keccak256(abi.encode("season", agentId, s, year, month));
        emit SeasonChanged(agentId, s, year, month);
    }

    function _render(Season s) internal pure returns (bytes memory) {
        (string memory a, string memory b, string memory glyph) = _palette(s);
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">',
            '<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">',
            '<stop offset="0%" stop-color="', a, '"/>',
            '<stop offset="100%" stop-color="', b, '"/>',
            '</linearGradient></defs>',
            '<rect width="200" height="200" fill="url(#g)"/>',
            '<text x="100" y="120" text-anchor="middle" font-size="80">', glyph, '</text>',
            '</svg>'
        );
    }

    function _palette(Season s) internal pure returns (string memory, string memory, string memory) {
        // ASCII glyphs to avoid surrogate-pair encoding issues in tests.
        if (s == Season.Spring) return ("#bff5a8", "#7adc53", "Spr");
        if (s == Season.Summer) return ("#ffe680", "#ff9a3c", "Sum");
        if (s == Season.Autumn) return ("#ffb27a", "#a3431b", "Aut");
        return ("#cfe7ff", "#4a6fa5", "Win");
    }

    /// @dev Ported from Howard Hinnant's "Date Algorithms" — civil_from_days.
    ///      Returns (year, month, day) for a UNIX timestamp.
    function _ymd(uint256 ts) internal pure returns (uint16 year, uint8 month, uint8 day) {
        uint256 z = ts / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;                                        // [0, 146096]
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;   // [0, 399]
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);                 // [0, 365]
        uint256 mp = (5 * doy + 2) / 153;                                      // [0, 11]
        day = uint8(doy - (153 * mp + 2) / 5 + 1);                             // [1, 31]
        month = uint8(mp < 10 ? mp + 3 : mp - 9);                              // [1, 12]
        year = uint16(month <= 2 ? y + 1 : y);
    }
}
