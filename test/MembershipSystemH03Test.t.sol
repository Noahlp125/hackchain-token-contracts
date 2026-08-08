// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { MembershipSystem } from "../src/MembershipSystem.sol";
import { HackToken } from "../src/HackTokenERC20.sol";

/// @dev Mock mínimo de IncentivesPool: solo necesita no revertir en deposit().
contract MockIncentivesPool {
    function deposit(uint256, string calldata) external {}
    function distribute(address, uint256, string calldata) external {}
}

contract MembershipSystemH03Test is Test {
    MembershipSystem memberships;
    HackToken token;
    MockIncentivesPool pool;

    address TREASURY = makeAddr("treasury");
    address EDUCATOR = makeAddr("educator");
    address VIEWER = makeAddr("viewer");

    function setUp() public {
        token = new HackToken();
        pool = new MockIncentivesPool();

        memberships = new MembershipSystem(address(token), address(pool), TREASURY);
        memberships.grantRole(memberships.EDUCATOR_ROLE(), EDUCATOR);

        token.mintTokens(VIEWER, 100_000 ether);
        token.mintTokens(EDUCATOR, 100_000 ether);

        vm.prank(VIEWER);
        token.approve(address(memberships), 100_000 ether);

        vm.prank(EDUCATOR);
        token.approve(address(memberships), 100_000 ether);
    }

    function test_H03_RejectsSelfView() public {
        vm.startPrank(EDUCATOR);
        memberships.activateAcademicMembership(MembershipSystem.AcademicTier.Monthly);

        vm.expectRevert(MembershipSystem.CannotViewOwnContent.selector);
        memberships.registerContentView(EDUCATOR);
        vm.stopPrank();
    }

    function test_H03_RejectsDuplicateViewInSameCycle() public {
        vm.startPrank(VIEWER);
        memberships.activateAcademicMembership(MembershipSystem.AcademicTier.Monthly);
        memberships.registerContentView(EDUCATOR);

        vm.expectRevert(MembershipSystem.ViewAlreadyCounted.selector);
        memberships.registerContentView(EDUCATOR);
        vm.stopPrank();
    }

    function test_H03_AllowsViewAgainAfterCycleAdvances() public {
        vm.startPrank(VIEWER);
        memberships.activateAcademicMembership(MembershipSystem.AcademicTier.Monthly);
        memberships.registerContentView(EDUCATOR);
        vm.stopPrank();

        memberships.advanceCycle();

        vm.prank(VIEWER);
        memberships.registerContentView(EDUCATOR); // no debe revertir

        (uint256 views, ) = memberships.educatorViews(EDUCATOR);
        assertEq(views, 2, "view count did not increase in new cycle");
    }

    function test_H03_EducatorCannotDrainPoolWithSelfViews() public {
        // Confirma que, tras el fix, el escenario original de la PoC de Julian
        // (test_H03_EducatorCanSelfGenerateViewsAndDrainPool) ya no es posible:
        // el educador no puede generar ni una sola vista de sí mismo.
        vm.startPrank(EDUCATOR);
        memberships.activateAcademicMembership(MembershipSystem.AcademicTier.Monthly);

        vm.expectRevert(MembershipSystem.CannotViewOwnContent.selector);
        memberships.registerContentView(EDUCATOR);
        vm.stopPrank();

        (uint256 views, ) = memberships.educatorViews(EDUCATOR);
        assertEq(views, 0, "educator should have zero self-generated views");
    }
}