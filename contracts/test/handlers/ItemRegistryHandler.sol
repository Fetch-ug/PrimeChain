// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ItemRegistry} from "../../src/ItemRegistry.sol";

/**
 * @notice Stateful fuzz handler for the ItemRegistry invariant suite.
 *
 * @dev GUARANTEE: every call to a targeted function performs a mint, a burn AND a
 *      transfer (`_warmUp`), then the primary operation with the fuzzed amount.
 *      That makes the per-run vacuity guard deterministic: any single call advances
 *      all three counters. Ordering is fixed, but the *fuzzed quantity* lands on a
 *      different operation each time, so each path is explored independently.
 *
 *      Warm-up arithmetic: mint 2 -> transfer 1 to B -> burn 1 from A leaves A with 0
 *      and B with 1, and keeps totalSupply == minted - burned.
 */
contract ItemRegistryHandler is Test {
    ItemRegistry public immutable registry;
    address public immutable actorA;
    address public immutable actorB;
    uint256 public immutable itemA;
    uint256 public immutable itemB;

    uint256 public mintCount;
    uint256 public burnCount;
    uint256 public transferCount;

    /// @notice Cumulative burned per id, used by the conservation invariant.
    mapping(uint256 => uint256) public burned;

    constructor(ItemRegistry registry_, address actorA_, address actorB_, uint256 itemA_, uint256 itemB_) {
        registry = registry_;
        actorA = actorA_;
        actorB = actorB_;
        itemA = itemA_;
        itemB = itemB_;
    }

    /// @notice Mint a fuzzed amount to actor A after the warm-up.
    function mintItem(uint256 idSeed, uint256 amount) external {
        if (!_warmUp()) return;

        uint256 id = _id(idSeed);
        amount = bound(amount, 1, 1_000);

        uint256 room = registry.remainingSupply(id);
        if (room == 0) return;
        if (amount > room) amount = room;

        registry.mint(actorA, id, amount, "");
        ++mintCount;
    }

    /// @notice Burn a fuzzed amount from actor A after the warm-up.
    function burnItem(uint256 idSeed, uint256 amount) external {
        if (!_warmUp()) return;

        uint256 id = _id(idSeed);
        uint256 balance = registry.balanceOf(actorA, id);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);
        registry.burn(actorA, id, amount);
        burned[id] += amount;
        ++burnCount;
    }

    /// @notice Transfer a fuzzed amount from actor A to actor B after the warm-up.
    function transferItem(uint256 idSeed, uint256 amount) external {
        if (!_warmUp()) return;

        uint256 id = _id(idSeed);
        uint256 balance = registry.balanceOf(actorA, id);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);
        vm.prank(actorA);
        registry.safeTransferFrom(actorA, actorB, id, amount, "");
        ++transferCount;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev One mint, one transfer and one burn, so every targeted call exercises all
    ///      three code paths. Returns false only if the item is out of supply.
    function _warmUp() internal returns (bool) {
        if (registry.remainingSupply(itemA) < 2) return false;

        registry.mint(actorA, itemA, 2, "");
        ++mintCount;

        // Build nothing between the prank and the call under test.
        vm.prank(actorA);
        registry.safeTransferFrom(actorA, actorB, itemA, 1, "");
        ++transferCount;

        registry.burn(actorA, itemA, 1);
        burned[itemA] += 1;
        ++burnCount;

        return true;
    }

    function _id(uint256 seed) internal view returns (uint256) {
        return seed % 2 == 0 ? itemA : itemB;
    }
}
