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
     */
    function applyIdentityFraudPenalty(
        bytes32 caseId_,
        address user_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (user_ == address(0)) revert InvalidAddress();

        uint256 balance = hackToken.balanceOf(user_);
        uint256 penalty = (balance * IDENTITY_FRAUD_PENALTY_PERCENT) / 100;
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
     * @dev NOTA: sigue leyendo balanceOf() en el momento de ejecución (H-05
     * no resuelto del todo). Un usuario puede mover fondos antes de que el
     * enforcer llame a esta función. Pendiente de snapshot firmado.
     */
    function applyMassSalePenalty(
        bytes32 caseId_,
        address user_,
        uint256 saleAmount_,
        uint256 circulatingSupply_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (user_ == address(0)) revert InvalidAddress();
        if (saleAmount_ == 0) revert AmountMustBeGreaterThanZero();

        uint256 balance = hackToken.balanceOf(user_);

        require(
            balance * 100 >= circulatingSupply_ * MASS_SALE_SUPPLY_THRESHOLD,
            "User does not hold 1% of supply"
        );
        require(
            saleAmount_ * 100 >= balance * MASS_SALE_THRESHOLD_PERCENT,
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
     */
    function applyNoShowPenalty(
        bytes32 caseId_,
        address user_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (user_ == address(0)) revert InvalidAddress();

        uint256 balance = hackToken.balanceOf(user_);
        uint256 penalty = (balance * NO_SHOW_PENALTY_PERCENT) / 100;
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
     */
    function applyEducatorInactivityPenalty(
        bytes32 caseId_,
        address educator_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (educator_ == address(0)) revert InvalidAddress();

        uint256 balance = hackToken.balanceOf(educator_);
        uint256 penalty = (balance * EDUCATOR_INACTIVITY_PENALTY_PERCENT) / 100;
        if (penalty == 0) revert AmountMustBeGreaterThanZero();

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
     */
    function applyPlagiarismPenalty(
        bytes32 caseId_,
        address offender_,
        address affected_,
        bool isExternal_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (offender_ == address(0)) revert InvalidAddress();
        if (affected_ == address(0)) revert InvalidAddress();

        uint256 balance = hackToken.balanceOf(offender_);
        uint256 penalty = (balance * PLAGIARISM_PENALTY_PERCENT) / 100;
        if (penalty == 0) revert AmountMustBeGreaterThanZero();

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
     */
    function applyRecruiterInactivityPenalty(
        bytes32 caseId_,
        address recruiter_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (recruiter_ == address(0)) revert InvalidAddress();

        uint256 balance = hackToken.balanceOf(recruiter_);
        uint256 penalty = (balance * RECRUITER_INACTIVITY_PENALTY_PERCENT) /
            100;
        if (penalty == 0) revert AmountMustBeGreaterThanZero();

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
            penaltyDebt[msg.sender] == 0 && roleRegistry.isBlocked(msg.sender)
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
     */
    function unblockProfile(address user_) external onlyRole(ENFORCER_ROLE) {
        if (!roleRegistry.isBlocked(user_)) revert ProfileNotBlocked();
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

        // RoleRegistry.setBlocked() revierte si ya estaba bloqueado (protege
        // contra un doble bloqueo silencioso). Un mismo usuario puede
        // acumular varios casos bloqueantes (ver test_H04_MultipleCases...),
        // asi que solo llamamos si todavia no esta bloqueado.
        if (blockProfile_ && !roleRegistry.isBlocked(user_)) {
            roleRegistry.setBlocked(user_);
        }

        penaltyDebt[user_] += amount_;
        pendingPenalties[caseId_] = PendingPenalty({
            user: user_,
            amount: amount_,
            destination: destination_,
            isPoolDeposit: isPoolDeposit_,
            settled: false
        });

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
    function setBlocked(address account_) external;
    function setUnblocked(address account_) external;
}
