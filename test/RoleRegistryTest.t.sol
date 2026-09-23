// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

contract RoleRegistryTest is Test {
    RoleRegistry registry;

    address EDUCATOR = makeAddr("educator");
    address TALENT = makeAddr("talent");
    address RECRUITER = makeAddr("recruiter");
    address STRANGER = makeAddr("stranger");

    function setUp() public {
        registry = new RoleRegistry();
        // El deployer (address(this)) ya tiene DEFAULT_ADMIN_ROLE por el
        // constructor. Le concedemos REGISTRAR_ROLE para poder registrar
        // roles de negocio directamente en los tests.
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));
    }

    function test_RegistersEducatorCorrectly() public {
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);

        assertTrue(registry.isEducator(EDUCATOR), "educator was not registered");
        assertFalse(registry.isTalent(EDUCATOR), "educator should not be talent");
        assertGt(
            registry.registeredAt(EDUCATOR, RoleRegistry.BusinessRole.Educator),
            0,
            "registeredAt was not set"
        );
    }

    function test_RegistersMultipleRolesForSameAddress() public {
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Talent);

        assertTrue(registry.isEducator(EDUCATOR), "educator role missing");
        assertTrue(registry.isTalent(EDUCATOR), "talent role missing");
    }

    function test_RevertsWhenRegisteringSameRoleTwice() public {
        registry.registerRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);

        vm.expectRevert(RoleRegistry.AlreadyRegistered.selector);
        registry.registerRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);
    }

    function test_RevokesRoleCorrectly() public {
        registry.registerRole(TALENT, RoleRegistry.BusinessRole.Talent);
        assertTrue(registry.isTalent(TALENT), "talent was not registered");

        registry.revokeRole(TALENT, RoleRegistry.BusinessRole.Talent);
        assertFalse(registry.isTalent(TALENT), "talent role was not revoked");
    }

    function test_RevertsWhenRevokingUnregisteredRole() public {
        vm.expectRevert(RoleRegistry.NotRegistered.selector);
        registry.revokeRole(STRANGER, RoleRegistry.BusinessRole.Educator);
    }

    function test_RevertsWhenCalledWithoutRegistrarRole() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        registry.registerRole(STRANGER, RoleRegistry.BusinessRole.Talent);
    }

    function test_RevertsOnZeroAddress() public {
        vm.expectRevert(RoleRegistry.InvalidAddress.selector);
        registry.registerRole(address(0), RoleRegistry.BusinessRole.Educator);
    }

    // --- HC-SRC-002: bloqueo de perfil ---

    function test_BlocksProfileCorrectly() public {
        registry.setBlocked(STRANGER);

        assertTrue(registry.isBlocked(STRANGER), "profile was not blocked");
    }

    function test_UnblocksProfileCorrectly() public {
        registry.setBlocked(STRANGER);
        registry.setUnblocked(STRANGER);

        assertFalse(registry.isBlocked(STRANGER), "profile was not unblocked");
    }

    function test_RevertsWhenBlockingAlreadyBlockedProfile() public {
        registry.setBlocked(STRANGER);

        vm.expectRevert(RoleRegistry.AlreadyBlocked.selector);
        registry.setBlocked(STRANGER);
    }

    function test_RevertsWhenUnblockingProfileThatIsNotBlocked() public {
        vm.expectRevert(RoleRegistry.NotBlocked.selector);
        registry.setUnblocked(STRANGER);
    }

    function test_RevertsWhenBlockingZeroAddress() public {
        vm.expectRevert(RoleRegistry.InvalidAddress.selector);
        registry.setBlocked(address(0));
    }

    function test_RevertsWhenBlockingWithoutRegistrarRole() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        registry.setBlocked(TALENT);
    }

    function test_BusinessRolesAreIndependentFromBlockedStatus() public {
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);
        registry.setBlocked(EDUCATOR);

        assertTrue(registry.isEducator(EDUCATOR), "blocking should not revoke business roles");
        assertTrue(registry.isBlocked(EDUCATOR), "profile should be blocked");
    }
}