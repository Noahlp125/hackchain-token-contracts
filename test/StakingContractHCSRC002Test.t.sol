// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakingContract} from "../src/StakingContract.sol";
import {IncentivesPool} from "../src/IncentivesPool.sol";
import {HackToken} from "../src/HackTokenERC20.sol";
import {RoleRegistry} from "../src/RoleRegistry.sol";

/// @dev Regresiones de HC-SRC-002 para StakingContract: un perfil bloqueado
/// en RoleRegistry no puede abrir posiciones nuevas ni reclamar incentivos,
/// pero conserva la salida (retirar principal propio, renunciar a un
/// beneficio) prevista para usuarios sancionados.

contract StakingContractHCSRC002Test is Test {
    StakingContract staking;
    IncentivesPool pool;
    HackToken token;
    RoleRegistry registry;

    address USER = makeAddr("user");

    function setUp() public {
        token = new HackToken();
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        staking = new StakingContract(
            address(token),
            address(pool),
            address(registry)
        );

        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(staking));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));

        token.mintTokens(USER, 300_000 ether);
        vm.prank(USER);
        token.approve(address(staking), 300_000 ether);
    }

    function test_HCSRC002_BlockedProfileCannotOpenNewStake() public {
        registry.setBlocked(USER);
        uint256 oneMonth = staking.ONE_MONTH();

        vm.prank(USER);
        vm.expectRevert(StakingContract.ProfileBlocked.selector);
        staking.stake(1_000 ether, oneMonth);
    }

    function test_HCSRC002_BlockedProfileCannotClaimRewards() public {
        vm.startPrank(USER);
        staking.stake(1_000 ether, staking.ONE_MONTH());
        vm.warp(block.timestamp + 30 days + 1);
        staking.withdrawPrincipal(0);
        vm.stopPrank();

        registry.setBlocked(USER);

        vm.prank(USER);
        vm.expectRevert(StakingContract.ProfileBlocked.selector);
        staking.claimRewards();
    }

    function test_HCSRC002_BlockedProfileCannotActivateNoCommission() public {
        uint256 oneYear = staking.ONE_YEAR();
        vm.prank(USER);
        staking.stake(100_000 ether, oneYear);

        vm.warp(block.timestamp + 365 days + 1);
        registry.setBlocked(USER);

        vm.prank(USER);
        vm.expectRevert(StakingContract.ProfileBlocked.selector);
        staking.activateNoCommission(0);
    }

    /// @dev Exencion explicita: recuperar el principal propio ya vencido
    /// debe seguir funcionando aunque el perfil este bloqueado.
    function test_HCSRC002_BlockedProfileCanStillWithdrawMaturePrincipal()
        public
    {
        uint256 oneMonth = staking.ONE_MONTH();
        vm.prank(USER);
        staking.stake(1_000 ether, oneMonth);

        vm.warp(block.timestamp + 30 days + 1);
        registry.setBlocked(USER);

        vm.prank(USER);
        staking.withdrawPrincipal(0);

        assertEq(
            token.balanceOf(USER),
            300_000 ether,
            "blocked user should still recover own principal"
        );
    }

    /// @dev Exencion explicita: renunciar al beneficio no-commission nunca
    /// deberia bloquearse, con o sin sancion activa.
    function test_HCSRC002_BlockedProfileCanStillDeactivateNoCommission()
        public
    {
        vm.startPrank(USER);
        staking.stake(100_000 ether, staking.ONE_YEAR());
        vm.warp(block.timestamp + 365 days + 1);
        staking.activateNoCommission(0);
        vm.stopPrank();

        registry.setBlocked(USER);

        vm.prank(USER);
        staking.deactivateNoCommission();

        assertFalse(
            staking.hasNoCommission(USER),
            "deactivate should work even while blocked"
        );
    }
}
