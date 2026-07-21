// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { CommissionSystem } from "../src/CommissionSystem.sol";
import { HackToken } from "../src/HackTokenERC20.sol";

contract CommissionSystemTest is Test {
    CommissionSystem commission;
    HackToken token;

    address TREASURY = makeAddr("treasury");
    address PAYER = makeAddr("payer");
    address PAYEE = makeAddr("payee");

    function setUp() public {
        token = new HackToken();
        token.mintTokens(PAYER, 10_000 ether);

        commission = new CommissionSystem(address(token), TREASURY);
        commission.grantRole(commission.TRANSACTION_ROLE(), address(this));

        vm.prank(PAYER);
        token.approve(address(commission), 10_000 ether);
    }

    function test_CollectsCommissionCorrectly() public {
        commission.collectCommission(
            keccak256("cert-001"), PAYER, PAYEE, 1000 ether, "certificate_emission"
        );

        assertEq(token.balanceOf(TREASURY), 50 ether, "treasury did not receive 5%");
        assertEq(token.balanceOf(PAYEE), 950 ether, "payee did not receive net amount");
        assertEq(commission.totalCommissionsCollected(), 50 ether, "accounting mismatch");
    }

    function test_CommissionCannotBeCollectedTwiceForSameEvidence() public {
        bytes32 evidenceId = keccak256("cert-001");

        commission.collectCommission(evidenceId, PAYER, PAYEE, 1000 ether, "certificate_emission");

        vm.expectRevert(CommissionSystem.AlreadyProcessed.selector);
        commission.collectCommission(evidenceId, PAYER, PAYEE, 1000 ether, "certificate_emission");
    }

    function test_RevertsWhenCalledWithoutTransactionRole() public {
        vm.prank(PAYER);
        vm.expectRevert();
        commission.collectCommission(
            keccak256("cert-002"), PAYER, PAYEE, 1000 ether, "certificate_emission"
        );
    }

    function test_RevertsWhenCommissionRateSetAboveLimit() public {
        vm.expectRevert(CommissionSystem.CommissionTooHigh.selector);
        commission.setCommissionRate(2_001);
    }

    function test_PreviewCommissionMatchesActualCollection() public {
        (uint256 previewFee, uint256 previewNet) = commission.previewCommission(1000 ether);

        commission.collectCommission(
            keccak256("cert-003"), PAYER, PAYEE, 1000 ether, "certificate_emission"
        );

        assertEq(previewFee, 50 ether, "preview fee mismatch");
        assertEq(previewNet, 950 ether, "preview net mismatch");
    }
}