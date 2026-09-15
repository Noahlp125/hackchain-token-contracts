// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {HackToken} from "../src/HackTokenERC20.sol";

/// @dev PoCs de la auditoria externa de Itish (30/08/2026) sobre HackTokenERC20.sol.
/// Reproducen el comportamiento vulnerable del contrato tal y como fue auditado, por eso ahora mismo pasan. Cada uno se convertira en regresion dentro del commit que arregle su hallazgo, la prueba de la vulnerabilidad queda en el historial.

/// Cobertura: HC-TKN-001 a HC-TKN-005. Los hallazgos HC-TKN-006 a HC-TKN-010 son estilo, documentacion, indexado y gas: no son reproducibles como PoC.

contract TokenAuditValidation is Test {
    HackToken token;

    address HOLDER = makeAddr("holder");
    address BURNER = makeAddr("burner");
    address ATTACKER = makeAddr("attacker");
    address NEW_OWNER = makeAddr("new-owner");

    function setUp() public {
        token = new HackToken();
    }

    /// @dev HC-TKN-001 (ALTO): burn() acepta un `from_` controlado por quien llama, sin
    /// comprobacion de propiedad, allowance ni consentimiento del titular. Cualquier
    /// direccion con BURNER_ROLE puede destruir el saldo de un tercero.
    /// Resultado esperado actual: el saldo de HOLDER queda a cero sin haber aprobado nada.
    function testBurnerCanDestroyAnyHolderBalance() public {
        token.mintTokens(HOLDER, 10_000 ether);
        token.grantRole(token.BURNER_ROLE(), BURNER);

        assertEq(
            token.allowance(HOLDER, BURNER),
            0,
            "sanity: the burner holds no allowance"
        );
        assertEq(
            token.balanceOf(HOLDER),
            10_000 ether,
            "sanity: the holder owns the tokens"
        );

        vm.prank(BURNER);
        token.burn(HOLDER, 10_000 ether);

        assertEq(
            token.balanceOf(HOLDER),
            0,
            "a BURNER_ROLE holder wiped a third party balance without consent"
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

    /// @dev HC-TKN-003 (IMPORTANTE): el constructor concede los cuatro roles a la misma
    /// direccion que despliega, sin multifirma ni timelock. Una sola clave puede emitir
    /// hasta el tope, quemar el saldo de cualquiera y pausar las transferencias.
    /// Resultado esperado actual: los cuatro roles en una unica EOA.
    function testDeployerHoldsAllFourRolesAfterDeploy() public view {
        assertTrue(
            token.hasRole(token.DEFAULT_ADMIN_ROLE(), address(this)),
            "deployer administers roles"
        );
        assertTrue(
            token.hasRole(token.MINTER_ROLE(), address(this)),
            "deployer can mint"
        );
        assertTrue(
            token.hasRole(token.BURNER_ROLE(), address(this)),
            "deployer can burn"
        );
        assertTrue(
            token.hasRole(token.PAUSER_ROLE(), address(this)),
            "deployer can pause"
        );
    }

    /// @dev HC-TKN-004 (IMPORTANTE): mintTokens() comprueba el tope contra mintedTokens,
    /// un contador que solo crece. burn() reduce totalSupply() pero no lo decrementa, asi
    /// que las quemas no devuelven margen de emision.
    /// Resultado esperado actual: con el circulante a cero, emitir 1 wei sigue revirtiendo.
    function testBurningDoesNotRestoreMintHeadroom() public {
        uint256 cap = token.maxSupply();

        token.mintTokens(HOLDER, cap);
        assertEq(
            token.totalSupply(),
            cap,
            "sanity: the whole cap has been minted"
        );

        token.burn(HOLDER, cap);
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
