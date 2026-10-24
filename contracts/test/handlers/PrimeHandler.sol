// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Prime} from "../../src/Prime.sol";

/**
 * @notice Stateful fuzz handler for the Prime invariant suite.
 *
 * Every action moves tokens *between the tracked actors only*. That restriction
 * is what makes `sum(balances) == totalSupply` a meaningful invariant: if an
 * action could send to an untracked address, the sum would trivially break and
 * the invariant would be worthless.
 */
contract PrimeHandler is Test {
    Prime public immutable prime;
    address public immutable treasury;

    address[] internal _actors;

    uint256 public transferCalls;
    uint256 public transferFromCalls;

    constructor(Prime prime_, address treasury_, address[] memory actors_) {
        prime = prime_;
        treasury = treasury_;
        for (uint256 i; i < actors_.length; ++i) {
            _actors.push(actors_[i]);
        }
    }

    function actorsLength() external view returns (uint256) {
        return _actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return _actors[index];
    }

    /// @dev Direct transfer between two actors.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);

        uint256 balance = prime.balanceOf(from);
        if (balance == 0) return; // nothing to move; returning (not reverting) keeps fail_on_revert meaningful

        amount = bound(amount, 1, balance);

        vm.prank(from);
        prime.transfer(to, amount);
        ++transferCalls;
    }

    /// @dev Approve-then-pull path, exercising `_spendAllowance` under fuzz.
    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);

        uint256 balance = prime.balanceOf(owner);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(owner);
        prime.approve(spender, amount);

        vm.prank(spender);
        prime.transferFrom(owner, to, amount);
        ++transferFromCalls;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }
}
