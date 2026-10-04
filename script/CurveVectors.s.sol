// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";

/**
 * @title  CurveVectorsScript
 * @notice Prints CurveMath prices for a fixed set of curves and positions,
 *         one JSON object per line. The SDK's TypeScript port is checked
 *         against them (vimsbot-sdk/tests/fixtures/curve-vectors.json):
 *
 *   forge script script/CurveVectors.s.sol 2>/dev/null | grep '^  {' | sed 's/^  //'
 */
contract CurveVectorsScript is Script {
    uint256 constant WAD = 1e18;

    function _emit(CurveMath.Curve memory c, uint256 sold) internal pure {
        console.log(string.concat(
            '{"kind":', vm.toString(uint256(c.kind)),
            ',"floor":"', vm.toString(uint256(c.floor)),
            '","ceiling":"', vm.toString(uint256(c.ceiling)),
            '","length":', vm.toString(uint256(c.length)),
            ',"a":', vm.toString(uint256(c.a)),
            ',"b":"', vm.toString(uint256(c.b)),
            '","sold":', vm.toString(sold),
            ',"price":"', vm.toString(CurveMath.priceAt(c, sold)), '"}'
        ));
    }

    function run() external pure {
        uint256[7] memory positions = [uint256(0), 1, 7, 33, 50, 99, 100];
        uint96[2] memory floors = [uint96(1e6), uint96(0.01 ether)];
        uint96[2] memory ceilings = [uint96(101e6), uint96(3.33 ether)];
        for (uint256 f; f < 2; ++f) {
            for (uint256 k; k <= uint256(CurveMath.Kind.AdjustableS); ++k) {
                CurveMath.Curve memory c = CurveMath.Curve({kind: CurveMath.Kind(k), floor: floors[f], ceiling: ceilings[f], length: 101, a: 0, b: 0});
                if (c.kind == CurveMath.Kind.Power) c.a = 3;
                if (c.kind == CurveMath.Kind.AdjustableS) { c.a = 5; c.b = uint96((WAD * 3) / 10); }
                for (uint256 p; p < positions.length; ++p) _emit(c, positions[p]);
            }
        }
        CurveMath.Curve memory e = CurveMath.Curve({kind: CurveMath.Kind.Exponential, floor: 1e6, ceiling: 5_000e6, length: 0, a: 0, b: uint96(WAD / 20)});
        CurveMath.Curve memory t = CurveMath.Curve({kind: CurveMath.Kind.Tiers, floor: 5e6, ceiling: 45e6, length: 0, a: 25, b: 7e6});
        uint256[6] memory open = [uint256(0), 1, 13, 100, 174, 10_000];
        for (uint256 p; p < open.length; ++p) { _emit(e, open[p]); _emit(t, open[p]); }
    }
}
