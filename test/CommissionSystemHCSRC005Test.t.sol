// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { CommissionSystem } from "../src/CommissionSystem.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { MentorshipSessions } from "../src/MentorshipSessions.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";
import { StakingContract } from "../src/StakingContract.sol";

/// @dev Fuentes de exencion rotas para comprobar que el cobro falla cerrado.
contract RevertingStaking {
    function hasNoCommission(address) external pure returns (bool) {
        revert("staking down");
    }
}

contract GasBurningStaking {
    function hasNoCommission(address) external view returns (bool exempt) {
        while (gasleft() > 0) {
            exempt = !exempt;
        }
    }
}

contract SilentStaking {
    fallback() external { }
}

contract MalformedStaking {
    function hasNoCommission(address) external pure returns (uint256) {
        return 2;
    }
}

/// @dev Regresiones de HC-SRC-005: CommissionSystem consulta el beneficio de
/// no pagar comision de StakingContract. Un pagador con el beneficio no paga
/// la comision, y el beneficiario recibe lo mismo que sin el.
contract CommissionSystemHCSRC005Test is Test {
    CommissionSystem commission;
    StakingContract staking;
    HackToken token;

    address TREASURY = makeAddr("treasury");
    address PAYER = makeAddr("payer");
    address PAYEE = makeAddr("payee");
    address STRANGER = makeAddr("stranger");

    uint256 constant GROSS = 1_000 ether;
    uint256 constant FEE = 50 ether; // 5% por defecto
    uint256 constant STAKE = 100_000 ether;

    function setUp() public {
        token = new HackToken(address(this));
        IncentivesPool pool = new IncentivesPool(address(token));
        staking = new StakingContract(address(token), address(pool), address(new RoleRegistry()));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(staking));

        commission = new CommissionSystem(address(token), TREASURY, address(staking));
        commission.grantRole(commission.TRANSACTION_ROLE(), address(this));

        token.mintTokens(PAYER, STAKE + 10_000 ether);
        vm.startPrank(PAYER);
        token.approve(address(staking), STAKE);
        token.approve(address(commission), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Stake de 100.000 HACK a un ano, madurado y con el beneficio activo.
    function _activateBenefit() internal {
        _activateBenefitFor(PAYER);
    }

    /// @dev La cuenta tiene que tener el stake y el approve hacia staking.
    function _activateBenefitFor(address account_) internal {
        uint256 oneYear = staking.ONE_YEAR();
        vm.startPrank(account_);
        staking.stake(STAKE, oneYear);
        vm.warp(block.timestamp + oneYear);
        staking.activateNoCommission(0);
        vm.stopPrank();
        assertTrue(staking.hasNoCommission(account_));
    }

    /// @dev Un contrato transaccional distinto del pagador, con TRANSACTION_ROLE.
    function _transactionCaller() internal returns (address caller) {
        caller = makeAddr("transaction-contract");
        commission.grantRole(commission.TRANSACTION_ROLE(), caller);
    }

    function _collect(bytes32 evidenceId_) internal returns (uint256 net) {
        net = commission.collectCommission(evidenceId_, PAYER, PAYEE, GROSS, "payment");
    }

    function test_HCSRC005_EligiblePayerPaysNoCommission() public {
        _activateBenefit();
        uint256 payerBefore = token.balanceOf(PAYER);

        uint256 net = _collect(keccak256("tx"));

        assertEq(token.balanceOf(TREASURY), 0, "treasury receives nothing");
        assertEq(payerBefore - token.balanceOf(PAYER), GROSS - FEE, "payer saves the commission");
        assertEq(token.balanceOf(PAYEE), GROSS - FEE, "payee receives the usual net");
        assertEq(net, GROSS - FEE, "returned net matches what the payee got");
        assertEq(commission.totalCommissionsCollected(), 0, "no commission accounted");
    }

    function test_HCSRC005_IneligiblePayerPaysTheConfiguredCommission() public {
        uint256 payerBefore = token.balanceOf(PAYER);

        _collect(keccak256("tx"));

        assertEq(token.balanceOf(TREASURY), FEE, "treasury gets 5%");
        assertEq(payerBefore - token.balanceOf(PAYER), GROSS, "payer pays the gross amount");
        assertEq(token.balanceOf(PAYEE), GROSS - FEE, "payee gets the net");
    }

    /// @dev El beneficiario cobra lo mismo tenga o no el pagador la exencion.
    function test_HCSRC005_PayeeReceivesTheSameWithOrWithoutTheBenefit() public {
        _collect(keccak256("before"));
        uint256 withoutBenefit = token.balanceOf(PAYEE);

        _activateBenefit();
        _collect(keccak256("after"));

        assertEq(token.balanceOf(PAYEE) - withoutBenefit, withoutBenefit, "same net in both cases");
    }

    function test_HCSRC005_CommissionReturnsAfterBenefitIsDeactivated() public {
        _activateBenefit();
        vm.prank(PAYER);
        staking.deactivateNoCommission();

        _collect(keccak256("tx"));

        assertEq(token.balanceOf(TREASURY), FEE, "the commission is charged again");
    }

    function test_HCSRC005_CommissionReturnsAfterBackingStakeIsWithdrawn() public {
        _activateBenefit();
        vm.prank(PAYER);
        staking.withdrawPrincipal(0);

        _collect(keccak256("tx"));

        assertEq(token.balanceOf(TREASURY), FEE, "without the backing stake there is no exemption");
    }

    function test_HCSRC005_WaiverIsRecordedInAnEvent() public {
        _activateBenefit();
        bytes32 evidenceId = keccak256("tx");

        vm.expectEmit(true, true, false, true);
        emit CommissionSystem.CommissionWaived(evidenceId, PAYER, FEE);
        _collect(evidenceId);
    }

    function test_HCSRC005_PreviewForReflectsTheExemption() public {
        (uint256 feeBefore, uint256 paysBefore, uint256 receivesBefore) =
            commission.previewCommissionFor(PAYER, GROSS);
        assertEq(feeBefore, FEE);
        assertEq(paysBefore, GROSS);
        assertEq(receivesBefore, GROSS - FEE);

        _activateBenefit();
        (uint256 feeAfter, uint256 paysAfter, uint256 receivesAfter) =
            commission.previewCommissionFor(PAYER, GROSS);
        assertEq(feeAfter, 0, "no commission with the benefit");
        assertEq(paysAfter, GROSS - FEE, "the payer pays only the net");
        assertEq(receivesAfter, GROSS - FEE, "the payee receives the same");
    }

    function test_HCSRC005_AdminCanUpdateTheStakingSource() public {
        address newStaking = address(new RevertingStaking());

        vm.expectEmit(true, true, false, false);
        emit CommissionSystem.StakingContractUpdated(address(staking), newStaking);
        commission.setStakingContract(newStaking);

        assertEq(address(commission.stakingContract()), newStaking);
    }

    function test_HCSRC005_StakingSourceRejectsZeroAndNonAdmins() public {
        vm.expectRevert(CommissionSystem.InvalidAddress.selector);
        commission.setStakingContract(address(0));

        bytes32 adminRole = commission.DEFAULT_ADMIN_ROLE();
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, adminRole)
        );
        commission.setStakingContract(makeAddr("new-staking"));
    }

    function test_HCSRC005_ConstructorRejectsZeroStakingSource() public {
        vm.expectRevert(CommissionSystem.InvalidAddress.selector);
        new CommissionSystem(address(token), TREASURY, address(0));
    }

    /// @dev Una EOA como fuente no responderia nunca. Como una consulta
    /// fallida cobra la comision normal, dejaria sin exencion a todos los
    /// pagadores.
    function test_HCSRC005_StakingSourceMustBeAContract() public {
        address eoa = makeAddr("eoa");

        vm.expectRevert(CommissionSystem.InvalidAddress.selector);
        commission.setStakingContract(eoa);

        vm.expectRevert(CommissionSystem.InvalidAddress.selector);
        new CommissionSystem(address(token), TREASURY, eoa);
    }

    /// @dev Un pagador con la exencion paga la comision normal si la fuente
    /// falla, el pago no se bloquea y el fallo queda en un evento.
    function _assertFailsClosed(address source_) internal {
        _activateBenefit();
        commission.setStakingContract(source_);
        bytes32 evidenceId = keccak256("tx");

        vm.expectEmit(true, true, false, false);
        emit CommissionSystem.ExemptionCheckFailed(evidenceId, PAYER);
        _collect(evidenceId);

        assertEq(token.balanceOf(TREASURY), FEE, "the normal commission is charged");
        assertEq(token.balanceOf(PAYEE), GROSS - FEE, "the payment goes through");
    }

    function test_HCSRC005_RevertingStakingSourceChargesTheCommission() public {
        _assertFailsClosed(address(new RevertingStaking()));
    }

    function test_HCSRC005_GasBurningStakingSourceChargesTheCommission() public {
        _assertFailsClosed(address(new GasBurningStaking()));
    }

    function test_HCSRC005_StakingSourceWithoutReturnDataChargesTheCommission() public {
        _assertFailsClosed(address(new SilentStaking()));
    }

    function test_HCSRC005_MalformedExemptionAnswerChargesTheCommission() public {
        _assertFailsClosed(address(new MalformedStaking()));
    }

    function test_HCSRC005_PreviewForFailsClosedWhenTheSourceFails() public {
        _activateBenefit();
        commission.setStakingContract(address(new RevertingStaking()));

        (uint256 fee, uint256 pays, uint256 receives) = commission.previewCommissionFor(PAYER, GROSS);
        assertEq(fee, FEE, "the preview shows the normal commission");
        assertEq(pays, GROSS);
        assertEq(receives, GROSS - FEE);
    }

    /// @dev Con poco gas la llamada puede revertir, pero si sale adelante un
    /// pagador con la exencion nunca paga la comision.
    function testFuzz_HCSRC005_LowGasNeverChargesAnExemptPayer(uint256 gas_) public {
        _activateBenefit();
        gas_ = bound(gas_, 30_000, 300_000);

        try commission.collectCommission{ gas: gas_ }(keccak256("tx"), PAYER, PAYEE, GROSS, "payment") {
            assertEq(token.balanceOf(TREASURY), 0, "an exempt payer is never charged");
            assertEq(token.balanceOf(PAYEE), GROSS - FEE, "the payee gets the net");
        } catch {
            assertEq(token.balanceOf(TREASURY), 0, "a reverted call charges nothing");
        }
    }

    /// @dev En la vista no hay transferencias despues de la consulta que
    /// hagan revertir por falta de gas. Si responde, para un pagador con la
    /// exencion nunca muestra la comision.
    function testFuzz_HCSRC005_LowGasNeverMakesThePreviewChargeAnExemptPayer(uint256 gas_) public {
        _activateBenefit();
        gas_ = bound(gas_, 1_000, 60_000);

        try commission.previewCommissionFor{ gas: gas_ }(PAYER, GROSS) returns (uint256 fee, uint256, uint256) {
            assertEq(fee, 0, "an exempt payer is never shown the commission");
        } catch { }
    }

    /// @dev La exencion del contrato que llama no exime al pagador.
    function test_HCSRC005_CallerExemptionDoesNotExemptThePayer() public {
        address caller = _transactionCaller();
        token.mintTokens(caller, STAKE);
        vm.prank(caller);
        token.approve(address(staking), STAKE);
        _activateBenefitFor(caller);

        vm.prank(caller);
        commission.collectCommission(keccak256("tx"), PAYER, PAYEE, GROSS, "payment");

        assertEq(token.balanceOf(TREASURY), FEE, "the payer pays, so the payer's status decides");
    }

    /// @dev Un pagador con la exencion no paga aunque quien llama no la tenga.
    function test_HCSRC005_PayerExemptionAppliesWhateverTheCaller() public {
        address caller = _transactionCaller();
        _activateBenefit();
        assertFalse(staking.hasNoCommission(caller));

        vm.prank(caller);
        commission.collectCommission(keccak256("tx"), PAYER, PAYEE, GROSS, "payment");

        assertEq(token.balanceOf(TREASURY), 0, "the payer's exemption applies");
        assertEq(token.balanceOf(PAYEE), GROSS - FEE);
    }

    /// @dev Con exencion hay un solo CommissionCollected por transaccion, con
    /// comision 0, mas un CommissionWaived. El indexador cuenta el primero.
    function test_HCSRC005_WaivedPaymentEmitsOneCollectedRecord() public {
        _activateBenefit();

        vm.recordLogs();
        _collect(keccak256("tx"));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 collected;
        uint256 waived;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(commission)) continue;
            if (logs[i].topics[0] == CommissionSystem.CommissionCollected.selector) {
                collected++;
                (, uint256 commissionAmount, ) = abi.decode(logs[i].data, (uint256, uint256, string));
                assertEq(commissionAmount, 0, "the record carries a zero commission");
            }
            if (logs[i].topics[0] == CommissionSystem.CommissionWaived.selector) waived++;
        }
        assertEq(collected, 1, "one transaction record");
        assertEq(waived, 1, "one waiver note");
    }

    /// @dev Con y sin exencion el beneficiario recibe exactamente el mismo
    /// neto, redondeo incluido, para cualquier bruto y cualquier tasa
    /// permitida. Lo que pagan los dos pagadores cuadra con tesoreria.
    function testFuzz_HCSRC005_NetIsIdenticalOnBothPaths(uint256 gross_, uint256 bps_) public {
        gross_ = bound(gross_, 1, 5_000 ether);
        bps_ = bound(bps_, 0, 2_000);
        commission.setCommissionRate(bps_);

        address otherPayer = makeAddr("other-payer");
        address otherPayee = makeAddr("other-payee");
        token.mintTokens(otherPayer, gross_);
        vm.prank(otherPayer);
        token.approve(address(commission), type(uint256).max);

        _activateBenefit();
        uint256 exemptBefore = token.balanceOf(PAYER);
        uint256 fee = (gross_ * bps_) / commission.BPS_DENOMINATOR();

        commission.collectCommission(keccak256("exempt"), PAYER, PAYEE, gross_, "payment");
        commission.collectCommission(keccak256("normal"), otherPayer, otherPayee, gross_, "payment");

        assertEq(token.balanceOf(PAYEE), token.balanceOf(otherPayee), "same net on both paths");
        assertEq(token.balanceOf(PAYEE), gross_ - fee, "the net is the gross minus the rounded fee");
        assertEq(exemptBefore - token.balanceOf(PAYER), gross_ - fee, "the exempt payer pays only the net");
        assertEq(token.balanceOf(otherPayer), 0, "the other payer pays the gross");
        assertEq(token.balanceOf(TREASURY), fee, "treasury gets only the non-exempt fee");
    }

    /// @dev Las clases 1 a 1 del Mecanismo 12 se pagan fuera de la cadena.
    /// MentorshipSessions no mueve tokens ni llama a CommissionSystem, asi que
    /// en una clase completa nadie paga comision.
    function test_HCSRC005_OneToOneSessionChargesNoCommission() public {
        RoleRegistry registry = new RoleRegistry();
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));
        address talent = makeAddr("talent");
        address educator = makeAddr("educator");
        registry.registerRole(talent, RoleRegistry.BusinessRole.Talent);
        registry.registerRole(educator, RoleRegistry.BusinessRole.Educator);
        MentorshipSessions mentorship = new MentorshipSessions(address(registry));

        token.mintTokens(talent, GROSS);
        token.mintTokens(educator, GROSS);

        vm.recordLogs();
        vm.prank(talent);
        uint256 sessionId = mentorship.requestSession(educator);
        vm.prank(educator);
        mentorship.acceptSession(sessionId);
        vm.prank(talent);
        mentorship.submitDepositProof(sessionId, "ipfs://deposit-proof");
        vm.prank(educator);
        mentorship.confirmDeposit(sessionId, true);
        vm.prank(talent);
        mentorship.submitFinalProof(sessionId, "ipfs://final-proof");
        vm.prank(educator);
        mentorship.confirmFinal(sessionId, true);
        vm.prank(educator);
        mentorship.issueCertificate(sessionId, "ipfs://certificate");
        vm.prank(talent);
        mentorship.confirmSessionCompleted(sessionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        MentorshipSessions.Session memory s = mentorship.getSession(sessionId);
        assertEq(uint8(s.status), uint8(MentorshipSessions.SessionStatus.Completed), "the session completes");

        assertEq(token.balanceOf(talent), GROSS, "the talent pays nothing on-chain");
        assertEq(token.balanceOf(educator), GROSS, "the educator receives nothing on-chain");
        assertEq(token.balanceOf(TREASURY), 0, "no commission");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(commission), "CommissionSystem is not involved");
            assertTrue(logs[i].emitter != address(token), "no token moves");
        }
    }

    /// @dev La exencion exige un stake de un ano ya madurado. Hacer stake y
    /// pagar en el mismo bloque no la da, y el stake no se puede retirar.
    function test_HCSRC005_StakeAndPayInTheSameBlockChargesTheCommission() public {
        uint256 oneYear = staking.ONE_YEAR();
        vm.startPrank(PAYER);
        staking.stake(STAKE, oneYear);

        vm.expectRevert(StakingContract.NoCommissionStakeNotMature.selector);
        staking.activateNoCommission(0);
        vm.stopPrank();

        _collect(keccak256("tx"));
        assertEq(token.balanceOf(TREASURY), FEE, "no exemption without a matured stake");

        vm.prank(PAYER);
        vm.expectRevert(StakingContract.StakingPeriodNotOver.selector);
        staking.withdrawPrincipal(0);
    }
}
