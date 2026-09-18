// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HackToken} from "../src/HackTokenERC20.sol";
import {DeployHackToken} from "../script/DeployHackToken.s.sol";

/// @dev Regresiones de HC-TKN-003 (TK-03, auditoria externa de Itish 30/08/2026).
///
/// El constructor auditado concedia los cuatro roles a msg.sender, dejando a quien
/// desplegaba como punto unico de fallo. La mitad de codigo se cerro en HC-TKN-002, al
/// adoptar AccessControlDefaultAdminRules: el constructor pasa a recibir la direccion
/// administradora y el deployer no conserva nada.
///
/// Esta bateria cubre la otra mitad de la tarea, "desplegar con la multifirma como
/// administradora desde el primer bloque". El contrato hace posible hacerlo bien; el
/// script es lo que lo hace inevitable. Aqui se comprueba que el script rechaza los tres
/// errores que reintroducirian el hallazgo, y que su verificacion posterior detecta un
/// despliegue mal administrado en vez de darlo por bueno.
///
/// Multifirma verificada en cadena el 18/09/2026: Safe v1.4.1 en Polygon (chain id 137),
/// umbral 2 de 3, desplegada y con transacciones ejecutadas.
contract TokenHCTKN003Test is Test {
    DeployHackToken script;

    address constant ADMIN = 0x5Dc3981C4f49181EDd8009905481fdA8772b4B1f;
    uint256 constant POLYGON = 137;

    address DEPLOYER = makeAddr("deployer");

    function setUp() public {
        script = new DeployHackToken();
        vm.chainId(POLYGON);
        // La multifirma es un contrato. En el fork local se le pone codigo para que la
        // comprobacion del script se ejerza igual que contra Polygon.
        vm.etch(ADMIN, hex"60006000f3");
    }

    // --- La constante coincide con lo verificado en cadena ---

    function test_HCTKN003_ScriptTargetsTheRealMultisig() public view {
        assertEq(script.ADMIN(), ADMIN, "the hardcoded admin is the project multisig");
        assertEq(script.EXPECTED_CHAIN_ID(), POLYGON, "and the target chain is Polygon");
    }

    // --- Preflight: los tres errores que reintroducirian el hallazgo ---

    function test_HCTKN003_PreflightPassesOnTheRightChain() public view {
        script.preflight(DEPLOYER);
    }

    /// @dev Cadena equivocada. Sin esto, el despliegue podria ir a una red donde esa
    /// direccion no es la multifirma, o no es nada.
    function test_HCTKN003_PreflightRejectsWrongChain() public {
        vm.chainId(1);

        vm.expectRevert(
            abi.encodeWithSelector(DeployHackToken.WrongChain.selector, POLYGON, 1)
        );
        script.preflight(DEPLOYER);
    }

    /// @dev Direccion sin codigo: o la multifirma no esta desplegada en esta cadena, o
    /// esta mal copiada. Las dos acaban con el token administrado por nadie.
    function test_HCTKN003_PreflightRejectsAdminWithoutCode() public {
        vm.etch(ADMIN, hex"");

        vm.expectRevert(
            abi.encodeWithSelector(DeployHackToken.AdminIsNotAContract.selector, ADMIN)
        );
        script.preflight(DEPLOYER);
    }

    /// @dev El nucleo del hallazgo: la administracion no puede acabar en la llave que
    /// firma el despliegue.
    function test_HCTKN003_PreflightRejectsDeployerAsAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeployHackToken.AdminIsTheDeployer.selector, ADMIN)
        );
        script.preflight(ADMIN);
    }

    // --- Verify: el estado que debe quedar tras desplegar ---

    function test_HCTKN003_VerifyAcceptsACorrectDeployment() public {
        vm.prank(DEPLOYER);
        HackToken token = new HackToken(ADMIN);

        script.verify(token, DEPLOYER);
    }

    /// @dev Si se despliega con el deployer como administrador, que es exactamente el
    /// hallazgo, la verificacion lo detecta en vez de dar el despliegue por bueno.
    function test_HCTKN003_VerifyRejectsDeployerAdministeredToken() public {
        vm.prank(DEPLOYER);
        HackToken token = new HackToken(DEPLOYER);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployHackToken.OwnerMismatch.selector,
                ADMIN,
                DEPLOYER
            )
        );
        script.verify(token, DEPLOYER);
    }

    /// @dev Y si se despliega con cualquier otra direccion, tambien.
    function test_HCTKN003_VerifyRejectsAnyOtherAdmin() public {
        address stranger = makeAddr("stranger");

        vm.prank(DEPLOYER);
        HackToken token = new HackToken(stranger);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployHackToken.OwnerMismatch.selector,
                ADMIN,
                stranger
            )
        );
        script.verify(token, DEPLOYER);
    }

    /// @dev El token debe nacer sin emitir: el reparto lo hace la multifirma despues.
    function test_HCTKN003_VerifyRejectsAPreMintedToken() public {
        vm.prank(DEPLOYER);
        HackToken token = new HackToken(ADMIN);

        vm.prank(ADMIN);
        token.mintTokens(DEPLOYER, 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployHackToken.SupplyNotZero.selector,
                1 ether,
                1 ether
            )
        );
        script.verify(token, DEPLOYER);
    }

    /// @dev El estado completo que TK-09 debe encontrar en el explorador.
    function test_HCTKN003_EndStateMatchesTheDeploymentChecklist() public {
        vm.prank(DEPLOYER);
        HackToken token = new HackToken(ADMIN);

        assertEq(token.owner(), ADMIN, "owner() is the multisig");
        assertEq(token.defaultAdmin(), ADMIN, "and so is defaultAdmin()");
        assertEq(token.defaultAdminDelay(), 3 days, "admin transfer delay is three days");
        assertEq(token.maxSupply(), 1_000_000_000 ether, "cap is one billion HACK");
        assertEq(token.mintedTokens(), 0, "nothing minted yet");
        assertEq(token.remainingMintable(), token.maxSupply(), "the whole cap is available");

        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), ADMIN), "multisig administers");
        assertTrue(token.hasRole(token.MINTER_ROLE(), ADMIN), "multisig can mint");
        assertTrue(token.hasRole(token.PAUSER_ROLE(), ADMIN), "multisig can pause");

        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), DEPLOYER), "deployer holds nothing");
        assertFalse(token.hasRole(token.MINTER_ROLE(), DEPLOYER), "deployer holds nothing");
        assertFalse(token.hasRole(token.PAUSER_ROLE(), DEPLOYER), "deployer holds nothing");
    }
}
