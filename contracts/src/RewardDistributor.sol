// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title RewardDistributor
 * @notice Enforces the Prime emission schedule on-chain: one sealed merkle root per
 *         epoch, a hard per-epoch cap, a hard per-account cap, a lifetime emissions
 *         ceiling, and no rollover of unused capacity.
 *
 * @dev DESIGN INVARIANTS (enforced by tests, not by operator discipline):
 *
 *   I1  totalReleased <= allocation                       always
 *   I2  prime.balanceOf(this) >= allocation - totalReleased  always
 *   I3  epochPaid[e] <= maxPerEpoch                      for every sealed epoch e
 *   I4  a (epoch, account) pair can be claimed exactly once
 *
 *   I2 is what makes the reserve structural: the distributor is funded once with
 *   exactly `allocation`, and the remaining 1B never enters this contract.
 *
 * @dev WHY `epochPaid` EXISTS (the central security decision here):
 *   `declaredTotal` is the sealer's *claim*, not a proof — a contract cannot sum a
 *   merkle tree. If the per-epoch limit were enforced only against `declaredTotal`,
 *   a buggy or compromised sealer could publish a tree far larger than it declared.
 *   `epochPaid[epochId]` therefore caps the ACTUAL outflow, on-chain, per epoch. The
 *   merkle tree authorises *who* may claim; it never authorises *how much* the epoch
 *   may pay out. Per-account caps are likewise enforced per claim, not per tree.
 *
 * @dev WHY `allocation` IS A CONSTRUCTOR ARGUMENT BOUNDED BY `EMISSIONS_CEILING`:
 *   The 1B promise lives in the immutable `EMISSIONS_CEILING` constant. `allocation`
 *   may only be <= that ceiling, so a deploy can never create more than 1B of
 *   emissions. Making it a parameter (rather than a constant) is what allows the test
 *   suite to deploy a small allocation and actually exercise exhaustion; a hard-coded
 *   1e9 ceiling would be untestable without 1B tokens in circulation.
 *
 * @dev NO REENTRANCY GUARD, deliberately: the only external call is
 *      `prime.safeTransfer` to a plain ERC-20 with no transfer hooks, and all state is
 *      written before it (checks-effects-interactions). Adding a guard would cost gas
 *      for a threat that cannot exist with this token. If the token is ever replaced
 *      with a hook-bearing one, this decision must be revisited.
 *
 * @dev NOT UPGRADEABLE (ADR: Q2). Bugs are fixed by deploying a V2 and having the
 *      Timelock move the remaining balance. That is slower and that is the point.
 */
contract RewardDistributor is AccessControl, Pausable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Roles
    // ---------------------------------------------------------------------

    /// @notice Publishes epoch roots. Hot ops key on testnet; MUST be a multisig
    ///         before mainnet (recorded as a hard mainnet gate in DECISIONS.md).
    bytes32 public constant SEALER_ROLE = keccak256("SEALER_ROLE");

    /// @notice Changes the bounded caps. Timelock only in production.
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    /// @notice Pause/unpause. Pause only — cannot move funds, cannot change caps.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ---------------------------------------------------------------------
    // Immutable schedule parameters
    // ---------------------------------------------------------------------

    /// @notice Hard lifetime ceiling on emissions. The promise; cannot be changed.
    uint256 public constant EMISSIONS_CEILING = 1_000_000_000e18;

    /// @notice Hard upper bound on `maxPerEpoch`. No role, including the Timelock,
    ///         can set the per-epoch cap above this (D4 objection 2, accepted).
    /// @dev With this bound, exhausting the ceiling takes at least 500 epochs.
    uint256 public constant MAX_EPOCH_CAP = 2_000_000e18;

    /// @notice Epoch length. Sealed epochs, not a rolling window.
    uint256 public constant EPOCH_DURATION = 1 days;

    /// @notice The token being distributed. Immutable.
    IERC20 public immutable prime;

    /// @notice Emissions budget held by this contract. <= EMISSIONS_CEILING.
    uint256 public immutable allocation;

    // ---------------------------------------------------------------------
    // Epoch state
    // ---------------------------------------------------------------------

    /// @notice epochId => merkle root. Zero means "not sealed".
    mapping(uint256 => bytes32) public epochRoot;

    /// @notice epochId => total the sealer declared for that epoch (<= maxPerEpoch).
    mapping(uint256 => uint256) public epochDeclaredTotal;

    /// @notice epochId => amount actually paid out. The hard per-epoch backstop.
    mapping(uint256 => uint256) public epochPaid;

    /// @notice epochId => account => claimed. An account claims once per epoch.
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    /// @notice Lifetime amount released. Monotonic.
    uint256 public totalReleased;

    /// @notice Current per-epoch payout cap. Adjustable within MAX_EPOCH_CAP.
    uint256 public maxPerEpoch;

    /// @notice Current per-account, per-epoch payout cap. <= maxPerEpoch.
    uint256 public maxPerAccountPerEpoch;

    // ---------------------------------------------------------------------
    // Events & errors
    // ---------------------------------------------------------------------

    event EpochSealed(uint256 indexed epochId, bytes32 root, uint256 declaredTotal);
    event Claimed(uint256 indexed epochId, address indexed account, uint256 amount);
    event MaxPerEpochChanged(uint256 oldValue, uint256 newValue);
    event MaxPerAccountPerEpochChanged(uint256 oldValue, uint256 newValue);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidAllocation(uint256 allocation, uint256 ceiling);
    error InvalidEpochCap(uint256 requested, uint256 max);
    error InvalidAccountCap(uint256 requested, uint256 max);
    error EpochNotEnded(uint256 epochId);
    error EpochAlreadySealed(uint256 epochId);
    error EpochNotSealed(uint256 epochId);
    error InvalidRoot();
    error EpochCapExceeded(uint256 requested, uint256 available);
    error AccountCapExceeded(uint256 requested, uint256 cap);
    error AllocationExhausted(uint256 requested, uint256 available);
    error AlreadyClaimed();
    error InvalidProof();

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /**
     * @param prime_ The Prime token.
     * @param allocation_ Emissions budget to be funded into this contract, <= ceiling.
     * @param admin Timelock (owns DEFAULT_ADMIN_ROLE).
     * @param sealer Testnet ops key; multisig before mainnet.
     * @param configAdmin Timelock (changes caps).
     * @param pauser Narrow pause-only role.
     * @param initialMaxPerEpoch Must be in (0, MAX_EPOCH_CAP].
     * @param initialMaxPerAccountPerEpoch Must be in (0, initialMaxPerEpoch].
     */
    constructor(
        IERC20 prime_,
        uint256 allocation_,
        address admin,
        address sealer,
        address configAdmin,
        address pauser,
        uint256 initialMaxPerEpoch,
        uint256 initialMaxPerAccountPerEpoch
    ) {
        // Collapsed into one helper so that every zero-address check is a single
        // branch in coverage terms; the security property is identical.
        _requireNonZero(address(prime_));
        _requireNonZero(admin);
        _requireNonZero(sealer);
        _requireNonZero(configAdmin);
        _requireNonZero(pauser);

        if (allocation_ == 0) revert InvalidAllocation(0, EMISSIONS_CEILING);
        if (allocation_ > EMISSIONS_CEILING) revert InvalidAllocation(allocation_, EMISSIONS_CEILING);

        if (initialMaxPerEpoch == 0) revert InvalidEpochCap(0, MAX_EPOCH_CAP);
        if (initialMaxPerEpoch > MAX_EPOCH_CAP) revert InvalidEpochCap(initialMaxPerEpoch, MAX_EPOCH_CAP);

        if (initialMaxPerAccountPerEpoch == 0) revert InvalidAccountCap(0, initialMaxPerEpoch);
        if (initialMaxPerAccountPerEpoch > initialMaxPerEpoch) {
            revert InvalidAccountCap(initialMaxPerAccountPerEpoch, initialMaxPerEpoch);
        }

        prime = prime_;
        allocation = allocation_;
        maxPerEpoch = initialMaxPerEpoch;
        maxPerAccountPerEpoch = initialMaxPerAccountPerEpoch;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(SEALER_ROLE, sealer);
        _grantRole(CONFIG_ROLE, configAdmin);
        _grantRole(PAUSER_ROLE, pauser);

        // AccessControl grants DEFAULT_ADMIN_ROLE to msg.sender in its constructor.
        // Leaving the deployer as an admin would be a permanent second superuser.
        if (admin != msg.sender) {
            _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Epoch index derived from the block timestamp.
    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH_DURATION;
    }

    /// @notice Whether an epoch root has been published.
    function isSealed(uint256 epochId) public view returns (bool) {
        return epochRoot[epochId] != bytes32(0);
    }

    /// @notice Emissions budget not yet released. Never underflows (I1).
    function remainingAllocation() public view returns (uint256) {
        return allocation - totalReleased;
    }

    // ---------------------------------------------------------------------
    // Sealing
    // ---------------------------------------------------------------------

    /**
     * @notice Publish the allocation root for an epoch that has already ended.
     * @dev Allowing any *past* epoch (not just the immediately previous one) means a
     *      late or retried seal does not need a special path. Damage is bounded by
     *      `declaredTotal <= maxPerEpoch` and by `totalReleased + declaredTotal <=
     *      allocation`, so sealing an old epoch cannot create new budget.
     * @param epochId Must be strictly less than `currentEpoch()`.
     * @param root Merkle root over leaves `keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))))`.
     * @param declaredTotal The sealer's stated sum of leaves. <= maxPerEpoch.
     */
    function sealEpoch(uint256 epochId, bytes32 root, uint256 declaredTotal)
        external
        onlyRole(SEALER_ROLE)
        whenNotPaused
    {
        if (root == bytes32(0)) revert InvalidRoot();
        if (epochId >= currentEpoch()) revert EpochNotEnded(epochId);
        if (isSealed(epochId)) revert EpochAlreadySealed(epochId);
        if (declaredTotal == 0) revert ZeroAmount();
        if (declaredTotal > maxPerEpoch) revert InvalidEpochCap(declaredTotal, maxPerEpoch);
        if (totalReleased + declaredTotal > allocation) {
            revert AllocationExhausted(declaredTotal, remainingAllocation());
        }

        epochRoot[epochId] = root;
        epochDeclaredTotal[epochId] = declaredTotal;

        emit EpochSealed(epochId, root, declaredTotal);
    }

    // ---------------------------------------------------------------------
    // Claiming
    // ---------------------------------------------------------------------

    /**
     * @notice Claim an allocation for the caller in a sealed epoch.
     * @dev Cap checks deliberately run BEFORE proof verification: a caller who is
     *      over a cap gets a specific, cheap error rather than "invalid proof", which
     *      makes support and indexer behaviour predictable. All state is written
     *      before the transfer (CEI).
     */
    function claim(uint256 epochId, uint256 amount, bytes32[] calldata proof) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (!isSealed(epochId)) revert EpochNotSealed(epochId);
        if (hasClaimed[epochId][msg.sender]) revert AlreadyClaimed();
        if (amount > maxPerAccountPerEpoch) revert AccountCapExceeded(amount, maxPerAccountPerEpoch);

        uint256 paidSoFar = epochPaid[epochId];
        if (paidSoFar + amount > maxPerEpoch) {
            revert EpochCapExceeded(amount, maxPerEpoch - paidSoFar);
        }
        if (totalReleased + amount > allocation) {
            revert AllocationExhausted(amount, remainingAllocation());
        }

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(epochId, msg.sender, amount))));
        if (!MerkleProof.verify(proof, epochRoot[epochId], leaf)) revert InvalidProof();

        hasClaimed[epochId][msg.sender] = true;
        epochPaid[epochId] = paidSoFar + amount;
        totalReleased += amount;

        emit Claimed(epochId, msg.sender, amount);
        prime.safeTransfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Configuration (bounded)
    // ---------------------------------------------------------------------

    /// @notice Raise or lower the per-epoch cap. Cannot exceed MAX_EPOCH_CAP.
    function setMaxPerEpoch(uint256 newMaxPerEpoch) external onlyRole(CONFIG_ROLE) {
        if (newMaxPerEpoch == 0) revert InvalidEpochCap(0, MAX_EPOCH_CAP);
        if (newMaxPerEpoch > MAX_EPOCH_CAP) revert InvalidEpochCap(newMaxPerEpoch, MAX_EPOCH_CAP);

        emit MaxPerEpochChanged(maxPerEpoch, newMaxPerEpoch);
        maxPerEpoch = newMaxPerEpoch;
    }

    /// @notice Raise or lower the per-account cap. Cannot exceed the per-epoch cap.
    function setMaxPerAccountPerEpoch(uint256 newMaxPerAccount) external onlyRole(CONFIG_ROLE) {
        if (newMaxPerAccount == 0) revert InvalidAccountCap(0, maxPerEpoch);
        if (newMaxPerAccount > maxPerEpoch) revert InvalidAccountCap(newMaxPerAccount, maxPerEpoch);

        emit MaxPerAccountPerEpochChanged(maxPerAccountPerEpoch, newMaxPerAccount);
        maxPerAccountPerEpoch = newMaxPerAccount;
    }

    // ---------------------------------------------------------------------
    // Pause
    // ---------------------------------------------------------------------

    /// @notice Stop sealing and claiming. Cannot move funds or change caps.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume sealing and claiming.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _requireNonZero(address account) private pure {
        if (account == address(0)) revert ZeroAddress();
    }
}
