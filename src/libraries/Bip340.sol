// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

/**
 * @title  Bip340
 * @notice BIP-340 Schnorr signature verification over secp256k1 — the
 *         signatures Nostr keys make — for 32-byte messages.
 *
 * @dev    Verifying needs R = s·G − e·P. `ecrecover(z, v, r, s')` returns the
 *         address of r⁻¹·(s'·Q − z·G) for the point Q with x = r and parity v,
 *         so with Q = P (x = px, even y), s' = −e·px and z = −s·px it returns
 *         address(R). R must then equal lift_x(rx) (even y), compared by
 *         address. Square roots use the modexp precompile (p ≡ 3 mod 4);
 *         the challenge hash is BIP-340's tagged SHA-256.
 *
 *         A public key x ≥ n (secp256k1's order) can't be passed to
 *         ecrecover and is rejected; such keys occur with probability ~2⁻¹²⁸.
 */
library Bip340 {
    uint256 internal constant P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    uint256 internal constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @dev sha256("BIP0340/challenge")
    bytes32 private constant CHALLENGE_TAG = 0x7bb52d7a9fef58323eb1bf7a407db382d2f3f2d81bb1224f49fe518f6d48d37c;

    /// @notice True when `sig` (rx ‖ s, 64 bytes) is a valid BIP-340
    ///         signature by x-only key `px` over the 32-byte message `m`.
    function verify(bytes32 px, bytes32 m, bytes memory sig) internal view returns (bool) {
        if (sig.length != 64) return false;
        uint256 rx;
        uint256 s;
        assembly {
            rx := mload(add(sig, 32))
            s := mload(add(sig, 64))
        }
        uint256 x = uint256(px);
        if (x >= N || x == 0 || rx >= P || s >= N) return false;
        (bool pOk, ) = liftX(x);
        if (!pOk) return false;
        (bool rOk, uint256 ry) = liftX(rx);
        if (!rOk) return false;

        uint256 e = uint256(sha256(abi.encodePacked(CHALLENGE_TAG, CHALLENGE_TAG, bytes32(rx), px, m))) % N;
        if (e == 0) return false;

        // address(s·G − e·P), P = lift_x(px) has even y → v = 27.
        bytes32 z = bytes32(N - mulmod(s, x, N));
        bytes32 sPrime = bytes32(N - mulmod(e, x, N));
        address recovered = ecrecover(z == bytes32(N) ? bytes32(0) : z, 27, px, sPrime);
        if (recovered == address(0)) return false;
        return recovered == address(uint160(uint256(keccak256(abi.encodePacked(rx, ry)))));
    }

    /// @notice The point with x-coordinate `x` and even y, if on the curve.
    function liftX(uint256 x) internal view returns (bool ok, uint256 y) {
        if (x >= P) return (false, 0);
        uint256 c = addmod(mulmod(mulmod(x, x, P), x, P), 7, P);
        y = _modexp(c, (P + 1) / 4);
        if (mulmod(y, y, P) != c) return (false, 0);
        if (y & 1 == 1) y = P - y;
        return (true, y);
    }

    function _modexp(uint256 base, uint256 exponent) private view returns (uint256) {
        (bool ok, bytes memory out) = address(0x05).staticcall(abi.encodePacked(uint256(32), uint256(32), uint256(32), base, exponent, P));
        require(ok && out.length == 32, "modexp");
        return abi.decode(out, (uint256));
    }
}
