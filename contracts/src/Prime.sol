// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title Prime
 * @notice The PrimeChain base token. Fixed supply, minted exactly once, to one address.
 *
 * @dev SECURITY PROPERTIES (these are the whole point of this contract):
 *
 *  1. There is no externally reachable mint. `_mint` is called once, from the
 *     constructor, and nowhere else. There is no role, no owner, no setter and
 *     no upgrade path. "No hidden admin mint" is therefore a property of the
 *     bytecode, not a promise in a document.
 *  2. The contract is not upgradeable and has no proxy. The deployed code is the
 *     code that was audited, forever.
 *  3. `TOTAL_SUPPLY` is a `constant`, so total supply cannot be raised even by a
 *     storage bug: there is no storage slot holding the supply cap to corrupt.
 *  4. No transfer hooks, no fee-on-transfer, no pause. Transfers are exactly the
 *     ERC-20 semantics in OpenZeppelin v5.7.0.
 *
 * @dev DELIBERATE OMISSIONS — each was considered and rejected for v1:
 *  - `ERC20Permit` (EIP-2612): extra signature surface; with sponsored gas the
 *    approve+action flow is already a single user operation.
 *  - `ERC20Pausable`: a pausable money token is an admin risk we do not need.
 *  - `ERC20Burnable`: burning would let supply fall, which is a game-design
 *    decision (sink policy), not a token primitive. If wanted, it ships as a
 *    separate sink contract in Phase 2 rather than as a token method.
 *
 * @custom:security-contact security@primetechnologies.example
 */
contract Prime is ERC20 {
    /// @notice Total supply ever created: 2,000,000,000 PRIME, 18 decimals.
    /// @dev 2_000_000_000e18 == 2e27, which is far below 2^256.
    uint256 public constant TOTAL_SUPPLY = 2_000_000_000e18;

    /// @notice The only address that ever received newly minted Prime.
    /// @dev Immutable so it is readable by indexers and auditors without a call.
    address public immutable treasury;

    /// @notice Emitted exactly once, in the constructor.
    /// @dev Distinct from ERC-20 `Transfer(0x0, treasury, TOTAL_SUPPLY)` so that
    ///      indexers can identify genesis issuance without replaying block 0.
    event GenesisMint(address indexed to, uint256 amount);

    error InvalidTreasury();

    /**
     * @param treasury_ The company treasury that receives the entire supply.
     * @dev Reverts on the zero address: minting to 0x0 would be an instant burn
     *      of the whole economy, which is unrecoverable.
     */
    constructor(address treasury_) ERC20("Prime", "PRIME") {
        if (treasury_ == address(0)) revert InvalidTreasury();
        treasury = treasury_;
        _mint(treasury_, TOTAL_SUPPLY);
        emit GenesisMint(treasury_, TOTAL_SUPPLY);
    }
}
