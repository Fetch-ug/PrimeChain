// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ItemRegistry} from "../src/ItemRegistry.sol";

contract ItemRegistryTest is Test {
    event ItemTypeRegistered(
        uint256 indexed itemTypeId, bytes32 contentHash, uint64 supplyCap, string metadataURI
    );
    event MetadataURIUpdated(uint256 indexed itemTypeId, string metadataURI);
    event ItemMinted(address indexed to, uint256 indexed itemTypeId, uint256 amount);
    event ItemBurned(address indexed from, uint256 indexed itemTypeId, uint256 amount);
    event Frozen(address indexed account);

    ItemRegistry internal registry;

    address internal alice;
    address internal bob;

    uint256 internal constant ITEM = 42;
    uint64 internal constant CAP = 100;
    bytes32 internal constant HASH = keccak256("manifest-v1");

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        registry = new ItemRegistry(address(this), address(this), address(this), "ipfs://base/");
        registry.registerItemType(ITEM, HASH, CAP, "ipfs://item/42.json");
    }

    function _mint(address to, uint256 amount) internal returns (uint256) {
        registry.mint(to, ITEM, amount, "");
        return amount;
    }

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    function test_ConstructorSetsRoles() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(registry.hasRole(registry.REGISTRAR_ROLE(), address(this)));
        assertTrue(registry.hasRole(registry.MODULE_ROLE(), address(this)));
    }

    function test_DeployerLosesAdminWhenAdminDiffers() public {
        address other = makeAddr("other");
        ItemRegistry r = new ItemRegistry(other, other, other, "");

        assertTrue(r.hasRole(r.DEFAULT_ADMIN_ROLE(), other));
        assertFalse(r.hasRole(r.DEFAULT_ADMIN_ROLE(), address(this)), "deployer must not stay admin");
    }

    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(ItemRegistry.ZeroAddress.selector);
        new ItemRegistry(address(0), address(this), address(this), "");

        vm.expectRevert(ItemRegistry.ZeroAddress.selector);
        new ItemRegistry(address(this), address(0), address(this), "");

        vm.expectRevert(ItemRegistry.ZeroAddress.selector);
        new ItemRegistry(address(this), address(this), address(0), "");
    }

    // ---------------------------------------------------------------------
    // Catalogue
    // ---------------------------------------------------------------------

    function test_RegisterItemType() public {
        vm.expectEmit(true, false, false, true);
        emit ItemTypeRegistered(7, keccak256("seven"), 10, "ipfs://seven");

        registry.registerItemType(7, keccak256("seven"), 10, "ipfs://seven");

        assertTrue(registry.isRegistered(7));
        assertEq(registry.contentHashOf(7), keccak256("seven"));
        assertEq(registry.supplyCapOf(7), 10);
        assertEq(registry.mintedOf(7), 0);
        assertEq(registry.uri(7), "ipfs://seven");
    }

    function test_RegisterRevertsWhenAlreadyRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(ItemRegistry.AlreadyRegistered.selector, uint256(ITEM)));
        registry.registerItemType(ITEM, HASH, CAP, "ipfs://again");
    }

    function test_RegisterRevertsOnZeroContentHash() public {
        vm.expectRevert(ItemRegistry.ZeroContentHash.selector);
        registry.registerItemType(7, bytes32(0), 10, "");
    }

    function test_RegisterRevertsOnZeroSupplyCap() public {
        vm.expectRevert(ItemRegistry.ZeroSupplyCap.selector);
        registry.registerItemType(7, HASH, 0, "");
    }

    function test_RegisterOnlyRegistrar() public {
        address stranger = makeAddr("stranger");
        uint256 newId = 99;
        bytes32 registrarRole = registry.REGISTRAR_ROLE(); // read before the prank

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, registrarRole)
        );
        registry.registerItemType(newId, HASH, 10, "");
        assertFalse(registry.isRegistered(newId), "stranger must not have registered");

        // Positive control.
        registry.registerItemType(newId, HASH, 10, "");
        assertTrue(registry.isRegistered(newId));
    }

    function test_SetMetadataURIUpdatesOnlyTheUri() public {
        vm.expectEmit(true, false, false, true);
        emit MetadataURIUpdated(ITEM, "ipfs://item/42-v2.json");

        registry.setMetadataURI(ITEM, "ipfs://item/42-v2.json");

        assertEq(registry.uri(ITEM), "ipfs://item/42-v2.json");
        assertEq(registry.contentHashOf(ITEM), HASH, "content hash must not change");
        assertEq(registry.supplyCapOf(ITEM), CAP, "supply cap must not change");
    }

    function test_SetMetadataURIRejectsUnknownItem() public {
        vm.expectRevert(abi.encodeWithSelector(ItemRegistry.NotRegistered.selector, uint256(7)));
        registry.setMetadataURI(7, "ipfs://nope");
    }

    function test_UriFallsBackToBaseForUnknownItem() public view {
        // OZ v5.7.0 `ERC1155.uri(uint256)` ignores the id and returns `_uri` verbatim:
        //
        //     function uri(uint256 /* id */) public view virtual returns (string memory) {
        //         return _uri;
        //     }
        //
        // The `{id}` substitution is the CLIENT's job per EIP-1155, so the fallback is
        // the base URI unchanged — not base + id.
        assertEq(registry.uri(1234), "ipfs://base/");
    }

    // ---------------------------------------------------------------------
    // Supply
    // ---------------------------------------------------------------------

    function test_Mint() public {
        vm.expectEmit(true, true, false, true);
        emit ItemMinted(alice, ITEM, 5);

        _mint(alice, 5);

        assertEq(registry.balanceOf(alice, ITEM), 5);
        assertEq(registry.totalSupply(ITEM), 5);
        assertEq(registry.mintedOf(ITEM), 5);
        assertEq(registry.remainingSupply(ITEM), CAP - 5);
    }

    function test_MintRespectsSupplyCapExactly() public {
        _mint(alice, CAP);
        assertEq(registry.remainingSupply(ITEM), 0);

        vm.expectRevert(
            abi.encodeWithSelector(ItemRegistry.SupplyCapExceeded.selector, ITEM, uint256(1), uint256(0))
        );
        registry.mint(alice, ITEM, 1, "");
    }

    function test_MintRejectsUnregisteredItem() public {
        vm.expectRevert(abi.encodeWithSelector(ItemRegistry.NotRegistered.selector, uint256(7)));
        registry.mint(alice, 7, 1, "");
    }

    function test_MintRejectsZeroAmount() public {
        vm.expectRevert(ItemRegistry.ZeroAmount.selector);
        registry.mint(alice, ITEM, 0, "");
    }

    function test_MintRejectsZeroRecipient() public {
        vm.expectRevert(ItemRegistry.ZeroAddress.selector);
        registry.mint(address(0), ITEM, 1, "");
    }

    function test_MintOnlyModule() public {
        address stranger = makeAddr("stranger");
        bytes32 moduleRole = registry.MODULE_ROLE(); // read before the prank

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, moduleRole)
        );
        registry.mint(stranger, ITEM, 1, "");
        assertEq(registry.mintedOf(ITEM), 0);

        // Positive control.
        _mint(alice, 1);
        assertEq(registry.mintedOf(ITEM), 1);
    }

    function test_BurnReducesBalanceButNotMintedCounter() public {
        _mint(alice, 10);

        vm.expectEmit(true, true, false, true);
        emit ItemBurned(alice, ITEM, 4);

        registry.burn(alice, ITEM, 4);

        assertEq(registry.balanceOf(alice, ITEM), 6);
        assertEq(registry.totalSupply(ITEM), 6);
        // Cumulative issuance is deliberately NOT reduced (P2): burning frees no cap.
        assertEq(registry.mintedOf(ITEM), 10);
        assertEq(registry.remainingSupply(ITEM), CAP - 10);
    }

    function test_BurnRejectsUnregisteredItem() public {
        vm.expectRevert(abi.encodeWithSelector(ItemRegistry.NotRegistered.selector, uint256(7)));
        registry.burn(alice, 7, 1);
    }

    function test_BurnRejectsZeroAmount() public {
        vm.expectRevert(ItemRegistry.ZeroAmount.selector);
        registry.burn(alice, ITEM, 0);
    }

    function test_BurnRevertsWhenBalanceInsufficient() public {
        vm.expectRevert(); // OZ ERC1155InsufficientBalance
        registry.burn(alice, ITEM, 1);
    }

    function test_BurnOnlyModule() public {
        _mint(alice, 1);
        address stranger = makeAddr("stranger");
        bytes32 moduleRole = registry.MODULE_ROLE();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, moduleRole)
        );
        registry.burn(alice, ITEM, 1);
        assertEq(registry.balanceOf(alice, ITEM), 1);
    }

    // ---------------------------------------------------------------------
    // Transfers & interface
    // ---------------------------------------------------------------------

    function test_TransferMovesBalanceAndPreservesSupply() public {
        _mint(alice, 10);

        vm.prank(alice);
        registry.safeTransferFrom(alice, bob, ITEM, 4, "");

        assertEq(registry.balanceOf(alice, ITEM), 6);
        assertEq(registry.balanceOf(bob, ITEM), 4);
        assertEq(registry.totalSupply(ITEM), 10);
        assertEq(registry.mintedOf(ITEM), 10);
    }

    function test_SupportsInterface() public view {
        assertTrue(registry.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(registry.supportsInterface(type(IAccessControl).interfaceId));
        assertFalse(registry.supportsInterface(0xdeadbeef));
    }

    function test_GetItemType() public view {
        ItemRegistry.ItemType memory item = registry.getItemType(ITEM);
        assertEq(item.contentHash, HASH);
        assertEq(item.supplyCap, CAP);
        assertEq(item.minted, 0);
        assertEq(item.metadataURI, "ipfs://item/42.json");
    }

    function test_GetItemTypeRevertsForUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(ItemRegistry.NotRegistered.selector, uint256(7)));
        registry.getItemType(7);
    }

    // ---------------------------------------------------------------------
    // Migration freeze (ADR-020)
    //
    // The contract is immutable, so the freeze is the only migration tool: it makes a V2
    // snapshot atomic. Each test below pins one of the client's stated constraints.
    // ---------------------------------------------------------------------

    function test_FreezeEmitsEventAndSetsFlag() public {
        vm.expectEmit(true, false, false, true);
        emit Frozen(address(this));

        registry.freeze();

        assertTrue(registry.frozen());
    }

    function test_FreezeOnlyTimelockAdmin() public {
        address admin = makeAddr("freezeAdmin");
        address registrar = makeAddr("freezeRegistrar");
        address module = makeAddr("freezeModule");
        ItemRegistry r = new ItemRegistry(admin, registrar, module, "");

        // Read the role BEFORE any prank; a getter between prank and call consumes it.
        bytes32 adminRole = r.DEFAULT_ADMIN_ROLE();

        vm.prank(registrar);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, registrar, adminRole)
        );
        r.freeze();
        assertFalse(r.frozen(), "registrar must not be able to freeze");

        vm.prank(module);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, module, adminRole)
        );
        r.freeze();
        assertFalse(r.frozen(), "module must not be able to freeze");

        address stranger = makeAddr("freezeStranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        r.freeze();
        assertFalse(r.frozen(), "stranger must not be able to freeze");

        // Positive control: the admin can.
        vm.prank(admin);
        r.freeze();
        assertTrue(r.frozen(), "admin must be able to freeze");
    }

    function test_FrozenBlocksTransfer() public {
        _mint(alice, 10);
        registry.freeze();

        vm.prank(alice);
        vm.expectRevert(ItemRegistry.ContractFrozen.selector);
        registry.safeTransferFrom(alice, bob, ITEM, 1, "");

        assertEq(registry.balanceOf(alice, ITEM), 10, "balance must be untouched");
    }

    function test_FrozenBlocksMint() public {
        registry.freeze();

        vm.expectRevert(ItemRegistry.ContractFrozen.selector);
        registry.mint(alice, ITEM, 1, "");
    }

    function test_FrozenBlocksBurn() public {
        _mint(alice, 10);
        registry.freeze();

        // Burn is blocked too: a MODULE burn after the snapshot would silently change a
        // player's recorded balance. Crafting therefore pauses while frozen (MIGRATION §4).
        vm.expectRevert(ItemRegistry.ContractFrozen.selector);
        registry.burn(alice, ITEM, 1);

        assertEq(registry.balanceOf(alice, ITEM), 10, "balance must be untouched");
    }

    function test_FreezeCannotMoveBurnOrReassignAnything() public {
        _mint(alice, 10);

        uint256 aliceBefore = registry.balanceOf(alice, ITEM);
        uint256 bobBefore = registry.balanceOf(bob, ITEM);
        uint256 supplyBefore = registry.totalSupply(ITEM);
        uint256 mintedBefore = registry.mintedOf(ITEM);
        uint256 capBefore = registry.supplyCapOf(ITEM);
        bytes32 hashBefore = registry.contentHashOf(ITEM);

        registry.freeze();

        assertEq(registry.balanceOf(alice, ITEM), aliceBefore);
        assertEq(registry.balanceOf(bob, ITEM), bobBefore);
        assertEq(registry.totalSupply(ITEM), supplyBefore);
        assertEq(registry.mintedOf(ITEM), mintedBefore);
        assertEq(registry.supplyCapOf(ITEM), capBefore);
        assertEq(registry.contentHashOf(ITEM), hashBefore);
    }

    function test_FreezeIsOneWay() public {
        registry.freeze();

        vm.expectRevert(ItemRegistry.AlreadyFrozen.selector);
        registry.freeze();

        // No unfreeze selector exists at all; a call to one must fail.
        (bool ok, ) = address(registry).call(abi.encodeWithSignature("unfreeze()"));
        assertFalse(ok, "there must be no unfreeze path");
        assertTrue(registry.frozen());
    }

    function test_MetadataStillUpdatableWhileFrozen() public {
        registry.freeze();

        // URIs are not balances; moving a CDN during a migration is legitimate.
        registry.setMetadataURI(ITEM, "ipfs://frozen/42.json");

        assertEq(registry.uri(ITEM), "ipfs://frozen/42.json");
        assertEq(registry.contentHashOf(ITEM), HASH, "content hash still immutable");
    }
}
