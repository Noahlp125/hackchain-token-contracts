// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title CommissionSystem
 * @dev Implementa el Mecanismo 8: Comisiones por transacción.
 *
 * Cobra una comisión (5% por defecto) en HACK sobre transacciones dentro
 * de la plataforma (emitir certificado, pagar por formación académica, etc.)
 * y la transfiere a la pool de tesorería.
 *
 * Diseñado para ser llamado por otros contratos "transaccionales" (p.ej. un
 * futuro CertificateSystem o el contrato del Mecanismo 12 de pago
 * Educador-Talento), no por el usuario final directamente. Sigue el
 * mismo patrón de roles que IncentivesPool.sol.
 */
contract CommissionSystem is AccessControl, ReentrancyGuard {
    // --- Roles ---

    /// @notice Rol asignado a los contratos transaccionales autorizados a
    /// invocar el cobro de comisión (p.ej. CertificateSystem, TrainingPayments).
    bytes32 public constant TRANSACTION_ROLE = keccak256("TRANSACTION_ROLE");

    // --- State ---

    /// @notice Referencia al token HACK.
    IERC20 public immutable hackToken;

    /// @notice Dirección de la pool de tesorería (recibe las comisiones).
    address public treasury;

    /// @notice Comisión en puntos básicos (5% = 500 bps). Ajustable por el admin.
    uint256 public commissionBps = 500;

    /// @notice Denominador para el cálculo de comisión (10_000 = 100%).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Total de comisiones cobradas históricamente (en HACK).
    uint256 public totalCommissionsCollected;

    /// @notice Registro de evidenceIds ya procesados para evitar cobros duplicados.
    mapping(bytes32 => bool) public processedTx;

    // --- Custom Errors ---

    error InvalidAddress();
    error AmountMustBeGreaterThanZero();
    error TransferFailed();
    error CommissionTooHigh();
    error AlreadyProcessed();

    // --- Events ---

    /// @dev Emitido cuando se cobra una comisión sobre una transacción.
    event CommissionCollected(
        bytes32 indexed evidenceId,
        address indexed payer,
        uint256 grossAmount,
        uint256 commissionAmount,
        string reason
    );

    /// @dev Emitido cuando el admin actualiza el porcentaje de comisión.
    event CommissionRateUpdated(uint256 oldBps, uint256 newBps);

    /// @dev Emitido cuando el admin actualiza la dirección de tesorería.
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // --- Constructor ---

    /**
     * @dev Despliega el contrato y lo vincula al token HACK y a la tesorería.
     * El deployer recibe DEFAULT_ADMIN_ROLE para gestionar roles y parámetros.
     * @param hackToken_ Dirección del token HACK.
     * @param treasury_ Dirección de la pool de tesorería.
     */
    constructor(address hackToken_, address treasury_) {
        if (hackToken_ == address(0)) revert InvalidAddress();
        if (treasury_ == address(0)) revert InvalidAddress();

        hackToken = IERC20(hackToken_);
        treasury = treasury_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // --- Core: Cobro de comisión ---

    /**
     * @notice Cobra la comisión sobre una transacción y transfiere el resto al beneficiario.
     * @dev Solo invocable por contratos con TRANSACTION_ROLE (p.ej. el contrato
     * que emite certificados o gestiona pagos de formación). El pagador (payer_)
     * debe haber hecho previamente approve() de grossAmount_ hacia este contrato.
     * @param evidenceId_ Identificador único de la transacción origen (p.ej. certId
     * o hiringId del contrato que llama). Evita el reprocesado de la misma transacción.
     * @param payer_ Dirección que paga la transacción (usuario).
     * @param payee_ Dirección que recibe el neto de la transacción (p.ej. Educador).
     * @param grossAmount_ Monto bruto de la transacción, en HACK.
     * @param reason_ Descripción legible de la transacción (p.ej. "certificate_emission").
     * @return netAmount Monto neto transferido al beneficiario tras descontar la comisión.
     */
    function collectCommission(
        bytes32 evidenceId_,
        address payer_,
        address payee_,
        uint256 grossAmount_,
        string calldata reason_
    ) external onlyRole(TRANSACTION_ROLE) nonReentrant returns (uint256 netAmount) {
        if (payer_ == address(0) || payee_ == address(0)) revert InvalidAddress();
        if (grossAmount_ == 0) revert AmountMustBeGreaterThanZero();
        if (processedTx[evidenceId_]) revert AlreadyProcessed();

        // Effect antes de la interacción externa (CEI pattern)
        processedTx[evidenceId_] = true;

        uint256 commissionAmount = (grossAmount_ * commissionBps) / BPS_DENOMINATOR;
        netAmount = grossAmount_ - commissionAmount;

        totalCommissionsCollected += commissionAmount;

        // Comisión -> tesorería
        bool successFee = hackToken.transferFrom(payer_, treasury, commissionAmount);
        if (!successFee) revert TransferFailed();

        // Neto -> beneficiario de la transacción
        bool successNet = hackToken.transferFrom(payer_, payee_, netAmount);
        if (!successNet) revert TransferFailed();

        emit CommissionCollected(evidenceId_, payer_, grossAmount_, commissionAmount, reason_);
    }

    // --- Admin ---

    /**
     * @notice Actualiza el porcentaje de comisión (en puntos básicos).
     * @dev Límite defensivo: no permite fijar una comisión superior al 20%.
     * @param newBps_ Nuevo porcentaje de comisión, en puntos básicos.
     */
    function setCommissionRate(uint256 newBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps_ > 2_000) revert CommissionTooHigh();
        uint256 old = commissionBps;
        commissionBps = newBps_;
        emit CommissionRateUpdated(old, newBps_);
    }

    /**
     * @notice Actualiza la dirección de la pool de tesorería.
     * @param newTreasury_ Nueva dirección de tesorería.
     */
    function setTreasury(address newTreasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury_ == address(0)) revert InvalidAddress();
        address old = treasury;
        treasury = newTreasury_;
        emit TreasuryUpdated(old, newTreasury_);
    }

    // --- Views ---

    /**
     * @notice Calcula la comisión que se cobraría sobre un monto dado, sin ejecutarla.
     * @param grossAmount_ Monto bruto de la transacción.
     * @return commissionAmount Comisión resultante.
     * @return netAmount Monto neto tras descontar la comisión.
     */
    function previewCommission(uint256 grossAmount_)
        external
        view
        returns (uint256 commissionAmount, uint256 netAmount)
    {
        commissionAmount = (grossAmount_ * commissionBps) / BPS_DENOMINATOR;
        netAmount = grossAmount_ - commissionAmount;
    }
}