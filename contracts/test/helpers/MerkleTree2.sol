// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title MerkleTree2
 * @notice Two-leaf merkle helper shared by the distributor tests.
 *
 * @dev Why only two leaves: a 2-leaf tree is the smallest structure that still
 *      exercises real proof verification (a proof of length one), and it is small
 *      enough to build inside a fuzz handler without shipping a tree library.
 *      Boundary behaviour (epoch caps, account caps, allocation exhaustion) is
 *      covered by targeted unit tests that need no larger tree.
 *
 *      The hashing MUST match OpenZeppelin v5.7.0 `MerkleProof`:
 *        - leaf  = keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))))
 *        - pair  = keccak256(abi.encodePacked(min(a,b), max(a,b)))   (sorted pairs)
 */
library MerkleTree2 {
    /// @notice Domain-separated leaf hash; double-hashed to prevent second preimages.
    function leaf(uint256 epochId, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))));
    }

    /// @notice OpenZeppelin-compatible sorted pair hash.
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @notice Root of a two-leaf tree.
    function root(bytes32 leafA, bytes32 leafB) internal pure returns (bytes32) {
        return hashPair(leafA, leafB);
    }

    /// @notice Proof for a leaf in a two-leaf tree: just its sibling.
    function proofFor(bytes32 sibling) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = sibling;
    }
}
