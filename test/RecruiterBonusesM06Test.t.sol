// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { RecruiterBonuses } from "../src/RecruiterBonuses.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";

contract RecruiterBonusesM06Test is Test {
    RecruiterBonuses bonuses;
    IncentivesPool pool;
    HackToken token;

    address RECRUITER = makeAddr("recruiter");
    address STRANGER = makeAddr("stranger");

    function setUp() public {
        token = new HackToken();
        pool = new IncentivesPool(address(token));
        bonuses = new RecruiterBonuses(address(pool));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(bonuses));

        token.mintTokens(address(this), 500_000 ether);
        token.approve(address(pool), 500_000 ether);
        pool.fundPool(500_000 ether);

        vm.warp(1_700_000_000); // timestamp realista, evita edge case de mes 0
    }

    /// @dev Escenario original de M-06: una wallet SIN registrar recibe
    /// verificacion KYC. Antes del fix esto era posible.
    function test_M06_KycRequiresRegisteredRecruiter() public {
        vm.expectRevert(RecruiterBonuses.NotRegistered.selector);
        bonuses.verifyKyc(STRANGER);
    }

    /// @dev Escenario original: esperar 7 dias sin ninguna actividad
    /// verificada y cobrar de todas formas. Antes del fix solo se medía
    /// tiempo transcurrido.
    function test_M06_NoBonusForElapsedTimeWithoutActivity() public {
        bonuses.registerRecruiter(RECRUITER);

        vm.warp(block.timestamp + 8 days); // paso el tiempo, pero sin actividad

        vm.prank(RECRUITER);
        vm.expectRevert(RecruiterBonuses.MinActiveDaysNotReached.selector);
        bonuses.claimRegistrationBonus();
    }

    function test_M06_ClaimsCorrectlyAfterSevenVerifiedDays() public {
        bonuses.registerRecruiter(RECRUITER);

        for (uint256 i = 0; i < 7; i++) {
            bonuses.recordActivity(RECRUITER, keccak256(abi.encodePacked("activity", i)));
            vm.warp(block.timestamp + 1 days);
        }

        vm.prank(RECRUITER);
        bonuses.claimRegistrationBonus();

        assertEq(token.balanceOf(RECRUITER), 50_000 ether, "registration bonus not paid");
    }

    /// @dev Multiples actividades el MISMO dia solo cuentan como un dia unico.
    function test_M06_DuplicateActivityOnSameDayDoesNotIncreaseDays() public {
        bonuses.registerRecruiter(RECRUITER);

        bonuses.recordActivity(RECRUITER, keccak256("activity-1"));
        bonuses.recordActivity(RECRUITER, keccak256("activity-2")); // mismo dia

        assertEq(bonuses.uniqueActiveDays(RECRUITER), 1, "same-day activity counted twice");
    }

    function test_M06_ActivityIdCannotBeReplayed() public {
        bonuses.registerRecruiter(RECRUITER);
        bytes32 activityId = keccak256("activity-1");

        bonuses.recordActivity(RECRUITER, activityId);

        vm.expectRevert(RecruiterBonuses.ActivityAlreadyProcessed.selector);
        bonuses.recordActivity(RECRUITER, activityId);
    }

    /// @dev Escenario de Pol: registerHiring() con el mismo talento
    /// repetido no debe inflar el contador mensual.
    function test_M06_SameTalentCannotBeCountedTwiceInSameMonth() public {
        bonuses.registerRecruiter(RECRUITER);
        bytes32 talentId = keccak256("talent-1");

        bonuses.registerHiring(RECRUITER, talentId);

        vm.expectRevert(RecruiterBonuses.TalentAlreadyCountedThisMonth.selector);
        bonuses.registerHiring(RECRUITER, talentId);
    }

    function test_M06_DifferentTalentsCountTowardsMonthlyBonus() public {
        bonuses.registerRecruiter(RECRUITER);

        bonuses.registerHiring(RECRUITER, keccak256("talent-1"));
        bonuses.registerHiring(RECRUITER, keccak256("talent-2"));
        bonuses.registerHiring(RECRUITER, keccak256("talent-3"));
        bonuses.registerHiring(RECRUITER, keccak256("talent-4"));

        vm.prank(RECRUITER);
        bonuses.claimMonthlyHiringBonus();

        assertEq(token.balanceOf(RECRUITER), 40_000 ether, "monthly hiring bonus not paid");
    }
}
