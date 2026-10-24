// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ItemRegistry} from "../src/ItemRegistry.sol";
import {ItemRegistryHandler} from "./handlers/ItemRegistryHandler.sol";

/**
 * @notice Invariants for the item catalogue.
 *
 *   I1  minted[id] <= supplyCap[id]                     (lifetime cap respected)
 *   I2  totalSupply[id] <= minted[id]                    (no conjured tokens)
 *   I3  totalSupply[id] == minted[id] - burned[id]        (conservation: every token is
 *                                                        accounted for by a mint or a burn)
 *   I4  a registered id always has a non-zero contentHash
 *
 * I3 is the strong one: transfers move balances but cannot change totalSupply, so any
 * accounting drift in mint/burn — double counting, a lost burn, a mint that skips the
 * counter — breaks it immediately.
 */
contract ItemRegistryInvariantTest is Test {
    ItemRegistry internal registry;
    ItemRegistryHandler internal handler;

    address internal actorA;
    address internal actorB;

    uint256 internal constant ITEM_A = 1;
    uint256 internal constant ITEM_B = 2;
    uint64 internal constant CAP = 1_000_000;

    function setUp() public {
        actorA = makeAddr("actorA");
        actorB = makeAddr("actorB");

        registry = new ItemRegistry(address(this), address(this), address(this), "");

        registry.registerItemType(ITEM_A, keccak256("item-a-manifest"), CAP, "ipfs://item-a");
        registry.registerItemType(ITEM_B, keccak256("item-b-manifest"), CAP, "ipfs://item-b");

        handler = new ItemRegistryHandler(registry, actorA, actorB, ITEM_A, ITEM_B);
        // The handler is the only minter/burner here; it still cannot exceed the caps.
        registry.grantRole(registry.MODULE_ROLE(), address(handler));

        // Explicit target set: without targetContract the registry itself would be
        // fuzzed, and a random transferFrom would revert the run (the run-6 lesson).
        targetContract(address(handler));
        excludeContract(address(registry));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = ItemRegistryHandler.mintItem.selector;
        selectors[1] = ItemRegistryHandler.burnItem.selector;
        selectors[2] = ItemRegistryHandler.transferItem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_SupplyCapNeverExceeded() public view {
        assertLe(registry.mintedOf(ITEM_A), registry.supplyCapOf(ITEM_A));
        assertLe(registry.mintedOf(ITEM_B), registry.supplyCapOf(ITEM_B));
    }

    function invariant_OutstandingNeverExceedsMinted() public view {
        assertLe(registry.totalSupply(ITEM_A), registry.mintedOf(ITEM_A));
        assertLe(registry.totalSupply(ITEM_B), registry.mintedOf(ITEM_B));
    }

    function invariant_TotalSupplyEqualsMintedMinusBurned() public view {
        assertEq(
            registry.totalSupply(ITEM_A),
            registry.mintedOf(ITEM_A) - handler.burned(ITEM_A),
            "item A conservation"
        );
        assertEq(
            registry.totalSupply(ITEM_B),
            registry.mintedOf(ITEM_B) - handler.burned(ITEM_B),
            "item B conservation"
        );
    }

    function invariant_RegisteredItemsKeepContentHash() public view {
        assertTrue(registry.contentHashOf(ITEM_A) != bytes32(0), "item A hash");
        assertTrue(registry.contentHashOf(ITEM_B) != bytes32(0), "item B hash");
    }

    /// @dev Vacuity guard. `_warmUp` performs a mint, a burn and a transfer on every
    ///      targeted call, so all three counters are non-zero after any single call.
    function afterInvariant() public view {
        assertGt(handler.mintCount(), 0, "never minted");
        assertGt(handler.burnCount(), 0, "never burned");
        assertGt(handler.transferCount(), 0, "never transferred");
    }
}
