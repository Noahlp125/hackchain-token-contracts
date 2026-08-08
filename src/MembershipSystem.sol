// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MembershipSystem
 * @dev Handles platform memberships (mechanisms 3 and 13).
 * Mechanism 3: Advanced features membership — 50,000 tokens/month.
 * Mechanism 13: Academic content membership — monthly/quarterly/annual tiers.
 * Payments are split between IncentivesPool and Treasury.
 */
contract MembershipSystem is AccessControl, ReentrancyGuard {

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    // EDUCATOR_ROLE: assigned to verified educators to register content views
    bytes32 public constant EDUCATOR_ROLE = keccak256("EDUCATOR_ROLE");

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

    // --- Enums ---
    enum AcademicTier { None, Monthly, Quarterly, Annual }

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
     * @dev Tracks content views per educator for reward distribution.
     * Reset after each distribution cycle.
     */
    struct EducatorViews {
        uint256 views;
        uint256 pendingRewards;
    }

    // --- State ---
    IERC20 public immutable hackToken;
    address public incentivesPool;
    address public treasury;

    // user => advanced membership info
    mapping(address => AdvancedMembership) public advancedMemberships;

    // user => academic membership info
    mapping(address => AcademicMembership) public academicMemberships;

    // educator => their view/reward tracking
    mapping(address => EducatorViews) public educatorViews;

    // total views across all educators in current cycle (for proportional distribution)
    uint256 public totalViewsThisCycle;

    // total academic fees pending distribution to educators
    uint256 public pendingEducatorPool;

    // ciclo de distribución actual — se incrementa manualmente por el admin
    // al cerrar un periodo, permitiendo que las vistas vuelvan a contarse
    uint256 public currentCycle;

    // cycle => viewer => educator => ya contado en este ciclo
    mapping(uint256 => mapping(address => mapping(address => bool))) public hasCountedView;

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

    // --- Events ---

    // Mechanism 3
    event AdvancedMembershipActivated(address indexed user, uint256 expiresAt);
    event AdvancedMembershipCancelled(address indexed user, uint256 penalty);
    event AdvancedMembershipRenewed(address indexed user, uint256 newExpiresAt);

    // Mechanism 13
    event AcademicMembershipActivated(address indexed user, AcademicTier tier, uint256 expiresAt);
    event ContentViewed(address indexed user, address indexed educator);
    event EducatorRewardsDistributed(address indexed educator, uint256 amount);

    // --- Constructor ---
    /**
     * @dev Links MembershipSystem to HackToken, IncentivesPool and Treasury.
     * @param hackToken_ Address of the deployed HackToken contract.
     * @param incentivesPool_ Address of the deployed IncentivesPool contract.
     * @param treasury_ Address of the treasury wallet.
     */
    constructor(address hackToken_, address incentivesPool_, address treasury_) {
        if (hackToken_ == address(0)) revert InvalidAddress();
        if (incentivesPool_ == address(0)) revert InvalidAddress();
        if (treasury_ == address(0)) revert InvalidAddress();

        hackToken = IERC20(hackToken_);
        incentivesPool = incentivesPool_;
        treasury = treasury_;

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
        if (advancedMemberships[msg.sender].active) revert MembershipAlreadyActive();

        // Transfer tokens from user to this contract
        bool success = hackToken.transferFrom(
            msg.sender,
            address(this),
            ADVANCED_MEMBERSHIP_COST
        );
        if (!success) revert TransferFailed();

        // Split payment
        uint256 poolAmount = ADVANCED_MEMBERSHIP_COST * POOL_SHARE / 100;
        uint256 treasuryAmount = ADVANCED_MEMBERSHIP_COST * TREASURY_SHARE / 100;

        // Send to IncentivesPool
        hackToken.transfer(incentivesPool, poolAmount);
        // Notify pool of deposit
        IIncentivesPool(incentivesPool).deposit(poolAmount, "advanced_membership_fee");

        // Send to Treasury
        hackToken.transfer(treasury, treasuryAmount);

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
        if (!membership.active) revert MembershipNotActive();

        // Apply cancellation penalty
        bool success = hackToken.transferFrom(
            msg.sender,
            address(this),
            ADVANCED_CANCELLATION_PENALTY
        );
        if (!success) revert TransferFailed();

        // Send penalty to IncentivesPool
        hackToken.transfer(incentivesPool, ADVANCED_CANCELLATION_PENALTY);
        IIncentivesPool(incentivesPool).deposit(
            ADVANCED_CANCELLATION_PENALTY,
            "advanced_membership_cancellation_penalty"
        );

        // Deactivate membership
        membership.active = false;

        emit AdvancedMembershipCancelled(msg.sender, ADVANCED_CANCELLATION_PENALTY);
    }

    /**
     * @notice Renew the advanced membership for another month.
     * @dev Can be called even if membership has expired.
     */
    function renewAdvancedMembership() external nonReentrant {
        // Transfer tokens
        bool success = hackToken.transferFrom(
            msg.sender,
            address(this),
            ADVANCED_MEMBERSHIP_COST
        );
        if (!success) revert TransferFailed();

        // Split payment
        uint256 poolAmount = ADVANCED_MEMBERSHIP_COST * POOL_SHARE / 100;
        uint256 treasuryAmount = ADVANCED_MEMBERSHIP_COST * TREASURY_SHARE / 100;

        hackToken.transfer(incentivesPool, poolAmount);
        IIncentivesPool(incentivesPool).deposit(poolAmount, "advanced_membership_renewal");
        hackToken.transfer(treasury, treasuryAmount);

        // Extend from now if expired, from current expiry if still active
        AdvancedMembership storage membership = advancedMemberships[msg.sender];
        uint256 base = membership.active && membership.expiresAt > block.timestamp
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
    function activateAcademicMembership(AcademicTier tier_) external nonReentrant {
        if (tier_ == AcademicTier.None) revert InvalidTier();
        if (academicMemberships[msg.sender].tier != AcademicTier.None &&
            academicMemberships[msg.sender].expiresAt > block.timestamp)
            revert MembershipAlreadyActive();

        // Determine cost and duration based on tier
        (uint256 cost, uint256 duration) = _getTierDetails(tier_);

        // Transfer tokens from user
        bool success = hackToken.transferFrom(msg.sender, address(this), cost);
        if (!success) revert TransferFailed();

        // Split: 50% treasury, 50% educator pool
        uint256 treasuryAmount = cost * TREASURY_SHARE / 100;
        uint256 educatorAmount = cost * POOL_SHARE / 100;

        hackToken.transfer(treasury, treasuryAmount);

        // Accumulate educator pool for proportional distribution
        pendingEducatorPool += educatorAmount;

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
     * Only accounts with EDUCATOR_ROLE can be registered as content creators.
     * @param educator_ Address of the educator whose content was viewed.
     */
    function registerContentView(address educator_) external {
        if (msg.sender == educator_) revert CannotViewOwnContent();

    // Only active academic members can generate views
        AcademicMembership memory membership = academicMemberships[msg.sender];
        if (membership.tier == AcademicTier.None) revert MembershipNotActive();
        if (membership.expiresAt < block.timestamp) revert MembershipExpired();
        if (!hasRole(EDUCATOR_ROLE, educator_)) revert InvalidAddress();
        if (hasCountedView[currentCycle][msg.sender][educator_]) revert ViewAlreadyCounted();

        hasCountedView[currentCycle][msg.sender][educator_] = true;
        educatorViews[educator_].views += 1;
        totalViewsThisCycle += 1;

        emit ContentViewed(msg.sender, educator_);
    }

    /**
     * @notice Claim proportional rewards based on content views.
     * @dev Called by educators to claim their share of the educator pool.
     * Share is proportional to their views vs total views this cycle.
     */
    function claimEducatorRewards() external nonReentrant {
        if (!hasRole(EDUCATOR_ROLE, msg.sender)) revert InvalidAddress();
        if (totalViewsThisCycle == 0) revert NoPendingRewards();

        EducatorViews storage ev = educatorViews[msg.sender];
        if (ev.views == 0) revert NoPendingRewards();

        // Calculate proportional reward
        uint256 reward = pendingEducatorPool * ev.views / totalViewsThisCycle;
        if (reward == 0) revert NoPendingRewards();

        // Reset views before transfer (CEI pattern)
        totalViewsThisCycle -= ev.views;
        ev.pendingRewards += reward;
        ev.views = 0;
        pendingEducatorPool -= reward;

        bool success = hackToken.transfer(msg.sender, reward);
        if (!success) revert TransferFailed();

        emit EducatorRewardsDistributed(msg.sender, reward);
    }

    // --- Views ---

    /**
     * @notice Check if a user has an active advanced membership.
     */
    function hasAdvancedMembership(address user_) external view returns (bool) {
        AdvancedMembership memory m = advancedMemberships[user_];
        return m.active && m.expiresAt > block.timestamp;
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
    function getAcademicTier(address user_) external view returns (AcademicTier) {
        return academicMemberships[user_].tier;
    }

    // --- Internal ---

    /**
     * @dev Returns cost and duration for a given academic tier.
     */
    function _getTierDetails(AcademicTier tier_)
        internal
        pure
        returns (uint256 cost, uint256 duration)
    {
        if (tier_ == AcademicTier.Monthly) return (ACADEMIC_MONTHLY_COST, ACADEMIC_MONTHLY_DURATION);
        if (tier_ == AcademicTier.Quarterly) return (ACADEMIC_QUARTERLY_COST, ACADEMIC_QUARTERLY_DURATION);
        if (tier_ == AcademicTier.Annual) return (ACADEMIC_ANNUAL_COST, ACADEMIC_ANNUAL_DURATION);
        revert InvalidTier();
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
    /**
 * @notice Avanza al siguiente ciclo de distribución de vistas académicas.
 * @dev Permite que los espectadores vuelvan a generar vistas contables
 * para el mismo educador. Debe llamarse tras cada distribución completa
 * del pool (p.ej. mensualmente), no arbitrariamente.
 */
function advanceCycle() external onlyRole(ADMIN_ROLE) {
    currentCycle += 1;
}
}

// --- Interfaces ---
interface IIncentivesPool {
    function distribute(address to_, uint256 amount_, string calldata reason_) external;
    function deposit(uint256 amount_, string calldata reason_) external;
}
