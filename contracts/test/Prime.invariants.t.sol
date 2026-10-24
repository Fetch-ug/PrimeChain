// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Prime} from "../src/Prime.sol";
import {PrimeHandler} from "./handlers/PrimeHandler.sol";

/**
 * @notice Invariant suite for Prime.
 *
 * These are the properties the economy depends on and the ones an auditor will
 * try to break first:
 *
 *   INV-1  totalSupply() == 2_000_000_000e18, always, after any sequence of actions.
 *   INV-2  the sum of every balance (treasury + all actors) equals totalSupply.
 *   INV-3  no single balance can exceed totalSupply.
 *
 * INV-1 plus the absence of a mint selector (unit test) is the complete
 * "no inflation" argument.
 *
 * @dev FIXTURE REQUIREMENT — read before changing setUp.
 * The first version of this suite funded nobody: every actor started at zero,
 * so the handler's `balance == 0` guard made every action a no-op. The invariants
 * still passed, vacuously. `afterInvariant()` now asserts that both handler paths
 * actually executed, so an unfunded fixture fails instead of flattering us.
 */
contract PrimeInvariantTest is Test {
    Prime internal prime;
    PrimeHandler internal handler;
    address internal treasury;
    address[] internal actors;

    /// @dev Local mirror of the genesis supply. `Prime.TOTAL_SUPPLY` is a
    ///      `public constant` and is not reachable through the contract type;
    ///      using a literal here also keeps the invariant independent of the
    ///      contract it is testing (a contract cannot confirm its own constant).
    uint256 internal constant TOTAL = 2_000_000_000e18;

    /// @dev Per-actor starting balance. 4 actors x 1,000,000 leaves the treasury
    ///      with 1,996,000,000 — plenty of room to move without starving either side.
    uint256 internal constant FUNDING = 1_000_000e18;

    uint256 internal constant ACTOR_COUNT = 4;

    function setUp() public {
        treasury = makeAddr("treasury");

        for (uint256 i; i < ACTOR_COUNT; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }

        prime = new Prime(treasury);

        // --- fund the actors -------------------------------------------------
        // Without this every handler call early-returns on a zero balance and
        // the whole suite is vacuous (caught by CI run #2, transferCalls == 0
        // after 262,144 calls).
        vm.startPrank(treasury);
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            prime.transfer(actors[i], FUNDING);
        }
        vm.stopPrank();

        // --- standing mutual approvals ---------------------------------------
        // Lets the transferFrom path execute even if a future handler action
        // forgets to approve. The handler still writes an exact allowance before
        // each pull, so the allowance *decrement* path is what gets fuzzed; the
        // infinite-allowance path is covered by a unit test instead.
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            for (uint256 j; j < ACTOR_COUNT; ++j) {
                if (i == j) continue;
                vm.prank(actors[i]);
                prime.approve(actors[j], type(uint256).max);
            }
        }

        handler = new PrimeHandler(prime, treasury, actors);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = PrimeHandler.transfer.selector;
        selectors[1] = PrimeHandler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_TotalSupplyIsConstant() public view {
        assertEq(prime.totalSupply(), TOTAL);
    }

    /// @dev Sum over the treasury *and* every actor. The handler only ever moves
    ///      tokens between these addresses, so any discrepancy means tokens were
    ///      created or destroyed. If a future handler action can send to an
    ///      untracked address, that address must be added here or the invariant
    ///      becomes meaningless.
    function invariant_BalancesSumToTotalSupply() public view {
        uint256 sum = prime.balanceOf(treasury); // treasury included explicitly
        uint256 count = handler.actorsLength();

        for (uint256 i; i < count; ++i) {
            sum += prime.balanceOf(handler.actorAt(i));
        }

        assertEq(sum, prime.totalSupply());
    }

    function invariant_NoBalanceExceedsTotalSupply() public view {
        assertLe(prime.balanceOf(treasury), TOTAL);
        assertLe(prime.balanceOf(address(prime)), TOTAL);

        uint256 count = handler.actorsLength();
        for (uint256 i; i < count; ++i) {
            assertLe(prime.balanceOf(handler.actorAt(i)), TOTAL);
        }
    }

    /// @dev Vacuity guard. An invariant that holds because nothing happened is
    ///      worse than no invariant: it gives false confidence in an audit.
    function afterInvariant() public view {
        assertGt(handler.transferCalls(), 0, "handler never executed a transfer");
        assertGt(handler.transferFromCalls(), 0, "handler never executed a transferFrom");
    }
}
