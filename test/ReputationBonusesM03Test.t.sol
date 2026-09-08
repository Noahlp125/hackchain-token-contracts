// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { ReputationBonuses } from "../src/ReputationBonuses.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

contract ReputationBonusesM03Test is Test {
    ReputationBonuses reputation;
    IncentivesPool pool;
    HackToken token;
    RoleRegistry registry;

    address WINNER = makeAddr("winner");

    function setUp() public {
        token = new HackToken();
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        reputation = new ReputationBonuses(address(pool), address(registry));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(reputation));

        token.mintTokens(address(this), 10_000 ether);
        token.approve(address(pool), 10_000 ether);
        pool.fundPool(10_000 ether);

        // Parte de un timestamp realista (no 0/1) para evitar el edge
        // case donde currentMonth == 0 coincide con el valor por defecto
        // de lastRegisteredMonth, causando un falso WinnerAlreadyRegistered.
        vm.warp(1_700_000_000);
    }

    /// @dev Escenario original de M-03 (PoC de Julian): el ganador se
    /// registra un dia antes del cambio de epoca de 30 dias, y reclama
    /// dos dias despues (dentro de la ventana de 3 dias, pero ya en el
    /// mes "siguiente"). Antes del fix, esto revertia con
    /// NoBonusForThisMonth aunque la ventana seguia abierta.
    function test_M03_ClaimWorksAcrossEpochBoundary() public {
        uint256 epoch = 30 days;
        vm.warp((100 * epoch) + epoch - 1 days); // un dia antes del cambio de epoca

        reputation.registerWinner(ReputationBonuses.UserRole.Talent, WINNER);
        uint256 registeredMonth = reputation.getCurrentMonth();

        vm.warp(block.timestamp + 2 days); // cruza a la siguiente epoca

        vm.prank(WINNER);
        reputation.claimBonus(ReputationBonuses.UserRole.Talent, registeredMonth);

        assertEq(token.balanceOf(WINNER), 5_000 ether, "winner was not paid across epoch boundary");
    }

    function test_M03_ExpiredBonusStillReverts() public {
        reputation.registerWinner(ReputationBonuses.UserRole.Talent, WINNER);
        uint256 month = reputation.getCurrentMonth();

        vm.warp(block.timestamp + 3 days + 1);

        vm.prank(WINNER);
        vm.expectRevert(ReputationBonuses.ClaimWindowExpired.selector);
        reputation.claimBonus(ReputationBonuses.UserRole.Talent, month);
    }

    function test_M03_BonusCannotBeClaimedTwice() public {
        reputation.registerWinner(ReputationBonuses.UserRole.Talent, WINNER);
        uint256 month = reputation.getCurrentMonth();

        vm.startPrank(WINNER);
        reputation.claimBonus(ReputationBonuses.UserRole.Talent, month);

        vm.expectRevert(ReputationBonuses.AlreadyClaimed.selector);
        reputation.claimBonus(ReputationBonuses.UserRole.Talent, month);
        vm.stopPrank();
    }

    function test_M03_RevertsWhenCallerIsNotTheWinner() public {
        reputation.registerWinner(ReputationBonuses.UserRole.Talent, WINNER);
        uint256 month = reputation.getCurrentMonth();

        address impostor = makeAddr("impostor");
        vm.prank(impostor);
        vm.expectRevert(ReputationBonuses.NotTheWinner.selector);
        reputation.claimBonus(ReputationBonuses.UserRole.Talent, month);
    }
}
