// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { StakingContract } from "../src/StakingContract.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

contract StakingContractM02Test is Test {
    StakingContract staking;
    IncentivesPool pool;
    HackToken token;
    RoleRegistry registry;

    address USER = makeAddr("user");

    function setUp() public {
        token = new HackToken();
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        staking = new StakingContract(address(token), address(pool), address(registry));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(staking));

        token.mintTokens(USER, 300_000 ether);
        vm.prank(USER);
        token.approve(address(staking), 300_000 ether);
    }

    /// @dev Escenario original de M-02: activar inmediatamente sin
    /// esperar los 365 dias. Antes del fix esto funcionaba sin problema.
    function test_M02_CannotActivateBeforeOneYearMatures() public {
        vm.startPrank(USER);
        staking.stake(100_000 ether, staking.ONE_YEAR());

        vm.expectRevert(StakingContract.NoCommissionStakeNotMature.selector);
        staking.activateNoCommission(0);
        vm.stopPrank();
    }

    function test_M02_ActivatesCorrectlyAfterMaturity() public {
        vm.startPrank(USER);
        staking.stake(100_000 ether, staking.ONE_YEAR());
        vm.warp(block.timestamp + 365 days + 1);

        staking.activateNoCommission(0);
        vm.stopPrank();

        assertTrue(staking.hasNoCommission(USER), "benefit should be active after maturity");
    }

    function test_M02_RevertsWhenAmountBelowThreshold() public {
        vm.startPrank(USER);
        staking.stake(10_000 ether, staking.ONE_YEAR()); // por debajo de 100,000
        vm.warp(block.timestamp + 365 days + 1);

        vm.expectRevert(StakingContract.IneligibleStakeForNoCommission.selector);
        staking.activateNoCommission(0);
        vm.stopPrank();
    }

    /// @dev Confirma el fix del "stale benefit": si la posicion que
    /// respalda el beneficio se retira, hasNoCommission() debe reflejar
    /// false de inmediato, incluso si la bandera interna sigue en true.
    function test_M02_BenefitBecomesFalseAfterQualifyingStakeWithdrawn() public {
        vm.startPrank(USER);
        staking.stake(100_000 ether, staking.ONE_YEAR());
        staking.stake(1_000 ether, staking.ONE_MONTH()); // segunda posicion, menor

        vm.warp(block.timestamp + 365 days + 1);
        staking.activateNoCommission(0);

        assertTrue(staking.hasNoCommission(USER), "should be active before withdrawal");

        staking.withdrawPrincipal(0); // retira la posicion que respaldaba el beneficio

        assertFalse(staking.hasNoCommission(USER), "benefit should not survive after backing stake is withdrawn");
        vm.stopPrank();
    }

    function test_M02_RevertsWhenAlreadyActive() public {
        vm.startPrank(USER);
        staking.stake(100_000 ether, staking.ONE_YEAR());
        vm.warp(block.timestamp + 365 days + 1);
        staking.activateNoCommission(0);

        vm.expectRevert(StakingContract.NoCommissionAlreadyActive.selector);
        staking.activateNoCommission(0);
        vm.stopPrank();
    }
}
