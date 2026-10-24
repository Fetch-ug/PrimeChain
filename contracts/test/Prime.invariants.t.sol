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
 *   INV-2  the sum of every balance equals totalSupply (no tokens appear or vanish).
 *   INV-3  no single balance can exceed totalSupply.
 *
 * INV-1 plus the absence of a mint selector (unit test) is the complete
 * "no inflation" argument.
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

    function setUp() public {
        treasury = makeAddr("treasury");

        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }

        prime = new Prime(treasury);
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

    function invariant_BalancesSumToTotalSupply() public view {
        uint256 sum = prime.balanceOf(treasury);
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

    /// @dev Sanity: the handler must actually be moving tokens, otherwise the
    /// invariants above hold vacuously and the suite is a false comfort.
    function afterInvariant() public view {
        assertGt(handler.transferCalls(), 0, "handler never executed a transfer");
    }
}
