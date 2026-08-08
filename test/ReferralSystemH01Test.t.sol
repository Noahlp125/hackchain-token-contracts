// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { ReferralSystem } from "../src/ReferralSystem.sol";
import { StakingContract } from "../src/StakingContract.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";

contract ReferralSystemH01Test is Test {
    ReferralSystem referral;
    StakingContract staking;
    IncentivesPool pool;
    HackToken token;

    address REFERRER = makeAddr("referrer");
    address REFERRED = makeAddr("referred");

    function setUp() public {
        token = new HackToken();
        pool = new IncentivesPool(address(token));
        staking = new StakingContract(address(token), address(pool));
        referral = new ReferralSystem(address(pool), address(staking));

        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(referral));

        token.mintTokens(REFERRED, 10_000 ether);
        vm.prank(REFERRED);
        token.approve(address(staking), 10_000 ether);

        // Financia el pool para poder pagar la recompensa
        token.mintTokens(address(this), 5_000 ether);
        token.approve(address(pool), 5_000 ether);
        pool.fundPool(5_000 ether);
    }

    /// @dev Escenario original de H-01 (PoC de Julian): B stakea, registra
    /// a A como referrer, y valida en el mismo bloque. Antes del fix, A
    /// cobraba de inmediato sin esperar madurez.
    function test_H01_CannotValidateBeforeStakeMaturity() public {
        vm.startPrank(REFERRED);
        staking.stake(1_000 ether, staking.ONE_MONTH());
        referral.registerReferral(REFERRER);

        vm.expectRevert(ReferralSystem.StakeNotMature.selector);
        referral.validateReferral(0);
        vm.stopPrank();
    }

    function test_H01_ValidatesCorrectlyAfterMaturity() public {
        vm.startPrank(REFERRED);
        staking.stake(1_000 ether, staking.ONE_MONTH());
        referral.registerReferral(REFERRER);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(REFERRED);
        referral.validateReferral(0);

        assertTrue(referral.isValidated(REFERRED), "referral was not validated");
        assertEq(token.balanceOf(REFERRER), 1_000 ether, "referrer was not paid");
    }

    /// @dev El referral debe registrarse ANTES del stake, no después.
    /// Evita que alguien stakee primero y "reclame" un referrer a posteriori.
    function test_H01_RejectsReferralRegisteredAfterStake() public {
        vm.startPrank(REFERRED);
        staking.stake(1_000 ether, staking.ONE_MONTH());
        vm.warp(block.timestamp + 1);

        // El referral se registra DESPUÉS del stake — debe rechazarse
        referral.registerReferral(REFERRER);

        vm.warp(block.timestamp + 30 days + 1);

        vm.expectRevert(ReferralSystem.ReferralRegisteredTooLate.selector);
        referral.validateReferral(0);
        vm.stopPrank();
    }

    function test_H01_RejectsStakeBelowMinimum() public {
        vm.startPrank(REFERRED);
        // Justo el mínimo del mecanismo 1 (1000), pero probamos con un
        // stake que no llega al mínimo de referral simulando un valor bajo
        // no es posible aquí porque MIN_STAKE_ONE_MONTH == MIN_STAKE_FOR_REFERRAL,
        // así que probamos con una posición inactiva en su lugar.
        staking.stake(1_000 ether, staking.ONE_MONTH());
        referral.registerReferral(REFERRER);
        vm.warp(block.timestamp + 30 days + 1);
        staking.withdrawPrincipal(0); // la posición queda inactiva

        vm.expectRevert(ReferralSystem.IneligibleStake.selector);
        referral.validateReferral(0);
        vm.stopPrank();
    }

    function test_H01_CannotValidateSameReferralTwice() public {
        vm.startPrank(REFERRED);
        staking.stake(1_000 ether, staking.ONE_MONTH());
        referral.registerReferral(REFERRER);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(REFERRED);
        referral.validateReferral(0);

        vm.prank(REFERRED);
        vm.expectRevert(ReferralSystem.ReferralAlreadyValidated.selector);
        referral.validateReferral(0);
    }
}
