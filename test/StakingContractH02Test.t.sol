// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { StakingContract } from "../src/StakingContract.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

contract StakingContractH02Test is Test {
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

        token.mintTokens(USER, 10_000 ether);
        vm.prank(USER);
        token.approve(address(staking), 10_000 ether);
    }

    /// @dev Escenario original de H-02: el pool está vacío cuando el
    /// usuario intenta retirar. Antes del fix, unstake() revertía
    /// completamente y el usuario ni siquiera recuperaba su principal.
    function test_H02_PrincipalIsReturnedEvenWhenPoolIsEmpty() public {
        vm.startPrank(USER);
        staking.stake(1_000 ether, staking.ONE_MONTH());
        vm.warp(block.timestamp + 30 days + 1);

        // El pool está vacío — antes esto habría revertido todo.
        staking.withdrawPrincipal(0);
        vm.stopPrank();

        assertEq(token.balanceOf(USER), 10_000 ether, "principal was not returned");
        assertEq(staking.pendingRewards(USER), 50 ether, "reward was not accrued as debt");
    }

    function test_H02_RewardCanBeClaimedLaterWhenPoolHasLiquidity() public {
        vm.startPrank(USER);
        staking.stake(1_000 ether, staking.ONE_MONTH());
        vm.warp(block.timestamp + 30 days + 1);
        staking.withdrawPrincipal(0);
        vm.stopPrank();

        // Ahora se financia el pool
        token.mintTokens(address(this), 100 ether);
        token.approve(address(pool), 100 ether);
        pool.fundPool(100 ether);

        vm.prank(USER);
        staking.claimRewards();

        assertEq(token.balanceOf(USER), 10_050 ether, "reward was not paid out");
        assertEq(staking.pendingRewards(USER), 0, "pending rewards should be zero after claim");
    }

    function test_H02_CannotWithdrawPrincipalTwice() public {
        vm.startPrank(USER);
        staking.stake(1_000 ether, staking.ONE_MONTH());
        vm.warp(block.timestamp + 30 days + 1);
        staking.withdrawPrincipal(0);

        vm.expectRevert(StakingContract.StakeAlreadyInactive.selector);
        staking.withdrawPrincipal(0);
        vm.stopPrank();
    }

    function test_H02_RevertsWhenClaimingWithNoPendingRewards() public {
        vm.prank(USER);
        vm.expectRevert(StakingContract.NoPendingRewards.selector);
        staking.claimRewards();
    }

    function test_H02_CannotWithdrawBeforeMaturity() public {
        vm.startPrank(USER);
        staking.stake(1_000 ether, staking.ONE_MONTH());

        vm.expectRevert(StakingContract.StakingPeriodNotOver.selector);
        staking.withdrawPrincipal(0);
        vm.stopPrank();
    }
}
