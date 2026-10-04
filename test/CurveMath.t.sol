// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";

contract CurveHarness {
    function priceAt(CurveMath.Curve memory c, uint256 sold) external pure returns (uint256) {
        return CurveMath.priceAt(c, sold);
    }
    function validate(CurveMath.Curve memory c) external pure {
        CurveMath.validate(c);
    }
}

contract CurveMathTest is Test {
    CurveHarness h = new CurveHarness();
    uint256 constant WAD = 1e18;
    uint96 constant FLOOR = 1e6;   // 1 USDC
    uint96 constant CEIL  = 101e6; // 101 USDC: range 100 USDC

    function _c(CurveMath.Kind k, uint16 a, uint96 b) internal pure returns (CurveMath.Curve memory) {
        return CurveMath.Curve({kind: k, floor: FLOOR, ceiling: CEIL, length: 101, a: a, b: b});
    }

    function _shaped() internal pure returns (CurveMath.Curve[8] memory cs) {
        cs[0] = _c(CurveMath.Kind.Linear, 0, 0);
        cs[1] = _c(CurveMath.Kind.Power, 2, 0);
        cs[2] = _c(CurveMath.Kind.Power, 4, 0);
        cs[3] = _c(CurveMath.Kind.Elliptical, 0, 0);
        cs[4] = _c(CurveMath.Kind.Sqrt, 0, 0);
        cs[5] = _c(CurveMath.Kind.Smoothstep, 0, 0);
        cs[6] = _c(CurveMath.Kind.Smootherstep, 0, 0);
        cs[7] = _c(CurveMath.Kind.AdjustableS, 6, uint96(WAD / 2));
    }

    // Every shaped curve starts at its floor, ends at its ceiling, stays there.
    function test_shapedCurvesSpanFloorToCeiling() public view {
        CurveMath.Curve[8] memory cs = _shaped();
        for (uint256 i; i < cs.length; ++i) {
            h.validate(cs[i]);
            assertEq(h.priceAt(cs[i], 0), FLOOR, "first at floor");
            assertEq(h.priceAt(cs[i], 100), CEIL, "last at ceiling");
            assertEq(h.priceAt(cs[i], 5000), CEIL, "after the last, the ceiling");
        }
    }

    // Halfway (x = ½), each shape where its formula puts it (range 100 USDC).
    function test_midpoints() public view {
        uint256 mid = 50;
        assertEq(h.priceAt(_c(CurveMath.Kind.Linear, 0, 0), mid), FLOOR + 50e6);
        assertEq(h.priceAt(_c(CurveMath.Kind.Power, 2, 0), mid), FLOOR + 25e6);
        assertEq(h.priceAt(_c(CurveMath.Kind.Power, 3, 0), mid), FLOOR + 12.5e6);
        assertApproxEqAbs(h.priceAt(_c(CurveMath.Kind.Elliptical, 0, 0), mid), FLOOR + 86_602_540, 1); // √0.75
        assertApproxEqAbs(h.priceAt(_c(CurveMath.Kind.Sqrt, 0, 0), mid), FLOOR + 70_710_678, 1);       // √0.5
        assertEq(h.priceAt(_c(CurveMath.Kind.Smoothstep, 0, 0), mid), FLOOR + 50e6);
        assertEq(h.priceAt(_c(CurveMath.Kind.Smootherstep, 0, 0), mid), FLOOR + 50e6);
        assertEq(h.priceAt(_c(CurveMath.Kind.AdjustableS, 6, uint96(WAD / 2)), mid), FLOOR + 50e6);
        // A midpoint moved to 30%: half the range is reached at the 30th agent.
        assertEq(h.priceAt(_c(CurveMath.Kind.AdjustableS, 6, uint96((WAD * 3) / 10)), 30), FLOOR + 50e6);
    }

    // The character of each shape: how much of the rise happens early vs late.
    function test_shapes() public view {
        // first-quarter rise vs last-quarter rise
        function(CurveMath.Curve memory) internal view returns (uint256, uint256) q = _quarters;
        (uint256 e1, uint256 l1) = q(_c(CurveMath.Kind.Power, 2, 0));
        assertLt(e1, l1, "power: slow, then accelerating");
        (uint256 e2, uint256 l2) = q(_c(CurveMath.Kind.Elliptical, 0, 0));
        assertGt(e2, 5 * l2, "elliptical: sharp rise, then tapering");
        (uint256 e3, uint256 l3) = q(_c(CurveMath.Kind.Sqrt, 0, 0));
        assertGt(e3, l3, "sqrt: rises then tapers");
        CurveMath.Curve memory s = _c(CurveMath.Kind.Smoothstep, 0, 0);
        uint256 middle = h.priceAt(s, 62) - h.priceAt(s, 37);
        (uint256 e4, uint256 l4) = q(s);
        assertGt(middle, e4 + l4, "S: most of the rise in the middle");
        CurveMath.Curve memory steep = _c(CurveMath.Kind.AdjustableS, 8, uint96(WAD / 2));
        CurveMath.Curve memory soft = _c(CurveMath.Kind.AdjustableS, 2, uint96(WAD / 2));
        assertGt(h.priceAt(steep, 55) - h.priceAt(steep, 45), h.priceAt(soft, 55) - h.priceAt(soft, 45), "steeper S, sharper middle");
    }

    function _quarters(CurveMath.Curve memory c) internal view returns (uint256 early, uint256 late) {
        early = h.priceAt(c, 25) - h.priceAt(c, 0);
        late = h.priceAt(c, 100) - h.priceAt(c, 75);
    }

    // No curve ever gets cheaper as more agents go out.
    function testFuzz_shapedCurvesNeverDecrease(uint8 kind, uint32 length, uint32 sold, uint96 floor, uint96 range, uint16 a, uint96 m) public view {
        kind = uint8(bound(kind, 0, 6));
        CurveMath.Curve memory c;
        c.kind = CurveMath.Kind(kind);
        c.length = uint32(bound(length, 2, CurveMath.MAX_LENGTH));
        c.floor = uint96(bound(floor, 0, 1e27));
        c.ceiling = uint96(uint256(c.floor) + bound(range, 0, 1e27));
        if (c.kind == CurveMath.Kind.Power) c.a = uint16(bound(a, 2, 4));
        if (c.kind == CurveMath.Kind.AdjustableS) {
            c.a = uint16(bound(a, 2, 8));
            c.b = uint96(bound(m, WAD / 20, (WAD * 19) / 20));
        }
        h.validate(c);
        uint256 s = bound(sold, 0, uint256(c.length) + 5);
        uint256 p0 = h.priceAt(c, s);
        uint256 p1 = h.priceAt(c, s + 1);
        assertGe(p1, p0, "never decreases");
        assertGe(p0, c.floor);
        assertLe(p1, c.ceiling);
    }

    function test_exponentialCompoundsAndCaps() public view {
        CurveMath.Curve memory c = CurveMath.Curve({kind: CurveMath.Kind.Exponential, floor: 1e6, ceiling: 1_000e6, length: 0, a: 0, b: uint96(WAD / 10)});
        h.validate(c);
        uint256 expected = 1e6 * WAD; // reference kept at full precision
        for (uint256 i; i < 40; ++i) {
            assertApproxEqAbs(h.priceAt(c, i), expected / WAD, 1, "floor * 1.1^n");
            expected = (expected * 11) / 10;
        }
        assertEq(h.priceAt(c, 73), 1_000e6, "1.1^73 > 1000: capped");
        assertEq(h.priceAt(c, type(uint32).max), 1_000e6);
    }

    function testFuzz_exponentialNeverOverflowsOrDecreases(uint96 floor, uint96 ceiling, uint96 growth, uint32 sold) public view {
        CurveMath.Curve memory c;
        c.kind = CurveMath.Kind.Exponential;
        c.floor = uint96(bound(floor, 1, type(uint96).max));
        c.ceiling = uint96(bound(ceiling, c.floor, type(uint96).max));
        c.b = uint96(bound(growth, 1, WAD));
        h.validate(c);
        uint256 p0 = h.priceAt(c, sold);
        uint256 p1 = h.priceAt(c, uint256(sold) + 1);
        assertGe(p1, p0);
        assertGe(p0, c.floor);
        assertLe(p1, c.ceiling);
    }

    function test_tiers() public view {
        CurveMath.Curve memory c = CurveMath.Curve({kind: CurveMath.Kind.Tiers, floor: 10e6, ceiling: 40e6, length: 0, a: 100, b: 10e6});
        h.validate(c);
        assertEq(h.priceAt(c, 0), 10e6);
        assertEq(h.priceAt(c, 99), 10e6);
        assertEq(h.priceAt(c, 100), 20e6);
        assertEq(h.priceAt(c, 250), 30e6);
        assertEq(h.priceAt(c, 10_000), 40e6, "capped");
        c.ceiling = 0;
        assertEq(h.priceAt(c, 10_000), 1_010e6, "uncapped");
    }

    function test_cappedTiersSaturateBeforeMultiplicationOverflows() public view {
        CurveMath.Curve memory c = CurveMath.Curve({kind: CurveMath.Kind.Tiers, floor: 10, ceiling: 100, length: 0, a: 1, b: type(uint96).max});
        h.validate(c);
        assertEq(h.priceAt(c, type(uint256).max), 100);
        c.b = 0;
        assertEq(h.priceAt(c, type(uint256).max), 10);
    }

    function testFuzz_shapedEndpointsAtMaximumPrices(uint8 kind, uint32 length, uint16 a, uint96 m) public view {
        CurveMath.Curve memory c = CurveMath.Curve({kind: CurveMath.Kind(bound(kind, 0, 6)), floor: 0, ceiling: type(uint96).max,
            length: uint32(bound(length, 2, CurveMath.MAX_LENGTH)), a: 0, b: 0});
        if (c.kind == CurveMath.Kind.Power) c.a = uint16(bound(a, 2, 4));
        if (c.kind == CurveMath.Kind.AdjustableS) {
            c.a = uint16(bound(a, 2, 8));
            c.b = uint96(bound(m, WAD / 20, WAD * 19 / 20));
        }
        h.validate(c);
        uint256 previous;
        uint256 start = c.length > 10 ? c.length - 10 : 0;
        for (uint256 i = start; i < c.length; ++i) {
            uint256 price = h.priceAt(c, i);
            assertGe(price, previous);
            assertLe(price, c.ceiling);
            previous = price;
        }
        assertEq(previous, c.ceiling);
    }

    function test_invalidCurvesAreRefused() public {
        CurveMath.Curve memory c = _c(CurveMath.Kind.Linear, 0, 0);
        c.length = 1;
        vm.expectRevert();
        h.validate(c);
        c = _c(CurveMath.Kind.Linear, 0, 0);
        c.length = uint32(CurveMath.MAX_LENGTH + 1);
        vm.expectRevert();
        h.validate(c);
        c = _c(CurveMath.Kind.Linear, 0, 0);
        c.ceiling = FLOOR - 1;
        vm.expectRevert();
        h.validate(c);
        vm.expectRevert();
        h.validate(_c(CurveMath.Kind.Power, 5, 0));
        vm.expectRevert();
        h.validate(_c(CurveMath.Kind.AdjustableS, 9, uint96(WAD / 2)));
        vm.expectRevert();
        h.validate(_c(CurveMath.Kind.AdjustableS, 4, uint96(WAD / 100)));
        vm.expectRevert();
        h.validate(CurveMath.Curve({kind: CurveMath.Kind.Exponential, floor: 0, ceiling: 1, length: 0, a: 0, b: 1}));
        vm.expectRevert();
        h.validate(CurveMath.Curve({kind: CurveMath.Kind.Exponential, floor: 1, ceiling: 2, length: 0, a: 0, b: uint96(WAD + 1)}));
        vm.expectRevert();
        h.validate(CurveMath.Curve({kind: CurveMath.Kind.Tiers, floor: 1, ceiling: 0, length: 0, a: 0, b: 1}));
    }
}
