// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {BaseEvolutionHook} from "../../src/hooks/BaseEvolutionHook.sol";
import {EvolutionTypes} from "../../src/hooks/EvolutionTypes.sol";

/// @dev Concrete subclass that declares every lifecycle flag so each
///      base-default lifecycle method takes the success branch.
contract HookAllFlags is BaseEvolutionHook {
    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_BEFORE_MINT |
               EvolutionTypes.FLAG_AFTER_MINT |
               EvolutionTypes.FLAG_BEFORE_TRANSFER |
               EvolutionTypes.FLAG_AFTER_TRANSFER |
               EvolutionTypes.FLAG_ON_TRIGGER;
    }
}

/// @dev Concrete subclass that declares no permissions — every lifecycle
///      method must revert with PermissionNotDeclared.
contract HookNoFlags is BaseEvolutionHook {
    function getPermissions() public pure override returns (uint256) {
        return 0;
    }
}

/// @dev Concrete subclass that declares only BEFORE_MINT, used to exercise
///      partial-flag combinations.
contract HookOnlyBeforeMint is BaseEvolutionHook {
    function getPermissions() public pure override returns (uint256) {
        return EvolutionTypes.FLAG_BEFORE_MINT;
    }
}

contract BaseEvolutionHookTest is Test {
    HookAllFlags        internal allHook;
    HookNoFlags         internal noHook;
    HookOnlyBeforeMint  internal beforeMintHook;

    function setUp() public {
        allHook = new HookAllFlags();
        noHook  = new HookNoFlags();
        beforeMintHook = new HookOnlyBeforeMint();
    }

    // ── permissions() cache ────────────────────────────────────────────────

    function test_permissions_returnsCachedFlagsFromConstructor() public view {
        // The constructor caches getPermissions(); permissions() must mirror it.
        assertEq(allHook.permissions(), allHook.getPermissions());
        assertEq(noHook.permissions(),  noHook.getPermissions());
        assertEq(beforeMintHook.permissions(), beforeMintHook.getPermissions());
    }

    function test_hookInterfaceId_matchesKeccak() public view {
        // Pinned interfaceId so host-side feature-detection cannot regress.
        assertEq(allHook.hookInterfaceId(), bytes4(0xb1f4f1a3));
        // Same id is shared by all subclasses (it's a `pure` constant).
        assertEq(noHook.hookInterfaceId(),  bytes4(0xb1f4f1a3));
    }

    // ── Lifecycle success paths (flag set → returns selector / noOp) ──────

    function test_beforeMint_returnsSelectorWhenFlagDeclared() public {
        bytes4 s = allHook.beforeMint(1, address(this), "");
        assertEq(s, BaseEvolutionHook.beforeMint.selector);
    }

    function test_afterMint_returnsSelectorWhenFlagDeclared() public {
        bytes4 s = allHook.afterMint(1, address(this), "");
        assertEq(s, BaseEvolutionHook.afterMint.selector);
    }

    function test_beforeTransfer_returnsSelectorWhenFlagDeclared() public {
        bytes4 s = allHook.beforeTransfer(1, address(0xa), address(0xb));
        assertEq(s, BaseEvolutionHook.beforeTransfer.selector);
    }

    function test_afterTransfer_returnsSelectorWhenFlagDeclared() public {
        bytes4 s = allHook.afterTransfer(1, address(0xa), address(0xb));
        assertEq(s, BaseEvolutionHook.afterTransfer.selector);
    }

    function test_onTrigger_returnsNoOpWhenFlagDeclared() public {
        EvolutionTypes.EvolutionResult memory r =
            allHook.onTrigger(1, bytes32("test"), "");
        assertFalse(r.svgChanged);
        assertEq(r.newSvgInline.length, 0);
        assertEq(bytes(r.newSvgUri).length, 0);
        assertEq(r.newStateHash, bytes32(0));
        assertFalse(r.requiresKeeper);
    }

    // ── Lifecycle revert paths (flag NOT set → PermissionNotDeclared) ─────

    function test_beforeMint_revertsWhenFlagAbsent() public {
        vm.expectRevert(abi.encodeWithSelector(BaseEvolutionHook.PermissionNotDeclared.selector, EvolutionTypes.FLAG_BEFORE_MINT));
        noHook.beforeMint(1, address(this), "");
    }

    function test_afterMint_revertsWhenFlagAbsent() public {
        vm.expectRevert(abi.encodeWithSelector(BaseEvolutionHook.PermissionNotDeclared.selector, EvolutionTypes.FLAG_AFTER_MINT));
        noHook.afterMint(1, address(this), "");
    }

    function test_beforeTransfer_revertsWhenFlagAbsent() public {
        vm.expectRevert(abi.encodeWithSelector(BaseEvolutionHook.PermissionNotDeclared.selector, EvolutionTypes.FLAG_BEFORE_TRANSFER));
        noHook.beforeTransfer(1, address(0xa), address(0xb));
    }

    function test_afterTransfer_revertsWhenFlagAbsent() public {
        vm.expectRevert(abi.encodeWithSelector(BaseEvolutionHook.PermissionNotDeclared.selector, EvolutionTypes.FLAG_AFTER_TRANSFER));
        noHook.afterTransfer(1, address(0xa), address(0xb));
    }

    function test_onTrigger_revertsWhenFlagAbsent() public {
        vm.expectRevert(abi.encodeWithSelector(BaseEvolutionHook.PermissionNotDeclared.selector, EvolutionTypes.FLAG_ON_TRIGGER));
        noHook.onTrigger(1, bytes32("test"), "");
    }

    // ── Partial-flag combinations ─────────────────────────────────────────

    function test_partialFlags_beforeMintAllowedAfterMintReverts() public {
        // Only BEFORE_MINT declared: that path must succeed, but every other
        // lifecycle method must revert. This locks the "principle of least
        // capability" — a subclass that declares one flag does not silently
        // accept calls to the others.
        bytes4 s = beforeMintHook.beforeMint(1, address(this), "");
        assertEq(s, BaseEvolutionHook.beforeMint.selector);

        vm.expectRevert(abi.encodeWithSelector(BaseEvolutionHook.PermissionNotDeclared.selector, EvolutionTypes.FLAG_AFTER_MINT));
        beforeMintHook.afterMint(1, address(this), "");

        vm.expectRevert(abi.encodeWithSelector(BaseEvolutionHook.PermissionNotDeclared.selector, EvolutionTypes.FLAG_BEFORE_TRANSFER));
        beforeMintHook.beforeTransfer(1, address(0xa), address(0xb));

        vm.expectRevert(abi.encodeWithSelector(BaseEvolutionHook.PermissionNotDeclared.selector, EvolutionTypes.FLAG_ON_TRIGGER));
        beforeMintHook.onTrigger(1, bytes32("x"), "");
    }
}
