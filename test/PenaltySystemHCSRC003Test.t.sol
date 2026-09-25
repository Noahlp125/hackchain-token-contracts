// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { PenaltySystem } from "../src/PenaltySystem.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

contract MockIncentivesPool {
    function deposit(uint256, string calldata) external {}
}

/// @dev Regresiones de HC-SRC-003: las penalizaciones porcentuales usan un
/// balance de evidencia aportado por el enforcer, no balanceOf() en vivo.
/// Mover tokens despues de la infraccion ya no reduce ni evita la sancion.
contract PenaltySystemHCSRC003Test is Test {
    PenaltySystem penalties;
    HackToken token;
    MockIncentivesPool pool;
    RoleRegistry registry;

    address USER = makeAddr("user");
    address ALTERNATE = makeAddr("alternate");

    function setUp() public {
        token = new HackToken();
        pool = new MockIncentivesPool();
        registry = new RoleRegistry();
        penalties = new PenaltySystem(address(token), address(pool), makeAddr("treasury"), address(registry));
        registry.grantRole(registry.REGISTRAR_ROLE(), address(penalties));
    }

    function test_HCSRC003_PenaltyUsesEvidenceAmountAfterUserMovesTokens() public {
        token.mintTokens(USER, 10_000 ether);

        vm.prank(USER);
        token.transfer(ALTERNATE, 10_000 ether);

        assertEq(token.balanceOf(USER), 0, "sanity: live balance is now zero");

        penalties.applyEducatorInactivityPenalty(keccak256("case-evidence"), USER, 10_000 ether);

        assertEq(penalties.penaltyDebt(USER), 500 ether, "penalty must be 5% of the evidence balance, not the live one");
        assertTrue(penalties.isProfileBlocked(USER));
    }

    /// @dev Caso especial de applyMassSalePenalty: holdingsBeforeSale_
    /// sustituye a balanceOf() en las dos comprobaciones de elegibilidad.
    /// El usuario vende y despues vacia también el resto de su saldo, y la
    /// penalizacion se registra igual usando el balance previo a la venta.
    function test_HCSRC003_MassSalePenaltyUsesHoldingsBeforeSaleNotLiveBalance() public {
        uint256 holdingsBeforeSale = 100_000 ether; // 2% de un supply de 5M
        uint256 saleAmount = 70_000 ether; // 70% de holdingsBeforeSale
        uint256 circulatingSupply = 5_000_000 ether;

        token.mintTokens(USER, holdingsBeforeSale);

        vm.startPrank(USER);
        token.transfer(ALTERNATE, saleAmount); // la venta masiva
        token.transfer(ALTERNATE, token.balanceOf(USER)); // vacia el resto
        vm.stopPrank();

        assertEq(token.balanceOf(USER), 0, "sanity: live balance is now zero");

        penalties.applyMassSalePenalty(
            keccak256("case-mass-sale"),
            USER,
            saleAmount,
            holdingsBeforeSale,
            circulatingSupply
        );

        assertEq(penalties.penaltyDebt(USER), 3_500 ether, "penalty must be 5% of saleAmount regardless of live balance");
        assertFalse(penalties.isProfileBlocked(USER), "mass sale does not block the profile, matches existing behaviour");
    }

    function test_HCSRC003_PenaltyCaseIdCannotBeReplayed() public {
        token.mintTokens(USER, 10_000 ether);
        bytes32 caseId = keccak256("case-identity-fraud");

        penalties.applyIdentityFraudPenalty(caseId, USER, 10_000 ether);

        vm.expectRevert(PenaltySystem.CaseAlreadyProcessed.selector);
        penalties.applyIdentityFraudPenalty(caseId, USER, 10_000 ether);
    }
}
