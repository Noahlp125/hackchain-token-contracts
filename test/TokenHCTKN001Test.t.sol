// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {HackToken} from "../src/HackTokenERC20.sol";

/// @dev Regresiones de HC-TKN-001 (ALTO, auditoria externa de Itish 30/08/2026).
///
/// El contrato auditado exponia burn(address from_, uint256 amount_) tras onlyRole(BURNER_ROLE):
/// quien tuviera el rol elegia de que direccion destruir saldo, sin propiedad, sin allowance y
/// sin consentimiento del titular.
///
/// La remediacion adopta ERC20Burnable de OpenZeppelin y elimina BURNER_ROLE. La propiedad de
/// seguridad que fijan estos tests: el saldo de una direccion solo puede destruirse por ella
/// misma, o por un tercero al que ella haya concedido allowance explicito y acotado.
contract TokenHCTKN001Test is Test {
    HackToken token;

    address HOLDER = makeAddr("holder");
    address SPENDER = makeAddr("spender");
    address BYSTANDER = makeAddr("bystander");

    function setUp() public {
        token = new HackToken(address(this));
        token.mintTokens(HOLDER, 10_000 ether);
        token.mintTokens(BYSTANDER, 10_000 ether);
    }

    /// @dev El titular quema lo suyo y nadie mas se ve afectado.
    function test_HCTKN001_BurnOnlyAffectsCallerBalance() public {
        vm.prank(HOLDER);
        token.burn(4_000 ether);

        assertEq(token.balanceOf(HOLDER), 6_000 ether, "the caller burns their own balance");
        assertEq(token.balanceOf(BYSTANDER), 10_000 ether, "no other holder is affected");
    }

    /// @dev Sin allowance previo no hay forma de quemar el saldo de otro. Es el PoC original
    /// invertido: antes bastaba con tener BURNER_ROLE, ahora hace falta el permiso del titular.
    function test_HCTKN001_BurnFromRevertsWithoutAllowance() public {
        vm.prank(SPENDER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1 ether)
        );
        token.burnFrom(HOLDER, 1 ether);

        assertEq(token.balanceOf(HOLDER), 10_000 ether, "balance untouched without consent");
    }

    /// @dev Con allowance, la quema consume exactamente lo aprobado y no deja credito residual.
    function test_HCTKN001_BurnFromConsumesAllowance() public {
        vm.prank(HOLDER);
        token.approve(SPENDER, 3_000 ether);

        vm.prank(SPENDER);
        token.burnFrom(HOLDER, 3_000 ether);

        assertEq(token.balanceOf(HOLDER), 7_000 ether, "only the approved amount was burned");
        assertEq(token.allowance(HOLDER, SPENDER), 0, "the allowance is fully consumed");
    }

    /// @dev El allowance es un techo: aprobar 100 no habilita quemar 101.
    function test_HCTKN001_BurnFromRevertsAboveAllowance() public {
        vm.prank(HOLDER);
        token.approve(SPENDER, 100 ether);

        vm.prank(SPENDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 100 ether, 101 ether
            )
        );
        token.burnFrom(HOLDER, 101 ether);

        assertEq(token.balanceOf(HOLDER), 10_000 ether, "balance untouched beyond the allowance");
        assertEq(token.allowance(HOLDER, SPENDER), 100 ether, "a failed burn consumes no allowance");
    }

    /// @dev El titular tampoco puede quemar mas de lo que tiene.
    function test_HCTKN001_BurnRevertsAboveBalance() public {
        vm.prank(HOLDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, HOLDER, 10_000 ether, 10_001 ether
            )
        );
        token.burn(10_001 ether);
    }

    /// @dev ERC20Burnable no lleva whenNotPaused, pero _burn pasa por _update, que lo aplica via
    /// ERC20Pausable. El comportamiento es identico al de la version auditada; lo que cambio en
    /// HC-TKN-006 es que el revert pasa a ser el error estandar EnforcedPause() en vez de un
    /// require con string propio. Esta regresion existe para que la ruta siga bloqueada.
    function test_HCTKN001_BurnRevertsWhenPaused() public {
        token.pause();

        vm.prank(HOLDER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.burn(1 ether);

        assertEq(token.balanceOf(HOLDER), 10_000 ether, "no burn goes through while paused");
    }

    /// @dev Lo mismo por la via de burnFrom, que es la que un integrador usaria.
    function test_HCTKN001_BurnFromRevertsWhenPaused() public {
        vm.prank(HOLDER);
        token.approve(SPENDER, 1 ether);

        token.pause();

        vm.prank(SPENDER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.burnFrom(HOLDER, 1 ether);
    }

    /// @dev La quema reduce el circulante, no solo el saldo del titular.
    function test_HCTKN001_BurnReducesTotalSupply() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(HOLDER);
        token.burn(1_000 ether);

        assertEq(token.totalSupply(), supplyBefore - 1_000 ether, "total supply drops by the burned amount");
    }
}
