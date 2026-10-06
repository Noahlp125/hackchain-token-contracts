// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HackToken} from "../src/HackTokenERC20.sol";

/// @dev Regresiones de HC-TKN-004 (auditoria externa de Itish 30/08/2026).
///
/// El informe senala que maxSupply se comprueba contra mintedTokens, un contador que solo
/// crece, y avisa de que con el tiempo bloquearia nuevas emisiones "despite plenty of tokens
/// having been burned and real headroom existing".
///
/// Se ha resuelto por la segunda via que el propio informe ofrece: declarar que el tope mide
/// emision acumulada y documentarlo, en vez de convertirlo en un tope de circulante. El
/// motivo esta en la tokenomics del proyecto, que reparte los 1.000M en cubos cerrados
/// (equipo, venta privada, preventa publica, venta publica, incentivos, tesoreria, airdrops)
/// que suman el 100%. Un token emitido para reemplazar a uno quemado no perteneceria a
/// ningun cubo, y los porcentajes dejarian de describir nada.
///
/// Agotar el tope no es el fallo que teme el informe: es el final previsto. Las recompensas
/// no se acuñan, salen del cubo de Incentivos y se reciclan a traves de IncentivesPool, que
/// se financia con transferFrom.
///
/// Propiedades que fijan estos tests: nunca se emiten mas de 1.000M en toda la vida del
/// contrato, quemar no devuelve margen, y remainingMintable() dice la verdad en todo momento.
contract TokenHCTKN004Test is Test {
    HackToken token;

    address ADMIN = makeAddr("admin");
    address HOLDER = makeAddr("holder");

    uint256 cap;

    function setUp() public {
        token = new HackToken(ADMIN);
        cap = token.maxSupply();
    }

    function _mint(address to_, uint256 amount_) internal {
        vm.prank(ADMIN);
        token.mintTokens(to_, amount_);
    }

    // --- El tope se respeta ---

    /// @dev El limite es exacto: se puede emitir el tope entero, ni un wei mas.
    function test_HCTKN004_CanMintExactlyUpToTheCap() public {
        _mint(HOLDER, cap);

        assertEq(token.mintedTokens(), cap, "the whole cap has been issued");
        assertEq(token.totalSupply(), cap, "and it is all in circulation");
        assertEq(token.remainingMintable(), 0, "no headroom left");
    }

    /// @dev Un wei por encima revierte, tanto de golpe como sumando emisiones.
    function test_HCTKN004_CannotMintOneWeiAboveTheCap() public {
        _mint(HOLDER, cap);

        vm.prank(ADMIN);
        vm.expectRevert(HackToken.MaxSupplyExceeded.selector);
        token.mintTokens(HOLDER, 1);
    }

    function test_HCTKN004_CapAppliesAcrossSeparateMints() public {
        _mint(HOLDER, cap / 2);
        _mint(HOLDER, cap / 2);

        assertEq(token.remainingMintable(), 0, "two halves exhaust the cap");

        vm.prank(ADMIN);
        vm.expectRevert(HackToken.MaxSupplyExceeded.selector);
        token.mintTokens(HOLDER, 1);
    }

    // --- Quemar no devuelve margen: la propiedad declarada ---

    /// @dev El nucleo de la decision. Quemar reduce el circulante pero no el contador de
    /// emision, asi que el margen no vuelve. Es deliberado, no un descuido.
    function test_HCTKN004_BurningDoesNotFreeHeadroom() public {
        _mint(HOLDER, cap);

        vm.prank(HOLDER);
        token.burn(cap / 4);

        assertEq(token.totalSupply(), cap - cap / 4, "circulating supply drops");
        assertEq(token.mintedTokens(), cap, "lifetime issuance does not");
        assertEq(token.remainingMintable(), 0, "and no headroom is handed back");

        vm.prank(ADMIN);
        vm.expectRevert(HackToken.MaxSupplyExceeded.selector);
        token.mintTokens(HOLDER, 1);
    }

    /// @dev Caso extremo: circulante a cero y el tope sigue agotado. Es la diferencia entre
    /// las dos semanticas, reducida a su expresion minima.
    function test_HCTKN004_EmptySupplyStillHasNoHeadroom() public {
        _mint(HOLDER, cap);

        vm.prank(HOLDER);
        token.burn(cap);

        assertEq(token.totalSupply(), 0, "nothing is in circulation");
        assertEq(token.remainingMintable(), 0, "and nothing can be minted either");
    }

    /// @dev Lo mismo por la via de burnFrom, para que ninguna de las dos rutas de quema
    /// pueda usarse como reciclador de margen de emision.
    function test_HCTKN004_BurnFromDoesNotFreeHeadroomEither() public {
        _mint(HOLDER, cap);

        address spender = makeAddr("spender");
        vm.prank(HOLDER);
        token.approve(spender, cap / 10);

        vm.prank(spender);
        token.burnFrom(HOLDER, cap / 10);

        assertEq(token.mintedTokens(), cap, "lifetime issuance is untouched");
        assertEq(token.remainingMintable(), 0, "no headroom returned");
    }

    // --- remainingMintable() dice la verdad ---

    function test_HCTKN004_RemainingMintableStartsAtFullCap() public view {
        assertEq(token.remainingMintable(), cap, "nothing issued yet");
        assertEq(token.mintedTokens(), 0, "counter starts at zero");
    }

    function test_HCTKN004_RemainingMintableTracksIssuance() public {
        _mint(HOLDER, 400_000_000 ether);
        assertEq(token.remainingMintable(), cap - 400_000_000 ether, "headroom drops by what was issued");

        _mint(HOLDER, 100_000_000 ether);
        assertEq(token.remainingMintable(), cap - 500_000_000 ether, "and keeps tracking");
    }

    /// @dev La invariante que un integrador puede asumir: lo emitido mas lo que queda por
    /// emitir es siempre el tope, pase lo que pase con las quemas.
    function test_HCTKN004_MintedPlusRemainingAlwaysEqualsCap() public {
        assertEq(token.mintedTokens() + token.remainingMintable(), cap, "holds at genesis");

        _mint(HOLDER, 300_000_000 ether);
        assertEq(token.mintedTokens() + token.remainingMintable(), cap, "holds after minting");

        vm.prank(HOLDER);
        token.burn(100_000_000 ether);
        assertEq(token.mintedTokens() + token.remainingMintable(), cap, "holds after burning");
    }

    /// @dev El reparto de la tokenomics cabe entero y agota el tope exactamente. Si alguien
    /// cambia maxSupply o los porcentajes sin revisar el otro lado, este test lo detecta.
    function test_HCTKN004_TokenomicsDistributionFitsExactly() public {
        uint256 team = (cap * 10) / 100;
        uint256 privateSale = (cap * 5) / 100;
        uint256 publicPresale = (cap * 10) / 100;
        uint256 publicSale = (cap * 15) / 100;
        uint256 incentives = (cap * 30) / 100;
        uint256 treasury = (cap * 20) / 100;
        uint256 airdrops = (cap * 10) / 100;

        _mint(makeAddr("team"), team);
        _mint(makeAddr("private-sale"), privateSale);
        _mint(makeAddr("public-presale"), publicPresale);
        _mint(makeAddr("public-sale"), publicSale);
        _mint(makeAddr("incentives"), incentives);
        _mint(makeAddr("treasury"), treasury);
        _mint(makeAddr("airdrops"), airdrops);

        assertEq(token.mintedTokens(), cap, "the seven buckets sum to the cap");
        assertEq(token.remainingMintable(), 0, "leaving nothing unallocated");
    }
}
