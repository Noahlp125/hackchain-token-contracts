// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { ReputationBonuses } from "../src/ReputationBonuses.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

/// @dev Regresion de HC-SRC-002 para ReputationBonuses: un perfil
/// bloqueado no puede reclamar el bonus mensual de reputacion, aunque
/// haya sido registrado como ganador.
contract ReputationBonusesHCSRC002Test is Test {
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
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));

        token.mintTokens(address(this), 10_000 ether);
        token.approve(address(pool), 10_000 ether);
        pool.fundPool(10_000 ether);

        vm.warp(1_700_000_000);
    }

    function test_HCSRC002_BlockedWinnerCannotClaimBonus() public {
        reputation.registerWinner(ReputationBonuses.UserRole.Talent, WINNER);
        uint256 month = reputation.getCurrentMonth();

        registry.setBlocked(WINNER);

        vm.prank(WINNER);
        vm.expectRevert(ReputationBonuses.ProfileBlocked.selector);
        reputation.claimBonus(ReputationBonuses.UserRole.Talent, month);
    }
}
