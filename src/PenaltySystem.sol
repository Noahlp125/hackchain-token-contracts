// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PenaltySystem
 * @dev Handles all penalty mechanisms (7, 9, 14, 25, 26, 30).
 * Penalties are triggered by an authorized enforcer (admin/multisig)
 * after off-chain detection of infractions.
 *
 * H-04 fix: penalties no longer depend on the offender's ERC-20 allowance.
 * The profile is frozen immediately and the penalty is recorded as debt
 * (`pendingPenalties`), which the user must settle via settlePenalty()
 * to have their profile unblocked. This guarantees the sanction always
 * has effect, regardless of whether the user cooperates with approve().
 *
 * HC-SRC-002 fix: el estado de bloqueo ya no vive aquí. Este contrato
 * escribe/lee el bloqueo a través de RoleRegistry (requiere REGISTRAR_ROLE
 * concedido a esta dirección), que es ahora la fuente única que deben
 * consultar el resto de módulos.
 *
 * HC-SRC-003 fix: las penalizaciones porcentuales ya no leen
 * hackToken.balanceOf() en el momento de la ejecución. El enforcer aporta
 * un balance de evidencia (verificado off-chain en el momento de la
 * infracción) y el contrato calcula el porcentaje sobre ese valor. Mover
 * tokens después de la infracción ya no reduce ni evita la sanción.
 *
 * HC-SRC-011 fix: el bloqueo ya no depende del importe. Las tres
 * penalizaciones bloqueantes bloquean aunque el porcentaje dé cero (evidencia
 * cero o por debajo del umbral de redondeo). Ese caso se registra sin deuda y
 * marca el perfil con manualUnblockRequired: como no hay nada que pagar,
 * settlePenalty() no puede levantarlo y solo lo levanta el enforcer con
 * unblockProfile(). Las penalizaciones que no bloquean siguen revirtiendo con
 * importe cero, porque sin bloqueo una deuda cero no tiene efecto.
 *
 * HC-SRC-012 fix: RoleRegistry guarda el bloqueo por origen. Este contrato
 * pone y quita solo el suyo, así que liquidar deuda ya no levanta un bloqueo
 * puesto por otro escritor (p.ej. un operador que bloquea a mano un fraude de
 * identidad). Por la misma razón añade su bloqueo aunque el perfil ya esté
 * bloqueado por otro: si no, al quitar ese otro la deuda quedaría sin bloqueo.
 */
contract PenaltySystem is AccessControl, ReentrancyGuard {
    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ENFORCER_ROLE = keccak256("ENFORCER_ROLE");

    // --- Constants ---

    uint256 public constant IDENTITY_FRAUD_PENALTY_PERCENT = 10;

    uint256 public constant MASS_SALE_PENALTY_PERCENT = 5;
    uint256 public constant MASS_SALE_THRESHOLD_PERCENT = 50;
    uint256 public constant MASS_SALE_SUPPLY_THRESHOLD = 1;

    uint256 public constant NO_SHOW_PENALTY_PERCENT = 5;
    uint256 public constant EDUCATOR_INACTIVITY_PENALTY_PERCENT = 5;
    uint256 public constant PLAGIARISM_PENALTY_PERCENT = 10;
    uint256 public constant RECRUITER_INACTIVITY_PENALTY_PERCENT = 5;

    // --- Enums ---
    enum PenaltyType {
        IdentityFraud,
        MassSale,
        NoShowInterview,
        EducatorInactivity,
        Plagiarism,
        RecruiterInactivity
    }

    // --- Structs ---

    struct PenaltyRecord {
        PenaltyType penaltyType;
        uint256 amount;
        uint256 timestamp;
        bool profileBlocked;
    }

    /**
     * @dev Deuda pendiente asociada a un caso de penalización concreto.
     * destination_ es la dirección final del pago (pool, tesorería, o la
     * parte afectada en un caso de plagio). isPoolDeposit_ indica si hay
     * que notificar el depósito a IncentivesPool tras el cobro.
     */
    struct PendingPenalty {
        address user;
        uint256 amount;
        address destination;
        bool isPoolDeposit;
        bool settled;
    }

    // --- State ---
    IERC20 public immutable hackToken;
    address public incentivesPool;
    address public treasury;
    IRoleRegistry public roleRegistry;

    mapping(address => PenaltyRecord[]) public penaltyHistory;
    mapping(address => uint256) public totalPenalized;

    /// @notice Deuda total pendiente de liquidar por usuario (suma de casos no saldados).
    mapping(address => uint256) public penaltyDebt;

    /// @notice caseId => detalle de la penalización pendiente/liquidada.
    mapping(bytes32 => PendingPenalty) public pendingPenalties;

    /// @notice Evita procesar dos veces el mismo caso (protección de replay).
    mapping(bytes32 => bool) public processedCase;

    /// @notice user => bloqueado por un caso sin deuda (HC-SRC-011). Mientras
    /// sea true, liquidar deuda no desbloquea el perfil, solo unblockProfile().
    mapping(address => bool) public manualUnblockRequired;

    // --- Custom Errors ---
    error InvalidAddress();
    error AmountMustBeGreaterThanZero();
    error ProfileAlreadyBlocked();
    error ProfileNotBlocked();
    error InsufficientBalance();
    error TransferFailed();
    error InvalidPenaltyType();
    error CaseAlreadyProcessed();
    error PenaltyNotFound();
    error NotPenaltyOwner();
    error PenaltyAlreadySettled();

    // --- Events ---
    event PenaltyApplied(
        bytes32 indexed caseId,
        address indexed user,
        PenaltyType penaltyType,
        uint256 amount,
        bool profileBlocked
    );
    event ProfileUnblocked(address indexed user);
    event PenaltySettled(
        bytes32 indexed caseId,
        address indexed user,
        uint256 amount
    );

    // --- Constructor ---
    constructor(
        address hackToken_,
        address incentivesPool_,
        address treasury_,
        address roleRegistry_
    ) {
        if (hackToken_ == address(0)) revert InvalidAddress();
        if (incentivesPool_ == address(0)) revert InvalidAddress();
        if (treasury_ == address(0)) revert InvalidAddress();
        if (roleRegistry_ == address(0)) revert InvalidAddress();

        hackToken = IERC20(hackToken_);
        incentivesPool = incentivesPool_;
        treasury = treasury_;
        roleRegistry = IRoleRegistry(roleRegistry_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(ENFORCER_ROLE, msg.sender);
    }

    // --- Core penalty functions ---

    /**
     * @notice Apply identity fraud penalty (mechanism 7).
     * @param caseId_ Identificador único del caso, evita el reprocesado.
     * @param user_ Address of the offending user.
     * @param evidenceBalance_ Balance del usuario verificado off-chain en
     * el momento de la infracción (HC-SRC-003). No se lee balanceOf().
     */
    function applyIdentityFraudPenalty(
        bytes32 caseId_,
        address user_,
        uint256 evidenceBalance_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (user_ == address(0)) revert InvalidAddress();

        uint256 penalty = (evidenceBalance_ * IDENTITY_FRAUD_PENALTY_PERCENT) / 100;
        if (penalty == 0) revert AmountMustBeGreaterThanZero();

        _recordPenalty(
            caseId_,
            user_,
            penalty,
            PenaltyType.IdentityFraud,
            false,
            incentivesPool,
            true
        );
    }

    /**
     * @notice Apply mass token sale penalty (mechanism 9).
     * @dev HC-SRC-003 fix: holdingsBeforeSale_ sustituye a balanceOf(),
     * verificado off-chain por el enforcer justo antes de la venta. Ya no
     * depende de lo que el usuario haga con sus tokens después.
     * @param holdingsBeforeSale_ Balance del usuario inmediatamente antes
     * de la venta masiva evidenciada.
     */
    function applyMassSalePenalty(
        bytes32 caseId_,
        address user_,
        uint256 saleAmount_,
        uint256 holdingsBeforeSale_,
        uint256 circulatingSupply_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (user_ == address(0)) revert InvalidAddress();
        if (saleAmount_ == 0) revert AmountMustBeGreaterThanZero();

        require(
            holdingsBeforeSale_ * 100 >= circulatingSupply_ * MASS_SALE_SUPPLY_THRESHOLD,
            "User does not hold 1% of supply"
        );
        require(
            saleAmount_ * 100 >= holdingsBeforeSale_ * MASS_SALE_THRESHOLD_PERCENT,
            "Sale does not exceed 50% of holdings"
        );

        uint256 penalty = (saleAmount_ * MASS_SALE_PENALTY_PERCENT) / 100;
        if (penalty == 0) revert AmountMustBeGreaterThanZero();

        _recordPenalty(
            caseId_,
            user_,
            penalty,
            PenaltyType.MassSale,
            false,
            incentivesPool,
            true
        );
    }

    /**
     * @notice Apply no-show interview penalty (mechanism 14).
     * @param evidenceBalance_ Balance del usuario verificado off-chain en
     * el momento de la infracción (HC-SRC-003).
     */
    function applyNoShowPenalty(
        bytes32 caseId_,
        address user_,
        uint256 evidenceBalance_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (user_ == address(0)) revert InvalidAddress();

        uint256 penalty = (evidenceBalance_ * NO_SHOW_PENALTY_PERCENT) / 100;
        if (penalty == 0) revert AmountMustBeGreaterThanZero();

        _recordPenalty(
            caseId_,
            user_,
            penalty,
            PenaltyType.NoShowInterview,
            false,
            incentivesPool,
            true
        );
    }

    /**
     * @notice Apply educator inactivity penalty (mechanism 25).
     * @param evidenceBalance_ Balance del educador verificado off-chain en
     * el momento de la infracción (HC-SRC-003).
     */
    function applyEducatorInactivityPenalty(
        bytes32 caseId_,
        address educator_,
        uint256 evidenceBalance_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (educator_ == address(0)) revert InvalidAddress();

        // Sin guard de importe cero: penalización bloqueante (HC-SRC-011).
        uint256 penalty = (evidenceBalance_ * EDUCATOR_INACTIVITY_PENALTY_PERCENT) / 100;

        _recordPenalty(
            caseId_,
            educator_,
            penalty,
            PenaltyType.EducatorInactivity,
            true,
            incentivesPool,
            true
        );
    }

    /**
     * @notice Apply plagiarism penalty (mechanism 26).
     * @dev External: el pago se registra hacia Treasury. Internal: se
     * registra directamente hacia el educador afectado.
     * @param evidenceBalance_ Balance del infractor verificado off-chain en
     * el momento de la infracción (HC-SRC-003).
     */
    function applyPlagiarismPenalty(
        bytes32 caseId_,
        address offender_,
        address affected_,
        bool isExternal_,
        uint256 evidenceBalance_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (offender_ == address(0)) revert InvalidAddress();
        if (affected_ == address(0)) revert InvalidAddress();

        // Sin guard de importe cero: penalización bloqueante (HC-SRC-011).
        uint256 penalty = (evidenceBalance_ * PLAGIARISM_PENALTY_PERCENT) / 100;

        address destination = isExternal_ ? treasury : affected_;

        _recordPenalty(
            caseId_,
            offender_,
            penalty,
            PenaltyType.Plagiarism,
            true,
            destination,
            false
        );
    }

    /**
     * @notice Apply recruiter inactivity penalty (mechanism 30).
     * @param evidenceBalance_ Balance del recruiter verificado off-chain en
     * el momento de la infracción (HC-SRC-003).
     */
    function applyRecruiterInactivityPenalty(
        bytes32 caseId_,
        address recruiter_,
        uint256 evidenceBalance_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (recruiter_ == address(0)) revert InvalidAddress();

        // Sin guard de importe cero: penalización bloqueante (HC-SRC-011).
        uint256 penalty = (evidenceBalance_ * RECRUITER_INACTIVITY_PENALTY_PERCENT) /
            100;

        _recordPenalty(
            caseId_,
            recruiter_,
            penalty,
            PenaltyType.RecruiterInactivity,
            true,
            incentivesPool,
            true
        );
    }

    // --- Settlement ---

    /**
     * @notice Liquida una penalización pendiente. El usuario paga el monto
     * exacto del caso; si con esto su deuda total llega a cero, su perfil
     * se desbloquea automáticamente.
     * @param caseId_ Identificador del caso a liquidar.
     */
    function settlePenalty(bytes32 caseId_) external nonReentrant {
        PendingPenalty storage p = pendingPenalties[caseId_];

        if (p.user == address(0)) revert PenaltyNotFound();
        if (p.user != msg.sender) revert NotPenaltyOwner();
        if (p.settled) revert PenaltyAlreadySettled();

        p.settled = true;
        penaltyDebt[msg.sender] -= p.amount;

        bool success = hackToken.transferFrom(
            msg.sender,
            p.destination,
            p.amount
        );
        if (!success) revert TransferFailed();

        if (p.isPoolDeposit) {
            IIncentivesPool(incentivesPool).deposit(
                p.amount,
                "penalty_settlement"
            );
        }

        if (
            penaltyDebt[msg.sender] == 0 &&
            !manualUnblockRequired[msg.sender] &&
            roleRegistry.isBlockedBy(msg.sender, address(this))
        ) {
            roleRegistry.setUnblocked(msg.sender);
            emit ProfileUnblocked(msg.sender);
        }

        emit PenaltySettled(caseId_, msg.sender, p.amount);
    }

    // --- Profile management ---

    /**
     * @notice Override manual del enforcer para casos excepcionales
     * (p.ej. condonación de deuda decidida off-chain).
     * @dev También es la única vía para levantar un bloqueo sin deuda
     * (HC-SRC-011), así que borra manualUnblockRequired. Solo levanta el
     * bloqueo de este contrato (HC-SRC-012), los de otros orígenes siguen.
     */
    function unblockProfile(address user_) external onlyRole(ENFORCER_ROLE) {
        if (!roleRegistry.isBlockedBy(user_, address(this))) revert ProfileNotBlocked();
        manualUnblockRequired[user_] = false;
        roleRegistry.setUnblocked(user_);
        emit ProfileUnblocked(user_);
    }

    // --- Views ---

    /// @dev Se mantiene por compatibilidad de interfaz, el dato en si vive
    /// en RoleRegistry (HC-SRC-002).
    function isProfileBlocked(address user_) external view returns (bool) {
        return roleRegistry.isBlocked(user_);
    }

    function getPenaltyHistory(
        address user_
    ) external view returns (PenaltyRecord[] memory) {
        return penaltyHistory[user_];
    }

    function getTotalPenalized(address user_) external view returns (uint256) {
        return totalPenalized[user_];
    }

    // --- Internal ---

    /**
     * @dev Registra una penalización como deuda pendiente y congela el
     * perfil de inmediato (si corresponde), sin depender de ninguna
     * transferencia. Sustituye al antiguo _applyPenalty().
     */
    function _recordPenalty(
        bytes32 caseId_,
        address user_,
        uint256 amount_,
        PenaltyType penaltyType_,
        bool blockProfile_,
        address destination_,
        bool isPoolDeposit_
    ) internal {
        if (processedCase[caseId_]) revert CaseAlreadyProcessed();
        processedCase[caseId_] = true;

        // RoleRegistry.setBlocked() revierte si este contrato ya tenia su
        // bloqueo puesto, y un usuario puede acumular varios casos
        // bloqueantes (ver test_H04_MultipleCases...), asi que solo lo
        // ponemos si falta. Se mira el bloqueo propio y no isBlocked(): el
        // de otro origen no cuenta (HC-SRC-012). Un bloqueo propio nuevo
        // descarta la marca de un bloqueo anterior que ya no existe.
        if (blockProfile_ && !roleRegistry.isBlockedBy(user_, address(this))) {
            manualUnblockRequired[user_] = false;
            roleRegistry.setBlocked(user_);
        }

        // Importe cero solo llega aquí desde una penalización bloqueante
        // (HC-SRC-011). No hay deuda que liquidar, así que no se crea caso
        // pendiente y el bloqueo pasa a depender del enforcer.
        if (amount_ == 0) {
            manualUnblockRequired[user_] = true;
        } else {
            penaltyDebt[user_] += amount_;
            pendingPenalties[caseId_] = PendingPenalty({
                user: user_,
                amount: amount_,
                destination: destination_,
                isPoolDeposit: isPoolDeposit_,
                settled: false
            });
        }

        penaltyHistory[user_].push(
            PenaltyRecord({
                penaltyType: penaltyType_,
                amount: amount_,
                timestamp: block.timestamp,
                profileBlocked: blockProfile_
            })
        );

        totalPenalized[user_] += amount_;

        emit PenaltyApplied(
            caseId_,
            user_,
            penaltyType_,
            amount_,
            blockProfile_
        );
    }

    // --- Admin ---

    function setIncentivesPool(address newPool_) external onlyRole(ADMIN_ROLE) {
        if (newPool_ == address(0)) revert InvalidAddress();
        incentivesPool = newPool_;
    }

    function setTreasury(address newTreasury_) external onlyRole(ADMIN_ROLE) {
        if (newTreasury_ == address(0)) revert InvalidAddress();
        treasury = newTreasury_;
    }

    function setRoleRegistry(
        address newRegistry_
    ) external onlyRole(ADMIN_ROLE) {
        if (newRegistry_ == address(0)) revert InvalidAddress();
        roleRegistry = IRoleRegistry(newRegistry_);
    }
}

// --- Interfaces ---
interface IIncentivesPool {
    function deposit(uint256 amount_, string calldata reason_) external;
}

interface IRoleRegistry {
    function isBlocked(address account_) external view returns (bool);
    function isBlockedBy(address account_, address source_) external view returns (bool);
    function setBlocked(address account_) external;
    function setUnblocked(address account_) external;
}
