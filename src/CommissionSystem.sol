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
 * futuro CertificateSystem), no por el usuario final directamente. Sigue el
 * mismo patrón de roles que IncentivesPool.sol. Las clases 1 a 1 del
 * Mecanismo 12 no llevan comisión, y su pago va fuera de la cadena.
 *
 * HC-SRC-005 fix: consulta StakingContract.hasNoCommission() sobre el
 * pagador. Si tiene el beneficio, no paga la comisión, transfiere solo el
 * neto, y el beneficiario recibe lo mismo que recibiría sin la exención.
 *
 * El beneficio exige un stake de ONE_YEAR de al menos 100.000 HACK, ya
 * madurado, y activado con activateNoCommission(). Se pierde al retirar ese
 * stake o al desactivarlo. Como el stake tiene que haber madurado un año
 * antes de activarse, no se puede hacer stake, pagar sin comisión y retirar
 * en la misma transacción.
 *
 * Si la consulta falla (revierte, agota su gas o devuelve algo que no es un
 * bool), se cobra la comisión normal y se emite ExemptionCheckFailed. Falla
 * cerrado: un fallo de la fuente nunca bloquea los pagos ni exime a nadie.
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

    /// @notice Fuente de la exención de comisión (Mecanismo 6, HC-SRC-005).
    IStakingContract public stakingContract;

    /// @notice Comisión en puntos básicos (5% = 500 bps). Ajustable por el admin.
    uint256 public commissionBps = 500;

    /// @notice Denominador para el cálculo de comisión (10_000 = 100%).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Gas máximo que se reenvía a hasNoCommission(). La consulta de
    /// StakingContract son unas pocas lecturas de storage, muy por debajo.
    uint256 public constant EXEMPTION_CHECK_GAS = 50_000;

    /// @notice Total de comisiones cobradas históricamente (en HACK).
    uint256 public totalCommissionsCollected;

    /// @notice Registro de evidenceIds ya procesados para evitar cobros duplicados.
    /// Solo guarda si se procesó, no el importe. Los importes quedan en
    /// CommissionCollected.
    mapping(bytes32 => bool) public processedTx;

    // --- Custom Errors ---

    error InvalidAddress();
    error AmountMustBeGreaterThanZero();
    error TransferFailed();
    error CommissionTooHigh();
    error AlreadyProcessed();

    // --- Events ---

    /// @dev Emitido una vez por cada evidenceId procesado, con o sin exención.
    /// Es el registro de la transacción para el indexador: sumar
    /// commissionAmount da el total cobrado. Con exención commissionAmount es
    /// 0 y el pagador transfirió grossAmount menos la comisión de
    /// CommissionWaived.
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

    /// @dev Emitido junto a CommissionCollected cuando el pagador tiene la
    /// exención. waivedAmount es la comisión que habría pagado. Es
    /// complementario, no una transacción aparte: el indexador no debe
    /// contarlo como cobro ni como transacción.
    event CommissionWaived(bytes32 indexed evidenceId, address indexed payer, uint256 waivedAmount);

    /// @dev Emitido cuando el admin actualiza la fuente de la exención.
    event StakingContractUpdated(address indexed oldStaking, address indexed newStaking);

    /// @dev Emitido cuando la consulta de la exención falla y se cobra la
    /// comisión normal.
    event ExemptionCheckFailed(bytes32 indexed evidenceId, address indexed payer);

    // --- Constructor ---

    /**
     * @dev Despliega el contrato y lo vincula al token HACK y a la tesorería.
     * El deployer recibe DEFAULT_ADMIN_ROLE para gestionar roles y parámetros.
     * @param hackToken_ Dirección del token HACK.
     * @param treasury_ Dirección de la pool de tesorería.
     * @param stakingContract_ StakingContract, fuente de la exención de comisión.
     */
    constructor(address hackToken_, address treasury_, address stakingContract_) {
        if (hackToken_ == address(0)) revert InvalidAddress();
        if (treasury_ == address(0)) revert InvalidAddress();
        // Exigir código descarta también la dirección 0 y cualquier EOA.
        if (stakingContract_.code.length == 0) revert InvalidAddress();

        hackToken = IERC20(hackToken_);
        treasury = treasury_;
        stakingContract = IStakingContract(stakingContract_);

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
     * @param payer_ Dirección que paga la transacción (usuario). La exención
     * se consulta sobre esta dirección, de la que salen los fondos, y no sobre
     * msg.sender, que es el contrato transaccional.
     * @param payee_ Dirección que recibe el neto de la transacción (p.ej. Educador).
     * @param grossAmount_ Monto bruto de la transacción, en HACK.
     * @param reason_ Descripción legible de la transacción (p.ej. "certificate_emission").
     * @return netAmount Monto neto transferido al beneficiario tras descontar la comisión.
     * Es el mismo tenga o no el pagador la exención: con exención el pagador
     * transfiere solo el neto, sin comisión (HC-SRC-005).
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

        (bool exempt, bool checked) = _checkExemption(payer_);
        if (!checked) emit ExemptionCheckFailed(evidenceId_, payer_);

        if (exempt) {
            // El pagador con exención no paga la comisión. El beneficiario
            // recibe el mismo neto que sin exención.
            bool successWaived = hackToken.transferFrom(payer_, payee_, netAmount);
            if (!successWaived) revert TransferFailed();

            emit CommissionCollected(evidenceId_, payer_, grossAmount_, 0, reason_);
            emit CommissionWaived(evidenceId_, payer_, commissionAmount);
            return netAmount;
        }

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

    /**
     * @notice Actualiza la fuente de la exención de comisión.
     * @dev Cambiar esta dirección equivale a conceder o quitar exenciones,
     * con el mismo poder que setTreasury() o setCommissionRate(). Por eso
     * DEFAULT_ADMIN_ROLE debe ser la multifirma del despliegue.
     * @param newStaking_ Nueva dirección de StakingContract. Debe ser un
     * contrato, lo que descarta también la dirección 0 y cualquier EOA.
     */
    function setStakingContract(address newStaking_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newStaking_.code.length == 0) revert InvalidAddress();
        address old = address(stakingContract);
        stakingContract = IStakingContract(newStaking_);
        emit StakingContractUpdated(old, newStaking_);
    }

    // --- Views ---

    /**
     * @notice Calcula la comisión que se cobraría sobre un monto dado, sin ejecutarla.
     * @dev No aplica la exención de HC-SRC-005, porque no sabe quién paga.
     * Para lo que pagaría un pagador concreto, usar previewCommissionFor().
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

    /**
     * @notice Calcula lo que pagaría un pagador concreto, teniendo en cuenta
     * su exención (HC-SRC-005).
     * @dev previewCommission() no sabe quién paga y no puede reflejarla.
     * @param payer_ Dirección que pagaría la transacción.
     * @param grossAmount_ Monto bruto de la transacción.
     * @return commissionAmount Comisión que pagaría (cero con exención).
     * @return payerPays Lo que transferiría el pagador.
     * @return payeeReceives Lo que recibiría el beneficiario.
     */
    function previewCommissionFor(address payer_, uint256 grossAmount_)
        external
        view
        returns (uint256 commissionAmount, uint256 payerPays, uint256 payeeReceives)
    {
        uint256 fee = (grossAmount_ * commissionBps) / BPS_DENOMINATOR;
        payeeReceives = grossAmount_ - fee;

        (bool exempt, ) = _checkExemption(payer_);
        if (exempt) {
            return (0, payeeReceives, payeeReceives);
        }
        return (fee, grossAmount_, payeeReceives);
    }

    // --- Internal ---

    /**
     * @dev Consulta hasNoCommission() con un límite de gas y sin propagar el
     * fallo. No usa try/catch porque no captura una dirección sin código ni
     * una respuesta mal formada. Solo cuenta como exento un 1 en exactamente
     * 32 bytes de respuesta.
     *
     * No hace falta distinguir un fallo por falta de gas en la transacción.
     * Si la consulta se queda sin gas, el 1/64 que queda tras ella no alcanza
     * para completar ni el cobro ni la vista, y la transacción revierte, así
     * que no se le puede cobrar la comisión a un exento por esa vía. Los
     * fuzz de gas bajo de CommissionSystemHCSRC005Test lo comprueban.
     * @param payer_ Dirección de la que salen los fondos.
     * @return exempt Si el pagador tiene la exención.
     * @return checked Si la consulta respondió de forma válida.
     */
    function _checkExemption(address payer_) internal view returns (bool exempt, bool checked) {
        (bool success, bytes memory data) = address(stakingContract).staticcall{ gas: EXEMPTION_CHECK_GAS }(
            abi.encodeCall(IStakingContract.hasNoCommission, (payer_))
        );

        if (!success || data.length != 32) return (false, false);

        uint256 result = abi.decode(data, (uint256));
        if (result > 1) return (false, false);
        return (result == 1, true);
    }
}

interface IStakingContract {
    function hasNoCommission(address user_) external view returns (bool);
}