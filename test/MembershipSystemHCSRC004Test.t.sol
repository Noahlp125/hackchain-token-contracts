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

/// @dev Regresiones de HC-SRC-004 para MembershipSystem: RoleRegistry pasa
/// a ser la unica fuente de verdad para el rol de Educador, sustituyendo
/// al EDUCATOR_ROLE local que podia desincronizarse de RoleRegistry.
contract MembershipSystemHCSRC004Test is Test {
    MembershipSystem memberships;
    HackToken token;
    MockIncentivesPool pool;
    RoleRegistry registry;

    address TREASURY = makeAddr("treasury");
    address EDUCATOR = makeAddr("educator");
    address VIEWER = makeAddr("viewer");

    function setUp() public {
        token = new HackToken(address(this));
        pool = new MockIncentivesPool();
        registry = new RoleRegistry();
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));

        memberships = new MembershipSystem(address(token), address(pool), TREASURY, address(registry));

        token.mintTokens(VIEWER, 100_000 ether);
        vm.prank(VIEWER);
        token.approve(address(memberships), 100_000 ether);
    }

    function test_HCSRC004_UnregisteredEducatorCannotBeViewed() public {
        vm.startPrank(VIEWER);
        memberships.activateAcademicMembership(MembershipSystem.AcademicTier.Monthly);

        vm.expectRevert(MembershipSystem.NotEducator.selector);
        memberships.registerContentView(EDUCATOR);
        vm.stopPrank();
    }

    function test_HCSRC004_RevokedEducatorCannotClaimRewards() public {
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);

        vm.startPrank(VIEWER);
        memberships.activateAcademicMembership(MembershipSystem.AcademicTier.Monthly);
        memberships.registerContentView(EDUCATOR);
        vm.stopPrank();

        registry.revokeRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);

        vm.prank(EDUCATOR);
        vm.expectRevert(MembershipSystem.NotEducator.selector);
        memberships.claimEducatorRewards();
    }

    /// @dev Caso positivo: un educador registrado en RoleRegistry sigue
    /// pudiendo recibir vistas y reclamar su recompensa con normalidad.
    function test_HCSRC004_RegisteredEducatorCanClaimRewards() public {
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);

        vm.startPrank(VIEWER);
        memberships.activateAcademicMembership(MembershipSystem.AcademicTier.Monthly);
        memberships.registerContentView(EDUCATOR);
        vm.stopPrank();

        vm.prank(EDUCATOR);
        memberships.claimEducatorRewards();

        (uint256 views, uint256 pendingRewards) = memberships.educatorViews(EDUCATOR);
        assertEq(views, 0, "views should reset after claim");
        assertGt(pendingRewards, 0, "educator should have received a reward");
    }
}
