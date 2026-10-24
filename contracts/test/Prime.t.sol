// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Prime} from "../src/Prime.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/**
 * @notice Unit and fuzz tests for the fixed-supply Prime token.
 *
 * The assertions that matter most are not the transfer mechanics (OpenZeppelin's
 * job) but the supply guarantees: total supply is constant, the mint selector
 * does not exist, and genesis issuance goes to exactly one address.
 */
contract PrimeTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event GenesisMint(address indexed to, uint256 amount);

    Prime internal prime;
    address internal treasury;
    address internal alice;
    address internal bob;

    uint256 internal constant TOTAL = 2_000_000_000e18;

    function setUp() public {
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        prime = new Prime(treasury);
    }

    // ---------------------------------------------------------------------
    // Metadata & genesis
    // ---------------------------------------------------------------------

    function test_Metadata() public view {
        assertEq(prime.name(), "Prime");
        assertEq(prime.symbol(), "PRIME");
        assertEq(prime.decimals(), 18);
    }

    function test_GenesisMintsEntireSupplyToTreasury() public view {
        assertEq(prime.totalSupply(), TOTAL);
        assertEq(prime.balanceOf(treasury), TOTAL);
        assertEq(prime.balanceOf(alice), 0);
    }

    function test_GenesisEmitsTransferAndGenesisMint() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), treasury, TOTAL);
        vm.expectEmit(true, false, false, true);
        emit GenesisMint(treasury, TOTAL);

        new Prime(treasury);
    }

    function test_ConstructorRevertsOnZeroTreasury() public {
        vm.expectRevert(Prime.InvalidTreasury.selector);
        new Prime(address(0));
    }

    // ---------------------------------------------------------------------
    // ERC-20 behaviour (the parts a game economy relies on)
    // ---------------------------------------------------------------------

    function test_TransferMovesBalance() public {
        vm.prank(treasury);
        assertTrue(prime.transfer(alice, 1_000e18));

        assertEq(prime.balanceOf(alice), 1_000e18);
        assertEq(prime.balanceOf(treasury), TOTAL - 1_000e18);
        assertEq(prime.totalSupply(), TOTAL);
    }

    function test_TransferRevertsOnInsufficientBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, uint256(0), uint256(1))
        );
        vm.prank(alice);
        prime.transfer(bob, 1);
    }

    function test_TransferRevertsOnZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(treasury);
        prime.transfer(address(0), 1);
    }

    function test_SelfTransferIsNoOp() public {
        vm.prank(treasury);
        prime.transfer(treasury, 500e18);

        assertEq(prime.balanceOf(treasury), TOTAL);
        assertEq(prime.totalSupply(), TOTAL);
    }

    function test_ApproveAndTransferFrom() public {
        vm.prank(treasury);
        prime.approve(alice, 2_000e18);
        assertEq(prime.allowance(treasury, alice), 2_000e18);

        vm.prank(alice);
        prime.transferFrom(treasury, bob, 750e18);

        assertEq(prime.balanceOf(bob), 750e18);
        assertEq(prime.allowance(treasury, alice), 1_250e18);
        assertEq(prime.totalSupply(), TOTAL);
    }

    function test_TransferFromRevertsWithoutAllowance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, uint256(0), uint256(10))
        );
        vm.prank(bob);
        prime.transferFrom(treasury, bob, 10);
    }

    function test_InfiniteAllowanceIsNotDecremented() public {
        vm.prank(treasury);
        prime.approve(alice, type(uint256).max);

        vm.prank(alice);
        prime.transferFrom(treasury, bob, 100e18);

        assertEq(prime.allowance(treasury, alice), type(uint256).max);
    }

    function test_ApproveRevertsForZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(treasury);
        prime.approve(address(0), 1);
    }

    function test_TreasuryCanDistributeToManyRecipients() public {
        uint256 recipients = 10;
        uint256 each = 1_000e18;

        vm.startPrank(treasury);
        for (uint256 i; i < recipients; ++i) {
            prime.transfer(makeAddr(string.concat("player", vm.toString(i))), each);
        }
        vm.stopPrank();

        assertEq(prime.balanceOf(treasury), TOTAL - recipients * each);
        assertEq(prime.totalSupply(), TOTAL);
    }

    // ---------------------------------------------------------------------
    // Supply guarantees — the security-critical section
    // ---------------------------------------------------------------------

    /// @notice The mint selector must not exist, in any plausible signature.
    function test_NoMintSelectorExists() public {
        (bool ok, ) = address(prime).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok, "mint(address,uint256) must not exist");

        (bool ok2, ) = address(prime).call(abi.encodeWithSignature("mint(uint256)", 1));
        assertFalse(ok2, "mint(uint256) must not exist");

        assertEq(prime.totalSupply(), TOTAL);
    }

    /// @notice No call to the token can raise total supply (common admin selectors fuzzed).
    /// @dev Only the token is targeted: calls to an EOA succeed by definition, so
    ///      including EOAs here would assert nothing about the contract.
    function testFuzz_TotalSupplyCannotBeInflated(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        string[4] memory sigs = ["mint(address,uint256)", "mint(uint256)", "setTotalSupply(uint256)", "burn(uint256)"];

        for (uint256 i; i < sigs.length; ++i) {
            (bool ok, ) = address(prime).call(abi.encodeWithSignature(sigs[i], amount));
            assertFalse(ok, "unexpected callable admin function");
        }

        // Two-argument mint selectors need a different encoding.
        (bool okMint, ) = address(prime).call(abi.encodeWithSignature("mint(address,uint256)", alice, amount));
        assertFalse(okMint, "unexpected mint(address,uint256)");

        assertEq(prime.totalSupply(), TOTAL);
    }

    function testFuzz_TransfersPreserveSupply(uint256 amount, address recipient) public {
        vm.assume(recipient != address(0));
        amount = bound(amount, 0, prime.balanceOf(treasury));

        vm.prank(treasury);
        prime.transfer(recipient, amount);

        assertEq(prime.totalSupply(), TOTAL);
        assertEq(prime.balanceOf(treasury) + amount, TOTAL);
    }
}
