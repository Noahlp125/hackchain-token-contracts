// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { PenaltySystem } from "../src/PenaltySystem.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

contract MockIncentivesPool {
    function deposit(uint256, string calldata) external {}
}

/// @dev Fuzzing de las seis funciones de penalizacion sobre el balance de
/// evidencia. Los tests unitarios de HC-SRC-003 usan valores redondos y grandes
/// (10.000 y 100.000 ether), que nunca se acercan al borde donde el porcentaje
/// redondea a cero. Aqui se recorre el rango entero.
///
/// Propiedades comprobadas:
///   1. La deuda registrada es siempre el porcentaje exacto de la evidencia.
///   2. Una penalizacion bloqueante deja siempre el perfil bloqueado, sea cual
///      sea la evidencia, incluida la que redondea a cero (HC-SRC-011).
contract PenaltySystemFuzzTest is Test {
    PenaltySystem penalties;
    HackToken token;
    MockIncentivesPool pool;
    RoleRegistry registry;

    address USER = makeAddr("user");

    uint256 constant MAX_SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new HackToken(address(this));
        pool = new MockIncentivesPool();
        registry = new RoleRegistry();
        penalties = new PenaltySystem(address(token), address(pool), makeAddr("treasury"), address(registry));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(penalties));
    }

    /// @dev La deuda registrada es exactamente el 5% de la evidencia, sea cual
    /// sea el valor, mientras el porcentaje no redondee a cero.
    function testFuzz_EducatorPenaltyIsAlwaysFivePercentOfEvidence(uint256 evidence_) public {
        evidence_ = bound(evidence_, 20, MAX_SUPPLY);

        penalties.applyEducatorInactivityPenalty(keccak256("case"), USER, evidence_);

        assertEq(
            penalties.penaltyDebt(USER),
            (evidence_ * penalties.EDUCATOR_INACTIVITY_PENALTY_PERCENT()) / 100,
            "la deuda debe ser el porcentaje exacto de la evidencia"
        );
    }

    /// @dev El balance en vivo del infractor no influye en la deuda, que es la
    /// propiedad que HC-SRC-003 vino a establecer.
    function testFuzz_LiveBalanceDoesNotChangeTheDebt(uint256 evidence_, uint256 liveBalance_) public {
        evidence_ = bound(evidence_, 20, MAX_SUPPLY / 2);
        liveBalance_ = bound(liveBalance_, 0, MAX_SUPPLY / 2);

        if (liveBalance_ > 0) {
            token.mintTokens(USER, liveBalance_);
        }

        penalties.applyEducatorInactivityPenalty(keccak256("case"), USER, evidence_);

        assertEq(
            penalties.penaltyDebt(USER),
            (evidence_ * penalties.EDUCATOR_INACTIVITY_PENALTY_PERCENT()) / 100,
            "el balance en vivo no debe influir en la deuda"
        );
    }

    /// @dev HC-SRC-011. Por debajo del umbral de redondeo (20 wei al 5%, 10 wei
    /// al 10%) las tres penalizaciones bloqueantes bloquean igual. Si el
    /// porcentaje da cero no hay deuda y el perfil exige desbloqueo manual.
    function testFuzz_HCSRC011_BlockingPenaltiesBlockBelowRoundingThreshold(
        uint256 evidence_,
        uint8 which_
    ) public {
        evidence_ = bound(evidence_, 0, 19);
        uint256 percent = _applyBlockingPenalty(which_ % 3, evidence_);
        uint256 expectedDebt = (evidence_ * percent) / 100;

        assertTrue(registry.isBlocked(USER), "el perfil debe quedar bloqueado con cualquier evidencia");
        assertEq(penalties.penaltyDebt(USER), expectedDebt, "la deuda es el porcentaje, aunque sea cero");
        assertEq(
            penalties.manualUnblockRequired(USER),
            expectedDebt == 0,
            "solo un caso sin deuda exige desbloqueo manual"
        );
    }

    function _applyBlockingPenalty(uint256 which_, uint256 evidence_) internal returns (uint256 percent) {
        bytes32 caseId = keccak256("case");
        if (which_ == 0) {
            penalties.applyEducatorInactivityPenalty(caseId, USER, evidence_);
            return penalties.EDUCATOR_INACTIVITY_PENALTY_PERCENT();
        }
        if (which_ == 1) {
            penalties.applyPlagiarismPenalty(caseId, USER, makeAddr("affected"), true, evidence_);
            return penalties.PLAGIARISM_PENALTY_PERCENT();
        }
        penalties.applyRecruiterInactivityPenalty(caseId, USER, evidence_);
        return penalties.RECRUITER_INACTIVITY_PENALTY_PERCENT();
    }

    /// @dev Por encima del umbral el bloqueo va con deuda y se levanta pagando,
    /// sin desbloqueo manual. Con el test anterior cubre el rango entero.
    function testFuzz_BlockingPenaltiesBlockAboveTheRoundingThreshold(uint256 evidence_, uint8 which_) public {
        evidence_ = bound(evidence_, 20, MAX_SUPPLY);

        _applyBlockingPenalty(which_ % 3, evidence_);

        assertTrue(registry.isBlocked(USER), "por encima del umbral el perfil debe quedar bloqueado");
        assertFalse(penalties.manualUnblockRequired(USER), "con deuda no hace falta desbloqueo manual");
    }

    /// @dev La penalizacion por venta masiva calcula sobre el importe vendido,
    /// no sobre las tenencias, siempre que se cumplan las dos elegibilidades.
    function testFuzz_MassSalePenaltyIsFivePercentOfSaleAmount(uint256 holdings_, uint256 saleFraction_) public {
        uint256 circulating = 5_000_000 ether;
        holdings_ = bound(holdings_, circulating / 50, circulating / 4);
        saleFraction_ = bound(saleFraction_, 51, 100);
        uint256 saleAmount = (holdings_ * saleFraction_) / 100;

        penalties.applyMassSalePenalty(keccak256("case"), USER, saleAmount, holdings_, circulating);

        assertEq(
            penalties.penaltyDebt(USER),
            (saleAmount * penalties.MASS_SALE_PENALTY_PERCENT()) / 100,
            "la deuda debe ser el porcentaje del importe vendido"
        );
    }
}
