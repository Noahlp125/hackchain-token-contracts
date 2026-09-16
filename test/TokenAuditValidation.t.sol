// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HackToken} from "../src/HackTokenERC20.sol";

/// @dev Mapa de la auditoria externa de Itish (30/08/2026) sobre HackTokenERC20.sol: una
/// prueba por hallazgo reproducible. Cada una nace como PoC que reproduce el comportamiento
/// vulnerable del contrato auditado, y se convierte en regresion dentro del commit que
/// arregla su hallazgo. La prueba de la vulnerabilidad queda en el historial de git.
///
/// El encabezado de cada test dice en que estado esta: SIN CORREGIR si sigue demostrando la
/// vulnerabilidad, CORREGIDO si ya comprueba la propiedad segura.
///
/// La bateria de regresion completa de cada hallazgo vive en su propio fichero,
/// TokenHCTKNXXXTest.t.sol.
///
/// Cobertura: HC-TKN-001 a HC-TKN-005. Los hallazgos HC-TKN-006 a HC-TKN-010 son estilo,
/// documentacion, indexado y gas: no son reproducibles como PoC.

contract TokenAuditValidation is Test {
    HackToken token;

    address HOLDER = makeAddr("holder");
    address BURNER = makeAddr("burner");
    address ATTACKER = makeAddr("attacker");
    address NEW_OWNER = makeAddr("new-owner");

    function setUp() public {
        token = new HackToken();
    }

    /// @dev HC-TKN-001 (ALTO, CORREGIDO): el PoC original concedia BURNER_ROLE a una
    /// direccion cualquiera y esta vaciaba el saldo de un tercero con burn(from_, amount_).
    /// Tras adoptar ERC20Burnable ese camino no existe: no hay BURNER_ROLE, y la unica via
    /// para quemar el saldo de otro es burnFrom(), que exige allowance previo del titular.
    /// Resultado esperado ahora: sin aprobacion del titular, la quema revierte.
    function testCannotBurnAnotherHoldersBalanceWithoutAllowance() public {
        token.mintTokens(HOLDER, 10_000 ether);

        assertEq(
            token.allowance(HOLDER, BURNER),
            0,
            "sanity: the caller holds no allowance"
        );

        vm.prank(BURNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                BURNER,
                0,
                10_000 ether
            )
        );
        token.burnFrom(HOLDER, 10_000 ether);

        assertEq(
            token.balanceOf(HOLDER),
            10_000 ether,
            "the holder balance must survive a burn attempt without consent"
        );
    }

    /// @dev HC-TKN-002 (ALTO): transferOwnershipCustom() mueve solo el slot de Ownable.
    /// DEFAULT_ADMIN_ROLE se concede una unica vez en el constructor y la cesion de
    /// propiedad no lo toca, asi que quien despliega conserva todo el poder real.
    /// Resultado esperado actual: tras ceder la propiedad, el deployer sigue pudiendo
    /// conceder MINTER_ROLE y emitir a traves de un tercero.
    function testDeployerKeepsAdminRoleAfterOwnershipTransfer() public {
        token.transferOwnershipCustom(NEW_OWNER);
        assertEq(
            token.owner(),
            NEW_OWNER,
            "sanity: ownership moved to the new owner"
        );

        assertTrue(
            token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)),
            "the previous owner still administers every role"
        );

        token.grantRole(token.MINTER_ROLE(), ATTACKER);
        vm.prank(ATTACKER);
        token.mintTokens(ATTACKER, 1_000 ether);

        assertEq(
            token.balanceOf(ATTACKER),
            1_000 ether,
            "the former owner still mints after handing over ownership"
        );
    }

    /// @dev HC-TKN-003 (IMPORTANTE, SIN CORREGIR): el constructor concede todos los roles a
    /// la misma direccion que despliega, sin multifirma ni timelock. Una sola clave puede
    /// emitir hasta el tope y pausar las transferencias.
    /// Adaptado en HC-TKN-001: eran cuatro roles, ahora son tres — BURNER_ROLE ya no existe.
    /// El hallazgo sigue vivo, solo se ha reducido en uno el numero de roles acumulados.
    /// Resultado esperado actual: los tres roles en una unica EOA.
    function testDeployerHoldsAllRolesAfterDeploy() public view {
        assertTrue(
            token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)),
            "deployer administers roles"
        );
        assertTrue(
            token.hasRole(token.MINTER_ROLE(), address(this)),
            "deployer can mint"
        );
        assertTrue(
            token.hasRole(token.PAUSER_ROLE(), address(this)),
            "deployer can pause"
        );
    }

    /// @dev HC-TKN-004 (IMPORTANTE, SIN CORREGIR): mintTokens() comprueba el tope contra
    /// mintedTokens, un contador que solo crece. Quemar reduce totalSupply() pero no lo
    /// decrementa, asi que las quemas no devuelven margen de emision.
    /// Adaptado en HC-TKN-001: antes quemaba el deployer via burn(HOLDER, cap); ahora es el
    /// propio titular quien quema lo suyo. El fallo del contador es identico.
    /// Resultado esperado actual: con el circulante a cero, emitir 1 wei sigue revirtiendo.
    function testBurningDoesNotRestoreMintHeadroom() public {
        uint256 cap = token.maxSupply();

        token.mintTokens(HOLDER, cap);
        assertEq(
            token.totalSupply(),
            cap,
            "sanity: the whole cap has been minted"
        );

        vm.prank(HOLDER);
        token.burn(cap);
        assertEq(
            token.totalSupply(),
            0,
            "sanity: the whole supply has been burned"
        );
        assertEq(
            token.mintedTokens(),
            cap,
            "the lifetime counter ignores the burn"
        );

        vm.expectRevert(HackToken.MaxSupplyExceeded.selector);
        token.mintTokens(HOLDER, 1);
    }

    /// @dev HC-TKN-005 (IMPORTANTE): transferOwnershipCustom() llama a la version de un
    /// solo paso de Ownable, efectiva de inmediato. No hay aceptacion por parte del
    /// destinatario, asi que un error de tipeo deja el contrato sin control recuperable.
    /// Resultado esperado actual: la propiedad cambia en una sola transaccion y el owner
    /// anterior ya no puede revertirla.
    function testOwnershipTransfersInOneStepWithNoAcceptance() public {
        token.transferOwnershipCustom(NEW_OWNER);

        assertEq(
            token.owner(),
            NEW_OWNER,
            "ownership moved with no acceptance step from the recipient"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        token.transferOwnershipCustom(address(this));
    }
}
