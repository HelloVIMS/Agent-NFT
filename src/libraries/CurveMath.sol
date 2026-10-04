// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title  CurveMath
 * @notice Price curves for selling a collection's agents: the price of the
 *         next agent given how many are already out. Integer fixed-point
 *         (WAD = 1e18), every shape non-decreasing in supply, prices
 *         rounded down. Prices are in the sale currency's base units (wei,
 *         USDC's 6 decimals).
 *
 *         Shaped curves span `length` agents from `floor` (the first) to
 *         `ceiling` (the last, and every one after): price =
 *         floor + (ceiling − floor) · f(x), x = sold / (length − 1).
 *
 *           Linear        f = x
 *           Power         f = x^a                        a ∈ [2, 4]: slow, then accelerating
 *           Elliptical    f = √(1 − (1 − x)²)            sharp rise, then tapering off
 *           Sqrt          f = √x                         a gentler rise-then-taper
 *           Smoothstep    f = 3x² − 2x³                  S: slow, rapid, levelling off
 *           Smootherstep  f = 6x⁵ − 15x⁴ + 10x³          a flatter-ended S
 *           AdjustableS   f = u^a / (u^a + (1 − u)^a)    S with steepness a ∈ [2, 8] and its
 *                                                        midpoint at x = b (WAD, 5%–95%): u maps
 *                                                        [0, b] → [0, ½] and [b, 1] → [½, 1]
 *
 *         Open-ended curves need no length:
 *
 *           Exponential   floor · (1 + b)^sold           b = growth per agent (WAD, ≤ 100%),
 *                                                        capped at `ceiling`
 *           Tiers         floor + ⌊sold / a⌋ · b         steps of b every a agents,
 *                                                        capped at `ceiling` (0: no cap)
 */
library CurveMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_LENGTH = 1_000_000;

    enum Kind { Linear, Power, Elliptical, Sqrt, Smoothstep, Smootherstep, AdjustableS, Exponential, Tiers }

    struct Curve {
        Kind    kind;
        uint96  floor;
        uint96  ceiling;
        uint32  length;
        uint16  a;
        uint96  b;
    }

    error InvalidCurve(string reason);

    function validate(Curve memory c) internal pure {
        if (c.kind == Kind.Exponential) {
            if (c.floor == 0) revert InvalidCurve("exponential needs a floor above zero");
            if (c.b == 0 || c.b > WAD) revert InvalidCurve("exponential growth must be in (0, 100%]");
            if (c.ceiling < c.floor) revert InvalidCurve("exponential needs a ceiling at or above the floor");
            return;
        }
        if (c.kind == Kind.Tiers) {
            if (c.a == 0) revert InvalidCurve("tiers need a size of at least one agent");
            if (c.ceiling != 0 && c.ceiling < c.floor) revert InvalidCurve("ceiling below floor");
            return;
        }
        if (c.length < 2 || c.length > MAX_LENGTH) revert InvalidCurve("a shaped curve spans 2 to 1,000,000 agents");
        if (c.ceiling < c.floor) revert InvalidCurve("ceiling below floor");
        if (c.kind == Kind.Power && (c.a < 2 || c.a > 4)) revert InvalidCurve("power exponent must be 2, 3 or 4");
        if (c.kind == Kind.AdjustableS) {
            if (c.a < 2 || c.a > 8) revert InvalidCurve("steepness must be 2 to 8");
            if (c.b < WAD / 20 || c.b > (WAD * 19) / 20) revert InvalidCurve("midpoint must be 5% to 95%");
        }
    }

    /// @notice Price of the next agent when `sold` are already out.
    function priceAt(Curve memory c, uint256 sold) internal pure returns (uint256) {
        if (c.kind == Kind.Exponential) return _exponential(c, sold);
        if (c.kind == Kind.Tiers) {
            uint256 p = uint256(c.floor) + (sold / c.a) * uint256(c.b);
            return c.ceiling != 0 && p > c.ceiling ? c.ceiling : p;
        }
        uint256 last = uint256(c.length) - 1;
        uint256 x = sold >= last ? WAD : (sold * WAD) / last;
        return uint256(c.floor) + Math.mulDiv(uint256(c.ceiling) - c.floor, shape(c, x), WAD);
    }

    /// @notice Total for the next `n` agents after `sold`.
    function costOf(Curve memory c, uint256 sold, uint256 n) internal pure returns (uint256 total) {
        for (uint256 i; i < n; ++i) total += priceAt(c, sold + i);
    }

    /// @notice A shaped curve's f(x), x and result in WAD, both in [0, WAD].
    function shape(Curve memory c, uint256 x) internal pure returns (uint256) {
        Kind k = c.kind;
        if (k == Kind.Linear) return x;
        if (k == Kind.Power) return _pow(x, c.a);
        if (k == Kind.Elliptical) {
            uint256 r = WAD - x;
            return Math.sqrt(WAD * WAD - r * r);
        }
        if (k == Kind.Sqrt) return Math.sqrt(x * WAD);
        if (k == Kind.Smoothstep) {
            uint256 x2 = _mul(x, x);
            return 3 * x2 - 2 * _mul(x2, x);
        }
        if (k == Kind.Smootherstep) {
            uint256 x2 = _mul(x, x);
            // x³ · (6x² − 15x + 10); the bracket is ≥ 1 on [0, 1].
            return _mul(_mul(x2, x), 6 * x2 + 10 * WAD - 15 * x);
        }
        // AdjustableS
        uint256 m = c.b;
        uint256 u = x <= m ? Math.mulDiv(x, WAD, 2 * m) : WAD / 2 + Math.mulDiv(x - m, WAD, 2 * (WAD - m));
        uint256 ua = _pow(u, c.a);
        uint256 va = _pow(WAD - u, c.a);
        return ua + va == 0 ? WAD / 2 : Math.mulDiv(ua, WAD, ua + va);
    }

    function _mul(uint256 a, uint256 b) private pure returns (uint256) {
        return (a * b) / WAD;
    }

    function _pow(uint256 x, uint256 n) private pure returns (uint256 r) {
        r = WAD;
        for (uint256 i; i < n; ++i) r = _mul(r, x);
    }

    /// @dev floor · (1 + g)^sold by squaring, saturating at the ceiling:
    ///      every factor stays at or below ceiling/floor, so nothing overflows.
    function _exponential(Curve memory c, uint256 sold) private pure returns (uint256) {
        uint256 limit = Math.mulDiv(c.ceiling, WAD, c.floor); // ceiling / floor in WAD
        uint256 rootLimit = Math.sqrt(limit * WAD);           // base ≥ this ⇒ base² ≥ limit
        uint256 base = WAD + c.b;
        uint256 r = WAD;
        for (uint256 e = sold; e != 0; e >>= 1) {
            if (e & 1 == 1) {
                r = Math.mulDiv(r, base, WAD);
                if (r >= limit) return c.ceiling;
            }
            if (e > 1) base = base >= rootLimit ? limit : _mul(base, base);
        }
        uint256 p = _mul(c.floor, r);
        return p > c.ceiling ? c.ceiling : p;
    }
}
