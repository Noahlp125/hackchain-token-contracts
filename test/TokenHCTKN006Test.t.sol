// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {HackToken} from "../src/HackTokenERC20.sol";

/// @dev Regresiones de los hallazgos menores de la auditoria externa de Itish (30/08/2026)
/// cerrados en el mismo commit:
///
///   HC-TKN-006 (INFO-1) el revert de la pausa era un require con string, inconsistente con
///                       los errores custom del resto del contrato. Resuelto por la segunda
///                       via que ofrece el informe: heredar ERC20Pausable, que ya cablea
///                       whenNotPaused en _update(). El revert pasa a ser EnforcedPause().
///   HC-TKN-008 (INFO-3) TokenMinted no indexaba el destinatario.
///   HC-TKN-009 (GAS-1)  maxSupply pasa a immutable.
///   HC-TKN-012          hallazgo propio: mintTokens() queda bloqueado por la pausa sin
///                       declararlo. Se documenta en NatSpec en vez de añadir el modificador,
///                       que duplicaria la comprobacion que _update ya hace.
contract TokenHCTKN006Test is Test {
    HackToken token;

    address ADMIN = makeAddr("admin");
    address HOLDER = makeAddr("holder");
    address OTHER = makeAddr("other");
    address SPENDER = makeAddr("spender");

    event TokenMinted(address indexed to, uint256 amount);

    function setUp() public {
        token = new HackToken(ADMIN);
        vm.prank(ADMIN);
        token.mintTokens(HOLDER, 10_000 ether);
    }

    // --- HC-TKN-006: la pausa revierte con el error estandar, por las tres rutas ---

    function test_HCTKN006_TransferRevertsWithEnforcedPause() public {
        vm.prank(ADMIN);
        token.pause();

        vm.prank(HOLDER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transfer(OTHER, 1 ether);
    }

    function test_HCTKN006_MintRevertsWithEnforcedPause() public {
        vm.prank(ADMIN);
        token.pause();

        vm.prank(ADMIN);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.mintTokens(HOLDER, 1 ether);
    }

    function test_HCTKN006_BurnRevertsWithEnforcedPause() public {
        vm.prank(ADMIN);
        token.pause();

        vm.prank(HOLDER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.burn(1 ether);
    }

    function test_HCTKN006_TransferFromRevertsWithEnforcedPause() public {
        vm.prank(HOLDER);
        token.approve(SPENDER, 1 ether);

        vm.prank(ADMIN);
        token.pause();

        vm.prank(SPENDER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transferFrom(HOLDER, OTHER, 1 ether);
    }

    /// @dev Aprobar no mueve saldo, asi que no pasa por _update y sigue funcionando en pausa.
    /// No es un descuido: dejar de aprobar no protege nada y romperia integraciones que
    /// preparan operaciones para cuando se reanude.
    function test_HCTKN006_ApproveStillWorksWhilePaused() public {
        vm.prank(ADMIN);
        token.pause();

        vm.prank(HOLDER);
        token.approve(SPENDER, 5 ether);

        assertEq(token.allowance(HOLDER, SPENDER), 5 ether, "approvals are unaffected by the pause");
    }

    /// @dev Al reanudar, todo vuelve a funcionar. La pausa no deja estado residual.
    function test_HCTKN006_EverythingResumesAfterUnpause() public {
        vm.startPrank(ADMIN);
        token.pause();
        token.unpause();
        vm.stopPrank();

        vm.prank(HOLDER);
        token.transfer(OTHER, 1 ether);
        assertEq(token.balanceOf(OTHER), 1 ether, "transfers work again");

        vm.prank(ADMIN);
        token.mintTokens(OTHER, 1 ether);
        assertEq(token.balanceOf(OTHER), 2 ether, "minting works again");
    }

    // --- HC-TKN-008: el destinatario de TokenMinted es filtrable ---

    /// @dev Con `to` indexado, un indexador puede filtrar por destinatario sin leer el cuerpo
    /// del evento. vm.expectEmit con el primer topic a true comprueba justamente eso.
    function test_HCTKN008_TokenMintedIndexesRecipient() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit TokenMinted(OTHER, 500 ether);

        vm.prank(ADMIN);
        token.mintTokens(OTHER, 500 ether);
    }

    /// @dev Y que el filtro discrimina de verdad: un evento con otro destinatario no encaja.
    function test_HCTKN008_FilteringByRecipientDiscriminates() public {
        vm.recordLogs();

        vm.startPrank(ADMIN);
        token.mintTokens(HOLDER, 1 ether);
        token.mintTokens(OTHER, 2 ether);
        vm.stopPrank();

        bytes32 topic = keccak256("TokenMinted(address,uint256)");
        uint256 forOther;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == topic) {
                if (address(uint160(uint256(logs[i].topics[1]))) == OTHER) forOther++;
            }
        }

        assertEq(forOther, 1, "exactly one mint is indexed against OTHER");
    }

    // --- HC-TKN-009: maxSupply inmutable ---

    function test_HCTKN009_MaxSupplyKeepsItsValueAsImmutable() public view {
        assertEq(token.maxSupply(), 1_000_000_000 ether, "one billion HACK with 18 decimals");
        assertEq(token.decimals(), 18, "decimals resolved correctly during construction");
    }

    /// @dev Cada despliegue lo fija por su cuenta: no es estado compartido ni mutable.
    function test_HCTKN009_MaxSupplyIsSetPerDeployment() public {
        HackToken other = new HackToken(makeAddr("another-admin"));
        assertEq(other.maxSupply(), token.maxSupply(), "every deployment gets the same cap");
    }
}
