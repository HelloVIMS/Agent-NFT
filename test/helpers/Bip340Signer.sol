// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import {Bip340} from "../../src/libraries/Bip340.sol";

/// Test-only BIP-340 signing: affine secp256k1 arithmetic, gas no object.
/// Deterministic nonces (keccak of key and message) — never use outside tests.
library Bip340Signer {
    uint256 constant P = Bip340.P;
    uint256 constant N = Bip340.N;
    uint256 constant GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    uint256 constant GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;
    bytes32 constant TAG = 0x7bb52d7a9fef58323eb1bf7a407db382d2f3f2d81bb1224f49fe518f6d48d37c;

    function pubkey(uint256 d) internal view returns (bytes32) {
        (uint256 x, ) = _mul(d, GX, GY);
        return bytes32(x);
    }

    function sign(uint256 d, bytes32 m) internal view returns (bytes memory) {
        (uint256 px, uint256 py) = _mul(d, GX, GY);
        if (py & 1 == 1) d = N - d;
        uint256 k = uint256(keccak256(abi.encode(d, m))) % N;
        if (k == 0) k = 1;
        (uint256 rx, uint256 ry) = _mul(k, GX, GY);
        if (ry & 1 == 1) k = N - k;
        uint256 e = uint256(sha256(abi.encodePacked(TAG, TAG, bytes32(rx), bytes32(px), m))) % N;
        return abi.encodePacked(bytes32(rx), bytes32(addmod(k, mulmod(e, d, N), N)));
    }

    function _inv(uint256 a) private view returns (uint256) {
        (bool ok, bytes memory out) = address(0x05).staticcall(abi.encodePacked(uint256(32), uint256(32), uint256(32), a, P - 2, P));
        require(ok, "modexp");
        return abi.decode(out, (uint256));
    }

    function _add(uint256 x1, uint256 y1, uint256 x2, uint256 y2) private view returns (uint256, uint256) {
        if (x1 == 0 && y1 == 0) return (x2, y2);
        if (x2 == 0 && y2 == 0) return (x1, y1);
        uint256 l;
        if (x1 == x2) {
            if (addmod(y1, y2, P) == 0) return (0, 0);
            l = mulmod(mulmod(3, mulmod(x1, x1, P), P), _inv(mulmod(2, y1, P)), P);
        } else {
            l = mulmod(addmod(y2, P - y1, P), _inv(addmod(x2, P - x1, P)), P);
        }
        uint256 x3 = addmod(mulmod(l, l, P), P - addmod(x1, x2, P), P);
        return (x3, addmod(mulmod(l, addmod(x1, P - x3, P), P), P - y1, P));
    }

    function _mul(uint256 k, uint256 x, uint256 y) private view returns (uint256 rx, uint256 ry) {
        while (k != 0) {
            if (k & 1 == 1) (rx, ry) = _add(rx, ry, x, y);
            (x, y) = _add(x, y, x, y);
            k >>= 1;
        }
    }
}
