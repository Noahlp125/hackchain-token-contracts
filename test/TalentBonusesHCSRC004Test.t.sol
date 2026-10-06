// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { TalentBonuses } from "../src/TalentBonuses.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";

/// @dev Regresiones de HC-SRC-004 para TalentBonuses: los mecanismos 4 y 11
/// pagan solo a direcciones registradas como Talento en RoleRegistry.
contract TalentBonusesHCSRC004Test is Test {
    TalentBonuses bonuses;
    RoleRegistry registry;
    IncentivesPool pool;
    HackToken token;

    address TALENT = makeAddr("talent");

    bytes32 constant DEGREE_ID = keccak256("hcsrc004-degree");

    function setUp() public {
        token = new HackToken(address(this));
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));

        bonuses = new TalentBonuses(address(token), address(pool), address(registry));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(bonuses));

        token.mintTokens(address(this), 100_000 ether);
        token.approve(address(pool), 100_000 ether);
        pool.fundPool(100_000 ether);

        // Con timestamp 1, currentMonth == 0 coincide con el valor por
        // defecto de lastHiringRewardMonth y da un falso HiringAlreadyRewardedThisMonth.
        vm.warp(1_700_000_000);
    }

    function test_HCSRC004_SchoolingDegreeRevertsForUnregisteredTalent() public {
        vm.expectRevert(TalentBonuses.NotTalent.selector);
        bonuses.rewardSchoolingDegree(TALENT, DEGREE_ID);
    }

    function test_HCSRC004_TalentHiredRevertsForRevokedTalent() public {
        registry.registerRole(TALENT, RoleRegistry.BusinessRole.Talent);
        registry.revokeRole(TALENT, RoleRegistry.BusinessRole.Talent);

        vm.expectRevert(TalentBonuses.NotTalent.selector);
        bonuses.rewardTalentHired(TALENT);
    }

    function test_HCSRC004_RegisteredTalentStillReceivesBothBonuses() public {
        registry.registerRole(TALENT, RoleRegistry.BusinessRole.Talent);

        bonuses.rewardSchoolingDegree(TALENT, DEGREE_ID);
        bonuses.rewardTalentHired(TALENT);

        assertEq(
            token.balanceOf(TALENT),
            bonuses.SCHOOLING_DEGREE_REWARD() + bonuses.TALENT_HIRED_REWARD()
        );
    }
}
