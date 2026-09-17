// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    IAccessControl
} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IERC20Errors
} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
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
    address NEW_ADMIN = makeAddr("new-admin");
    address OTHER_ADMIN = makeAddr("other-admin");

    function setUp() public {
        token = new HackToken(address(this));
    }

    /// @dev Traspaso completo de la administracion, usado por varias regresiones.
    function _handOverAdminTo(address newAdmin_) internal {
        token.beginDefaultAdminTransfer(newAdmin_);
        vm.warp(block.timestamp + token.defaultAdminDelay() + 1);
        vm.prank(newAdmin_);
        token.acceptDefaultAdminTransfer();
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

    /// @dev HC-TKN-002 (ALTO, CORREGIDO): el PoC original cedia la propiedad con
    /// transferOwnershipCustom() y demostraba que el deployer conservaba DEFAULT_ADMIN_ROLE,
    /// pudiendo concederse MINTER_ROLE indefinidamente.
    /// Tras adoptar AccessControlDefaultAdminRules no hay capa Ownable: owner() es una vista
    /// sobre defaultAdmin(), asi que titularidad y administracion no pueden divergir.
    /// Resultado esperado ahora: tras el traspaso, el admin anterior no conserva el rol ni
    /// puede conceder ninguno.
    function testPreviousAdminRetainsNoControlAfterHandover() public {
        _handOverAdminTo(NEW_ADMIN);

        assertEq(token.owner(), NEW_ADMIN, "owner() follows defaultAdmin()");
        assertFalse(
            token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)),
            "the previous admin keeps no administrative role"
        );

        // Los getters de rol se resuelven antes de armar expectRevert: si se dejan dentro de
        // la llamada, la cheatcode captura esa lectura en vez de la llamada que debe revertir.
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = token.MINTER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                adminRole
            )
        );
        token.grantRole(minterRole, ATTACKER);
    }

    /// @dev HC-TKN-003 (IMPORTANTE, CORREGIDO): el constructor concedia los roles a
    /// msg.sender, dejando a quien desplegaba como punto unico de fallo.
    /// Ahora recibe la direccion administradora como parametro y no concede nada al deployer.
    /// Resultado esperado ahora: quien despliega no conserva ningun rol.
    function testDeployerHoldsNoRolesWhenAdminIsAnother() public {
        HackToken fresh = new HackToken(OTHER_ADMIN);

        assertFalse(
            fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), address(this)),
            "the deployer does not administer roles"
        );
        assertFalse(
            fresh.hasRole(fresh.MINTER_ROLE(), address(this)),
            "the deployer cannot mint"
        );
        assertFalse(
            fresh.hasRole(fresh.PAUSER_ROLE(), address(this)),
            "the deployer cannot pause"
        );

        assertTrue(
            fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), OTHER_ADMIN),
            "the declared admin administers roles"
        );
        assertEq(
            fresh.owner(),
            OTHER_ADMIN,
            "owner() reports the declared admin"
        );
    }

    /// @dev HC-TKN-004 (IMPORTANTE, CORREGIDO): el comportamiento observable no cambia con
    /// el circulante a cero, emitir 1 wei sigue revirtiendo. Lo que cambia es que ha dejado de
    /// ser un efecto no documentado para pasar a ser una propiedad declarada.
    ///
    /// El tope mide emision acumulada, no circulante: la tokenomics reparte los 1.000M en
    /// cubos cerrados que suman el 100%, asi que un token emitido para reemplazar a uno
    /// quemado no perteneceria a ningun cubo. Agotar el tope es el final previsto, no un
    /// fallo: las recompensas salen del cubo de Incentivos, que recicla tokens existentes a
    /// traves de IncentivesPool y nunca acuña.
    ///
    /// Resultado esperado ahora: quemar no devuelve margen, y eso es correcto.
    function testBurningDoesNotFreeMintHeadroomByDesign() public {
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
            "the lifetime counter is unaffected by the burn, as documented"
        );
        assertEq(
            token.remainingMintable(),
            0,
            "no headroom is left, and burning did not create any"
        );

        vm.expectRevert(HackToken.MaxSupplyExceeded.selector);
        token.mintTokens(HOLDER, 1);
    }

    /// @dev HC-TKN-005 (IMPORTANTE, CORREGIDO): el PoC original demostraba que la propiedad
    /// cambiaba en una sola transaccion, sin aceptacion, dejando el contrato sin control
    /// recuperable ante un error de tipeo.
    /// Ahora el traspaso es en dos pasos con retardo: agendar, esperar, y que el destinatario
    /// acepte. Hasta entonces no cambia nada y el admin actual puede cancelar.
    /// Resultado esperado ahora: sin aceptacion, la administracion no se mueve.
    function testAdminTransferDoesNotTakeEffectWithoutAcceptance() public {
        token.beginDefaultAdminTransfer(NEW_ADMIN);

        assertEq(
            token.owner(),
            address(this),
            "scheduling alone moves nothing"
        );

        vm.warp(block.timestamp + token.defaultAdminDelay() + 1);

        assertEq(
            token.owner(),
            address(this),
            "the delay elapsing alone moves nothing either"
        );

        vm.prank(NEW_ADMIN);
        token.acceptDefaultAdminTransfer();

        assertEq(
            token.owner(),
            NEW_ADMIN,
            "control moves only once the recipient accepts"
        );
    }
}
