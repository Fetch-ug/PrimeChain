// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Prime} from "../src/Prime.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {MerkleTree2} from "./helpers/MerkleTree2.sol";

contract RewardDistributorTest is Test {
    // Local mirrors of the distributor's events. Declared here rather than emitted
    // as `RewardDistributor.Event(...)` so the test does not depend on cross-contract
    // `emit` resolution; signatures (and indexed flags) must stay in sync.
    event EpochSealed(uint256 indexed epochId, bytes32 root, uint256 declaredTotal);
    event Claimed(uint256 indexed epochId, address indexed account, uint256 amount);
    event MaxPerEpochChanged(uint256 oldValue, uint256 newValue);
    event MaxPerAccountPerEpochChanged(uint256 oldValue, uint256 newValue);

    Prime internal prime;
    RewardDistributor internal dist;

    address internal alice;
    address internal bob;

    uint256 internal constant ALLOCATION = 10_000e18;
    uint256 internal constant MAX_PER_EPOCH = 1_000e18;
    uint256 internal constant MAX_PER_ACCOUNT = 200e18;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        prime = new Prime(address(this));
        dist = _deploy(ALLOCATION, MAX_PER_EPOCH, MAX_PER_ACCOUNT);
        prime.transfer(address(dist), ALLOCATION);

        // Move past genesis so a previous epoch always exists.
        vm.warp(10 days);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _deploy(uint256 allocation_, uint256 maxPerEpoch_, uint256 maxPerAccount_)
        internal
        returns (RewardDistributor)
    {
        return new RewardDistributor(
            IERC20(address(prime)),
            allocation_,
            address(this),
            address(this),
            address(this),
            address(this),
            maxPerEpoch_,
            maxPerAccount_
        );
    }

    function _leaf(uint256 epochId, address account, uint256 amount) internal pure returns (bytes32) {
        return MerkleTree2.leaf(epochId, account, amount);
    }

    function _seal(
        uint256 epochId,
        address accountA,
        uint256 amountA,
        address accountB,
        uint256 amountB,
        uint256 declaredTotal
    ) internal returns (bytes32 root) {
        root = MerkleTree2.root(_leaf(epochId, accountA, amountA), _leaf(epochId, accountB, amountB));
        dist.sealEpoch(epochId, root, declaredTotal);
    }

    function _proof(uint256 epochId, address sibling, uint256 siblingAmount)
        internal
        pure
        returns (bytes32[] memory)
    {
        return MerkleTree2.proofFor(_leaf(epochId, sibling, siblingAmount));
    }

    function _claim(address account, uint256 epochId, uint256 amount, address sibling, uint256 siblingAmount)
        internal
    {
        vm.prank(account);
        dist.claim(epochId, amount, _proof(epochId, sibling, siblingAmount));
    }

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    function test_ConstructorConfig() public view {
        assertEq(dist.allocation(), ALLOCATION);
        assertEq(dist.maxPerEpoch(), MAX_PER_EPOCH);
        assertEq(dist.maxPerAccountPerEpoch(), MAX_PER_ACCOUNT);
        assertEq(dist.EMISSIONS_CEILING(), 1_000_000_000e18);
        assertEq(dist.MAX_EPOCH_CAP(), 2_000_000e18);
        assertEq(dist.EPOCH_DURATION(), 1 days);
        assertEq(address(dist.prime()), address(prime));

        assertTrue(dist.hasRole(dist.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(dist.hasRole(dist.SEALER_ROLE(), address(this)));
        assertTrue(dist.hasRole(dist.CONFIG_ROLE(), address(this)));
        assertTrue(dist.hasRole(dist.PAUSER_ROLE(), address(this)));

        assertEq(prime.balanceOf(address(dist)), ALLOCATION);
    }

    function test_ConstructorRejectsZeroPrime() public {
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        new RewardDistributor(
            IERC20(address(0)), ALLOCATION, address(this), address(this), address(this), address(this), 1, 1
        );
    }

    function test_ConstructorRejectsZeroAdmin() public {
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        new RewardDistributor(
            IERC20(address(prime)), ALLOCATION, address(0), address(this), address(this), address(this), 1, 1
        );
    }

    function test_ConstructorRejectsZeroAllocation() public {
        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.InvalidAllocation.selector, uint256(0), 1_000_000_000e18)
        );
        _deploy(0, MAX_PER_EPOCH, MAX_PER_ACCOUNT);
    }

    function test_ConstructorRejectsAllocationAboveCeiling() public {
        uint256 tooMuch = 1_000_000_000e18 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.InvalidAllocation.selector, tooMuch, 1_000_000_000e18)
        );
        _deploy(tooMuch, MAX_PER_EPOCH, MAX_PER_ACCOUNT);
    }

    function test_ConstructorRejectsZeroEpochCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.InvalidEpochCap.selector, uint256(0), 2_000_000e18)
        );
        _deploy(ALLOCATION, 0, MAX_PER_ACCOUNT);
    }

    function test_ConstructorRejectsEpochCapAboveMax() public {
        uint256 tooMuch = 2_000_000e18 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.InvalidEpochCap.selector, tooMuch, 2_000_000e18)
        );
        _deploy(ALLOCATION, tooMuch, MAX_PER_ACCOUNT);
    }

    function test_ConstructorRejectsZeroAccountCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.InvalidAccountCap.selector, uint256(0), MAX_PER_EPOCH)
        );
        _deploy(ALLOCATION, MAX_PER_EPOCH, 0);
    }

    function test_ConstructorRejectsAccountCapAboveEpochCap() public {
        uint256 tooMuch = MAX_PER_EPOCH + 1;
        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.InvalidAccountCap.selector, tooMuch, MAX_PER_EPOCH)
        );
        _deploy(ALLOCATION, MAX_PER_EPOCH, tooMuch);
    }

    function test_DeployerLosesAdminWhenAdminDiffers() public {
        address other = makeAddr("other");
        RewardDistributor d = new RewardDistributor(
            IERC20(address(prime)), ALLOCATION, other, other, other, other, MAX_PER_EPOCH, MAX_PER_ACCOUNT
        );

        assertTrue(d.hasRole(d.DEFAULT_ADMIN_ROLE(), other));
        assertFalse(d.hasRole(d.DEFAULT_ADMIN_ROLE(), address(this)), "deployer must not stay admin");
    }

    // ---------------------------------------------------------------------
    // Time
    // ---------------------------------------------------------------------

    function test_CurrentEpochFollowsTime() public {
        assertEq(dist.currentEpoch(), 10);
        vm.warp(10 days + 3 hours);
        assertEq(dist.currentEpoch(), 10);
        vm.warp(11 days);
        assertEq(dist.currentEpoch(), 11);
    }

    // ---------------------------------------------------------------------
    // Sealing
    // ---------------------------------------------------------------------

    function test_SealStoresRootAndDeclaredTotal() public {
        uint256 epochId = dist.currentEpoch() - 1;

        vm.expectEmit(true, false, false, true);
        bytes32 expectedRoot = MerkleTree2.root(_leaf(epochId, alice, 100e18), _leaf(epochId, bob, 50e18));
        emit EpochSealed(epochId, expectedRoot, 150e18);

        _seal(epochId, alice, 100e18, bob, 50e18, 150e18);

        assertTrue(dist.isSealed(epochId));
        assertEq(dist.epochRoot(epochId), expectedRoot);
        assertEq(dist.epochDeclaredTotal(epochId), 150e18);
    }

    function test_SealRevertsBeforeEpochEnds() public {
        uint256 epochId = dist.currentEpoch();
        vm.expectRevert(abi.encodeWithSelector(RewardDistributor.EpochNotEnded.selector, epochId));
        dist.sealEpoch(epochId, bytes32(uint256(1)), 1);
    }

    function test_SealRevertsWhenAlreadySealed() public {
        uint256 epochId = dist.currentEpoch() - 1;
        _seal(epochId, alice, 1e18, bob, 1e18, 2e18);

        vm.expectRevert(abi.encodeWithSelector(RewardDistributor.EpochAlreadySealed.selector, epochId));
        dist.sealEpoch(epochId, bytes32(uint256(2)), 1);
    }

    function test_SealRevertsOnZeroRoot() public {
        vm.expectRevert(RewardDistributor.InvalidRoot.selector);
        dist.sealEpoch(9, bytes32(0), 1);
    }

    function test_SealRevertsOnZeroTotal() public {
        vm.expectRevert(RewardDistributor.ZeroAmount.selector);
        dist.sealEpoch(9, bytes32(uint256(1)), 0);
    }

    function test_SealRevertsAbovePerEpochCap() public {
        uint256 tooMuch = MAX_PER_EPOCH + 1;
        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.InvalidEpochCap.selector, tooMuch, MAX_PER_EPOCH)
        );
        dist.sealEpoch(9, bytes32(uint256(1)), tooMuch);
    }

    function test_SealRevertsWhenAllocationExhausted() public {
        RewardDistributor small = _deploy(100e18, 1_000e18, 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.AllocationExhausted.selector, uint256(101e18), 100e18)
        );
        small.sealEpoch(9, bytes32(uint256(1)), 101e18);
    }

    function test_SealOnlySealer() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, dist.SEALER_ROLE()
            )
        );
        dist.sealEpoch(9, bytes32(uint256(1)), 1);
    }

    // ---------------------------------------------------------------------
    // Claiming
    // ---------------------------------------------------------------------

    function test_ClaimPays() public {
        uint256 epochId = dist.currentEpoch() - 1;
        _seal(epochId, alice, MAX_PER_ACCOUNT, bob, MAX_PER_ACCOUNT, 2 * MAX_PER_ACCOUNT);

        vm.expectEmit(true, true, false, true);
        emit Claimed(epochId, alice, MAX_PER_ACCOUNT);

        _claim(alice, epochId, MAX_PER_ACCOUNT, bob, MAX_PER_ACCOUNT);

        assertEq(prime.balanceOf(alice), MAX_PER_ACCOUNT);
        assertEq(dist.totalReleased(), MAX_PER_ACCOUNT);
        assertEq(dist.epochPaid(epochId), MAX_PER_ACCOUNT);
        assertTrue(dist.hasClaimed(epochId, alice));
        assertEq(dist.remainingAllocation(), ALLOCATION - MAX_PER_ACCOUNT);
    }

    function test_ClaimRevertsOnZeroAmount() public {
        uint256 epochId = dist.currentEpoch() - 1;
        _seal(epochId, alice, MAX_PER_ACCOUNT, bob, MAX_PER_ACCOUNT, 2 * MAX_PER_ACCOUNT);

        vm.expectRevert(RewardDistributor.ZeroAmount.selector);
        vm.prank(alice);
        dist.claim(epochId, 0, _proof(epochId, bob, MAX_PER_ACCOUNT));
    }

    function test_ClaimRevertsWhenNotSealed() public {
        vm.expectRevert(abi.encodeWithSelector(RewardDistributor.EpochNotSealed.selector, uint256(9)));
        vm.prank(alice);
        dist.claim(9, 1e18, _proof(9, bob, 1e18));
    }

    function test_ClaimRevertsOnSecondClaim() public {
        uint256 epochId = dist.currentEpoch() - 1;
        _seal(epochId, alice, MAX_PER_ACCOUNT, bob, MAX_PER_ACCOUNT, 2 * MAX_PER_ACCOUNT);
        _claim(alice, epochId, MAX_PER_ACCOUNT, bob, MAX_PER_ACCOUNT);

        vm.expectRevert(RewardDistributor.AlreadyClaimed.selector);
        vm.prank(alice);
        dist.claim(epochId, MAX_PER_ACCOUNT, _proof(epochId, bob, MAX_PER_ACCOUNT));
    }

    function test_ClaimRevertsAboveAccountCap() public {
        uint256 epochId = dist.currentEpoch() - 1;
        uint256 overCap = MAX_PER_ACCOUNT + 1;
        _seal(epochId, alice, overCap, bob, 0, overCap);

        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.AccountCapExceeded.selector, overCap, MAX_PER_ACCOUNT)
        );
        vm.prank(alice);
        dist.claim(epochId, overCap, _proof(epochId, bob, 0));
    }

    function test_ClaimRevertsAboveEpochCap() public {
        dist.setMaxPerEpoch(300e18); // caller holds CONFIG_ROLE

        uint256 epochId = dist.currentEpoch() - 1;
        // Sealer under-declares (300) while the tree authorises 400 total: the
        // epochPaid backstop must still stop the second claim.
        _seal(epochId, alice, MAX_PER_ACCOUNT, bob, MAX_PER_ACCOUNT, 300e18);

        _claim(alice, epochId, MAX_PER_ACCOUNT, bob, MAX_PER_ACCOUNT);
        assertEq(dist.epochPaid(epochId), MAX_PER_ACCOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                RewardDistributor.EpochCapExceeded.selector, MAX_PER_ACCOUNT, 300e18 - MAX_PER_ACCOUNT
            )
        );
        vm.prank(bob);
        dist.claim(epochId, MAX_PER_ACCOUNT, _proof(epochId, alice, MAX_PER_ACCOUNT));
    }

    function test_ClaimRevertsWhenPaused() public {
        uint256 epochId = dist.currentEpoch() - 1;
        _seal(epochId, alice, MAX_PER_ACCOUNT, bob, MAX_PER_ACCOUNT, 2 * MAX_PER_ACCOUNT);
        dist.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        dist.claim(epochId, MAX_PER_ACCOUNT, _proof(epochId, bob, MAX_PER_ACCOUNT));
    }

    function test_ClaimRevertsOnInvalidProof() public {
        uint256 epochId = dist.currentEpoch() - 1;
        _seal(epochId, alice, MAX_PER_ACCOUNT, bob, MAX_PER_ACCOUNT, 2 * MAX_PER_ACCOUNT);

        // Proof built from a different sibling amount than the one committed.
        vm.expectRevert(RewardDistributor.InvalidProof.selector);
        vm.prank(alice);
        dist.claim(epochId, MAX_PER_ACCOUNT, _proof(epochId, bob, MAX_PER_ACCOUNT - 1));
    }

    function test_ClaimRevertsWhenAllocationExhausted() public {
        // Small allocation, per-epoch cap high enough that the epoch cap does not
        // fire first — this isolates the allocation-exhaustion backstop.
        RewardDistributor small = _deploy(100e18, 200e18, 60e18);
        prime.transfer(address(small), 100e18);

        uint256 epochId = small.currentEpoch() - 1;
        small.sealEpoch(
            epochId,
            MerkleTree2.root(_leaf(epochId, alice, 60e18), _leaf(epochId, bob, 60e18)),
            1e18 // under-declared on purpose
        );

        vm.prank(alice);
        small.claim(epochId, 60e18, _proof(epochId, bob, 60e18));
        assertEq(small.totalReleased(), 60e18);

        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.AllocationExhausted.selector, uint256(60e18), uint256(40e18))
        );
        vm.prank(bob);
        small.claim(epochId, 60e18, _proof(epochId, alice, 60e18));
    }

    function test_UnusedCapacityDoesNotRollOver() public {
        dist.setMaxPerEpoch(300e18);

        uint256 epoch9 = dist.currentEpoch() - 1;
        _seal(epoch9, alice, 100e18, bob, 0, 100e18);
        _claim(alice, epoch9, 100e18, bob, 0);
        assertEq(dist.epochPaid(epoch9), 100e18); // 200e18 left unused in epoch 9

        vm.warp(11 days);
        uint256 epoch10 = dist.currentEpoch() - 1;
        _seal(epoch10, alice, MAX_PER_ACCOUNT, bob, MAX_PER_ACCOUNT, 300e18);

        _claim(alice, epoch10, MAX_PER_ACCOUNT, bob, MAX_PER_ACCOUNT);
        assertEq(dist.epochPaid(epoch10), MAX_PER_ACCOUNT);

        // If epoch 9's unused capacity rolled over, 200 + 200 would fit in 300+200.
        // It must not: the per-epoch budget is strictly per epoch.
        vm.expectRevert(
            abi.encodeWithSelector(
                RewardDistributor.EpochCapExceeded.selector, MAX_PER_ACCOUNT, 300e18 - MAX_PER_ACCOUNT
            )
        );
        vm.prank(bob);
        dist.claim(epoch10, MAX_PER_ACCOUNT, _proof(epoch10, alice, MAX_PER_ACCOUNT));

        assertEq(dist.epochPaid(epoch10), MAX_PER_ACCOUNT);
        assertEq(dist.epochPaid(epoch9), 100e18);
        assertEq(dist.totalReleased(), 300e18);
    }

    // ---------------------------------------------------------------------
    // Configuration
    // ---------------------------------------------------------------------

    function test_SetMaxPerEpochUpdates() public {
        vm.expectEmit(false, false, false, true);
        emit MaxPerEpochChanged(MAX_PER_EPOCH, 1_500e18);

        dist.setMaxPerEpoch(1_500e18);
        assertEq(dist.maxPerEpoch(), 1_500e18);
    }

    function test_SetMaxPerEpochRejectsZeroAndAboveMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.InvalidEpochCap.selector, uint256(0), 2_000_000e18)
        );
        dist.setMaxPerEpoch(0);

        uint256 tooMuch = 2_000_000e18 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.InvalidEpochCap.selector, tooMuch, 2_000_000e18)
        );
        dist.setMaxPerEpoch(tooMuch);
    }

    function test_SetMaxPerAccountUpdates() public {
        vm.expectEmit(false, false, false, true);
        emit MaxPerAccountPerEpochChanged(MAX_PER_ACCOUNT, 100e18);

        dist.setMaxPerAccountPerEpoch(100e18);
        assertEq(dist.maxPerAccountPerEpoch(), 100e18);
    }

    function test_SetMaxPerAccountRejectsZeroAndAboveEpochCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.InvalidAccountCap.selector, uint256(0), MAX_PER_EPOCH)
        );
        dist.setMaxPerAccountPerEpoch(0);

        uint256 tooMuch = MAX_PER_EPOCH + 1;
        vm.expectRevert(
            abi.encodeWithSelector(RewardDistributor.InvalidAccountCap.selector, tooMuch, MAX_PER_EPOCH)
        );
        dist.setMaxPerAccountPerEpoch(tooMuch);
    }

    function test_ConfigSettersOnlyConfigRole() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, dist.CONFIG_ROLE()
            )
        );
        dist.setMaxPerEpoch(1);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, dist.CONFIG_ROLE()
            )
        );
        dist.setMaxPerAccountPerEpoch(1);
    }

    // ---------------------------------------------------------------------
    // Pause
    // ---------------------------------------------------------------------

    function test_PauseOnlyPauser() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, dist.PAUSER_ROLE()
            )
        );
        dist.pause();
    }

    function test_PauseBlocksSealAndClaimThenUnpauseWorks() public {
        uint256 epochId = dist.currentEpoch() - 1;
        dist.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        dist.sealEpoch(epochId, bytes32(uint256(1)), 1);

        dist.unpause();

        _seal(epochId, alice, MAX_PER_ACCOUNT, bob, MAX_PER_ACCOUNT, 2 * MAX_PER_ACCOUNT);
        _claim(alice, epochId, MAX_PER_ACCOUNT, bob, MAX_PER_ACCOUNT);
        assertEq(prime.balanceOf(alice), MAX_PER_ACCOUNT);
    }
}
