// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { EducatorBonuses } from "../src/EducatorBonuses.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

/// @dev Regresiones de HC-SRC-004 para EducatorBonuses: las 6 funciones que
/// registran o pagan un bono de educador exigen RoleRegistry.isEducator()
/// sobre el educador en cuestion, en vez de confiar por completo en que
/// ENFORCER_ROLE mande la address correcta.
contract EducatorBonusesHCSRC004Test is Test {
    EducatorBonuses bonuses;
    IncentivesPool pool;
    HackToken token;
    RoleRegistry registry;

    address EDUCATOR = makeAddr("educator");
    address TALENT = makeAddr("talent");

    function setUp() public {
        token = new HackToken(address(this));
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        bonuses = new EducatorBonuses(address(pool), address(registry));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(bonuses));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));

        token.mintTokens(address(this), 200_000 ether);
        token.approve(address(pool), 200_000 ether);
        pool.fundPool(200_000 ether);
    }

    function test_HCSRC004_RewardApiIntegrationRevertsForUnregisteredEducator() public {
        vm.expectRevert(EducatorBonuses.NotEducator.selector);
        bonuses.rewardApiIntegration(EDUCATOR);
    }

    function test_HCSRC004_RegisterLegacyCertRevertsForUnregisteredEducator() public {
        vm.expectRevert(EducatorBonuses.NotEducator.selector);
        bonuses.registerLegacyCert(EDUCATOR, TALENT);
    }

    function test_HCSRC004_RegisterActiveTalentRevertsForUnregisteredEducator() public {
        vm.expectRevert(EducatorBonuses.NotEducator.selector);
        bonuses.registerActiveTalent(EDUCATOR, TALENT);
    }

    function test_HCSRC004_RewardTalentHiredRevertsForUnregisteredEducator() public {
        vm.expectRevert(EducatorBonuses.NotEducator.selector);
        bonuses.rewardTalentHired(EDUCATOR, TALENT);
    }

    function test_HCSRC004_RevokedEducatorCannotClaimLegacyCertsBonus() public {
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);
        for (uint256 i = 0; i < 10; i++) {
            bonuses.registerLegacyCert(EDUCATOR, address(uint160(i + 1000)));
        }

        registry.revokeRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);

        vm.prank(EDUCATOR);
        vm.expectRevert(EducatorBonuses.NotEducator.selector);
        bonuses.claimLegacyCertsBonus();
    }

    function test_HCSRC004_RevokedEducatorCannotClaimFirstTalentsBonus() public {
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);
        for (uint256 i = 0; i < 10; i++) {
            bonuses.registerActiveTalent(EDUCATOR, address(uint160(i + 2000)));
        }

        registry.revokeRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);

        vm.prank(EDUCATOR);
        vm.expectRevert(EducatorBonuses.NotEducator.selector);
        bonuses.claimFirstTalentsBonus();
    }

    /// @dev Caso positivo: un educador registrado en RoleRegistry sigue
    /// recibiendo con normalidad los 3 bonos pagados directamente por el
    /// enforcer.
    function test_HCSRC004_RegisteredEducatorCanStillReceiveDirectBonuses() public {
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);

        bonuses.rewardApiIntegration(EDUCATOR);
        bonuses.rewardTalentHired(EDUCATOR, TALENT);

        assertEq(token.balanceOf(EDUCATOR), bonuses.API_INTEGRATION_REWARD() + bonuses.TALENT_HIRED_REWARD());
    }
}
