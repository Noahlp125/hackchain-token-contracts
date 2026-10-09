// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MembershipSystem
 * @dev Handles platform memberships (mechanisms 3 and 13).
 * Mechanism 3: Advanced features membership — 50,000 tokens/month.
 * Mechanism 13: Academic content membership — monthly/quarterly/annual tiers.
 * Payments are split between IncentivesPool and Treasury.
 *
 * HC-SRC-002 fix: activar o renovar cualquier membresia, registrar una
 * vista y reclamar recompensas de educador consultan
 * RoleRegistry.isBlocked(), un perfil bloqueado no puede. Se deja
 * cancelAdvancedMembership() exenta a proposito: es salida + pago de
 * penalizacion, no reclamacion de incentivo.
 *
 * HC-SRC-004 fix: el EDUCATOR_ROLE local (AccessControl) desaparece.
 * registerContentView() y claimEducatorRewards() consultan
 * RoleRegistry.isEducator() en su lugar, para que revocar a un educador
 * en RoleRegistry tenga efecto inmediato aqui tambien, sin un rol
 * paralelo que se pueda olvidar sincronizar.
 *
 * HC-SRC-001 fix: la recompensa académica se contabiliza por ciclo. Cada
 * ciclo guarda su pool (las cuotas pagadas mientras está abierto), su total
 * de vistas y las vistas de cada educador. advanceCycle() cierra el ciclo y
 * congela esos datos. Solo se reclama contra ciclos cerrados, una vez por
 * educador, así que el reparto no depende del orden de los claims ni de las
 * cuotas que entren después. Un ciclo cerrado sin vistas pasa su pool al
 * siguiente. Lo que nadie reclame en UNCLAIMED_ROLLOVER_WINDOW tras el cierre
 * se puede pasar al ciclo abierto.
 */
contract MembershipSystem is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // --- Constants ---

    // Mechanism 3 — Advanced membership
    uint256 public constant ADVANCED_MEMBERSHIP_COST = 50_000 * 1e18;
    uint256 public constant ADVANCED_MEMBERSHIP_DURATION = 30 days;
    uint256 public constant ADVANCED_CANCELLATION_PENALTY = 1_000 * 1e18;

    // Mechanism 13 — Academic content membership tiers
    uint256 public constant ACADEMIC_MONTHLY_COST = 30_000 * 1e18;
    uint256 public constant ACADEMIC_QUARTERLY_COST = 80_000 * 1e18;
    uint256 public constant ACADEMIC_ANNUAL_COST = 330_000 * 1e18;

    uint256 public constant ACADEMIC_MONTHLY_DURATION = 30 days;
    uint256 public constant ACADEMIC_QUARTERLY_DURATION = 90 days;
    uint256 public constant ACADEMIC_ANNUAL_DURATION = 365 days;

    // Split percentages — 50% to pool, 50% to treasury
    uint256 public constant POOL_SHARE = 50;
    uint256 public constant TREASURY_SHARE = 50;

    // Plazo tras el cierre de un ciclo para reclamar su parte, después del
    // cual lo no reclamado puede pasar al ciclo abierto (HC-SRC-001)
    uint256 public constant UNCLAIMED_ROLLOVER_WINDOW = 90 days;

    // --- Enums ---
    enum AcademicTier {
        None,
        Monthly,
        Quarterly,
        Annual
    }

    // --- Structs ---

    /**
     * @dev Tracks advanced membership (mechanism 3) for a user.
     */
    struct AdvancedMembership {
        bool active;
        uint256 startTime;
        uint256 expiresAt;
    }

    /**
     * @dev Tracks academic content membership (mechanism 13) for a user.
     */
    struct AcademicMembership {
        AcademicTier tier;
        uint256 startTime;
        uint256 expiresAt;
    }

    /**
     * @dev Contabilidad de un ciclo de recompensas académicas (HC-SRC-001).
     * pool y totalViews se congelan al cerrar el ciclo.
     */
    struct Cycle {
        uint256 pool;
        uint256 totalViews;
        uint256 claimed;
        uint256 closedAt;
        bool rolledOver;
    }

    // --- State ---
    IERC20 public immutable hackToken;
    address public incentivesPool;
    address public treasury;
    IRoleRegistry public roleRegistry;

    // user => advanced membership info
    mapping(address => AdvancedMembership) public advancedMemberships;

    // user => academic membership info
    mapping(address => AcademicMembership) public academicMemberships;

    // ciclo de distribución abierto. El admin lo cierra con advanceCycle(),
    // que abre el siguiente
    uint256 public currentCycle;

    // cycle => contabilidad del ciclo
    mapping(uint256 => Cycle) public cycles;

    // cycle => educator => vistas del educador en ese ciclo
    mapping(uint256 => mapping(address => uint256)) public educatorCycleViews;

    // cycle => educator => ya reclamó su parte de ese ciclo
    mapping(uint256 => mapping(address => bool)) public rewardsClaimed;

    // cycle => viewer => educator => ya contado en este ciclo
    mapping(uint256 => mapping(address => mapping(address => bool)))
        public hasCountedView;

    // --- Custom Errors ---
    error InvalidAddress();
    error AmountMustBeGreaterThanZero();
    error MembershipAlreadyActive();
    error MembershipNotActive();
    error MembershipExpired();
    error TransferFailed();
    error InvalidTier();
    error NoPendingRewards();
    error CannotViewOwnContent();
    error ViewAlreadyCounted();
    error ProfileBlocked();
    error NotEducator();
    error CycleNotClosed();
    error RewardsAlreadyClaimed();
    error CycleRolledOver();
    error RolloverWindowStillOpen();

    // --- Events ---

    // Mechanism 3
    event AdvancedMembershipActivated(address indexed user, uint256 expiresAt);
    event AdvancedMembershipCancelled(address indexed user, uint256 penalty);
    event AdvancedMembershipRenewed(address indexed user, uint256 newExpiresAt);

    // Mechanism 13
    event AcademicMembershipActivated(
        address indexed user,
        AcademicTier tier,
        uint256 expiresAt
    );
    event ContentViewed(address indexed user, address indexed educator);
    event EducatorRewardsDistributed(
        address indexed educator,
        uint256 indexed cycleId,
        uint256 amount
    );
    event CycleClosed(uint256 indexed cycleId, uint256 pool, uint256 totalViews);
    event UnclaimedRolledOver(
        uint256 indexed fromCycle,
        uint256 indexed toCycle,
        uint256 amount
    );

    // --- Constructor ---
    /**
     * @dev Links MembershipSystem to HackToken, IncentivesPool and Treasury.
     * @param hackToken_ Address of the deployed HackToken contract.
     * @param incentivesPool_ Address of the deployed IncentivesPool contract.
     * @param treasury_ Address of the treasury wallet.
     */
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
    }

    // --- Mechanism 3: Advanced Membership ---

    /**
     * @notice Activate the advanced features membership.
     * @dev Costs 50,000 tokens. Split 50/50 between IncentivesPool and Treasury.
     * User must approve this contract to spend their tokens first.
     */
    function activateAdvancedMembership() external nonReentrant {
        if (roleRegistry.isBlocked(msg.sender)) revert ProfileBlocked();
        if (_isAdvancedActive(msg.sender)) revert MembershipAlreadyActive();

        // Transfer tokens from user to this contract
        bool success = hackToken.transferFrom(
            msg.sender,
            address(this),
            ADVANCED_MEMBERSHIP_COST
        );
        if (!success) revert TransferFailed();

        // Split payment
        uint256 poolAmount = (ADVANCED_MEMBERSHIP_COST * POOL_SHARE) / 100;
        uint256 treasuryAmount = (ADVANCED_MEMBERSHIP_COST * TREASURY_SHARE) /
            100;

        // Send to IncentivesPool
        hackToken.safeTransfer(incentivesPool, poolAmount);
        // Notify pool of deposit
        IIncentivesPool(incentivesPool).deposit(
            poolAmount,
            "advanced_membership_fee"
        );

        // Send to Treasury
        hackToken.safeTransfer(treasury, treasuryAmount);

        // Register membership
        uint256 expiresAt = block.timestamp + ADVANCED_MEMBERSHIP_DURATION;
        advancedMemberships[msg.sender] = AdvancedMembership({
            active: true,
            startTime: block.timestamp,
            expiresAt: expiresAt
        });

        emit AdvancedMembershipActivated(msg.sender, expiresAt);
    }

    /**
     * @notice Cancel the advanced membership early.
     * @dev Applies a 1,000 token cancellation penalty.
     * Penalty goes to IncentivesPool.
     */
    function cancelAdvancedMembership() external nonReentrant {
        AdvancedMembership storage membership = advancedMemberships[msg.sender];
        if (!_isAdvancedActive(msg.sender)) revert MembershipNotActive();

        // Apply cancellation penalty
        bool success = hackToken.transferFrom(
            msg.sender,
            address(this),
            ADVANCED_CANCELLATION_PENALTY
        );
        if (!success) revert TransferFailed();

        // Send penalty to IncentivesPool
        hackToken.safeTransfer(incentivesPool, ADVANCED_CANCELLATION_PENALTY);
        IIncentivesPool(incentivesPool).deposit(
            ADVANCED_CANCELLATION_PENALTY,
            "advanced_membership_cancellation_penalty"
        );

        // Deactivate membership
        membership.active = false;

        emit AdvancedMembershipCancelled(
            msg.sender,
            ADVANCED_CANCELLATION_PENALTY
        );
    }

    /**
     * @notice Renew the advanced membership for another month.
     * @dev Can be called even if membership has expired.
     */
    function renewAdvancedMembership() external nonReentrant {
        if (roleRegistry.isBlocked(msg.sender)) revert ProfileBlocked();

        // Transfer tokens
        bool success = hackToken.transferFrom(
            msg.sender,
            address(this),
            ADVANCED_MEMBERSHIP_COST
        );
        if (!success) revert TransferFailed();

        // Split payment
        uint256 poolAmount = (ADVANCED_MEMBERSHIP_COST * POOL_SHARE) / 100;
        uint256 treasuryAmount = (ADVANCED_MEMBERSHIP_COST * TREASURY_SHARE) /
            100;

        hackToken.safeTransfer(incentivesPool, poolAmount);
        IIncentivesPool(incentivesPool).deposit(
            poolAmount,
            "advanced_membership_renewal"
        );
        hackToken.safeTransfer(treasury, treasuryAmount);

        // Extend from now if expired, from current expiry if still active
        AdvancedMembership storage membership = advancedMemberships[msg.sender];
        uint256 base = membership.active &&
            membership.expiresAt > block.timestamp
            ? membership.expiresAt
            : block.timestamp;

        uint256 newExpiresAt = base + ADVANCED_MEMBERSHIP_DURATION;
        membership.active = true;
        membership.expiresAt = newExpiresAt;

        emit AdvancedMembershipRenewed(msg.sender, newExpiresAt);
    }

    // --- Mechanism 13: Academic Content Membership ---

    /**
     * @notice Activate an academic content membership.
     * @dev Three tiers: Monthly (30k), Quarterly (80k), Annual (330k).
     * 50% goes to Treasury, 50% goes to educator reward pool.
     * @param tier_ The membership tier (1=Monthly, 2=Quarterly, 3=Annual).
     */
    function activateAcademicMembership(
        AcademicTier tier_
    ) external nonReentrant {
        if (roleRegistry.isBlocked(msg.sender)) revert ProfileBlocked();
        if (tier_ == AcademicTier.None) revert InvalidTier();
        if (
            academicMemberships[msg.sender].tier != AcademicTier.None &&
            academicMemberships[msg.sender].expiresAt > block.timestamp
        ) revert MembershipAlreadyActive();

        // Determine cost and duration based on tier
        (uint256 cost, uint256 duration) = _getTierDetails(tier_);

        // Transfer tokens from user
        bool success = hackToken.transferFrom(msg.sender, address(this), cost);
        if (!success) revert TransferFailed();

        // Split: 50% treasury, 50% educator pool
        uint256 treasuryAmount = (cost * TREASURY_SHARE) / 100;
        uint256 educatorAmount = (cost * POOL_SHARE) / 100;

        hackToken.safeTransfer(treasury, treasuryAmount);

        // La parte para educadores cuenta en el ciclo abierto
        cycles[currentCycle].pool += educatorAmount;

        // Register membership
        uint256 expiresAt = block.timestamp + duration;
        academicMemberships[msg.sender] = AcademicMembership({
            tier: tier_,
            startTime: block.timestamp,
            expiresAt: expiresAt
        });

        emit AcademicMembershipActivated(msg.sender, tier_, expiresAt);
    }

    /**
     * @notice Register a content view for an educator.
     * @dev Called by the platform when a member watches an educator's content.
     * Only addresses registered as Educator in RoleRegistry can be
     * registered as content creators.
     * @param educator_ Address of the educator whose content was viewed.
     */
    function registerContentView(address educator_) external {
        if (roleRegistry.isBlocked(msg.sender)) revert ProfileBlocked();
        if (msg.sender == educator_) revert CannotViewOwnContent();

        // Only active academic members can generate views
        AcademicMembership memory membership = academicMemberships[msg.sender];
        if (membership.tier == AcademicTier.None) revert MembershipNotActive();
        if (membership.expiresAt < block.timestamp) revert MembershipExpired();
        if (!roleRegistry.isEducator(educator_)) revert NotEducator();
        if (hasCountedView[currentCycle][msg.sender][educator_])
            revert ViewAlreadyCounted();

        hasCountedView[currentCycle][msg.sender][educator_] = true;
        educatorCycleViews[currentCycle][educator_] += 1;
        cycles[currentCycle].totalViews += 1;

        emit ContentViewed(msg.sender, educator_);
    }

    /**
     * @notice Claim the educator's share of a closed cycle.
     * @dev Share = pool del ciclo × vistas propias / vistas totales del ciclo,
     * sobre datos congelados al cierre (HC-SRC-001). Una vez por educador y
     * ciclo.
     * @param cycleId_ Ciclo cerrado cuya parte se reclama.
     */
    function claimEducatorRewards(uint256 cycleId_) external nonReentrant {
        if (roleRegistry.isBlocked(msg.sender)) revert ProfileBlocked();
        if (!roleRegistry.isEducator(msg.sender)) revert NotEducator();
        if (cycleId_ >= currentCycle) revert CycleNotClosed();
        if (rewardsClaimed[cycleId_][msg.sender]) revert RewardsAlreadyClaimed();

        Cycle storage cycle = cycles[cycleId_];
        if (cycle.rolledOver) revert CycleRolledOver();

        uint256 views = educatorCycleViews[cycleId_][msg.sender];
        if (views == 0) revert NoPendingRewards();

        uint256 reward = (cycle.pool * views) / cycle.totalViews;
        if (reward == 0) revert NoPendingRewards();

        rewardsClaimed[cycleId_][msg.sender] = true;
        cycle.claimed += reward;

        hackToken.safeTransfer(msg.sender, reward);

        emit EducatorRewardsDistributed(msg.sender, cycleId_, reward);
    }

    /**
     * @notice Pasa al ciclo abierto lo que no se reclamó de un ciclo cerrado.
     * @dev Callable por cualquiera una vez pasado UNCLAIMED_ROLLOVER_WINDOW
     * desde el cierre. Cubre las partes de educadores revocados, bloqueados o
     * que no reclaman, y los restos de redondeo. Después ese ciclo ya no se
     * puede reclamar.
     * @param cycleId_ Ciclo cerrado cuyo resto se traslada.
     */
    function rollOverUnclaimed(uint256 cycleId_) external {
        if (cycleId_ >= currentCycle) revert CycleNotClosed();

        Cycle storage cycle = cycles[cycleId_];
        if (cycle.rolledOver) revert CycleRolledOver();
        if (block.timestamp < cycle.closedAt + UNCLAIMED_ROLLOVER_WINDOW) {
            revert RolloverWindowStillOpen();
        }

        _rollOver(cycleId_, cycle.pool - cycle.claimed);
    }

    // --- Views ---

    /**
     * @notice Check if a user has an active advanced membership.
     */
    function hasAdvancedMembership(address user_) external view returns (bool) {
        return _isAdvancedActive(user_);
    }

    /**
     * @notice Check if a user has an active academic membership.
     */
    function hasAcademicMembership(address user_) external view returns (bool) {
        AcademicMembership memory m = academicMemberships[user_];
        return m.tier != AcademicTier.None && m.expiresAt > block.timestamp;
    }

    /**
     * @notice Returns the academic membership tier of a user.
     */
    function getAcademicTier(
        address user_
    ) external view returns (AcademicTier) {
        return academicMemberships[user_].tier;
    }

    // --- Internal ---

    /**
     * @dev Returns cost and duration for a given academic tier.
     */
    function _getTierDetails(
        AcademicTier tier_
    ) internal pure returns (uint256 cost, uint256 duration) {
        if (tier_ == AcademicTier.Monthly)
            return (ACADEMIC_MONTHLY_COST, ACADEMIC_MONTHLY_DURATION);
        if (tier_ == AcademicTier.Quarterly)
            return (ACADEMIC_QUARTERLY_COST, ACADEMIC_QUARTERLY_DURATION);
        if (tier_ == AcademicTier.Annual)
            return (ACADEMIC_ANNUAL_COST, ACADEMIC_ANNUAL_DURATION);
        revert InvalidTier();
    }
    /**
     * @dev Fuente de verdad única para saber si una membresía avanzada está
     * realmente activa (activa y no expirada). Evita el desajuste entre
     * el booleano `active` y `expiresAt` señalado en L-03.
     */
    function _isAdvancedActive(address user_) internal view returns (bool) {
        AdvancedMembership storage m = advancedMemberships[user_];
        return m.active && m.expiresAt > block.timestamp;
    }

    /// @dev Marca el ciclo como trasladado y suma el importe al ciclo abierto.
    function _rollOver(uint256 cycleId_, uint256 amount_) internal {
        cycles[cycleId_].rolledOver = true;
        cycles[currentCycle].pool += amount_;

        emit UnclaimedRolledOver(cycleId_, currentCycle, amount_);
    }

    // --- Admin ---

    /**
     * @notice Update the IncentivesPool address.
     */
    function setIncentivesPool(address newPool_) external onlyRole(ADMIN_ROLE) {
        if (newPool_ == address(0)) revert InvalidAddress();
        incentivesPool = newPool_;
    }

    /**
     * @notice Update the Treasury address.
     */
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
    /**
     * @notice Cierra el ciclo abierto y abre el siguiente.
     * @dev El pool y las vistas del ciclo cerrado quedan congelados para los
     * claims (HC-SRC-001). Los espectadores vuelven a poder generar vistas
     * contables en el ciclo nuevo. Si el ciclo se cierra sin vistas nadie
     * podría reclamar su pool, así que pasa entero al siguiente.
     */
    function advanceCycle() external onlyRole(ADMIN_ROLE) {
        uint256 closing = currentCycle;
        Cycle storage cycle = cycles[closing];
        cycle.closedAt = block.timestamp;
        currentCycle = closing + 1;

        emit CycleClosed(closing, cycle.pool, cycle.totalViews);

        if (cycle.totalViews == 0 && cycle.pool > 0) {
            _rollOver(closing, cycle.pool);
        }
    }
}

// --- Interfaces ---
interface IIncentivesPool {
    function distribute(
        address to_,
        uint256 amount_,
        string calldata reason_
    ) external;
    function deposit(uint256 amount_, string calldata reason_) external;
}

interface IRoleRegistry {
    function isBlocked(address account_) external view returns (bool);
    function isEducator(address account_) external view returns (bool);
}
