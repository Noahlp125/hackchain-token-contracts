// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ReputationBonuses
 * @dev Handles monthly reputation bonuses (mechanisms 15, 16, 17).
 * The platform determines the winner off-chain.
 * An enforcer registers the winner on-chain.
 * The winner has 3 days to claim from their dashboard.
 * Unclaimed bonuses return to IncentivesPool.
 */
contract ReputationBonuses is AccessControl, ReentrancyGuard {

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    // ENFORCER_ROLE: registers monthly winners after off-chain reputation calculation
    bytes32 public constant ENFORCER_ROLE = keccak256("ENFORCER_ROLE");

    // --- Constants ---
    uint256 public constant REPUTATION_BONUS = 5_000 * 1e18;
    uint256 public constant CLAIM_WINDOW = 3 days;

    // --- Enums ---
    enum UserRole { Talent, Educator, Recruiter }

    // --- Structs ---
    /**
     * @dev Represents a monthly bonus assigned to a winner.
     */
    struct MonthlyBonus {
        address winner;       // who won this month
        uint256 registeredAt; // when the enforcer registered the winner
        bool claimed;         // whether the bonus has been claimed
        bool returned;        // whether unclaimed tokens were returned to pool
    }

    // --- State ---
    address public incentivesPool;

    // role => month => bonus info
    // month calculated as block.timestamp / 30 days
    mapping(UserRole => mapping(uint256 => MonthlyBonus)) public monthlyBonuses;

    // role => current month (to avoid registering twice)
    mapping(UserRole => uint256) public lastRegisteredMonth;

    // --- Custom Errors ---
    error InvalidAddress();
    error WinnerAlreadyRegistered();
    error NoBonusForThisMonth();
    error ClaimWindowExpired();
    error ClaimWindowStillOpen();
    error AlreadyClaimed();
    error AlreadyReturned();
    error NotTheWinner();
    error TransferFailed();

    // --- Events ---
    event WinnerRegistered(UserRole indexed role, address indexed winner, uint256 month);
    event BonusClaimed(UserRole indexed role, address indexed winner, uint256 amount);
    event BonusReturnedToPool(UserRole indexed role, uint256 month, uint256 amount);

    // --- Constructor ---
    /**
     * @dev Links ReputationBonuses to IncentivesPool.
     * @param incentivesPool_ Address of the deployed IncentivesPool contract.
     */
    constructor(address incentivesPool_) {
        if (incentivesPool_ == address(0)) revert InvalidAddress();

        incentivesPool = incentivesPool_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(ENFORCER_ROLE, msg.sender);
    }

    // --- Core functions ---

    /**
     * @notice Register the monthly reputation winner for a given role.
     * @dev Only callable by ENFORCER_ROLE after off-chain reputation calculation.
     * Can only be called once per role per month.
     * @param role_ The user role (Talent, Educator, Recruiter).
     * @param winner_ Address of the winner.
     */
    function registerWinner(
        UserRole role_,
        address winner_
    ) external onlyRole(ENFORCER_ROLE) {
        if (winner_ == address(0)) revert InvalidAddress();

        uint256 currentMonth = block.timestamp / 30 days;

        // Prevent registering twice in the same month for the same role
        if (lastRegisteredMonth[role_] == currentMonth) revert WinnerAlreadyRegistered();

        lastRegisteredMonth[role_] = currentMonth;

        monthlyBonuses[role_][currentMonth] = MonthlyBonus({
            winner: winner_,
            registeredAt: block.timestamp,
            claimed: false,
            returned: false
        });

        emit WinnerRegistered(role_, winner_, currentMonth);
    }

    /**
     * @notice Claim the monthly reputation bonus.
     * @dev Called by the winner from their dashboard within 3 days of registration.
     * Requests distribution from IncentivesPool.
     * @param role_ The role for which the bonus is being claimed.
     */
    /**
     * @notice Claim the monthly reputation bonus.
     * @dev M-03 fix: recibe el mes/ciclo de forma explicita en vez de
     * recalcularlo con block.timestamp / 30 days. Esto evita que un
     * ganador legitimo pierda su ventana de reclamacion valida al
     * cruzarse un cambio de epoca entre el registro y el claim.
     * @param role_ The role for which the bonus is being claimed.
     * @param month_ El ciclo bajo el cual se registro el bono
     * (devuelto por WinnerRegistered o consultable off-chain).
     */
    function claimBonus(UserRole role_, uint256 month_) external nonReentrant {
        MonthlyBonus storage bonus = monthlyBonuses[role_][month_];

        // Check bonus exists for this month
        if (bonus.winner == address(0)) revert NoBonusForThisMonth();

        // Check caller is the winner
        if (bonus.winner != msg.sender) revert NotTheWinner();

        // Check not already claimed
        if (bonus.claimed) revert AlreadyClaimed();

        // Check not already returned to pool
        if (bonus.returned) revert AlreadyReturned();

        // Check within 3-day claim window, medido siempre desde registeredAt
        if (block.timestamp > bonus.registeredAt + CLAIM_WINDOW) revert ClaimWindowExpired();

        // Mark as claimed before external call (CEI pattern)
        bonus.claimed = true;

        // Request reward from IncentivesPool
        IIncentivesPool(incentivesPool).distribute(
            msg.sender,
            REPUTATION_BONUS,
            _reasonForRole(role_)
        );

        emit BonusClaimed(role_, msg.sender, REPUTATION_BONUS);
    }

    /**
     * @notice Return unclaimed bonus tokens to IncentivesPool.
     * @dev Callable by anyone after the 3-day claim window has expired.
     * This keeps the pool funded and prevents tokens from being locked.
     * @param role_ The role whose unclaimed bonus should be returned.
     * @param month_ The month to process (block.timestamp / 30 days).
     */
    function returnUnclaimedBonus(UserRole role_, uint256 month_) external nonReentrant {
        MonthlyBonus storage bonus = monthlyBonuses[role_][month_];

        // Check bonus exists
        if (bonus.winner == address(0)) revert NoBonusForThisMonth();

        // Check not already claimed or returned
        if (bonus.claimed) revert AlreadyClaimed();
        if (bonus.returned) revert AlreadyReturned();

        // Check claim window has expired
        if (block.timestamp <= bonus.registeredAt + CLAIM_WINDOW) revert ClaimWindowStillOpen();

        // Mark as returned before external call (CEI pattern)
        bonus.returned = true;

        // Notify pool — tokens were never distributed so no transfer needed
        // Just mark as returned so pool accounting stays consistent
        emit BonusReturnedToPool(role_, month_, REPUTATION_BONUS);
    }

    // --- Views ---

    /**
     * @notice Returns the bonus info for a given role and month.
     */
    function getMonthlyBonus(
        UserRole role_,
        uint256 month_
    ) external view returns (MonthlyBonus memory) {
        return monthlyBonuses[role_][month_];
    }

    /**
     * @notice Returns the current month number.
     * Useful for the frontend to know which month to query.
     */
    function getCurrentMonth() external view returns (uint256) {
        return block.timestamp / 30 days;
    }

    /**
     * @notice Returns whether the claim window is still open for a given role.
     */
    function isClaimWindowOpen(UserRole role_, uint256 month_) external view returns (bool) {
        MonthlyBonus memory bonus = monthlyBonuses[role_][month_];
        if (bonus.winner == address(0)) return false;
        return block.timestamp <= bonus.registeredAt + CLAIM_WINDOW;
    }

    /**
     * @notice Returns the winner for the current month for a given role.
     */
    function getCurrentWinner(UserRole role_) external view returns (address) {
        uint256 currentMonth = block.timestamp / 30 days;
        return monthlyBonuses[role_][currentMonth].winner;
    }

    // --- Internal ---

    /**
     * @dev Returns a human-readable reason string for each role.
     * Used in IncentivesPool distribute() call for tracking.
     */
    function _reasonForRole(UserRole role_) internal pure returns (string memory) {
        if (role_ == UserRole.Talent) return "reputation_bonus_talent";
        if (role_ == UserRole.Educator) return "reputation_bonus_educator";
        return "reputation_bonus_recruiter";
    }

    // --- Admin ---

    /**
     * @notice Update the IncentivesPool address.
     */
    function setIncentivesPool(address newPool_) external onlyRole(ADMIN_ROLE) {
        if (newPool_ == address(0)) revert InvalidAddress();
        incentivesPool = newPool_;
    }
}

// --- Interface ---
interface IIncentivesPool {
    function distribute(address to_, uint256 amount_, string calldata reason_) external;
}