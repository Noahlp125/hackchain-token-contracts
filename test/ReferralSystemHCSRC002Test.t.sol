// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReferralSystem} from "../src/ReferralSystem.sol";
import {StakingContract} from "../src/StakingContract.sol";
import {IncentivesPool} from "../src/IncentivesPool.sol";
import {HackToken} from "../src/HackTokenERC20.sol";
import {RoleRegistry} from "../src/RoleRegistry.sol";

/// @dev Regresiones de HC-SRC-002 para ReferralSystem. registerReferral()
/// se bloquea por quien llama (el referido). validateReferral() se
/// bloquea por el REFERRER, que es quien cobra el incentivo, no por el
/// referido que dispara la llamada.

contract ReferralSystemHCSRC002Test is Test {
    ReferralSystem referral;
    StakingContract staking;
    IncentivesPool pool;
    HackToken token;
    RoleRegistry registry;

    address REFERRER = makeAddr("referrer");
    address REFERRED = makeAddr("referred");

    function setUp() public {
        token = new HackToken();
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        staking = new StakingContract(
            address(token),
            address(pool),
            address(registry)
        );
        referral = new ReferralSystem(
            address(pool),
            address(staking),
            address(registry)
        );

        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(referral));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));

        token.mintTokens(REFERRED, 10_000 ether);
        vm.prank(REFERRED);
        token.approve(address(staking), 10_000 ether);

        token.mintTokens(address(this), 5_000 ether);
        token.approve(address(pool), 5_000 ether);
        pool.fundPool(5_000 ether);
    }

    function test_HCSRC002_BlockedProfileCannotRegisterAsReferred() public {
        registry.setBlocked(REFERRED);

        vm.prank(REFERRED);
        vm.expectRevert(ReferralSystem.ProfileBlocked.selector);
        referral.registerReferral(REFERRER);
    }

    function test_HCSRC002_ValidateRevertsWhenReferrerIsBlocked() public {
        uint256 oneMonth = staking.ONE_MONTH();
        vm.startPrank(REFERRED);
        staking.stake(1_000 ether, oneMonth);
        referral.registerReferral(REFERRER);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days + 1);
        registry.setBlocked(REFERRER);

        vm.prank(REFERRED);
        vm.expectRevert(ReferralSystem.ProfileBlocked.selector);
        referral.validateReferral(0);
    }

    /// @dev Exencion explicita e intencional: el estado de bloqueo del
    /// referido (quien llama) es irrelevante, no recibe nada en esta
    /// funcion. Bloquearlo solo perjudicaria al referrer, que si es quien
    /// cobra y no esta bloqueado en este caso.

    function test_HCSRC002_ValidateSucceedsWhenOnlyReferredIsBlocked() public {
        uint256 oneMonth = staking.ONE_MONTH();
        vm.startPrank(REFERRED);
        staking.stake(1_000 ether, oneMonth);
        referral.registerReferral(REFERRER);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days + 1);
        registry.setBlocked(REFERRED);

        vm.prank(REFERRED);
        referral.validateReferral(0);

        assertEq(
            token.balanceOf(REFERRER),
            1_000 ether,
            "referrer should still be paid"
        );
    }
}
