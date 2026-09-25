// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { PenaltySystem } from "../src/PenaltySystem.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

contract MockIncentivesPool {
    function deposit(uint256, string calldata) external {}
}

contract PenaltySystemH04Test is Test {
    PenaltySystem penalties;
    HackToken token;
    MockIncentivesPool pool;
    RoleRegistry registry;

    address TREASURY = makeAddr("treasury");
    address USER = makeAddr("user");
    address EDUCATOR_A = makeAddr("educatorA");
    address EDUCATOR_B = makeAddr("educatorB");

    function setUp() public {
        token = new HackToken();
        pool = new MockIncentivesPool();
        registry = new RoleRegistry();
        penalties = new PenaltySystem(address(token), address(pool), TREASURY, address(registry));
        // PenaltySystem necesita REGISTRAR_ROLE para poder bloquear/desbloquear
        // perfiles en RoleRegistry (HC-SRC-002).
        registry.grantRole(registry.REGISTRAR_ROLE(), address(penalties));

        token.mintTokens(USER, 10_000 ether);
        token.mintTokens(EDUCATOR_A, 10_000 ether);
    }

    /// @dev El escenario original de H-04: el usuario NO ha dado approve.
    /// Antes del fix, esto revertía y el perfil quedaba sin bloquear.
    function test_H04_PenaltyBlocksProfileEvenWithoutAllowance() public {
        bytes32 caseId = keccak256("case-001");

        // Nótese: no hay ningún token.approve() aquí.
        penalties.applyEducatorInactivityPenalty(caseId, USER, 10_000 ether);

        assertTrue(penalties.isProfileBlocked(USER), "profile was not blocked without allowance");
        assertEq(penalties.penaltyDebt(USER), 500 ether, "debt was not recorded (5% of 10,000)");
        assertEq(token.balanceOf(USER), 10_000 ether, "tokens should not move until settlement");
    }

    function test_H04_CaseCannotBeReplayed() public {
        bytes32 caseId = keccak256("case-002");
        penalties.applyEducatorInactivityPenalty(caseId, USER, 10_000 ether);

        vm.expectRevert(PenaltySystem.CaseAlreadyProcessed.selector);
        penalties.applyEducatorInactivityPenalty(caseId, USER, 10_000 ether);
    }

    function test_H04_UserCanSettleDebtAndGetUnblocked() public {
        bytes32 caseId = keccak256("case-003");
        penalties.applyEducatorInactivityPenalty(caseId, USER, 10_000 ether);

        assertTrue(penalties.isProfileBlocked(USER), "profile should be blocked");

        vm.startPrank(USER);
        token.approve(address(penalties), 500 ether);
        penalties.settlePenalty(caseId);
        vm.stopPrank();

        assertFalse(penalties.isProfileBlocked(USER), "profile should be unblocked after settlement");
        assertEq(penalties.penaltyDebt(USER), 0, "debt should be zero after settlement");
        assertEq(token.balanceOf(TREASURY), 0, "educator inactivity goes to pool, not treasury");
    }

    function test_H04_CannotSettleSomeoneElsesCase() public {
        bytes32 caseId = keccak256("case-004");
        penalties.applyEducatorInactivityPenalty(caseId, USER, 10_000 ether);

        vm.startPrank(EDUCATOR_A);
        token.approve(address(penalties), 500 ether);
        vm.expectRevert(PenaltySystem.NotPenaltyOwner.selector);
        penalties.settlePenalty(caseId);
        vm.stopPrank();
    }

    function test_H04_CannotSettleTwice() public {
        bytes32 caseId = keccak256("case-005");
        penalties.applyEducatorInactivityPenalty(caseId, USER, 10_000 ether);

        vm.startPrank(USER);
        token.approve(address(penalties), 1_000 ether);
        penalties.settlePenalty(caseId);

        vm.expectRevert(PenaltySystem.PenaltyAlreadySettled.selector);
        penalties.settlePenalty(caseId);
        vm.stopPrank();
    }

    /// @dev Confirma que múltiples casos acumulan deuda y el perfil sigue
    /// bloqueado hasta liquidar TODOS los casos pendientes.
    function test_H04_MultipleCasesRequireFullSettlementToUnblock() public {
        bytes32 caseId1 = keccak256("case-006a");
        bytes32 caseId2 = keccak256("case-006b");

        penalties.applyEducatorInactivityPenalty(caseId1, USER, 10_000 ether);
        // segunda infracción, aplicada tras la primera
        penalties.applyRecruiterInactivityPenalty(caseId2, USER, 10_000 ether);

        assertEq(penalties.penaltyDebt(USER), 1_000 ether, "expected 500 + 500, both penalties calculated on the same untouched 10,000 balance");

        vm.startPrank(USER);
        token.approve(address(penalties), 1_000 ether);
        penalties.settlePenalty(caseId1);

        assertTrue(penalties.isProfileBlocked(USER), "should still be blocked, one case remains");

        penalties.settlePenalty(caseId2);
        vm.stopPrank();

        assertFalse(penalties.isProfileBlocked(USER), "should be unblocked after settling both cases");
    }

    function test_H04_PlagiarismInternalGoesDirectlyToAffectedEducator() public {
        bytes32 caseId = keccak256("case-007");
        penalties.applyPlagiarismPenalty(caseId, EDUCATOR_A, EDUCATOR_B, false, 10_000 ether);

        vm.startPrank(EDUCATOR_A);
        token.approve(address(penalties), 1_000 ether);
        penalties.settlePenalty(caseId);
        vm.stopPrank();

        assertEq(token.balanceOf(EDUCATOR_B), 1_000 ether, "affected educator did not receive penalty directly");
    }
}