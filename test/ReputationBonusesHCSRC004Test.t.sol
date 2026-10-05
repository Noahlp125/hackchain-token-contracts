// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { ReputationBonuses } from "../src/ReputationBonuses.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

/// @dev Regresiones de HC-SRC-004 para ReputationBonuses: el ganador debe
/// tener en RoleRegistry el rol por el que gana, tanto al registrarse como
/// al reclamar.
contract ReputationBonusesHCSRC004Test is Test {
    ReputationBonuses reputation;
    IncentivesPool pool;
    HackToken token;
    RoleRegistry registry;

    address TALENT = makeAddr("talent");
    address EDUCATOR = makeAddr("educator");
    address RECRUITER = makeAddr("recruiter");

    function setUp() public {
        token = new HackToken(address(this));
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        reputation = new ReputationBonuses(address(pool), address(registry));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(reputation));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));

        token.mintTokens(address(this), 20_000 ether);
        token.approve(address(pool), 20_000 ether);
        pool.fundPool(20_000 ether);

        // Evita el caso borde de currentMonth == 0 (ver ReputationBonusesM03Test).
        vm.warp(1_700_000_000);
    }

    function test_HCSRC004_RegisterWinnerRevertsWithoutBusinessRole() public {
        vm.expectRevert(ReputationBonuses.MissingBusinessRole.selector);
        reputation.registerWinner(ReputationBonuses.UserRole.Talent, TALENT);
    }

    /// @dev UserRole y RoleRegistry.BusinessRole tienen distinto orden. Cada
    /// rol se cruza con los otros dos: tener un rol distinto del que se
    /// premia no basta, y el rol correcto si.
    function test_HCSRC004_EachRoleIsCheckedAgainstItsOwnRegistryRole() public {
        registry.registerRole(TALENT, RoleRegistry.BusinessRole.Talent);
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);
        registry.registerRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);

        vm.expectRevert(ReputationBonuses.MissingBusinessRole.selector);
        reputation.registerWinner(ReputationBonuses.UserRole.Talent, EDUCATOR);
        vm.expectRevert(ReputationBonuses.MissingBusinessRole.selector);
        reputation.registerWinner(ReputationBonuses.UserRole.Educator, TALENT);
        vm.expectRevert(ReputationBonuses.MissingBusinessRole.selector);
        reputation.registerWinner(ReputationBonuses.UserRole.Recruiter, EDUCATOR);

        reputation.registerWinner(ReputationBonuses.UserRole.Talent, TALENT);
        reputation.registerWinner(ReputationBonuses.UserRole.Educator, EDUCATOR);
        reputation.registerWinner(ReputationBonuses.UserRole.Recruiter, RECRUITER);

        uint256 month = reputation.getCurrentMonth();
        assertEq(reputation.getMonthlyBonus(ReputationBonuses.UserRole.Talent, month).winner, TALENT);
        assertEq(reputation.getMonthlyBonus(ReputationBonuses.UserRole.Educator, month).winner, EDUCATOR);
        assertEq(reputation.getMonthlyBonus(ReputationBonuses.UserRole.Recruiter, month).winner, RECRUITER);
    }

    /// @dev El rol se revoca dentro de la ventana de 3 dias, entre el
    /// registro del ganador y el claim.
    function test_HCSRC004_WinnerRevokedBeforeClaimCannotClaim() public {
        registry.registerRole(TALENT, RoleRegistry.BusinessRole.Talent);
        reputation.registerWinner(ReputationBonuses.UserRole.Talent, TALENT);
        uint256 month = reputation.getCurrentMonth();

        registry.revokeRole(TALENT, RoleRegistry.BusinessRole.Talent);

        vm.prank(TALENT);
        vm.expectRevert(ReputationBonuses.MissingBusinessRole.selector);
        reputation.claimBonus(ReputationBonuses.UserRole.Talent, month);
    }

    function test_HCSRC004_WinnerWithRoleCanClaim() public {
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);
        reputation.registerWinner(ReputationBonuses.UserRole.Educator, EDUCATOR);
        uint256 month = reputation.getCurrentMonth();

        vm.prank(EDUCATOR);
        reputation.claimBonus(ReputationBonuses.UserRole.Educator, month);

        assertEq(token.balanceOf(EDUCATOR), reputation.REPUTATION_BONUS());
    }
}
