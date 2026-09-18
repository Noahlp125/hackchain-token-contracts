// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {HackToken} from "../src/HackTokenERC20.sol";

/**
 * @title DeployHackToken
 * @dev Despliegue de HackToken con la multifirma del proyecto como administradora
 * desde el primer bloque (TK-03, HC-TKN-003).
 *
 * La direccion administradora va escrita aqui como constante y no se lee de una
 * variable de entorno. El hallazgo que esta tarea cierra es que quien despliega
 * quedaba como punto unico de fallo, si la direccion viajase en una variable de
 * entorno, un error de tipeo el dia del despliegue reintroduciria el hallazgo sin
 * que nadie lo notase. Escrita aqui entra en el diff que revisa el auditor, y la
 * verificacion posterior en el explorador (TK-09) tiene contra que comparar.
 *
 * Este script NO emite los siete cubos del reparto. Eso lo ejecuta la multifirma
 * despues, mezclarlo significaria que las llaves que firman el despliegue tocan
 * tambien la distribucion.
 *
 * Uso:
 *   forge script script/DeployHackToken.s.sol:DeployHackToken \
 *     --rpc-url <polygon> --broadcast --verify
 */
contract DeployHackToken is Script {
    /// @dev Multifirma de HackChain en Polygon. Safe v1.4.1, umbral 2 de 3.
    address public constant ADMIN = 0x5Dc3981C4f49181EDd8009905481fdA8772b4B1f;

    /// @dev Polygon PoS. Verificado que soporta los opcodes de Cancun (MCOPY,
    /// TSTORE), que es el evm_version con el que compila solc 0.8.24 aqui.
    uint256 public constant EXPECTED_CHAIN_ID = 137;

    error WrongChain(uint256 expected, uint256 actual);
    error AdminIsNotAContract(address admin);
    error AdminIsTheDeployer(address admin);
    error OwnerMismatch(address expected, address actual);
    error DefaultAdminMismatch(address expected, address actual);
    error AdminMissingRole(bytes32 role);
    error DeployerRetainsRole(address deployer, bytes32 role);
    error UnexpectedDelay(uint48 expected, uint48 actual);
    error SupplyNotZero(uint256 totalSupply, uint256 mintedTokens);

    function run() external returns (HackToken token) {
        address deployer = msg.sender;

        preflight(deployer);

        vm.startBroadcast();
        token = new HackToken(ADMIN);
        vm.stopBroadcast();

        verify(token, deployer);
    }

    /**
     * @notice Comprobaciones previas, antes de gastar un wei.
     * @dev Se ejecutan en la simulacion, asi que un error de cadena o de direccion
     * se detecta sin desplegar nada.
     */
    function preflight(address deployer_) public view {
        if (block.chainid != EXPECTED_CHAIN_ID) {
            revert WrongChain(EXPECTED_CHAIN_ID, block.chainid);
        }

        // Un Safe es un contrato. Sin codigo en esta direccion, o la multifirma no
        // esta desplegada en esta cadena, o la direccion esta mal copiada. Las dos
        // cosas terminarian con el token administrado por nadie.
        if (ADMIN.code.length == 0) revert AdminIsNotAContract(ADMIN);

        // El sentido entero de la tarea: la administracion no puede acabar en la
        // llave que firma el despliegue.
        if (ADMIN == deployer_) revert AdminIsTheDeployer(ADMIN);
    }

    /**
     * @notice Estado que debe cumplirse tras el despliegue.
     * @dev Es la lista de verificacion de TK-09, ejecutada en el mismo momento del
     * despliegue en vez de a mano despues. Si algo no cuadra, la transaccion no se
     * da por buena y queda constancia de por que.
     */
    function verify(HackToken token_, address deployer_) public view {
        bytes32 adminRole = token_.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = token_.MINTER_ROLE();
        bytes32 pauserRole = token_.PAUSER_ROLE();

        // Titularidad y administracion, que en este contrato son el mismo dato.
        if (token_.owner() != ADMIN)
            revert OwnerMismatch(ADMIN, token_.owner());
        if (token_.defaultAdmin() != ADMIN) {
            revert DefaultAdminMismatch(ADMIN, token_.defaultAdmin());
        }

        // La multifirma tiene los tres roles.
        if (!token_.hasRole(adminRole, ADMIN))
            revert AdminMissingRole(adminRole);
        if (!token_.hasRole(minterRole, ADMIN))
            revert AdminMissingRole(minterRole);
        if (!token_.hasRole(pauserRole, ADMIN))
            revert AdminMissingRole(pauserRole);

        // Y quien desplego no conserva ninguno.
        if (token_.hasRole(adminRole, deployer_)) {
            revert DeployerRetainsRole(deployer_, adminRole);
        }
        if (token_.hasRole(minterRole, deployer_)) {
            revert DeployerRetainsRole(deployer_, minterRole);
        }
        if (token_.hasRole(pauserRole, deployer_)) {
            revert DeployerRetainsRole(deployer_, pauserRole);
        }

        // El retardo del traspaso de administracion es el esperado.
        if (token_.defaultAdminDelay() != token_.ADMIN_TRANSFER_DELAY()) {
            revert UnexpectedDelay(
                token_.ADMIN_TRANSFER_DELAY(),
                token_.defaultAdminDelay()
            );
        }

        // Nace sin emitir. El reparto lo hace la multifirma despues.
        if (token_.totalSupply() != 0 || token_.mintedTokens() != 0) {
            revert SupplyNotZero(token_.totalSupply(), token_.mintedTokens());
        }
    }
}
