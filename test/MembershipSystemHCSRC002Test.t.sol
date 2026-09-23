// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { MembershipSystem } from "../src/MembershipSystem.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

contract MockIncentivesPool {
    function deposit(uint256, string calldata) external {}
    function distribute(address, uint256, string calldata) external {}
}

/// @dev Regresiones de HC-SRC-002 para MembershipSystem: un perfil
/// bloqueado no puede activar/renovar membresias, registrar vistas ni
/// reclamar recompensas de educador. cancelAdvancedMembership() queda
/// exenta a proposito (salida + pago de penalizacion).
contract MembershipSystemHCSRC002Test is Test {
    MembershipSystem memberships;
    HackToken token;
    MockIncentivesPool pool;
    RoleRegistry registry;

    address TREASURY = makeAddr("treasury");
    address EDUCATOR = makeAddr("educator");
    address USER = makeAddr("user");

    function setUp() public {
        token = new HackToken();
        pool = new MockIncentivesPool();
        registry = new RoleRegistry();
        memberships = new MembershipSystem(address(token), address(pool), TREASURY, address(registry));
        memberships.grantRole(memberships.EDUCATOR_ROLE(), EDUCATOR);
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));

        token.mintTokens(USER, 400_000 ether);
        vm.prank(USER);
        token.approve(address(memberships), 400_000 ether);

        token.mintTokens(EDUCATOR, 400_000 ether);
        vm.prank(EDUCATOR);
        token.approve(address(memberships), 400_000 ether);
    }

    function test_HCSRC002_BlockedProfileCannotActivateAdvancedMembership() public {
        registry.setBlocked(USER);

        vm.prank(USER);
        vm.expectRevert(MembershipSystem.ProfileBlocked.selector);
        memberships.activateAdvancedMembership();
    }

    function test_HCSRC002_BlockedProfileCannotRenewAdvancedMembership() public {
        vm.prank(USER);
        memberships.activateAdvancedMembership();

        registry.setBlocked(USER);

        vm.prank(USER);
        vm.expectRevert(MembershipSystem.ProfileBlocked.selector);
        memberships.renewAdvancedMembership();
    }

    function test_HCSRC002_BlockedProfileCannotActivateAcademicMembership() public {
        registry.setBlocked(USER);

        vm.prank(USER);
        vm.expectRevert(MembershipSystem.ProfileBlocked.selector);
        memberships.activateAcademicMembership(MembershipSystem.AcademicTier.Monthly);
    }

    function test_HCSRC002_BlockedProfileCannotRegisterContentView() public {
        vm.prank(USER);
        memberships.activateAcademicMembership(MembershipSystem.AcademicTier.Monthly);

        registry.setBlocked(USER);

        vm.prank(USER);
        vm.expectRevert(MembershipSystem.ProfileBlocked.selector);
        memberships.registerContentView(EDUCATOR);
    }

    function test_HCSRC002_BlockedEducatorCannotClaimRewards() public {
        vm.startPrank(USER);
        memberships.activateAcademicMembership(MembershipSystem.AcademicTier.Monthly);
        memberships.registerContentView(EDUCATOR);
        vm.stopPrank();

        registry.setBlocked(EDUCATOR);

        vm.prank(EDUCATOR);
        vm.expectRevert(MembershipSystem.ProfileBlocked.selector);
        memberships.claimEducatorRewards();
    }

    /// @dev Exencion explicita: cancelar la membresia avanzada es salida +
    /// pago de penalizacion, no reclamacion de incentivo, asi que debe
    /// seguir funcionando aunque el perfil este bloqueado.
    function test_HCSRC002_BlockedProfileCanStillCancelAdvancedMembership() public {
        vm.prank(USER);
        memberships.activateAdvancedMembership();

        registry.setBlocked(USER);

        uint256 balanceBefore = token.balanceOf(USER);
        vm.prank(USER);
        memberships.cancelAdvancedMembership();

        assertEq(balanceBefore - token.balanceOf(USER), 1_000 ether, "cancellation penalty should still apply");
        assertFalse(memberships.hasAdvancedMembership(USER), "membership should be inactive after cancel");
    }
}
