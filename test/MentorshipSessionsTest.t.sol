// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { MentorshipSessions } from "../src/MentorshipSessions.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

contract MentorshipSessionsTest is Test {
    MentorshipSessions mentorship;
    RoleRegistry registry;

    address TALENT = makeAddr("talent");
    address EDUCATOR = makeAddr("educator");
    address STRANGER = makeAddr("stranger");

    function setUp() public {
        registry = new RoleRegistry();
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));
        registry.registerRole(TALENT, RoleRegistry.BusinessRole.Talent);
        registry.registerRole(EDUCATOR, RoleRegistry.BusinessRole.Educator);

        mentorship = new MentorshipSessions(address(registry));
    }

    /// @dev Flujo feliz completo, los 12 pasos, sin disputas.
    function test_FullHappyPathFlow() public {
        vm.prank(TALENT);
        uint256 sessionId = mentorship.requestSession(EDUCATOR);

        vm.prank(EDUCATOR);
        mentorship.acceptSession(sessionId);

        vm.prank(TALENT);
        mentorship.submitDepositProof(sessionId, "ipfs://deposit-proof");

        vm.prank(EDUCATOR);
        mentorship.confirmDeposit(sessionId, true);

        vm.prank(TALENT);
        mentorship.submitFinalProof(sessionId, "ipfs://final-proof");

        vm.prank(EDUCATOR);
        mentorship.confirmFinal(sessionId, true);

        vm.prank(EDUCATOR);
        mentorship.issueCertificate(sessionId, "ipfs://certificate");

        vm.prank(TALENT);
        mentorship.confirmSessionCompleted(sessionId);

        MentorshipSessions.Session memory s = mentorship.getSession(sessionId);
        assertEq(uint8(s.status), uint8(MentorshipSessions.SessionStatus.Completed), "session not completed");
    }

    function test_RevertsWhenRequesterIsNotRegisteredTalent() public {
        vm.prank(STRANGER);
        vm.expectRevert(MentorshipSessions.NotTalent.selector);
        mentorship.requestSession(EDUCATOR);
    }

    function test_RevertsWhenTargetIsNotRegisteredEducator() public {
        vm.prank(TALENT);
        vm.expectRevert(MentorshipSessions.NotEducator.selector);
        mentorship.requestSession(STRANGER);
    }

    function test_RevertsWhenStrangerTriesToAccept() public {
        vm.prank(TALENT);
        uint256 sessionId = mentorship.requestSession(EDUCATOR);

        vm.prank(STRANGER);
        vm.expectRevert(MentorshipSessions.NotSessionEducator.selector);
        mentorship.acceptSession(sessionId);
    }

    /// @dev Camino de disputa en el primer pago: el educador dice que no
    /// recibió, HackChain confirma que sí se pagó.
    function test_DepositDisputeResolvedAsPaid() public {
        vm.prank(TALENT);
        uint256 sessionId = mentorship.requestSession(EDUCATOR);

        vm.prank(EDUCATOR);
        mentorship.acceptSession(sessionId);

        vm.prank(TALENT);
        mentorship.submitDepositProof(sessionId, "ipfs://deposit-proof");

        vm.prank(EDUCATOR);
        mentorship.confirmDeposit(sessionId, false); // disputa

        mentorship.resolveDepositDispute(sessionId, true); // HackChain confirma que si se pago

        MentorshipSessions.Session memory s = mentorship.getSession(sessionId);
        assertEq(
            uint8(s.status),
            uint8(MentorshipSessions.SessionStatus.DepositConfirmed),
            "dispute should resolve to confirmed"
        );
    }

    /// @dev Camino de disputa resuelto como NO pagado: la sesion se cancela.
    function test_DepositDisputeResolvedAsUnpaidCancelsSession() public {
        vm.prank(TALENT);
        uint256 sessionId = mentorship.requestSession(EDUCATOR);

        vm.prank(EDUCATOR);
        mentorship.acceptSession(sessionId);

        vm.prank(TALENT);
        mentorship.submitDepositProof(sessionId, "ipfs://deposit-proof");

        vm.prank(EDUCATOR);
        mentorship.confirmDeposit(sessionId, false);

        mentorship.resolveDepositDispute(sessionId, false);

        MentorshipSessions.Session memory s = mentorship.getSession(sessionId);
        assertEq(
            uint8(s.status),
            uint8(MentorshipSessions.SessionStatus.Cancelled),
            "unpaid dispute should cancel session"
        );
    }

    /// @dev Auto-confirmacion tras 24h si el Talento no responde.
    function test_AutoCompletesAfter24HoursWithoutFlag() public {
        vm.prank(TALENT);
        uint256 sessionId = mentorship.requestSession(EDUCATOR);

        vm.prank(EDUCATOR);
        mentorship.acceptSession(sessionId);
        vm.prank(TALENT);
        mentorship.submitDepositProof(sessionId, "ipfs://deposit-proof");
        vm.prank(EDUCATOR);
        mentorship.confirmDeposit(sessionId, true);
        vm.prank(TALENT);
        mentorship.submitFinalProof(sessionId, "ipfs://final-proof");
        vm.prank(EDUCATOR);
        mentorship.confirmFinal(sessionId, true);
        vm.prank(EDUCATOR);
        mentorship.issueCertificate(sessionId, "ipfs://certificate");

        vm.warp(block.timestamp + 24 hours + 1);
        mentorship.autoCompleteSession(sessionId); // cualquiera puede llamarla

        MentorshipSessions.Session memory s = mentorship.getSession(sessionId);
        assertEq(uint8(s.status), uint8(MentorshipSessions.SessionStatus.Completed), "should auto-complete");
    }

    function test_AutoCompleteRevertsBeforeWindow() public {
        vm.prank(TALENT);
        uint256 sessionId = mentorship.requestSession(EDUCATOR);
        vm.prank(EDUCATOR);
        mentorship.acceptSession(sessionId);
        vm.prank(TALENT);
        mentorship.submitDepositProof(sessionId, "ipfs://deposit-proof");
        vm.prank(EDUCATOR);
        mentorship.confirmDeposit(sessionId, true);
        vm.prank(TALENT);
        mentorship.submitFinalProof(sessionId, "ipfs://final-proof");
        vm.prank(EDUCATOR);
        mentorship.confirmFinal(sessionId, true);
        vm.prank(EDUCATOR);
        mentorship.issueCertificate(sessionId, "ipfs://certificate");

        vm.expectRevert(MentorshipSessions.TooEarlyForAutoConfirm.selector);
        mentorship.autoCompleteSession(sessionId);
    }

    /// @dev Si el Talento reporta un error de certificado, el auto-confirm
    /// queda bloqueado hasta que HackChain resuelva manualmente.
    function test_FlaggedCertificateBlocksAutoComplete() public {
        vm.prank(TALENT);
        uint256 sessionId = mentorship.requestSession(EDUCATOR);
        vm.prank(EDUCATOR);
        mentorship.acceptSession(sessionId);
        vm.prank(TALENT);
        mentorship.submitDepositProof(sessionId, "ipfs://deposit-proof");
        vm.prank(EDUCATOR);
        mentorship.confirmDeposit(sessionId, true);
        vm.prank(TALENT);
        mentorship.submitFinalProof(sessionId, "ipfs://final-proof");
        vm.prank(EDUCATOR);
        mentorship.confirmFinal(sessionId, true);
        vm.prank(EDUCATOR);
        mentorship.issueCertificate(sessionId, "ipfs://certificate");

        vm.prank(TALENT);
        mentorship.flagCertificateIssue(sessionId);

        vm.warp(block.timestamp + 24 hours + 1);
        vm.expectRevert(MentorshipSessions.CertificateIssueFlagged.selector);
        mentorship.autoCompleteSession(sessionId);

        // HackChain resuelve manualmente
        mentorship.adminConfirmSessionCompleted(sessionId);

        MentorshipSessions.Session memory s = mentorship.getSession(sessionId);
        assertEq(uint8(s.status), uint8(MentorshipSessions.SessionStatus.Completed), "admin should resolve flagged session");
    }
}
