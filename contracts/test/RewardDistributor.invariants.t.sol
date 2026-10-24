// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Prime} from "../src/Prime.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {DistributorHandler} from "./handlers/DistributorHandler.sol";

/**
 * @notice Invariants for the emission schedule.
 *
 *   I1  totalReleased <= allocation
 *   I2  prime.balanceOf(distributor) >= allocation - totalReleased   (structural reserve)
 *   I3  epochPaid[e] <= maxPerEpoch, for every sealed epoch e        (per-epoch cap,
 *                                                                    and therefore no rollover)
 *   I4  totalReleased == sum of epochPaid over sealed epochs         (no hidden carry)
 *
 * I2 is the property that makes "the reserve is unreachable" checkable rather than
 * rhetorical. I4 is what rules out capacity rolling over: if unused capacity were
 * banked anywhere, the sum of per-epoch payouts would stop matching the lifetime total.
 */
contract RewardDistributorInvariantTest is Test {
    Prime internal prime;
    RewardDistributor internal dist;
    DistributorHandler internal handler;

    address internal actorA;
    address internal actorB;

    // Deliberately small so the suite can actually reach exhaustion and the caps.
    uint256 internal constant ALLOCATION = 2_000e18;
    uint256 internal constant EPOCH_CAP = 600e18;
    uint256 internal constant ACCOUNT_CAP = 200e18;

    function setUp() public {
        actorA = makeAddr("actorA");
        actorB = makeAddr("actorB");

        prime = new Prime(address(this));

        dist = new RewardDistributor(
            IERC20(address(prime)),
            ALLOCATION,
            address(this),
            address(this),
            address(this),
            address(this),
            EPOCH_CAP,
            ACCOUNT_CAP
        );
        prime.transfer(address(dist), ALLOCATION);

        handler = new DistributorHandler(dist, actorA, actorB);
        // The handler is the sealer for this suite; it still cannot exceed the caps.
        dist.grantRole(dist.SEALER_ROLE(), address(handler));

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = DistributorHandler.seal.selector;
        selectors[1] = DistributorHandler.claimA.selector;
        selectors[2] = DistributorHandler.claimB.selector;
        selectors[3] = DistributorHandler.advance.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_TotalReleasedWithinAllocation() public view {
        assertLe(dist.totalReleased(), dist.allocation());
    }

    function invariant_BalanceCoversOutstandingAllocation() public view {
        assertGe(prime.balanceOf(address(dist)), dist.allocation() - dist.totalReleased());
    }

    function invariant_EpochPaidWithinCap() public view {
        uint256 count = handler.sealedCount();
        for (uint256 i; i < count; ++i) {
            uint256 epochId = handler.sealedEpochs(i);
            assertLe(dist.epochPaid(epochId), dist.maxPerEpoch());
        }
    }

    function invariant_TotalReleasedEqualsSumOfEpochPaid() public view {
        uint256 sum;
        uint256 count = handler.sealedCount();
        for (uint256 i; i < count; ++i) {
            sum += dist.epochPaid(handler.sealedEpochs(i));
        }
        assertEq(dist.totalReleased(), sum, "totalReleased must equal sum of per-epoch payouts");
    }

    /// @dev Vacuity guard: without this, a handler that silently no-ops would make
    ///      every invariant above trivially true.
    function afterInvariant() public view {
        assertGt(handler.sealCount(), 0, "handler never sealed an epoch");
        assertGt(handler.claimCount(), 0, "handler never claimed");
    }
}
