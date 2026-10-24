// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RewardDistributor} from "../../src/RewardDistributor.sol";
import {MerkleTree2} from "../helpers/MerkleTree2.sol";

/**
 * @notice Stateful fuzz handler for the RewardDistributor invariant suite.
 *
 * @dev Every action is written to be revert-free when `fail_on_revert = true`:
 *      anything the contract would reject is skipped, not attempted. The counters
 *      let the invariant test prove the handler actually did something (the Phase 1
 *      vacuity lesson: an invariant that holds because nothing happened is worse
 *      than no invariant).
 *
 *      Time only moves forward via `advance`, and a seal can only ever target the
 *      immediately previous epoch, so the handler cannot fabricate a future epoch.
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

    /// @notice Move time forward so new epochs become sealable.
    function advance(uint256 epochs) external {
        epochs = bound(epochs, 1, 3);
        vm.warp(block.timestamp + epochs * dist.EPOCH_DURATION());
    }

    /// @notice Seal the previous epoch with a fresh two-leaf allocation.
    function seal(uint256 amountA_, uint256 amountB_) external {
        if (sealedEpochs.length >= 8) return; // bound state growth so runs stay fast

        uint256 nowEpoch = dist.currentEpoch();
        if (nowEpoch == 0) return;

        uint256 epochId = nowEpoch - 1;
        if (dist.isSealed(epochId)) return;

        uint256 accountCap = dist.maxPerAccountPerEpoch();
        amountA_ = bound(amountA_, 0, accountCap);
        amountB_ = bound(amountB_, 0, accountCap);

        uint256 total = amountA_ + amountB_;
        if (total == 0) return;
        if (total > dist.maxPerEpoch()) return;
        if (dist.totalReleased() + total > dist.allocation()) return;

        bytes32 leafA = MerkleTree2.leaf(epochId, actorA, amountA_);
        bytes32 leafB = MerkleTree2.leaf(epochId, actorB, amountB_);

        dist.sealEpoch(epochId, MerkleTree2.root(leafA, leafB), total);

        allocA[epochId] = amountA_;
        allocB[epochId] = amountB_;
        sealedEpochs.push(epochId);
        ++sealCount;
    }

    function claimA(uint256 index) external {
        _claim(index, true);
    }

    function claimB(uint256 index) external {
        _claim(index, false);
    }

    function _claim(uint256 index, bool asA) internal {
        if (index >= sealedEpochs.length) return;

        uint256 epochId = sealedEpochs[index];
        address account = asA ? actorA : actorB;
        if (dist.hasClaimed(epochId, account)) return;

        uint256 amount = asA ? allocA[epochId] : allocB[epochId];
        if (amount == 0) return;

        // Only claim what still fits, so the handler never reverts.
        if (dist.epochPaid(epochId) + amount > dist.maxPerEpoch()) return;
        if (dist.totalReleased() + amount > dist.allocation()) return;

        bytes32 sibling = asA
            ? MerkleTree2.leaf(epochId, actorB, allocB[epochId])
            : MerkleTree2.leaf(epochId, actorA, allocA[epochId]);

        vm.prank(account);
        dist.claim(epochId, amount, MerkleTree2.proofFor(sibling));
        ++claimCount;
    }
}
