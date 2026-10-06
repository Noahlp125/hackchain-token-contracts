// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { RecruiterBonuses } from "../src/RecruiterBonuses.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

/// @dev Regresiones de HC-SRC-004 para RecruiterBonuses: ademas del alta
/// local (isRegistered), todo el flujo exige RoleRegistry.isRecruiter(), asi
/// que revocar el rol en RoleRegistry corta la actividad en este modulo.
contract RecruiterBonusesHCSRC004Test is Test {
    RecruiterBonuses bonuses;
    IncentivesPool pool;
    HackToken token;
    RoleRegistry registry;

    address RECRUITER = makeAddr("recruiter");

    function setUp() public {
        token = new HackToken(address(this));
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        bonuses = new RecruiterBonuses(address(pool), address(registry));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(bonuses));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));

        token.mintTokens(address(this), 500_000 ether);
        token.approve(address(pool), 500_000 ether);
        pool.fundPool(500_000 ether);

        vm.warp(1_700_000_000); // timestamp realista, evita edge case de mes 0
    }

    function _registerAndRevoke() internal {
        registry.registerRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);
        bonuses.registerRecruiter(RECRUITER);
        registry.revokeRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);
    }

    function test_HCSRC004_RegisterRecruiterRevertsWithoutRegistryRole() public {
        vm.expectRevert(RecruiterBonuses.NotRecruiter.selector);
        bonuses.registerRecruiter(RECRUITER);
    }

    /// @dev Sigue con isRegistered == true, pero el rol global fue revocado:
    /// el enforcer ya no puede acumularle actividad, contrataciones ni KYC.
    function test_HCSRC004_RevokedRecruiterCannotAccumulateActivity() public {
        _registerAndRevoke();
        assertTrue(bonuses.isRegistered(RECRUITER));

        vm.expectRevert(RecruiterBonuses.NotRecruiter.selector);
        bonuses.recordActivity(RECRUITER, keccak256("activity"));

        vm.expectRevert(RecruiterBonuses.NotRecruiter.selector);
        bonuses.registerHiring(RECRUITER, keccak256("talent"));

        vm.expectRevert(RecruiterBonuses.NotRecruiter.selector);
        bonuses.verifyKyc(RECRUITER);
    }

    function test_HCSRC004_RevokedRecruiterCannotClaimRegistrationBonus() public {
        registry.registerRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);
        bonuses.registerRecruiter(RECRUITER);
        for (uint256 i = 0; i < 7; i++) {
            bonuses.recordActivity(RECRUITER, keccak256(abi.encode("activity", i)));
            vm.warp(block.timestamp + 1 days);
        }

        registry.revokeRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);

        vm.prank(RECRUITER);
        vm.expectRevert(RecruiterBonuses.NotRecruiter.selector);
        bonuses.claimRegistrationBonus();
    }

    function test_HCSRC004_RevokedRecruiterCannotClaimMonthlyHiringBonus() public {
        registry.registerRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);
        bonuses.registerRecruiter(RECRUITER);
        for (uint256 i = 0; i < 4; i++) {
            bonuses.registerHiring(RECRUITER, keccak256(abi.encode("talent", i)));
        }

        registry.revokeRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);

        vm.prank(RECRUITER);
        vm.expectRevert(RecruiterBonuses.NotRecruiter.selector);
        bonuses.claimMonthlyHiringBonus();
    }

    function test_HCSRC004_RevokedRecruiterCannotClaimKycBonus() public {
        registry.registerRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);
        bonuses.registerRecruiter(RECRUITER);
        bonuses.verifyKyc(RECRUITER);

        registry.revokeRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);

        vm.prank(RECRUITER);
        vm.expectRevert(RecruiterBonuses.NotRecruiter.selector);
        bonuses.claimKycBonus();
    }

    function test_HCSRC004_RecruiterWithRoleCanStillClaimKycBonus() public {
        registry.registerRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);
        bonuses.registerRecruiter(RECRUITER);
        bonuses.verifyKyc(RECRUITER);

        vm.prank(RECRUITER);
        bonuses.claimKycBonus();

        assertEq(token.balanceOf(RECRUITER), bonuses.KYC_BONUS());
    }
}
