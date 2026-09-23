// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { TalentBonuses } from "../src/TalentBonuses.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";

/// @dev Regresiones de HC-SRC-002 para TalentBonuses: un sponsor
/// bloqueado no puede financiar proyectos nuevos, pero conserva el
/// reembolso de su propia contribucion tras vencer el plazo.
contract TalentBonusesHCSRC002Test is Test {
    TalentBonuses bonuses;
    RoleRegistry registry;
    IncentivesPool pool;
    HackToken token;

    address EDUCATOR = makeAddr("educator");

    bytes32 constant PROJECT_ID = keccak256("hcsrc002-project");

    function setUp() public {
        token = new HackToken();
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);

        bonuses = new TalentBonuses(address(token), address(pool), address(registry));

        token.mintTokens(EDUCATOR, 200_000 ether);
        vm.prank(EDUCATOR);
        token.approve(address(bonuses), 200_000 ether);
    }

    function test_HCSRC002_BlockedProfileCannotFundProject() public {
        registry.setBlocked(EDUCATOR);

        vm.prank(EDUCATOR);
        vm.expectRevert(TalentBonuses.ProfileBlocked.selector);
        bonuses.fundProject(PROJECT_ID, 1_000 ether);
    }

    /// @dev Exencion explicita: recuperar la propia contribucion tras
    /// vencer el plazo de financiacion no es reclamar un incentivo.
    function test_HCSRC002_BlockedProfileCanStillRefundContribution() public {
        vm.prank(EDUCATOR);
        bonuses.fundProject(PROJECT_ID, 1_000 ether);

        vm.warp(block.timestamp + 90 days + 1);
        registry.setBlocked(EDUCATOR);

        uint256 balanceBefore = token.balanceOf(EDUCATOR);
        vm.prank(EDUCATOR);
        bonuses.refundContribution(PROJECT_ID);

        assertEq(token.balanceOf(EDUCATOR) - balanceBefore, 1_000 ether, "blocked sponsor should still get refunded");
    }
}
