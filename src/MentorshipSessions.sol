// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title MentorshipSessions
 * @dev Implementa el Mecanismo 12: sesiones de mentoria/formacion 1:1
 * entre Talento y Educador, con pago 50/50 FUERA de la cadena y
 * arbitraje de HackChain en caso de disputa.
 *
 * Este contrato NO mueve tokens. Solo registra el estado de la sesion,
 * la evidencia de pago aportada por el Talento, y las confirmaciones
 * del Educador. Ver supuestos de diseño documentados junto al codigo.
 */
contract MentorshipSessions is AccessControl {
    bytes32 public constant ENFORCER_ROLE = keccak256("ENFORCER_ROLE");

    enum SessionStatus {
        None,
        Requested,
        Accepted,
        DepositProofSubmitted,
        DepositDisputed,
        DepositConfirmed,
        FinalProofSubmitted,
        FinalDisputed,
        FinalConfirmed,
        CertificateIssued,
        Completed,
        Cancelled
    }

    struct Session {
        address talent;
        address educator;
        SessionStatus status;
        string depositProofURI;
        string finalProofURI;
        string certificateURI;
        uint256 certificateIssuedAt;
        bool certificateIssueFlagged;
    }

    IRoleRegistry public roleRegistry;

    uint256 public nextSessionId;
    mapping(uint256 => Session) public sessions;

    uint256 public constant AUTO_CONFIRM_WINDOW = 24 hours;

    // --- Errors ---
    error InvalidAddress();
    error NotTalent();
    error NotEducator();
    error NotSessionTalent();
    error NotSessionEducator();
    error InvalidStatus();
    error TooEarlyForAutoConfirm();
    error CertificateIssueFlagged();

    // --- Events ---
    event SessionRequested(uint256 indexed sessionId, address indexed talent, address indexed educator);
    event SessionAccepted(uint256 indexed sessionId);
    event DepositProofSubmitted(uint256 indexed sessionId, string proofURI);
    event DepositConfirmed(uint256 indexed sessionId);
    event DepositDisputed(uint256 indexed sessionId);
    event DepositDisputeResolved(uint256 indexed sessionId, bool wasPaid);
    event FinalProofSubmitted(uint256 indexed sessionId, string proofURI);
    event FinalConfirmed(uint256 indexed sessionId);
    event FinalDisputed(uint256 indexed sessionId);
    event FinalDisputeResolved(uint256 indexed sessionId, bool wasPaid);
    event CertificateIssued(uint256 indexed sessionId, string certificateURI);
    event CertificateIssueFlaggedEvent(uint256 indexed sessionId);
    event SessionCompleted(uint256 indexed sessionId, bool wasAuto);

    constructor(address roleRegistry_) {
        if (roleRegistry_ == address(0)) revert InvalidAddress();
        roleRegistry = IRoleRegistry(roleRegistry_);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ENFORCER_ROLE, msg.sender);
    }

    modifier onlySessionTalent(uint256 sessionId_) {
        if (sessions[sessionId_].talent != msg.sender) revert NotSessionTalent();
        _;
    }

    modifier onlySessionEducator(uint256 sessionId_) {
        if (sessions[sessionId_].educator != msg.sender) revert NotSessionEducator();
        _;
    }

    // --- 1. Talento solicita la clase ---
    function requestSession(address educator_) external returns (uint256 sessionId) {
        if (educator_ == address(0)) revert InvalidAddress();
        if (!roleRegistry.isTalent(msg.sender)) revert NotTalent();
        if (!roleRegistry.isEducator(educator_)) revert NotEducator();

        sessionId = nextSessionId++;
        sessions[sessionId] = Session({
            talent: msg.sender,
            educator: educator_,
            status: SessionStatus.Requested,
            depositProofURI: "",
            finalProofURI: "",
            certificateURI: "",
            certificateIssuedAt: 0,
            certificateIssueFlagged: false
        });

        emit SessionRequested(sessionId, msg.sender, educator_);
    }

    // --- 2. Educador acepta ---
    function acceptSession(uint256 sessionId_) external onlySessionEducator(sessionId_) {
        Session storage s = sessions[sessionId_];
        if (s.status != SessionStatus.Requested) revert InvalidStatus();
        s.status = SessionStatus.Accepted;
        emit SessionAccepted(sessionId_);
    }

    // --- 3-4. Talento paga 50% fuera de cadena y sube evidencia ---
    function submitDepositProof(uint256 sessionId_, string calldata proofURI_)
        external
        onlySessionTalent(sessionId_)
    {
        Session storage s = sessions[sessionId_];
        if (s.status != SessionStatus.Accepted) revert InvalidStatus();
        s.depositProofURI = proofURI_;
        s.status = SessionStatus.DepositProofSubmitted;
        emit DepositProofSubmitted(sessionId_, proofURI_);
    }

    // --- 5. Educador confirma o disputa el primer pago ---
    function confirmDeposit(uint256 sessionId_, bool received_)
        external
        onlySessionEducator(sessionId_)
    {
        Session storage s = sessions[sessionId_];
        if (s.status != SessionStatus.DepositProofSubmitted) revert InvalidStatus();

        if (received_) {
            s.status = SessionStatus.DepositConfirmed;
            emit DepositConfirmed(sessionId_);
        } else {
            s.status = SessionStatus.DepositDisputed;
            emit DepositDisputed(sessionId_);
        }
    }

    function resolveDepositDispute(uint256 sessionId_, bool wasPaid_)
        external
        onlyRole(ENFORCER_ROLE)
    {
        Session storage s = sessions[sessionId_];
        if (s.status != SessionStatus.DepositDisputed) revert InvalidStatus();

        s.status = wasPaid_ ? SessionStatus.DepositConfirmed : SessionStatus.Cancelled;
        emit DepositDisputeResolved(sessionId_, wasPaid_);
    }

    // --- 6. La clase ocurre (sin accion on-chain) ---

    // --- 7-8. Talento paga el 50% restante y sube evidencia ---
    function submitFinalProof(uint256 sessionId_, string calldata proofURI_)
        external
        onlySessionTalent(sessionId_)
    {
        Session storage s = sessions[sessionId_];
        if (s.status != SessionStatus.DepositConfirmed) revert InvalidStatus();
        s.finalProofURI = proofURI_;
        s.status = SessionStatus.FinalProofSubmitted;
        emit FinalProofSubmitted(sessionId_, proofURI_);
    }

    // --- 9. Educador confirma o disputa el pago final ---
    function confirmFinal(uint256 sessionId_, bool received_)
        external
        onlySessionEducator(sessionId_)
    {
        Session storage s = sessions[sessionId_];
        if (s.status != SessionStatus.FinalProofSubmitted) revert InvalidStatus();

        if (received_) {
            s.status = SessionStatus.FinalConfirmed;
            emit FinalConfirmed(sessionId_);
        } else {
            s.status = SessionStatus.FinalDisputed;
            emit FinalDisputed(sessionId_);
        }
    }

    function resolveFinalDispute(uint256 sessionId_, bool wasPaid_)
        external
        onlyRole(ENFORCER_ROLE)
    {
        Session storage s = sessions[sessionId_];
        if (s.status != SessionStatus.FinalDisputed) revert InvalidStatus();

        s.status = wasPaid_ ? SessionStatus.FinalConfirmed : SessionStatus.Cancelled;
        emit FinalDisputeResolved(sessionId_, wasPaid_);
    }

    // --- 10. Educador emite el certificado ---
    function issueCertificate(uint256 sessionId_, string calldata certificateURI_)
        external
        onlySessionEducator(sessionId_)
    {
        Session storage s = sessions[sessionId_];
        if (s.status != SessionStatus.FinalConfirmed) revert InvalidStatus();

        s.certificateURI = certificateURI_;
        s.certificateIssuedAt = block.timestamp;
        s.status = SessionStatus.CertificateIssued;

        emit CertificateIssued(sessionId_, certificateURI_);
    }

    // --- 11. Talento confirma finalizada la clase, o reporta un error ---
    function confirmSessionCompleted(uint256 sessionId_) external onlySessionTalent(sessionId_) {
        Session storage s = sessions[sessionId_];
        if (s.status != SessionStatus.CertificateIssued) revert InvalidStatus();

        s.status = SessionStatus.Completed;
        emit SessionCompleted(sessionId_, false);
    }

    function flagCertificateIssue(uint256 sessionId_) external onlySessionTalent(sessionId_) {
        Session storage s = sessions[sessionId_];
        if (s.status != SessionStatus.CertificateIssued) revert InvalidStatus();

        s.certificateIssueFlagged = true;
        emit CertificateIssueFlaggedEvent(sessionId_);
    }

    /// @notice Tras un flagCertificateIssue(), HackChain resuelve manualmente.
    function adminConfirmSessionCompleted(uint256 sessionId_) external onlyRole(ENFORCER_ROLE) {
        Session storage s = sessions[sessionId_];
        if (s.status != SessionStatus.CertificateIssued) revert InvalidStatus();

        s.status = SessionStatus.Completed;
        emit SessionCompleted(sessionId_, false);
    }

    /// @notice Auto-confirmacion tras 24h sin respuesta del Talento,
    /// siempre que no se haya reportado un error de certificado.
    function autoCompleteSession(uint256 sessionId_) external {
        Session storage s = sessions[sessionId_];
        if (s.status != SessionStatus.CertificateIssued) revert InvalidStatus();
        if (s.certificateIssueFlagged) revert CertificateIssueFlagged();
        if (block.timestamp < s.certificateIssuedAt + AUTO_CONFIRM_WINDOW) revert TooEarlyForAutoConfirm();

        s.status = SessionStatus.Completed;
        emit SessionCompleted(sessionId_, true);
    }

    // --- Views ---
    function getSession(uint256 sessionId_) external view returns (Session memory) {
        return sessions[sessionId_];
    }
}

interface IRoleRegistry {
    function isEducator(address account_) external view returns (bool);
    function isTalent(address account_) external view returns (bool);
}
