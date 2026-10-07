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
///   2. Una penalizacion bloqueante deja el perfil bloqueado, o revierte.
///      El test documenta el caso en el que no se cumple (HC-SRC-011).
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

    /// @dev HC-SRC-011. Una penalizacion bloqueante deberia dejar el perfil
    /// bloqueado para cualquier evidencia. Por debajo del umbral de redondeo la
    /// llamada revierte y el perfil queda sin bloquear, que es el hallazgo.
    ///
    /// Este test documenta el comportamiento actual: pasa porque afirma lo que
    /// el contrato hace hoy, no lo que deberia hacer. Se invierte cuando se
    /// remedie HC-SRC-011.
    function testFuzz_HCSRC011_LowEvidenceLeavesProfileUnblocked(uint256 evidence_) public {
        evidence_ = bound(evidence_, 0, 19);

        vm.expectRevert(PenaltySystem.AmountMustBeGreaterThanZero.selector);
        penalties.applyEducatorInactivityPenalty(keccak256("case"), USER, evidence_);

        assertFalse(registry.isBlocked(USER), "el perfil queda sin bloquear por debajo del umbral");
    }

    /// @dev Por encima del umbral el bloqueo si ocurre, lo que delimita el
    /// alcance exacto de HC-SRC-011.
    function testFuzz_BlockingPenaltyBlocksAboveTheRoundingThreshold(uint256 evidence_) public {
        evidence_ = bound(evidence_, 20, MAX_SUPPLY);

        penalties.applyEducatorInactivityPenalty(keccak256("case"), USER, evidence_);

        assertTrue(registry.isBlocked(USER), "por encima del umbral el perfil debe quedar bloqueado");
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
