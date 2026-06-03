// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

/// @notice Tiny Merkle-tree helper for tests. Matches OpenZeppelin's
///         {MerkleProof.verify} sibling-pair hashing (sorted pair).
library Merkle {
    /// @notice Build the 2-leaf root + each leaf's proof.
    function pair(bytes32 a, bytes32 b)
        internal pure
        returns (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB)
    {
        root = _hashPair(a, b);
        proofA = new bytes32[](1); proofA[0] = b;
        proofB = new bytes32[](1); proofB[0] = a;
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b
            ? keccak256(abi.encode(a, b))
            : keccak256(abi.encode(b, a));
    }
}
