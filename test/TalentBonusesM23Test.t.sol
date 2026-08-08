// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { TalentBonuses } from "../src/TalentBonuses.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";

contract TalentBonusesM23Test is Test {
    TalentBonuses bonuses;
    RoleRegistry registry;
    IncentivesPool pool;
    HackToken token;

    address EDUCATOR = makeAddr("educator");
    address RECRUITER = makeAddr("recruiter");
    address STRANGER = makeAddr("stranger");
    address TALENT = makeAddr("talent");

    bytes32 constant PROJECT_ID = keccak256("project-1");

    function setUp() public {
        token = new HackToken();
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);
        registry.registerRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);

        bonuses = new TalentBonuses(address(token), address(pool), address(registry));

        token.mintTokens(EDUCATOR, 200_000 ether);
        token.mintTokens(RECRUITER, 200_000 ether);
        token.mintTokens(STRANGER, 200_000 ether);

        vm.prank(EDUCATOR);
        token.approve(address(bonuses), 200_000 ether);
        vm.prank(RECRUITER);
        token.approve(address(bonuses), 200_000 ether);
        vm.prank(STRANGER);
        token.approve(address(bonuses), 200_000 ether);
    }

    function test_RevertsWhenProjectIdIsZero() public {
        vm.prank(EDUCATOR);
        vm.expectRevert(TalentBonuses.InvalidProjectId.selector);
        bonuses.fundProject(bytes32(0), 1_000 ether);
    }

    function test_RevertsWhenSponsorIsNotEducatorOrRecruiter() public {
        vm.prank(STRANGER);
        vm.expectRevert(TalentBonuses.UnauthorizedSponsor.selector);
        bonuses.fundProject(PROJECT_ID, 1_000 ether);
    }

    /// @dev Confirma el fix de L-05: dos sponsors distintos financian el
    /// mismo proyecto y AMBAS contribuciones quedan registradas por
    /// separado, sin que una sobrescriba a la otra.
    function test_MultipleSponsorsRetainSeparateContributions() public {
        vm.prank(EDUCATOR);
        bonuses.fundProject(PROJECT_ID, 1_000 ether);

        vm.prank(RECRUITER);
        bonuses.fundProject(PROJECT_ID, 1_000 ether);

        assertEq(bonuses.contribution(PROJECT_ID, EDUCATOR), 1_000 ether, "educator contribution lost");
        assertEq(bonuses.contribution(PROJECT_ID, RECRUITER), 1_000 ether, "recruiter contribution lost");

        (uint256 funded, , , ) = bonuses.getProjectFunding(PROJECT_ID);
        assertEq(funded, 2_000 ether, "total funded mismatch");
    }

    /// @dev Confirma que un sponsor no puede figurar como talento
    /// receptor de su propio proyecto financiado.
    function test_SponsorCannotReceiveDistributionFromOwnProject() public {
        vm.prank(EDUCATOR);
        bonuses.fundProject(PROJECT_ID, 1_000 ether);

        address[] memory talents = new address[](1);
        talents[0] = EDUCATOR; // el propio sponsor
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500 ether;

        vm.expectRevert(TalentBonuses.TalentCannotBeSponsor.selector);
        bonuses.distributeToTalents(PROJECT_ID, talents, amounts);
    }

    function test_DistributesCorrectlyToLegitimateTalent() public {
        vm.prank(EDUCATOR);
        bonuses.fundProject(PROJECT_ID, 1_000 ether);

        address[] memory talents = new address[](1);
        talents[0] = TALENT;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000 ether;

        bonuses.distributeToTalents(PROJECT_ID, talents, amounts);

        assertEq(token.balanceOf(TALENT), 1_000 ether, "talent was not paid");
    }

    /// @dev Confirma el refund tras vencer el deadline sin distribuir.
    function test_RefundAfterDeadlineWithNoDistribution() public {
        vm.prank(EDUCATOR);
        bonuses.fundProject(PROJECT_ID, 1_000 ether);

        vm.warp(block.timestamp + 90 days + 1);

        uint256 balanceBefore = token.balanceOf(EDUCATOR);
        vm.prank(EDUCATOR);
        bonuses.refundContribution(PROJECT_ID);

        assertEq(token.balanceOf(EDUCATOR) - balanceBefore, 1_000 ether, "refund amount mismatch");
    }

    function test_RevertsRefundBeforeDeadline() public {
        vm.prank(EDUCATOR);
        bonuses.fundProject(PROJECT_ID, 1_000 ether);

        vm.prank(EDUCATOR);
        vm.expectRevert(TalentBonuses.FundingWindowStillOpen.selector);
        bonuses.refundContribution(PROJECT_ID);
    }

    function test_RevertsDoubleRefund() public {
        vm.prank(EDUCATOR);
        bonuses.fundProject(PROJECT_ID, 1_000 ether);

        vm.warp(block.timestamp + 90 days + 1);

        vm.startPrank(EDUCATOR);
        bonuses.refundContribution(PROJECT_ID);

        vm.expectRevert(TalentBonuses.AlreadyRefunded.selector);
        bonuses.refundContribution(PROJECT_ID);
        vm.stopPrank();
    }

    /// @dev Refund proporcional: si parte del proyecto ya se distribuyo,
    /// el sponsor solo recupera la parte no distribuida.
    function test_PartialRefundAfterPartialDistribution() public {
        vm.prank(EDUCATOR);
        bonuses.fundProject(PROJECT_ID, 1_000 ether);

        address[] memory talents = new address[](1);
        talents[0] = TALENT;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 400 ether;
        bonuses.distributeToTalents(PROJECT_ID, talents, amounts);

        vm.warp(block.timestamp + 90 days + 1);

        uint256 balanceBefore = token.balanceOf(EDUCATOR);
        vm.prank(EDUCATOR);
        bonuses.refundContribution(PROJECT_ID);

        assertEq(token.balanceOf(EDUCATOR) - balanceBefore, 600 ether, "partial refund mismatch");
    }

    function test_RevertsFundingAfterWindowClosed() public {
        vm.prank(EDUCATOR);
        bonuses.fundProject(PROJECT_ID, 1_000 ether);

        vm.warp(block.timestamp + 90 days + 1);

        vm.prank(RECRUITER);
        vm.expectRevert(TalentBonuses.FundingWindowClosed.selector);
        bonuses.fundProject(PROJECT_ID, 1_000 ether);
    }
}
