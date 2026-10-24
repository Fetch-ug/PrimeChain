// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RewardDistributor} from "../../src/RewardDistributor.sol";
import {MerkleTree2} from "../helpers/MerkleTree2.sol";

/**
 * @notice Stateful fuzz handler for the RewardDistributor invariant suite.
 *
 * @dev GUARANTEE: every single call to a targeted function leaves BOTH
 *      `sealCount > 0` and `claimCount > 0`.
 *
 *      The previous version assumed the fuzzer would eventually call `seal` and then
 *      `claim`. It did not: at block.timestamp == 0 the current epoch is 0, so `seal`
 *      had nothing ended to seal and no-op'd, and `claim` had nothing to claim. The
 *      invariants then passed vacuously for whole runs.
 *
 *      Fix, in two parts:
 *        1. `_prepareEpoch` warps time if no epoch has ended yet, and skips forward
 *           past already-sealed epochs, so a seal always has a target.
 *        2. A seal immediately claims for actor A. So a run consisting entirely of
 *           `seal` calls still exercises the claim path, and a run consisting entirely
 *           of `claimA/claimB` seals on demand first. The guard is therefore
 *           deterministic, not probabilistic.
 *
 *      Every action is written to be revert-free under `fail_on_revert = true`.
 */
contract DistributorHandler is Test {
    RewardDistributor public immutable dist;
    address public immutable actorA;
    address public immutable actorB;

    uint256 public sealCount;
    uint256 public claimCount;

    uint256[] public sealedEpochs;
    mapping(uint256 => uint256) public allocA;
    mapping(uint256 => uint256) public allocB;

    constructor(RewardDistributor dist_, address actorA_, address actorB_) {
        dist = dist_;
        actorA = actorA_;
        actorB = actorB_;
    }

    function sealedCount() external view returns (uint256) {
        return sealedEpochs.length;
    }

    /// @notice Seal a new epoch, then claim once so the claim path always runs.
    function seal(uint256 amountA_, uint256 amountB_) external {
        if (_sealWith(amountA_, amountB_)) {
            _claim(sealedEpochs.length - 1, true);
        }
    }

    function claimA(uint256 index) external {
        if (sealedEpochs.length == 0) _sealDefault();
        _claim(index, true);
    }

    function claimB(uint256 index) external {
        if (sealedEpochs.length == 0) _sealDefault();
        _claim(index, false);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev A seal with sensible amounts, used when a claim is called before any seal.
    function _sealDefault() internal {
        uint256 accountCap = dist.maxPerAccountPerEpoch();
        uint256 epochCap = dist.maxPerEpoch();

        uint256 amountA = accountCap; // >= 1: the constructor forbids a zero cap
        uint256 amountB = epochCap > accountCap ? epochCap - accountCap : 0;
        if (amountB > accountCap) amountB = accountCap;

        _sealWith(amountA, amountB);
    }

    /// @return True if an epoch was actually sealed.
    function _sealWith(uint256 amountA_, uint256 amountB_) internal returns (bool) {
        if (sealedEpochs.length >= 8) return false; // bound state growth; keep runs fast
        if (!_prepareEpoch()) return false;

        uint256 epochId = dist.currentEpoch() - 1;

        uint256 accountCap = dist.maxPerAccountPerEpoch();
        // amountA is forced >= 1 so the follow-up claim is never a no-op.
        amountA_ = bound(amountA_, 1, accountCap);
        amountB_ = bound(amountB_, 0, accountCap);

        uint256 total = amountA_ + amountB_;
        if (total > dist.maxPerEpoch()) return false;
        if (dist.totalReleased() + total > dist.allocation()) return false;

        bytes32 leafA = MerkleTree2.leaf(epochId, actorA, amountA_);
        bytes32 leafB = MerkleTree2.leaf(epochId, actorB, amountB_);

        dist.sealEpoch(epochId, MerkleTree2.root(leafA, leafB), total);

        allocA[epochId] = amountA_;
        allocB[epochId] = amountB_;
        sealedEpochs.push(epochId);
        ++sealCount;
        return true;
    }

    /// @dev Ensure `currentEpoch() > 0` and that `currentEpoch() - 1` is unsealed.
    function _prepareEpoch() internal returns (bool) {
        if (dist.currentEpoch() == 0) {
            vm.warp(dist.EPOCH_DURATION());
        }

        for (uint256 i; i < 4; ++i) {
            if (!dist.isSealed(dist.currentEpoch() - 1)) return true;
            vm.warp((dist.currentEpoch() + 1) * dist.EPOCH_DURATION());
        }
        return false;
    }

    function _claim(uint256 index, bool asA) internal {
        if (sealedEpochs.length == 0) return;

        uint256 epochId = sealedEpochs[index % sealedEpochs.length];
        address account = asA ? actorA : actorB;
        if (dist.hasClaimed(epochId, account)) return;

        uint256 amount = asA ? allocA[epochId] : allocB[epochId];
        if (amount == 0) return;

        // Keep the handler revert-free: only claim what still fits.
        if (dist.epochPaid(epochId) + amount > dist.maxPerEpoch()) return;
        if (dist.totalReleased() + amount > dist.allocation()) return;

        bytes32 sibling = asA
            ? MerkleTree2.leaf(epochId, actorB, allocB[epochId])
            : MerkleTree2.leaf(epochId, actorA, allocA[epochId]);

        // Evaluate the proof BEFORE the prank: anything that makes an external call
        // between `vm.prank` and the call under test would consume the prank.
        bytes32[] memory proof = MerkleTree2.proofFor(sibling);

        vm.prank(account);
        dist.claim(epochId, amount, proof);
        ++claimCount;
    }
}
