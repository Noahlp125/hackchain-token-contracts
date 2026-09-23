// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { EducatorBonuses } from "../src/EducatorBonuses.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

/// @dev Regresiones de HC-SRC-002 para EducatorBonuses: un perfil
/// bloqueado no puede reclamar el bonus de certificados legacy ni el de
/// los primeros 10 talentos activos.
contract EducatorBonusesHCSRC002Test is Test {
    EducatorBonuses bonuses;
    IncentivesPool pool;
    HackToken token;
    RoleRegistry registry;

    address EDUCATOR = makeAddr("educator");

    function setUp() public {
        token = new HackToken();
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        bonuses = new EducatorBonuses(address(pool), address(registry));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(bonuses));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));

        token.mintTokens(address(this), 20_000 ether);
        token.approve(address(pool), 20_000 ether);
        pool.fundPool(20_000 ether);
    }

    function test_HCSRC002_BlockedProfileCannotClaimLegacyCertsBonus() public {
        for (uint256 i = 0; i < 10; i++) {
            bonuses.registerLegacyCert(EDUCATOR, address(uint160(i + 1000)));
        }

        registry.setBlocked(EDUCATOR);

        vm.prank(EDUCATOR);
        vm.expectRevert(EducatorBonuses.ProfileBlocked.selector);
        bonuses.claimLegacyCertsBonus();
    }

    function test_HCSRC002_BlockedProfileCannotClaimFirstTalentsBonus() public {
        for (uint256 i = 0; i < 10; i++) {
            bonuses.registerActiveTalent(EDUCATOR, address(uint160(i + 2000)));
        }

        registry.setBlocked(EDUCATOR);

        vm.prank(EDUCATOR);
        vm.expectRevert(EducatorBonuses.ProfileBlocked.selector);
        bonuses.claimFirstTalentsBonus();
    }
}
