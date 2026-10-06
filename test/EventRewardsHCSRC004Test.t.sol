// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { EventRewards } from "../src/EventRewards.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

/// @dev Regresiones de HC-SRC-004 para EventRewards: los mecanismos 10, 18 y
/// 19 exigen el rol de RoleRegistry que les corresponde. El mecanismo 5
/// (rewardPromoEvent) queda sin guard de rol a proposito.
contract EventRewardsHCSRC004Test is Test {
    EventRewards events;
    IncentivesPool pool;
    HackToken token;
    RoleRegistry registry;

    address TALENT = makeAddr("talent");
    address EDUCATOR = makeAddr("educator");
    address ORGANIZER = makeAddr("organizer");

    function setUp() public {
        token = new HackToken(address(this));
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        events = new EventRewards(address(pool), address(registry));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(events));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));

        token.mintTokens(address(this), 100_000 ether);
        token.approve(address(pool), 100_000 ether);
        pool.fundPool(100_000 ether);
    }

    function test_HCSRC004_RegisterTalentAttendanceRevertsForUnregisteredTalent() public {
        vm.expectRevert(EventRewards.NotTalent.selector);
        events.registerTalentAttendance(TALENT);
    }

    function test_HCSRC004_RevokedTalentCannotClaimAttendanceReward() public {
        registry.registerRole(TALENT, RoleRegistry.BusinessRole.Talent);
        for (uint256 i = 0; i < 4; i++) {
            events.registerTalentAttendance(TALENT);
        }

        registry.revokeRole(TALENT, RoleRegistry.BusinessRole.Talent);

        vm.prank(TALENT);
        vm.expectRevert(EventRewards.NotTalent.selector);
        events.claimTalentAttendanceReward();
    }

    function test_HCSRC004_RewardEducatorFirstEventRevertsForUnregisteredEducator() public {
        vm.expectRevert(EventRewards.NotEducator.selector);
        events.rewardEducatorFirstEvent(EDUCATOR);
    }

    function test_HCSRC004_RegisterEducatorEventRevertsForUnregisteredEducator() public {
        vm.expectRevert(EventRewards.NotEducator.selector);
        events.registerEducatorEvent(EDUCATOR);
    }

    function test_HCSRC004_RevokedEducatorCannotClaimMonthlyReward() public {
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);
        for (uint256 i = 0; i < 4; i++) {
            events.registerEducatorEvent(EDUCATOR);
        }

        registry.revokeRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);

        vm.prank(EDUCATOR);
        vm.expectRevert(EventRewards.NotEducator.selector);
        events.claimEducatorMonthlyReward();
    }

    /// @dev Caso positivo: con el rol registrado, los tres mecanismos siguen
    /// pagando con normalidad.
    function test_HCSRC004_RegisteredRolesCanStillClaim() public {
        registry.registerRole(TALENT, RoleRegistry.BusinessRole.Talent);
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);

        for (uint256 i = 0; i < 4; i++) {
            events.registerTalentAttendance(TALENT);
            events.registerEducatorEvent(EDUCATOR);
        }
        events.rewardEducatorFirstEvent(EDUCATOR);

        vm.prank(TALENT);
        events.claimTalentAttendanceReward();
        vm.prank(EDUCATOR);
        events.claimEducatorMonthlyReward();

        assertEq(token.balanceOf(TALENT), events.TALENT_ATTENDANCE_REWARD());
        assertEq(
            token.balanceOf(EDUCATOR),
            events.EDUCATOR_FIRST_EVENT_REWARD() + events.EDUCATOR_MONTHLY_EVENTS_REWARD()
        );
    }

    /// @dev Exencion explicita: el organizador de un evento promocional no
    /// necesita ningun rol de negocio en RoleRegistry.
    function test_HCSRC004_PromoEventOrganizerNeedsNoBusinessRole() public {
        events.rewardPromoEvent(ORGANIZER, keccak256("promo-event"), 10);

        assertEq(token.balanceOf(ORGANIZER), events.PROMO_EVENT_REWARD());
    }
}
