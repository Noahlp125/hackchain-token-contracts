// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RecruiterBonuses
 * @dev Handles recruiter-specific bonus mechanisms (27, 28, 29).
 *
 * M-06 fixes:
 * - verifyKyc()/claimKycBonus() ahora exigen que el recruiter este
 *   registrado (isRegistered), evitando verificar/pagar wallets no
 *   registradas.
 * - El bono de 7 dias "activos" ahora exige actividad verificable
 *   (recordActivity con un activityId unico por dia), no solo tiempo
 *   transcurrido desde el registro.
 * - registerHiring() ahora recibe un talentId_ concreto y evita contar
 *   al mismo talento dos veces dentro del mismo mes.
 */
contract RecruiterBonuses is AccessControl, ReentrancyGuard {

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ENFORCER_ROLE = keccak256("ENFORCER_ROLE");

    // --- Constants ---
    uint256 public constant REGISTRATION_BONUS = 50_000 * 1e18;
    uint256 public constant MIN_ACTIVE_DAYS = 7;

    uint256 public constant MONTHLY_HIRING_BONUS = 40_000 * 1e18;
    uint256 public constant MONTHLY_HIRING_REQUIRED = 4;

    uint256 public constant KYC_BONUS = 200_000 * 1e18;

    // --- Structs ---
    struct RegistrationInfo {
        uint256 registeredAt;
        bool bonusClaimed;
    }

    struct MonthlyHiring {
        uint256 currentMonth;
        uint256 talentsHired;
        bool rewardClaimed;
    }

    // --- State ---
    address public incentivesPool;

    mapping(address => RegistrationInfo) public registrationInfo;
    mapping(address => bool) public isRegistered;
    mapping(address => MonthlyHiring) public monthlyHiring;
    mapping(address => bool) public kycRewarded;
    mapping(address => bool) public isKycVerified;

    /// @notice recruiter => dias unicos de actividad verificada acumulados.
    mapping(address => uint256) public uniqueActiveDays;

    /// @notice evita procesar dos veces la misma evidencia de actividad.
    mapping(bytes32 => bool) public processedActivity;

    /// @notice recruiter => dia (timestamp/1 days) => ya contado como activo.
    mapping(address => mapping(uint256 => bool)) public activeOnDay;

    /// @notice recruiter => mes => talentId => ya contado en ese mes.
    /// Evita que el mismo talento se cuente varias veces para el bono 28.
    mapping(address => mapping(uint256 => mapping(bytes32 => bool))) public talentCountedThisMonth;

    // --- Custom Errors ---
    error InvalidAddress();
    error AlreadyRegistered();
    error NotRegistered();
    error RegistrationBonusAlreadyClaimed();
    error MinActiveDaysNotReached();
    error MonthlyRewardAlreadyClaimed();
    error NotEnoughHiringsThisMonth();
    error KycAlreadyRewarded();
    error NotKycVerified();
    error ActivityAlreadyProcessed();
    error TalentAlreadyCountedThisMonth();

    // --- Events ---
    event RecruiterRegistered(address indexed recruiter, uint256 registeredAt);
    event ActivityRecorded(address indexed recruiter, bytes32 activityId, uint256 uniqueActiveDays);
    event RegistrationBonusClaimed(address indexed recruiter, uint256 amount);
    event TalentHiringRegistered(address indexed recruiter, bytes32 talentId, uint256 talentsHired);
    event MonthlyHiringRewarded(address indexed recruiter, uint256 month, uint256 amount);
    event KycVerified(address indexed recruiter);
    event KycBonusClaimed(address indexed recruiter, uint256 amount);

    // --- Constructor ---
    constructor(address incentivesPool_) {
        if (incentivesPool_ == address(0)) revert InvalidAddress();

        incentivesPool = incentivesPool_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(ENFORCER_ROLE, msg.sender);
    }

    // --- Mechanism 27: Registration bonus ---

    function registerRecruiter(address recruiter_)
        external
        onlyRole(ENFORCER_ROLE)
    {
        if (recruiter_ == address(0)) revert InvalidAddress();
        if (isRegistered[recruiter_]) revert AlreadyRegistered();

        isRegistered[recruiter_] = true;
        registrationInfo[recruiter_] = RegistrationInfo({
            registeredAt: block.timestamp,
            bonusClaimed: false
        });

        emit RecruiterRegistered(recruiter_, block.timestamp);
    }

    /**
     * @notice Registra un dia de actividad verificable para un recruiter.
     * @dev Solo cuenta un dia unico por recruiter — llamadas repetidas el
     * mismo dia no incrementan el contador. Cada activityId_ solo puede
     * procesarse una vez (evita replay).
     * @param activityId_ Identificador unico de la evidencia de actividad
     * (p.ej. hash de la accion verificada off-chain por el enforcer).
     */
    function recordActivity(address recruiter_, bytes32 activityId_)
        external
        onlyRole(ENFORCER_ROLE)
    {
        if (!isRegistered[recruiter_]) revert NotRegistered();
        if (processedActivity[activityId_]) revert ActivityAlreadyProcessed();

        processedActivity[activityId_] = true;

        uint256 dayId = block.timestamp / 1 days;
        if (!activeOnDay[recruiter_][dayId]) {
            activeOnDay[recruiter_][dayId] = true;
            uniqueActiveDays[recruiter_] += 1;
        }

        emit ActivityRecorded(recruiter_, activityId_, uniqueActiveDays[recruiter_]);
    }

    /**
     * @notice Claim the registration bonus after 7 dias de actividad
     * VERIFICABLE (no solo tiempo transcurrido — M-06 fix).
     */
    function claimRegistrationBonus() external nonReentrant {
        if (!isRegistered[msg.sender]) revert NotRegistered();

        RegistrationInfo storage info = registrationInfo[msg.sender];

        if (info.bonusClaimed) revert RegistrationBonusAlreadyClaimed();
        if (uniqueActiveDays[msg.sender] < MIN_ACTIVE_DAYS) revert MinActiveDaysNotReached();

        info.bonusClaimed = true;

        IIncentivesPool(incentivesPool).distribute(
            msg.sender,
            REGISTRATION_BONUS,
            "recruiter_registration_bonus"
        );

        emit RegistrationBonusClaimed(msg.sender, REGISTRATION_BONUS);
    }

    // --- Mechanism 28: Monthly hiring bonus ---

    /**
     * @notice Register a Talent hiring for a recruiter.
     * @dev M-06 fix: recibe un talentId_ concreto y no permite contar al
     * mismo talento dos veces dentro del mismo mes (evita inflar el
     * contador repitiendo siempre el mismo talento).
     * @param recruiter_ Address of the recruiter.
     * @param talentId_ Identificador unico del talento contratado
     * (p.ej. su address como bytes32, o un hash del registro de hiring).
     */
    function registerHiring(address recruiter_, bytes32 talentId_)
        external
        onlyRole(ENFORCER_ROLE)
    {
        if (recruiter_ == address(0)) revert InvalidAddress();

        uint256 currentMonth = block.timestamp / 30 days;
        MonthlyHiring storage hiring = monthlyHiring[recruiter_];

        if (hiring.currentMonth != currentMonth) {
            hiring.currentMonth = currentMonth;
            hiring.talentsHired = 0;
            hiring.rewardClaimed = false;
        }

        if (talentCountedThisMonth[recruiter_][currentMonth][talentId_]) {
            revert TalentAlreadyCountedThisMonth();
        }
        talentCountedThisMonth[recruiter_][currentMonth][talentId_] = true;

        hiring.talentsHired += 1;

        emit TalentHiringRegistered(recruiter_, talentId_, hiring.talentsHired);
    }

    function claimMonthlyHiringBonus() external nonReentrant {
        uint256 currentMonth = block.timestamp / 30 days;
        MonthlyHiring storage hiring = monthlyHiring[msg.sender];

        if (hiring.currentMonth != currentMonth) {
            hiring.currentMonth = currentMonth;
            hiring.talentsHired = 0;
            hiring.rewardClaimed = false;
        }

        if (hiring.rewardClaimed) revert MonthlyRewardAlreadyClaimed();
        if (hiring.talentsHired < MONTHLY_HIRING_REQUIRED)
            revert NotEnoughHiringsThisMonth();

        hiring.rewardClaimed = true;

        IIncentivesPool(incentivesPool).distribute(
            msg.sender,
            MONTHLY_HIRING_BONUS,
            "recruiter_monthly_hiring_bonus"
        );

        emit MonthlyHiringRewarded(msg.sender, currentMonth, MONTHLY_HIRING_BONUS);
    }

    // --- Mechanism 29: KYC verification bonus ---

    /**
     * @notice Mark a recruiter as KYC verified.
     * @dev M-06 fix: exige que el recruiter este registrado antes de
     * poder verificarse por KYC.
     */
    function verifyKyc(address recruiter_)
        external
        onlyRole(ENFORCER_ROLE)
    {
        if (recruiter_ == address(0)) revert InvalidAddress();
        if (!isRegistered[recruiter_]) revert NotRegistered();
        if (kycRewarded[recruiter_]) revert KycAlreadyRewarded();

        isKycVerified[recruiter_] = true;

        emit KycVerified(recruiter_);
    }

    function claimKycBonus() external nonReentrant {
        if (!isRegistered[msg.sender]) revert NotRegistered();
        if (!isKycVerified[msg.sender]) revert NotKycVerified();
        if (kycRewarded[msg.sender]) revert KycAlreadyRewarded();

        kycRewarded[msg.sender] = true;

        IIncentivesPool(incentivesPool).distribute(
            msg.sender,
            KYC_BONUS,
            "recruiter_kyc_bonus"
        );

        emit KycBonusClaimed(msg.sender, KYC_BONUS);
    }

    // --- Views ---

    function getIsRegistered(address recruiter_) external view returns (bool) {
        return isRegistered[recruiter_];
    }

    function getRegistrationInfo(address recruiter_)
        external
        view
        returns (RegistrationInfo memory)
    {
        return registrationInfo[recruiter_];
    }

    function getMonthlyHiring(address recruiter_)
        external
        view
        returns (MonthlyHiring memory)
    {
        return monthlyHiring[recruiter_];
    }

    function getIsKycVerified(address recruiter_) external view returns (bool) {
        return isKycVerified[recruiter_];
    }

    function getHiringsLeft(address recruiter_) external view returns (uint256) {
        MonthlyHiring memory hiring = monthlyHiring[recruiter_];
        uint256 currentMonth = block.timestamp / 30 days;

        if (hiring.currentMonth != currentMonth) return MONTHLY_HIRING_REQUIRED;
        if (hiring.talentsHired >= MONTHLY_HIRING_REQUIRED) return 0;
        return MONTHLY_HIRING_REQUIRED - hiring.talentsHired;
    }

    // --- Admin ---

    function setIncentivesPool(address newPool_) external onlyRole(ADMIN_ROLE) {
        if (newPool_ == address(0)) revert InvalidAddress();
        incentivesPool = newPool_;
    }
}

// --- Interface ---
interface IIncentivesPool {
    function distribute(address to_, uint256 amount_, string calldata reason_) external;
}
