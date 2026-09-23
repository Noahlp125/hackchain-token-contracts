// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { StakingContract } from "../src/StakingContract.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

contract StakingContractL06Test is Test {
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

        token.mintTokens(address(this), 1_000 ether);
        token.approve(address(pool), 1_000 ether);
        pool.fundPool(1_000 ether);
    }

    function test_L06_PauseBlocksNewStake() public {
        staking.pauseEntrances();
        uint256 oneMonth = staking.ONE_MONTH();

        vm.prank(USER);
        vm.expectRevert();
        staking.stake(1_000 ether, oneMonth);
    }

    function test_L06_PauseDoesNotBlockPrincipalWithdrawal() public {
        uint256 oneMonth = staking.ONE_MONTH();

        vm.prank(USER);
        staking.stake(1_000 ether, oneMonth);

        vm.warp(block.timestamp + 30 days + 1);

        staking.pauseEntrances();

        vm.prank(USER);
        staking.withdrawPrincipal(0);

        assertEq(token.balanceOf(USER), 10_000 ether, "principal was blocked by pause");
    }

    function test_L06_PauseDoesNotBlockClaimRewards() public {
        uint256 oneMonth = staking.ONE_MONTH();

        vm.prank(USER);
        staking.stake(1_000 ether, oneMonth);

        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(USER);
        staking.withdrawPrincipal(0);

        staking.pauseEntrances();

        vm.prank(USER);
        staking.claimRewards();

        assertEq(staking.pendingRewards(USER), 0, "reward claim was blocked by pause");
    }

    function test_L06_UnpauseRestoresNewStaking() public {
        staking.pauseEntrances();
        staking.unpauseEntrances();
        uint256 oneMonth = staking.ONE_MONTH();

        vm.prank(USER);
        staking.stake(1_000 ether, oneMonth);
    }

    function test_L06_RevertsWhenNonEmergencyRoleTriesToPause() public {
        vm.prank(USER);
        vm.expectRevert();
        staking.pauseEntrances();
    }
}
