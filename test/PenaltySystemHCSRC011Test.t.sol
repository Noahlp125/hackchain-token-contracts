// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { PenaltySystem } from "../src/PenaltySystem.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

contract MockIncentivesPool {
    function deposit(uint256, string calldata) external {}
}

/// @dev Regresiones de HC-SRC-011: una penalizacion bloqueante bloquea con
/// independencia del importe. Si el porcentaje da cero no hay deuda que
/// liquidar, asi que el bloqueo solo lo levanta el enforcer.
contract PenaltySystemHCSRC011Test is Test {
    PenaltySystem penalties;
    HackToken token;
    MockIncentivesPool pool;
    RoleRegistry registry;

    address TREASURY = makeAddr("treasury");
    address USER = makeAddr("user");
    address AFFECTED = makeAddr("affected");

    bytes32 constant ZERO_CASE = keccak256("zero-evidence-case");
    bytes32 constant DEBT_CASE = keccak256("debt-case");

    function setUp() public {
        token = new HackToken(address(this));
        pool = new MockIncentivesPool();
        registry = new RoleRegistry();
        penalties = new PenaltySystem(address(token), address(pool), TREASURY, address(registry));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(penalties));

        token.mintTokens(USER, 10_000 ether);
        vm.prank(USER);
        token.approve(address(penalties), type(uint256).max);
    }

    function test_HCSRC011_EducatorInactivityBlocksWithZeroEvidence() public {
        penalties.applyEducatorInactivityPenalty(ZERO_CASE, USER, 0);

        assertTrue(registry.isBlocked(USER), "zero evidence must still block");
        assertEq(penalties.penaltyDebt(USER), 0, "no debt for zero evidence");
        assertTrue(penalties.manualUnblockRequired(USER), "zero-debt block needs the enforcer");
    }

    function test_HCSRC011_PlagiarismBlocksWithZeroEvidence() public {
        penalties.applyPlagiarismPenalty(ZERO_CASE, USER, AFFECTED, false, 0);

        assertTrue(registry.isBlocked(USER), "zero evidence must still block");
        assertTrue(penalties.manualUnblockRequired(USER), "zero-debt block needs the enforcer");
    }

    function test_HCSRC011_RecruiterInactivityBlocksWithZeroEvidence() public {
        penalties.applyRecruiterInactivityPenalty(ZERO_CASE, USER, 0);

        assertTrue(registry.isBlocked(USER), "zero evidence must still block");
        assertTrue(penalties.manualUnblockRequired(USER), "zero-debt block needs the enforcer");
    }

    /// @dev 19 wei al 5% y 9 wei al 10% redondean a cero, igual que el cero.
    function test_HCSRC011_DustEvidenceBlocksWithoutDebt() public {
        penalties.applyEducatorInactivityPenalty(ZERO_CASE, USER, 19);
        penalties.applyPlagiarismPenalty(keccak256("dust-plagiarism"), USER, AFFECTED, false, 9);

        assertTrue(registry.isBlocked(USER), "dust evidence must still block");
        assertEq(penalties.penaltyDebt(USER), 0, "dust evidence records no debt");
        assertTrue(penalties.manualUnblockRequired(USER), "zero-debt block needs the enforcer");
    }

    /// @dev El caso queda en el historial y consume su caseId, pero no crea
    /// un caso pendiente de pago: no hay nada que settlePenalty() pueda saldar.
    function test_HCSRC011_ZeroAmountCaseIsRecordedButNotSettleable() public {
        penalties.applyEducatorInactivityPenalty(ZERO_CASE, USER, 0);

        PenaltySystem.PenaltyRecord[] memory history = penalties.getPenaltyHistory(USER);
        assertEq(history.length, 1, "the case is in the history");
        assertEq(history[0].amount, 0, "recorded with amount zero");
        assertTrue(history[0].profileBlocked, "recorded as blocking");

        vm.prank(USER);
        vm.expectRevert(PenaltySystem.PenaltyNotFound.selector);
        penalties.settlePenalty(ZERO_CASE);

        vm.expectRevert(PenaltySystem.CaseAlreadyProcessed.selector);
        penalties.applyEducatorInactivityPenalty(ZERO_CASE, USER, 0);
    }

    /// @dev Pagar otro caso con deuda deja la deuda en cero, pero no levanta un
    /// bloqueo que viene de un caso sin deuda.
    function test_HCSRC011_SettlingAnotherCaseDoesNotLiftManualBlock() public {
        penalties.applyEducatorInactivityPenalty(ZERO_CASE, USER, 0);
        penalties.applyRecruiterInactivityPenalty(DEBT_CASE, USER, 1_000 ether);

        vm.prank(USER);
        penalties.settlePenalty(DEBT_CASE);

        assertEq(penalties.penaltyDebt(USER), 0, "debt fully settled");
        assertTrue(registry.isBlocked(USER), "the zero-debt block must survive the settlement");
    }

    /// @dev El enforcer levanta el bloqueo y borra la marca. Despues, el
    /// desbloqueo automatico al pagar vuelve a funcionar con normalidad.
    function test_HCSRC011_EnforcerUnblockClearsTheManualFlag() public {
        penalties.applyEducatorInactivityPenalty(ZERO_CASE, USER, 0);

        penalties.unblockProfile(USER);

        assertFalse(registry.isBlocked(USER), "the enforcer lifts the block");
        assertFalse(penalties.manualUnblockRequired(USER), "the flag is cleared");

        penalties.applyRecruiterInactivityPenalty(DEBT_CASE, USER, 1_000 ether);
        vm.prank(USER);
        penalties.settlePenalty(DEBT_CASE);

        assertFalse(registry.isBlocked(USER), "settling unblocks again once the flag is clear");
    }

    /// @dev Sin bloqueo, una deuda cero no tiene efecto: las tres penalizaciones
    /// que no bloquean siguen rechazando el importe cero.
    function test_HCSRC011_NonBlockingPenaltiesStillRejectZero() public {
        vm.expectRevert(PenaltySystem.AmountMustBeGreaterThanZero.selector);
        penalties.applyIdentityFraudPenalty(ZERO_CASE, USER, 0);

        vm.expectRevert(PenaltySystem.AmountMustBeGreaterThanZero.selector);
        penalties.applyNoShowPenalty(ZERO_CASE, USER, 0);

        vm.expectRevert(PenaltySystem.AmountMustBeGreaterThanZero.selector);
        penalties.applyMassSalePenalty(ZERO_CASE, USER, 0, 0, 0);

        assertFalse(registry.isBlocked(USER), "non-blocking penalties never block");
    }
}
