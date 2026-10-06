// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlDefaultAdminRules}
    from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {HackToken} from "../src/HackTokenERC20.sol";

/// @dev Regresiones de HC-TKN-002 (ALTO, auditoria externa de Itish 30/08/2026), y de los
/// hallazgos que la misma remediacion cierra: HC-TKN-005 (traspaso en un solo paso) y
/// HC-TKN-011 (la transferOwnership heredada eludia la funcion custom, hallazgo propio).
///
/// El contrato auditado llevaba dos sistemas de control en paralelo: Ownable, que solo
/// protegia la funcion que transferia Ownable, y AccessControl, que guardaba el poder real.
/// Ceder la titularidad no movia DEFAULT_ADMIN_ROLE, asi que quien desplegaba conservaba
/// indefinidamente la capacidad de concederse MINTER_ROLE.
///
/// La remediacion elimina Ownable y adopta AccessControlDefaultAdminRules. Las propiedades
/// que fijan estos tests: hay un unico administrador, owner() y defaultAdmin() son el mismo
/// dato por construccion, y el traspaso exige agendado, espera y aceptacion del destinatario.
contract TokenHCTKN002Test is Test {
    HackToken token;

    address ADMIN = makeAddr("admin");
    address NEW_ADMIN = makeAddr("new-admin");
    address ATTACKER = makeAddr("attacker");

    function setUp() public {
        token = new HackToken(ADMIN);
    }

    // --- Una sola fuente de verdad ---

    /// @dev El nucleo del hallazgo: titularidad y administracion no pueden divergir porque
    /// owner() no es un slot propio, es una vista sobre defaultAdmin() (ERC-5313).
    function test_HCTKN002_OwnerIsAViewOverDefaultAdmin() public view {
        assertEq(token.owner(), token.defaultAdmin(), "owner() mirrors defaultAdmin()");
        assertEq(token.owner(), ADMIN, "and both report the declared admin");
    }

    /// @dev El deployer no se queda con nada. Es el punto que TK-03 pide y que la firma
    /// anterior del constructor no permitia.
    function test_HCTKN002_DeployerHoldsNothing() public view {
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)), "no admin role");
        assertFalse(token.hasRole(token.MINTER_ROLE(), address(this)), "no minter role");
        assertFalse(token.hasRole(token.PAUSER_ROLE(), address(this)), "no pauser role");
    }

    /// @dev La extension impide que DEFAULT_ADMIN_ROLE se reparta: no hay dos administradores.
    function test_HCTKN002_AdminRoleCannotBeGrantedDirectly() public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();

        vm.prank(ADMIN);
        vm.expectRevert(
            IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector
        );
        token.grantRole(adminRole, ATTACKER);
    }

    /// @dev Y tampoco por la via de revocarlo directamente.
    function test_HCTKN002_AdminRoleCannotBeRevokedDirectly() public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();

        vm.prank(ADMIN);
        vm.expectRevert(
            IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector
        );
        token.revokeRole(adminRole, ADMIN);
    }

    // --- El traspaso, paso a paso ---

    /// @dev Agendar no mueve nada. El admin actual sigue mandando durante toda la espera.
    function test_HCTKN002_SchedulingDoesNotMoveControl() public {
        vm.prank(ADMIN);
        token.beginDefaultAdminTransfer(NEW_ADMIN);

        assertEq(token.owner(), ADMIN, "the incumbent still holds control");

        (address pending, ) = token.pendingDefaultAdmin();
        assertEq(pending, NEW_ADMIN, "the transfer is scheduled");
    }

    /// @dev No se puede aceptar antes de que venza el plazo. Es el timelock del hallazgo.
    function test_HCTKN002_CannotAcceptBeforeDelayElapses() public {
        vm.prank(ADMIN);
        token.beginDefaultAdminTransfer(NEW_ADMIN);

        vm.warp(block.timestamp + token.defaultAdminDelay() - 1);

        vm.prank(NEW_ADMIN);
        vm.expectRevert();
        token.acceptDefaultAdminTransfer();

        assertEq(token.owner(), ADMIN, "control has not moved");
    }

    /// @dev Solo acepta el destinatario. Un tercero no puede consumar el traspaso.
    function test_HCTKN002_OnlyThePendingAdminCanAccept() public {
        vm.prank(ADMIN);
        token.beginDefaultAdminTransfer(NEW_ADMIN);
        vm.warp(block.timestamp + token.defaultAdminDelay() + 1);

        vm.prank(ATTACKER);
        vm.expectRevert();
        token.acceptDefaultAdminTransfer();

        assertEq(token.owner(), ADMIN, "control has not moved");
    }

    /// @dev La ventana de cancelacion es lo que hace util el retardo: si alguien roba la clave
    /// y agenda un traspaso, el admin legitimo tiene ADMIN_TRANSFER_DELAY para abortarlo.
    function test_HCTKN002_IncumbentCanCancelBeforeAcceptance() public {
        vm.startPrank(ADMIN);
        token.beginDefaultAdminTransfer(NEW_ADMIN);
        token.cancelDefaultAdminTransfer();
        vm.stopPrank();

        vm.warp(block.timestamp + token.defaultAdminDelay() + 1);

        vm.prank(NEW_ADMIN);
        vm.expectRevert();
        token.acceptDefaultAdminTransfer();

        assertEq(token.owner(), ADMIN, "the cancelled transfer cannot be resumed");
    }

    /// @dev Consumado el traspaso, el admin anterior no conserva el rol...
    function test_HCTKN002_HandoverMovesAdminRole() public {
        _handOver();

        assertEq(token.owner(), NEW_ADMIN, "owner() follows the new admin");
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), NEW_ADMIN), "new admin holds it");
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), ADMIN), "previous admin does not");
    }

    /// @dev ...ni puede seguir concediendo roles, que era el impacto concreto del hallazgo:
    /// el deployer podia concederse MINTER_ROLE despues de haber "cedido" el contrato.
    function test_HCTKN002_PreviousAdminCannotGrantRolesAfterHandover() public {
        _handOver();

        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = token.MINTER_ROLE();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                ADMIN,
                adminRole
            )
        );
        token.grantRole(minterRole, ATTACKER);
    }

    /// @dev El retardo esta fijado en codigo, no se toma del despliegue.
    function test_HCTKN002_DelayIsThreeDays() public view {
        assertEq(token.defaultAdminDelay(), 3 days, "delay fixed at three days");
        assertEq(token.ADMIN_TRANSFER_DELAY(), 3 days, "and exposed as a constant");
    }

    // --- Lo que el traspaso NO mueve ---

    /// @dev Documentado a proposito: la extension solo gobierna DEFAULT_ADMIN_ROLE.
    /// MINTER_ROLE y PAUSER_ROLE siguen con el admin saliente hasta que alguien los revoque.
    /// Este test no describe un fallo: fija la frontera de lo que el contrato garantiza, para
    /// que el runbook de despliegue no de por hecho lo que el codigo no hace.
    function test_HCTKN002_HandoverDoesNotCarryMinterOrPauser() public {
        _handOver();

        assertTrue(
            token.hasRole(token.MINTER_ROLE(), ADMIN),
            "MINTER_ROLE stays with the outgoing admin and must be revoked explicitly"
        );
        assertTrue(
            token.hasRole(token.PAUSER_ROLE(), ADMIN),
            "PAUSER_ROLE stays with the outgoing admin and must be revoked explicitly"
        );

        // El admin entrante si puede limpiarlos, que es lo que el runbook debe exigir.
        vm.startPrank(NEW_ADMIN);
        token.revokeRole(token.MINTER_ROLE(), ADMIN);
        token.revokeRole(token.PAUSER_ROLE(), ADMIN);
        vm.stopPrank();

        assertFalse(token.hasRole(token.MINTER_ROLE(), ADMIN), "revoked by the incoming admin");
        assertFalse(token.hasRole(token.PAUSER_ROLE(), ADMIN), "revoked by the incoming admin");
    }

    function _handOver() internal {
        vm.prank(ADMIN);
        token.beginDefaultAdminTransfer(NEW_ADMIN);
        vm.warp(block.timestamp + token.defaultAdminDelay() + 1);
        vm.prank(NEW_ADMIN);
        token.acceptDefaultAdminTransfer();
    }
}
