// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TalentBonuses
 * @dev Handles talent-related bonus mechanisms (4, 11, 23).
 *
 * Mecanismo 23 fix (L-05 + hallazgos de Pol):
 * - Solo Educador/Recruiter verificados en RoleRegistry pueden fundar proyectos.
 * - projectId_ no puede ser cero.
 * - Las contribuciones se rastrean por sponsor (contribution), no se
 *   sobrescriben — permite reembolso individual tras el deadline.
 * - Cada proyecto tiene un deadline de financiacion; tras vencer sin
 *   distribuir, cada sponsor puede recuperar su parte no distribuida.
 * - distributeToTalents() rechaza que cualquier sponsor del proyecto
 *   figure como talento receptor (evita auto-pago).
 *
 * HC-SRC-002 fix: fundProject() consulta RoleRegistry.isBlocked(), un
 * perfil bloqueado no puede financiar proyectos nuevos. refundContribution()
 * y distributeToTalents() quedan fuera de este guard: el primero es
 * recuperar fondos propios, el segundo es un pago del enforcer que se
 * revisara aparte.
 */
contract TalentBonuses is AccessControl, ReentrancyGuard {
    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ENFORCER_ROLE = keccak256("ENFORCER_ROLE");

    // --- Constants ---
    uint256 public constant SCHOOLING_DEGREE_REWARD = 50_000 * 1e18;
    uint256 public constant TALENT_HIRED_REWARD = 5_000 * 1e18;

    uint256 public constant FUNDING_TIER_1 = 1_000 * 1e18;
    uint256 public constant FUNDING_TIER_2 = 10_000 * 1e18;
    uint256 public constant FUNDING_TIER_3 = 100_000 * 1e18;

    /// @notice Plazo de financiacion de un proyecto tras su primera aportacion.
    uint256 public constant FUNDING_WINDOW = 90 days;
    uint256 public constant MAX_BATCH = 50;

    // --- State ---
    IERC20 public immutable hackToken;
    address public incentivesPool;
    IRoleRegistry public roleRegistry;

    mapping(address => mapping(bytes32 => bool)) public degreeRewarded;
    mapping(address => uint256) public lastHiringRewardMonth;

    // projectId => timestamp de la primera aportacion (define el deadline)
    mapping(bytes32 => uint256) public projectFundingDeadline;

    // projectId => total aportado en total
    mapping(bytes32 => uint256) public projectFundedAmount;

    // projectId => total distribuido a talentos
    mapping(bytes32 => uint256) public projectDistributedAmount;

    // projectId => sponsor => cuanto aporto ese sponsor concreto
    mapping(bytes32 => mapping(address => uint256)) public contribution;

    // projectId => sponsor => ya reembolsado (evita doble refund)
    mapping(bytes32 => mapping(address => bool)) public refunded;

    // projectId => address => es sponsor de este proyecto (para bloquear auto-pago)
    mapping(bytes32 => mapping(address => bool)) public isProjectSponsor;

    // --- Custom Errors ---
    error InvalidAddress();
    error InvalidAmount();
    error DegreeAlreadyRewarded();
    error HiringAlreadyRewardedThisMonth();
    error InvalidFundingTier();
    error TransferFailed();
    error ProjectNotFunded();
    error ExceedsFundedAmount();
    error EmptyTalentsList();
    error InvalidProjectId();
    error UnauthorizedSponsor();
    error FundingWindowClosed();
    error FundingWindowStillOpen();
    error NothingToRefund();
    error AlreadyRefunded();
    error TalentCannotBeSponsor();
    error BatchTooLarge();
    error ProfileBlocked();

    // --- Events ---
    event SchoolingDegreeRewarded(
        address indexed user,
        bytes32 degreeId,
        uint256 amount
    );
    event TalentHiredRewarded(
        address indexed talent,
        uint256 month,
        uint256 amount
    );
    event ProjectFunded(
        bytes32 indexed projectId,
        address indexed sponsor,
        uint256 amount
    );
    event ProjectDistributed(
        bytes32 indexed projectId,
        address indexed talent,
        uint256 amount
    );
    event ProjectRefunded(
        bytes32 indexed projectId,
        address indexed sponsor,
        uint256 amount
    );

    // --- Constructor ---
    constructor(
        address hackToken_,
        address incentivesPool_,
        address roleRegistry_
    ) {
        if (hackToken_ == address(0)) revert InvalidAddress();
        if (incentivesPool_ == address(0)) revert InvalidAddress();
        if (roleRegistry_ == address(0)) revert InvalidAddress();

        hackToken = IERC20(hackToken_);
        incentivesPool = incentivesPool_;
        roleRegistry = IRoleRegistry(roleRegistry_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(ENFORCER_ROLE, msg.sender);
    }

    // --- Mechanism 4: Schooling degree bonus ---

    function rewardSchoolingDegree(
        address user_,
        bytes32 degreeId_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (user_ == address(0)) revert InvalidAddress();
        if (degreeRewarded[user_][degreeId_]) revert DegreeAlreadyRewarded();

        degreeRewarded[user_][degreeId_] = true;

        IIncentivesPool(incentivesPool).distribute(
            user_,
            SCHOOLING_DEGREE_REWARD,
            "schooling_degree_reward"
        );

        emit SchoolingDegreeRewarded(user_, degreeId_, SCHOOLING_DEGREE_REWARD);
    }

    // --- Mechanism 11: Talent hired bonus ---

    function rewardTalentHired(
        address talent_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (talent_ == address(0)) revert InvalidAddress();

        uint256 currentMonth = block.timestamp / 30 days;
        if (lastHiringRewardMonth[talent_] == currentMonth)
            revert HiringAlreadyRewardedThisMonth();

        lastHiringRewardMonth[talent_] = currentMonth;

        IIncentivesPool(incentivesPool).distribute(
            talent_,
            TALENT_HIRED_REWARD,
            "talent_hired_reward"
        );

        emit TalentHiredRewarded(talent_, currentMonth, TALENT_HIRED_REWARD);
    }

    // --- Mechanism 23: Open source project funding ---

    /**
     * @notice Fund an open source project worked on by Talents.
     * @dev Solo Educador o Recruiter verificados en RoleRegistry. La
     * primera aportacion fija el deadline de financiacion del proyecto.
     * Aportaciones sucesivas (incluso de sponsors distintos) se acumulan
     * de forma rastreable, sin sobrescribir al sponsor anterior.
     */
    function fundProject(
        bytes32 projectId_,
        uint256 amount_
    ) external nonReentrant {
        if (roleRegistry.isBlocked(msg.sender)) revert ProfileBlocked();
        if (projectId_ == bytes32(0)) revert InvalidProjectId();
        if (
            amount_ != FUNDING_TIER_1 &&
            amount_ != FUNDING_TIER_2 &&
            amount_ != FUNDING_TIER_3
        ) revert InvalidFundingTier();
        if (
            !roleRegistry.isEducator(msg.sender) &&
            !roleRegistry.isRecruiter(msg.sender)
        ) {
            revert UnauthorizedSponsor();
        }

        if (projectFundingDeadline[projectId_] == 0) {
            projectFundingDeadline[projectId_] =
                block.timestamp +
                FUNDING_WINDOW;
        } else if (block.timestamp >= projectFundingDeadline[projectId_]) {
            revert FundingWindowClosed();
        }

        bool success = hackToken.transferFrom(
            msg.sender,
            address(this),
            amount_
        );
        if (!success) revert TransferFailed();

        contribution[projectId_][msg.sender] += amount_;
        isProjectSponsor[projectId_][msg.sender] = true;
        projectFundedAmount[projectId_] += amount_;

        emit ProjectFunded(projectId_, msg.sender, amount_);
    }

    /**
     * @notice Distribute funded tokens individually to Talents involved in a project.
     * @dev Rechaza si algun destinatario es tambien sponsor del mismo
     * proyecto (evita que alguien se financie y se pague a si mismo).
     */
    function distributeToTalents(
        bytes32 projectId_,
        address[] calldata talents_,
        uint256[] calldata amounts_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (talents_.length == 0) revert EmptyTalentsList();
        if (talents_.length > MAX_BATCH) revert BatchTooLarge();
        require(talents_.length == amounts_.length, "Arrays length mismatch");
        if (projectFundedAmount[projectId_] == 0) revert ProjectNotFunded();

        uint256 totalToDistribute = 0;
        for (uint256 i = 0; i < amounts_.length; i++) {
            totalToDistribute += amounts_[i];
        }

        uint256 remaining = projectFundedAmount[projectId_] -
            projectDistributedAmount[projectId_];
        if (totalToDistribute > remaining) revert ExceedsFundedAmount();

        projectDistributedAmount[projectId_] += totalToDistribute;

        for (uint256 i = 0; i < talents_.length; i++) {
            if (talents_[i] == address(0)) revert InvalidAddress();
            if (amounts_[i] == 0) revert InvalidAmount();
            if (isProjectSponsor[projectId_][talents_[i]])
                revert TalentCannotBeSponsor();

            bool success = hackToken.transfer(talents_[i], amounts_[i]);
            if (!success) revert TransferFailed();

            emit ProjectDistributed(projectId_, talents_[i], amounts_[i]);
        }
    }

    /**
     * @notice Reembolsa a un sponsor su parte no distribuida de un
     * proyecto cuyo plazo de financiacion ya venció.
     * @dev Cada sponsor recupera proporcionalmente a lo no distribuido
     * del total del proyecto sobre lo que el aporto.
     */
    function refundContribution(bytes32 projectId_) external nonReentrant {
        if (block.timestamp < projectFundingDeadline[projectId_])
            revert FundingWindowStillOpen();
        if (refunded[projectId_][msg.sender]) revert AlreadyRefunded();

        uint256 myContribution = contribution[projectId_][msg.sender];
        if (myContribution == 0) revert NothingToRefund();

        uint256 funded = projectFundedAmount[projectId_];
        uint256 distributed = projectDistributedAmount[projectId_];
        uint256 remaining = funded - distributed;
        if (remaining == 0) revert NothingToRefund();

        // Parte proporcional de lo no distribuido que corresponde a este sponsor
        uint256 refundAmount = (myContribution * remaining) / funded;
        if (refundAmount == 0) revert NothingToRefund();

        refunded[projectId_][msg.sender] = true;

        bool success = hackToken.transfer(msg.sender, refundAmount);
        if (!success) revert TransferFailed();

        emit ProjectRefunded(projectId_, msg.sender, refundAmount);
    }

    // --- Views ---

    function hasDegreeReward(
        address user_,
        bytes32 degreeId_
    ) external view returns (bool) {
        return degreeRewarded[user_][degreeId_];
    }

    function getLastHiringRewardMonth(
        address talent_
    ) external view returns (uint256) {
        return lastHiringRewardMonth[talent_];
    }

    function getProjectFunding(
        bytes32 projectId_
    )
        external
        view
        returns (
            uint256 funded,
            uint256 distributed,
            uint256 remaining,
            uint256 deadline
        )
    {
        funded = projectFundedAmount[projectId_];
        distributed = projectDistributedAmount[projectId_];
        remaining = funded - distributed;
        deadline = projectFundingDeadline[projectId_];
    }

    // --- Admin ---

    function setIncentivesPool(address newPool_) external onlyRole(ADMIN_ROLE) {
        if (newPool_ == address(0)) revert InvalidAddress();
        incentivesPool = newPool_;
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
    function distribute(
        address to_,
        uint256 amount_,
        string calldata reason_
    ) external;
}

interface IRoleRegistry {
    function isEducator(address account_) external view returns (bool);
    function isRecruiter(address account_) external view returns (bool);
    function isBlocked(address account_) external view returns (bool);
}
