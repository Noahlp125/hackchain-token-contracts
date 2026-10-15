// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { PenaltySystem } from "../src/PenaltySystem.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

contract MockIncentivesPool {
    function deposit(uint256, string calldata) external {}
}

/// @dev Regresiones de HC-SRC-012 para PenaltySystem: pone y quita solo su
/// propio bloqueo en RoleRegistry. Liquidar deuda ya no levanta un bloqueo
/// puesto por otro escritor.
contract PenaltySystemHCSRC012Test is Test {
    PenaltySystem penalties;
    HackToken token;
    MockIncentivesPool pool;
    RoleRegistry registry;

    address TREASURY = makeAddr("treasury");
    address OPERATOR = makeAddr("operator");
    address USER = makeAddr("user");

    bytes32 constant FRAUD_CASE = keccak256("identity-fraud");
    bytes32 constant BLOCKING_CASE = keccak256("blocking-case");

    function setUp() public {
        token = new HackToken(address(this));
        pool = new MockIncentivesPool();
        registry = new RoleRegistry();
        penalties = new PenaltySystem(address(token), address(pool), TREASURY, address(registry));
        bytes32 registrar = registry.REGISTRAR_ROLE();
        registry.grantRole(registrar, address(penalties));
        registry.grantRole(registrar, OPERATOR);

        token.mintTokens(USER, 10_000 ether);
        vm.prank(USER);
        token.approve(address(penalties), type(uint256).max);
    }

    /// @dev El escenario del PoC, invertido: el fraude de identidad no bloquea,
    /// un operador bloquea a mano, y pagar la deuda ya no levanta ese bloqueo.
    function test_HCSRC012_ManualBlockSurvivesSettlement() public {
        penalties.applyIdentityFraudPenalty(FRAUD_CASE, USER, 1_000 ether);
        vm.prank(OPERATOR);
        registry.setBlocked(USER);

        vm.prank(USER);
        penalties.settlePenalty(FRAUD_CASE);

        assertEq(penalties.penaltyDebt(USER), 0, "debt settled");
        assertTrue(registry.isBlocked(USER), "the operator's block must survive the settlement");
    }

    function test_HCSRC012_PenaltyBlockIsStillLiftedOnSettlement() public {
        penalties.applyEducatorInactivityPenalty(BLOCKING_CASE, USER, 1_000 ether);

        vm.prank(USER);
        penalties.settlePenalty(BLOCKING_CASE);

        assertFalse(registry.isBlocked(USER), "the penalty's own block is lifted when the debt is paid");
    }

    /// @dev Si el perfil ya estaba bloqueado a mano, PenaltySystem anade su
    /// propio bloqueo. Quitar el manual no deja la deuda sin bloqueo.
    function test_HCSRC012_PenaltyAddsItsOwnBlockOverAManualOne() public {
        vm.prank(OPERATOR);
        registry.setBlocked(USER);

        penalties.applyEducatorInactivityPenalty(BLOCKING_CASE, USER, 1_000 ether);
        assertTrue(registry.isBlockedBy(USER, address(penalties)), "PenaltySystem holds its own block");

        vm.prank(OPERATOR);
        registry.setUnblocked(USER);
        assertTrue(registry.isBlocked(USER), "the debt keeps the profile blocked");

        vm.prank(USER);
        penalties.settlePenalty(BLOCKING_CASE);
        assertFalse(registry.isBlocked(USER), "no block left once the debt is paid");
    }

    function test_HCSRC012_UnblockProfileOnlyLiftsPenaltySystemsBlock() public {
        vm.prank(OPERATOR);
        registry.setBlocked(USER);
        penalties.applyEducatorInactivityPenalty(BLOCKING_CASE, USER, 0);

        penalties.unblockProfile(USER);

        assertFalse(registry.isBlockedBy(USER, address(penalties)), "the enforcer lifts the penalty block");
        assertTrue(registry.isBlocked(USER), "the operator's block stays");
    }

    function test_HCSRC012_UnblockProfileRevertsWithoutItsOwnBlock() public {
        vm.prank(OPERATOR);
        registry.setBlocked(USER);

        vm.expectRevert(PenaltySystem.ProfileNotBlocked.selector);
        penalties.unblockProfile(USER);
    }

    /// @dev Riesgo residual de HC-SRC-011: si el bloqueo de PenaltySystem
    /// desaparece por otra via, la marca de desbloqueo manual no debe quedar
    /// colgando sobre el siguiente caso.
    function test_HCSRC012_ManualFlagDoesNotOutliveTheBlockItDescribes() public {
        penalties.applyEducatorInactivityPenalty(keccak256("zero-case"), USER, 0);
        assertTrue(penalties.manualUnblockRequired(USER));

        registry.adminUnblock(USER, address(penalties));

        penalties.applyRecruiterInactivityPenalty(BLOCKING_CASE, USER, 1_000 ether);
        assertFalse(penalties.manualUnblockRequired(USER), "a fresh block starts without the old flag");

        vm.prank(USER);
        penalties.settlePenalty(BLOCKING_CASE);
        assertFalse(registry.isBlocked(USER), "settling lifts the fresh block");
    }
}
