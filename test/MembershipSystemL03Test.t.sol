// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { MembershipSystem } from "../src/MembershipSystem.sol";
import { HackToken } from "../src/HackTokenERC20.sol";

contract MockIncentivesPool {
    function deposit(uint256, string calldata) external {}
    function distribute(address, uint256, string calldata) external {}
}

contract MembershipSystemL03Test is Test {
    MembershipSystem memberships;
    HackToken token;
    MockIncentivesPool pool;

    address TREASURY = makeAddr("treasury");
    address USER = makeAddr("user");

    function setUp() public {
        token = new HackToken();
        pool = new MockIncentivesPool();

        memberships = new MembershipSystem(address(token), address(pool), TREASURY);

        token.mintTokens(USER, 200_000 ether);
        vm.prank(USER);
        token.approve(address(memberships), 200_000 ether);
    }

    function test_L03_ExpiredMembershipCanBeReactivated() public {
        vm.startPrank(USER);
        memberships.activateAdvancedMembership();

        // Avanzamos más allá de la duración (30 días)
        vm.warp(block.timestamp + 31 days);

        assertFalse(memberships.hasAdvancedMembership(USER), "membership should be expired");

        // Antes del fix esto revertía con MembershipAlreadyActive
        memberships.activateAdvancedMembership();
        vm.stopPrank();

        assertTrue(memberships.hasAdvancedMembership(USER), "reactivation did not work");
    }

    function test_L03_ExpiredMembershipCannotBePenalized() public {
        vm.startPrank(USER);
        memberships.activateAdvancedMembership();

        vm.warp(block.timestamp + 31 days);

        // Antes del fix esto cobraba la penalización de 1,000 HACK indebidamente
        vm.expectRevert(MembershipSystem.MembershipNotActive.selector);
        memberships.cancelAdvancedMembership();
        vm.stopPrank();
    }

    function test_L03_ActiveMembershipCanStillBeCancelledWithPenalty() public {
        vm.startPrank(USER);
        memberships.activateAdvancedMembership();

        uint256 balanceBefore = token.balanceOf(USER);
        memberships.cancelAdvancedMembership();
        vm.stopPrank();

        assertEq(
            balanceBefore - token.balanceOf(USER),
            1_000 ether,
            "cancellation penalty was not charged correctly"
        );
        assertFalse(memberships.hasAdvancedMembership(USER), "membership should be inactive after cancel");
    }
}