// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { EventRewards } from "../src/EventRewards.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

/// @dev Regresiones de HC-SRC-002 para EventRewards: un perfil bloqueado
/// no puede reclamar el incentivo de asistencia mensual (talento) ni el
/// de eventos mensuales (educador).
contract EventRewardsHCSRC002Test is Test {
    EventRewards events;
    IncentivesPool pool;
    HackToken token;
    RoleRegistry registry;

    address TALENT = makeAddr("talent");
    address EDUCATOR = makeAddr("educator");

    function setUp() public {
        token = new HackToken();
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        events = new EventRewards(address(pool), address(registry));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(events));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));

        token.mintTokens(address(this), 20_000 ether);
        token.approve(address(pool), 20_000 ether);
        pool.fundPool(20_000 ether);
    }

    function test_HCSRC002_BlockedTalentCannotClaimAttendanceReward() public {
        for (uint256 i = 0; i < 4; i++) {
            events.registerTalentAttendance(TALENT);
        }

        registry.setBlocked(TALENT);

        vm.prank(TALENT);
        vm.expectRevert(EventRewards.ProfileBlocked.selector);
        events.claimTalentAttendanceReward();
    }

    function test_HCSRC002_BlockedEducatorCannotClaimMonthlyReward() public {
        for (uint256 i = 0; i < 4; i++) {
            events.registerEducatorEvent(EDUCATOR);
        }

        registry.setBlocked(EDUCATOR);

        vm.prank(EDUCATOR);
        vm.expectRevert(EventRewards.ProfileBlocked.selector);
        events.claimEducatorMonthlyReward();
    }
}
