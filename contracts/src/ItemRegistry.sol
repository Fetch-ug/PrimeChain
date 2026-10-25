// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title ItemRegistry
 * @notice On-chain catalogue of item *types*: a content hash, a JSON metadata URI and a
 *         hard lifetime supply cap. Tokens are ERC-1155 balances.
 *
 * @dev WHAT IS AND IS NOT ON-CHAIN
 *   On-chain: itemTypeId, keccak256 content hash of the asset manifest, metadata URI,
 *             supply cap, cumulative minted count, balances.
 *   Off-chain: every 3D model, texture, audio file and recipe definition. Clients fetch
 *              the manifest from the URI and verify it against `contentHash` before
 *              rendering. Nothing that costs bandwidth is stored here.
 *
 * @dev ECONOMIC PROMISES THIS CONTRACT KEEPS
 *   P1  A registered item type can never change its contentHash. The URI may change
 *       (CDN moves) and emits an event, so a bait-and-switch is visible on-chain.
 *   P2  `minted` is cumulative and monotonic: burning does NOT free capacity. A supply
 *       cap is therefore a lifetime issuance cap, not an outstanding-supply cap. This
 *       prevents mint/burn cycles from inflating issuance.
 *   P3  mint() reverts the instant the cap would be exceeded; there is no partial mint.
 *
 * @dev NOT UPGRADEABLE — deviation from PHASE2_PLAN §2, recorded as ADR-019.
 *      The upgradeable OpenZeppelin package (`contracts-upgradeable`) is not vendored, and
 *      the non-upgradeable `ERC1155`/`AccessControl` constructors write storage that a
 *      proxy would never execute (no `__ERC1155_init` exists in the base package). Making
 *      the contract non-upgradeable is honest; pretending a proxy would be safe is not.
 *      This needs a decision before Crafting/Marketplace are written.
 *
 * @dev Reentrancy: `safeTransferFrom`/`safeBatchTransferFrom` call `onERC1155Received` on
 *      contract recipients. Those are OZ's functions and our hooks do not exist; mint/burn
 *      are MODULE-only and touch no external contracts. No guard is added; revisit if a
 *      mint hook or a reward-on-receive mechanism is ever introduced.
 */
contract ItemRegistry is ERC1155Supply, AccessControl {
    /// @notice Registers item types and updates metadata URIs. Timelock in production.
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    /// @notice Mints and burns. Held by game contracts (Crafting, Marketplace), never an EOA.
    bytes32 public constant MODULE_ROLE = keccak256("MODULE_ROLE");

    struct ItemType {
        bytes32 contentHash;
        uint64 supplyCap;
        uint64 minted;
        string metadataURI;
    }

    mapping(uint256 => ItemType) private _items;
    mapping(uint256 => bool) private _registered;

    /// @notice Terminal migration state. Once true, no balance can ever change again.
    /// @dev One-way by construction: there is no unfreeze path anywhere in this contract.
    bool public frozen;

    event ItemTypeRegistered(
        uint256 indexed itemTypeId, bytes32 contentHash, uint64 supplyCap, string metadataURI
    );
    event MetadataURIUpdated(uint256 indexed itemTypeId, string metadataURI);
    event ItemMinted(address indexed to, uint256 indexed itemTypeId, uint256 amount);
    event ItemBurned(address indexed from, uint256 indexed itemTypeId, uint256 amount);

    /// @notice Emitted exactly once, when the catalogue becomes read-only for balances.
    event Frozen(address indexed account);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroContentHash();
    error ZeroSupplyCap();
    error AlreadyRegistered(uint256 itemTypeId);
    error NotRegistered(uint256 itemTypeId);
    error SupplyCapExceeded(uint256 itemTypeId, uint256 requested, uint256 available);
    error AlreadyFrozen();
    error ContractFrozen();

    /**
     * @param admin Timelock.
     * @param registrar Timelock (registers item types, updates URIs).
     * @param module Game contract allowed to mint/burn.
     * @param baseURI Fallback URI for unregistered ids; normally "".
     */
    constructor(address admin, address registrar, address module, string memory baseURI) ERC1155(baseURI) {
        if (admin == address(0) || registrar == address(0) || module == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRAR_ROLE, registrar);
        _grantRole(MODULE_ROLE, module);

        // AccessControl grants DEFAULT_ADMIN_ROLE to msg.sender in its constructor;
        // leaving the deployer as a second superuser would be a permanent backdoor.
        if (admin != msg.sender) {
            _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
    }

    // ---------------------------------------------------------------------
    // Catalogue
    // ---------------------------------------------------------------------

    /**
     * @notice Register a new item type. One-shot per id; the content hash is immutable.
     * @param itemTypeId Caller-chosen id (game-side numbering). Must be unique.
     * @param contentHash keccak256 of the canonical asset manifest. Never zero.
     * @param supplyCap Lifetime issuance cap. Never zero.
     * @param metadataURI URI of the off-chain JSON metadata.
     */
    function registerItemType(
        uint256 itemTypeId,
        bytes32 contentHash,
        uint64 supplyCap,
        string calldata metadataURI
    ) external onlyRole(REGISTRAR_ROLE) {
        if (_registered[itemTypeId]) revert AlreadyRegistered(itemTypeId);
        if (contentHash == bytes32(0)) revert ZeroContentHash();
        if (supplyCap == 0) revert ZeroSupplyCap();

        _registered[itemTypeId] = true;
        _items[itemTypeId] = ItemType({
            contentHash: contentHash,
            supplyCap: supplyCap,
            minted: 0,
            metadataURI: metadataURI
        });

        emit ItemTypeRegistered(itemTypeId, contentHash, supplyCap, metadataURI);
    }

    /// @notice Point an item type at a new metadata URI. The content hash cannot change.
    function setMetadataURI(uint256 itemTypeId, string calldata metadataURI)
        external
        onlyRole(REGISTRAR_ROLE)
    {
        if (!_registered[itemTypeId]) revert NotRegistered(itemTypeId);
        _items[itemTypeId].metadataURI = metadataURI;
        emit MetadataURIUpdated(itemTypeId, metadataURI);
    }

    // ---------------------------------------------------------------------
    // Supply
    // ---------------------------------------------------------------------

    /// @notice Mint item tokens. Only a registered game module may call.
    function mint(address to, uint256 itemTypeId, uint256 amount, bytes memory data)
        external
        onlyRole(MODULE_ROLE)
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        ItemType storage item = _requireRegistered(itemTypeId);
        uint256 available = item.supplyCap - item.minted;
        if (amount > available) revert SupplyCapExceeded(itemTypeId, amount, available);

        // Safe: amount <= available <= supplyCap <= type(uint64).max.
        item.minted = item.minted + uint64(amount);

        _mint(to, itemTypeId, amount, data);
        emit ItemMinted(to, itemTypeId, amount);
    }

    /// @notice Burn item tokens. Cumulative `minted` is NOT reduced (P2).
    function burn(address from, uint256 itemTypeId, uint256 amount) external onlyRole(MODULE_ROLE) {
        if (amount == 0) revert ZeroAmount();
        _requireRegistered(itemTypeId);

        _burn(from, itemTypeId, amount);
        emit ItemBurned(from, itemTypeId, amount);
    }

    // ---------------------------------------------------------------------
    // Migration freeze (ADR-020)
    // ---------------------------------------------------------------------

    /**
     * @notice Permanently make every balance immutable, so a V2 migration can be snapshotted.
     * @dev Callable ONLY by DEFAULT_ADMIN_ROLE (the Timelock). Not the registrar, not a game
     *      module, not an ops key: exactly one slow authority can end trading, and the
     *      function takes no arguments and touches no balance, so it cannot move, burn or
     *      reassign anything. There is no unfreeze.
     *
     *      It blocks `_update`, which covers mint, burn AND transfer. Blocking burn is
     *      deliberate: a MODULE burn after the snapshot would silently change a player's
     *      recorded balance. Consequence: Crafting (which burns recipe inputs) pauses while
     *      frozen, by design — see MIGRATION.md §4.
     */
    function freeze() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (frozen) revert AlreadyFrozen();
        frozen = true;
        emit Frozen(msg.sender);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getItemType(uint256 itemTypeId) external view returns (ItemType memory) {
        return _requireRegistered(itemTypeId);
    }

    function isRegistered(uint256 itemTypeId) external view returns (bool) {
        return _registered[itemTypeId];
    }

    function contentHashOf(uint256 itemTypeId) external view returns (bytes32) {
        return _items[itemTypeId].contentHash;
    }

    function supplyCapOf(uint256 itemTypeId) external view returns (uint256) {
        return _items[itemTypeId].supplyCap;
    }

    function mintedOf(uint256 itemTypeId) external view returns (uint256) {
        return _items[itemTypeId].minted;
    }

    /// @notice Lifetime issuance still available for an item type.
    function remainingSupply(uint256 itemTypeId) external view returns (uint256) {
        if (!_registered[itemTypeId]) return 0;
        ItemType storage item = _items[itemTypeId];
        return item.supplyCap - item.minted;
    }

    /// @notice Per-item metadata URI; falls back to the base URI for unknown ids.
    function uri(uint256 itemTypeId) public view override returns (string memory) {
        if (_registered[itemTypeId]) {
            return _items[itemTypeId].metadataURI;
        }
        return super.uri(itemTypeId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Single choke point for every balance change. The freeze guard lives here so
    ///      mint, burn and transfer cannot drift apart: one flag, one check, no exceptions.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155, ERC1155Supply)
    {
        if (frozen) revert ContractFrozen();
        super._update(from, to, ids, values);
    }

    function _requireRegistered(uint256 itemTypeId) private view returns (ItemType storage item) {
        if (!_registered[itemTypeId]) revert NotRegistered(itemTypeId);
        item = _items[itemTypeId];
    }
}
