// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";

contract IncentivesPoolM01Test is Test {
    IncentivesPool pool;
    HackToken token;

    function setUp() public {
        token = new HackToken();
        pool = new IncentivesPool(address(token));
        pool.grantRole(pool.DEPOSITOR_ROLE(), address(this));
    }

    /// @dev Escenario original de M-01: deposit() sin haber transferido
    /// tokens antes. Antes del fix, esto inflaba poolBalance a 1000
    /// mientras actualBalance() seguia en 0.
    function test_M01_RevertsWhenDepositingWithoutRealTransfer() public {
        vm.expectRevert(IncentivesPool.AccountingMismatch.selector);
        pool.deposit(1_000 ether, "accounting-only");
    }

    function test_M01_SucceedsWhenTokensWereActuallyTransferredFirst() public {
        token.mintTokens(address(this), 1_000 ether);
        token.transfer(address(pool), 1_000 ether);

        pool.deposit(1_000 ether, "real-deposit");

        assertEq(pool.poolBalance(), 1_000 ether, "accounting mismatch");
        assertEq(pool.actualBalance(), 1_000 ether, "real balance mismatch");
    }

    function test_M01_RevertsWhenDepositExceedsRealBalance() public {
        token.mintTokens(address(this), 500 ether);
        token.transfer(address(pool), 500 ether);

        // Se declara un depósito de 1000 pero solo se transfirieron 500 antes
        vm.expectRevert(IncentivesPool.AccountingMismatch.selector);
        pool.deposit(1_000 ether, "mismatched-deposit");
    }
}
