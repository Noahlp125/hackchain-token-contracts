// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

/// @dev Regresiones de HC-SRC-012 para RoleRegistry: el bloqueo se guarda por
/// origen. Cada REGISTRAR pone y quita solo el suyo, y el perfil sigue
/// bloqueado mientras quede alguno.
contract RoleRegistryHCSRC012Test is Test {
    RoleRegistry registry;

    address OPERATOR_A = makeAddr("operatorA");
    address OPERATOR_B = makeAddr("operatorB");
    address USER = makeAddr("user");

    function setUp() public {
        registry = new RoleRegistry();
        bytes32 registrar = registry.REGISTRAR_ROLE();
        registry.grantRole(registrar, OPERATOR_A);
        registry.grantRole(registrar, OPERATOR_B);
    }

    function test_HCSRC012_ProfileStaysBlockedUntilEverySourceLifts() public {
        vm.prank(OPERATOR_A);
        registry.setBlocked(USER);
        vm.prank(OPERATOR_B);
        registry.setBlocked(USER);

        vm.prank(OPERATOR_A);
        registry.setUnblocked(USER);
        assertTrue(registry.isBlocked(USER), "B still holds its block");

        vm.prank(OPERATOR_B);
        registry.setUnblocked(USER);
        assertFalse(registry.isBlocked(USER), "no source left");
    }

    function test_HCSRC012_RegistrarCannotLiftAnotherSourcesBlock() public {
        vm.prank(OPERATOR_B);
        registry.setBlocked(USER);

        vm.prank(OPERATOR_A);
        vm.expectRevert(RoleRegistry.NotBlocked.selector);
        registry.setUnblocked(USER);

        assertTrue(registry.isBlocked(USER), "B's block must survive A's attempt");
    }

    function test_HCSRC012_IsBlockedByReportsEachSource() public {
        vm.prank(OPERATOR_A);
        registry.setBlocked(USER);

        assertTrue(registry.isBlockedBy(USER, OPERATOR_A));
        assertFalse(registry.isBlockedBy(USER, OPERATOR_B));
        assertEq(registry.blockCount(USER), 1);
    }

    /// @dev Un origen que ya no puede quitar su bloqueo (llave perdida o
    /// rotada) no deja el perfil bloqueado para siempre.
    function test_HCSRC012_AdminCanLiftAnOrphanedSource() public {
        vm.prank(OPERATOR_B);
        registry.setBlocked(USER);

        vm.expectEmit(true, true, true, false);
        emit RoleRegistry.BlockLiftedByAdmin(USER, OPERATOR_B, address(this));
        registry.adminUnblock(USER, OPERATOR_B);

        assertFalse(registry.isBlocked(USER), "the admin lifts the orphaned block");
    }

    function test_HCSRC012_AdminUnblockRevertsWhenSourceHoldsNoBlock() public {
        vm.prank(OPERATOR_A);
        registry.setBlocked(USER);

        vm.expectRevert(RoleRegistry.NotBlocked.selector);
        registry.adminUnblock(USER, OPERATOR_B);
    }

    function test_HCSRC012_OnlyTheAdminCanUseAdminUnblock() public {
        vm.prank(OPERATOR_B);
        registry.setBlocked(USER);
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();

        vm.prank(OPERATOR_A);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OPERATOR_A, adminRole)
        );
        registry.adminUnblock(USER, OPERATOR_B);
    }

    function test_HCSRC012_EventsCarryTheSource() public {
        vm.expectEmit(true, true, false, false);
        emit RoleRegistry.ProfileBlocked(USER, OPERATOR_A);
        vm.prank(OPERATOR_A);
        registry.setBlocked(USER);

        vm.expectEmit(true, true, false, false);
        emit RoleRegistry.ProfileUnblocked(USER, OPERATOR_A);
        vm.prank(OPERATOR_A);
        registry.setUnblocked(USER);
    }
}
