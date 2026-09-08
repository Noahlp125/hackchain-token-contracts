// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { RecruiterBonuses } from "../src/RecruiterBonuses.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

/// @dev Regresiones de HC-SRC-002 para RecruiterBonuses: un perfil
/// bloqueado no puede reclamar ninguno de los tres bonos (registro,
/// contratacion mensual, KYC).
contract RecruiterBonusesHCSRC002Test is Test {
    RecruiterBonuses bonuses;
    IncentivesPool pool;
    HackToken token;
    RoleRegistry registry;

    address RECRUITER = makeAddr("recruiter");

    function setUp() public {
        token = new HackToken();
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        bonuses = new RecruiterBonuses(address(pool), address(registry));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(bonuses));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));

        token.mintTokens(address(this), 500_000 ether);
        token.approve(address(pool), 500_000 ether);
        pool.fundPool(500_000 ether);

        vm.warp(1_700_000_000); // timestamp realista, evita edge case de mes 0

        bonuses.registerRecruiter(RECRUITER);
    }

    function test_HCSRC002_BlockedProfileCannotClaimRegistrationBonus() public {
        for (uint256 i = 0; i < 7; i++) {
            bonuses.recordActivity(RECRUITER, keccak256(abi.encodePacked("activity", i)));
            vm.warp(block.timestamp + 1 days);
        }

        registry.setBlocked(RECRUITER);

        vm.prank(RECRUITER);
        vm.expectRevert(RecruiterBonuses.ProfileBlocked.selector);
        bonuses.claimRegistrationBonus();
    }

    function test_HCSRC002_BlockedProfileCannotClaimMonthlyHiringBonus() public {
        bonuses.registerHiring(RECRUITER, keccak256("talent-1"));
        bonuses.registerHiring(RECRUITER, keccak256("talent-2"));
        bonuses.registerHiring(RECRUITER, keccak256("talent-3"));
        bonuses.registerHiring(RECRUITER, keccak256("talent-4"));

        registry.setBlocked(RECRUITER);

        vm.prank(RECRUITER);
        vm.expectRevert(RecruiterBonuses.ProfileBlocked.selector);
        bonuses.claimMonthlyHiringBonus();
    }

    function test_HCSRC002_BlockedProfileCannotClaimKycBonus() public {
        bonuses.verifyKyc(RECRUITER);
        registry.setBlocked(RECRUITER);

        vm.prank(RECRUITER);
        vm.expectRevert(RecruiterBonuses.ProfileBlocked.selector);
        bonuses.claimKycBonus();
    }
}
