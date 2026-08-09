// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title EventRewards
 * @dev Handles event-based reward mechanisms (5, 10, 18, 19).
 * Mechanism 5:  Organizing a Hackchain promotional event → 30,000 tokens.
 * Mechanism 10: Talent attends 4 academic events in a month → 4,000 tokens.
 * Mechanism 18: Educator hosts their first academic event → 5,000 tokens (once ever).
 * Mechanism 19: Educator hosts 4 academic events in a month → 4,000 tokens.
 * Events are verified off-chain by an enforcer before rewards are distributed.
 */
contract EventRewards is AccessControl, ReentrancyGuard {

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    // ENFORCER_ROLE: verifies event completion and triggers rewards
    bytes32 public constant ENFORCER_ROLE = keccak256("ENFORCER_ROLE");

    // --- Constants ---

    // Mechanism 5: Promotional event reward
    uint256 public constant PROMO_EVENT_REWARD = 30_000 * 1e18;
    uint256 public constant PROMO_EVENT_MIN_ATTENDEES = 10;

    // Mechanism 10: Talent monthly attendance reward
    uint256 public constant TALENT_ATTENDANCE_REWARD = 4_000 * 1e18;
    uint256 public constant TALENT_ATTENDANCE_REQUIRED = 4;

    // Mechanism 18: Educator first event reward
    uint256 public constant EDUCATOR_FIRST_EVENT_REWARD = 5_000 * 1e18;

    // Mechanism 19: Educator monthly events reward
    uint256 public constant EDUCATOR_MONTHLY_EVENTS_REWARD = 4_000 * 1e18;
    uint256 public constant EDUCATOR_MONTHLY_EVENTS_REQUIRED = 4;

    // --- Structs ---

    /**
     * @dev Tracks monthly event activity for Talents (mechanism 10).
     */
    struct TalentMonthlyAttendance {
        uint256 currentMonth;
        uint256 eventsAttended;
        bool rewardClaimed;
    }

    /**
     * @dev Tracks monthly event activity for Educators (mechanism 19).
     */
    struct EducatorMonthlyEvents {
        uint256 currentMonth;
        uint256 eventsHosted;
        bool rewardClaimed;
    }

    // --- State ---
    address public incentivesPool;

    // Mechanism 18: tracks if educator has received their first event reward
    mapping(address => bool) public firstEventRewarded;

    // Mechanism 10: talent => monthly attendance tracking
    mapping(address => TalentMonthlyAttendance) public talentAttendance;

    // Mechanism 19: educator => monthly events tracking
    mapping(address => EducatorMonthlyEvents) public educatorMonthlyEvents;

    // Mechanism 5: eventId => whether reward has been distributed
    mapping(bytes32 => bool) public promoEventRewarded;

    // --- Custom Errors ---
    error InvalidAddress();
    error AmountMustBeGreaterThanZero();
    error NotEnoughAttendees();
    error PromoEventAlreadyRewarded();
    error FirstEventAlreadyRewarded();
    error MonthlyRewardAlreadyClaimed();
    error NotEnoughEventsThisMonth();

    // --- Events ---
    event PromoEventRewarded(address indexed organizer, bytes32 indexed eventId, uint256 amount);
    event TalentAttendanceRewarded(address indexed talent, uint256 month, uint256 amount);
    event EducatorFirstEventRewarded(address indexed educator, uint256 amount);
    event EducatorMonthlyEventsRewarded(address indexed educator, uint256 month, uint256 amount);
    event TalentAttendanceRegistered(address indexed talent, uint256 eventsAttended);
    event EducatorEventRegistered(address indexed educator, uint256 eventsHosted);

    // --- Constructor ---
    /**
     * @dev Links EventRewards to IncentivesPool.
     * @param incentivesPool_ Address of the deployed IncentivesPool contract.
     */
    constructor(address incentivesPool_) {
        if (incentivesPool_ == address(0)) revert InvalidAddress();

        incentivesPool = incentivesPool_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(ENFORCER_ROLE, msg.sender);
    }

    // --- Mechanism 5: Promotional event ---

    /**
     * @notice Reward the organizer of a Hackchain promotional event.
     * @dev Only callable by ENFORCER_ROLE after verifying the event had
     * at least 10 attendees. Each event has a unique ID to prevent double rewards.
     * If there are multiple organizers, the enforcer calls this once per organizer
     * with a proportional amount — split handled off-chain.
     * @param organizer_ Address of the event organizer.
     * @param eventId_ Unique identifier for the event (e.g. keccak256 of event details).
     * @param attendees_ Number of verified attendees.
     */
    function rewardPromoEvent(
        address organizer_,
        bytes32 eventId_,
        uint256 attendees_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (organizer_ == address(0)) revert InvalidAddress();
        if (attendees_ < PROMO_EVENT_MIN_ATTENDEES) revert NotEnoughAttendees();
        if (promoEventRewarded[eventId_]) revert PromoEventAlreadyRewarded();

        // Mark as rewarded before external call (CEI pattern)
        promoEventRewarded[eventId_] = true;

        IIncentivesPool(incentivesPool).distribute(
            organizer_,
            PROMO_EVENT_REWARD,
            "promo_event_reward"
        );

        emit PromoEventRewarded(organizer_, eventId_, PROMO_EVENT_REWARD);
    }

    // --- Mechanism 10: Talent monthly attendance ---

    /**
     * @notice Register an academic event attendance for a Talent.
     * @dev Called by ENFORCER_ROLE each time a Talent attends a verified event.
     * Resets the counter automatically when a new month starts.
     * @param talent_ Address of the Talent who attended.
     */
    function registerTalentAttendance(address talent_)
        external
        onlyRole(ENFORCER_ROLE)
    {
        if (talent_ == address(0)) revert InvalidAddress();

        uint256 currentMonth = block.timestamp / 30 days;
        TalentMonthlyAttendance storage attendance = talentAttendance[talent_];

        // Reset counter if new month
        if (attendance.currentMonth != currentMonth) {
            attendance.currentMonth = currentMonth;
            attendance.eventsAttended = 0;
            attendance.rewardClaimed = false;
        }

        attendance.eventsAttended += 1;

        emit TalentAttendanceRegistered(talent_, attendance.eventsAttended);
    }

    /**
     * @notice Claim the monthly attendance reward for a Talent.
     * @dev Callable by the Talent once they have attended 4 events this month.
     * Only claimable once per month.
     */
    function claimTalentAttendanceReward() external nonReentrant {
        uint256 currentMonth = block.timestamp / 30 days;
        TalentMonthlyAttendance storage attendance = talentAttendance[msg.sender];

        // Reset if new month
        if (attendance.currentMonth != currentMonth) {
            attendance.currentMonth = currentMonth;
            attendance.eventsAttended = 0;
            attendance.rewardClaimed = false;
        }

        if (attendance.rewardClaimed) revert MonthlyRewardAlreadyClaimed();
        if (attendance.eventsAttended < TALENT_ATTENDANCE_REQUIRED)
            revert NotEnoughEventsThisMonth();

        // Mark as claimed before external call (CEI pattern)
        attendance.rewardClaimed = true;

        IIncentivesPool(incentivesPool).distribute(
            msg.sender,
            TALENT_ATTENDANCE_REWARD,
            "talent_attendance_reward"
        );

        emit TalentAttendanceRewarded(msg.sender, currentMonth, TALENT_ATTENDANCE_REWARD);
    }

    // --- Mechanism 18: Educator first event ---

    /**
     * @notice Reward an educator for hosting their first academic event.
     * @dev Only callable by ENFORCER_ROLE after the event is marked as "Finished"
     * and certificates have been issued to Talents.
     * Can only be triggered once per educator ever.
     * @param educator_ Address of the educator.
     */
    function rewardEducatorFirstEvent(address educator_)
        external
        onlyRole(ENFORCER_ROLE)
        nonReentrant
    {
        if (educator_ == address(0)) revert InvalidAddress();
        if (firstEventRewarded[educator_]) revert FirstEventAlreadyRewarded();

        // Mark before external call (CEI pattern)
        firstEventRewarded[educator_] = true;

        IIncentivesPool(incentivesPool).distribute(
            educator_,
            EDUCATOR_FIRST_EVENT_REWARD,
            "educator_first_event_reward"
        );

        emit EducatorFirstEventRewarded(educator_, EDUCATOR_FIRST_EVENT_REWARD);
    }

    // --- Mechanism 19: Educator monthly events ---

    /**
     * @notice Register a completed academic event for an Educator.
     * @dev Called by ENFORCER_ROLE when an event is marked as "Finished"
     * and certificates have been issued.
     * Resets the counter automatically when a new month starts.
     * @param educator_ Address of the educator.
     */
    function registerEducatorEvent(address educator_)
        external
        onlyRole(ENFORCER_ROLE)
    {
        if (educator_ == address(0)) revert InvalidAddress();

        uint256 currentMonth = block.timestamp / 30 days;
        EducatorMonthlyEvents storage monthly = educatorMonthlyEvents[educator_];

        // Reset counter if new month
        if (monthly.currentMonth != currentMonth) {
            monthly.currentMonth = currentMonth;
            monthly.eventsHosted = 0;
            monthly.rewardClaimed = false;
        }

        monthly.eventsHosted += 1;

        emit EducatorEventRegistered(educator_, monthly.eventsHosted);
    }

    /**
     * @notice Claim the monthly events reward for an Educator.
     * @dev Callable by the Educator once they have hosted 4 events this month.
     * Only claimable once per month.
     */
    function claimEducatorMonthlyReward() external nonReentrant {
        uint256 currentMonth = block.timestamp / 30 days;
        EducatorMonthlyEvents storage monthly = educatorMonthlyEvents[msg.sender];

        // Reset if new month
        if (monthly.currentMonth != currentMonth) {
            monthly.currentMonth = currentMonth;
            monthly.eventsHosted = 0;
            monthly.rewardClaimed = false;
        }

        if (monthly.rewardClaimed) revert MonthlyRewardAlreadyClaimed();
        if (monthly.eventsHosted < EDUCATOR_MONTHLY_EVENTS_REQUIRED)
            revert NotEnoughEventsThisMonth();

        // Mark as claimed before external call (CEI pattern)
        monthly.rewardClaimed = true;

        IIncentivesPool(incentivesPool).distribute(
            msg.sender,
            EDUCATOR_MONTHLY_EVENTS_REWARD,
            "educator_monthly_events_reward"
        );

        emit EducatorMonthlyEventsRewarded(msg.sender, currentMonth, EDUCATOR_MONTHLY_EVENTS_REWARD);
    }

    // --- Views ---

    /**
     * @notice Returns monthly attendance info for a Talent.
     */
    function getTalentAttendance(address talent_)
        external
        view
        returns (TalentMonthlyAttendance memory)
    {
        return talentAttendance[talent_];
    }

    /**
     * @notice Returns monthly events info for an Educator.
     */
    function getEducatorMonthlyEvents(address educator_)
        external
        view
        returns (EducatorMonthlyEvents memory)
    {
        return educatorMonthlyEvents[educator_];
    }

    /**
     * @notice Returns whether an educator has received their first event reward.
     */
    function hasFirstEventReward(address educator_) external view returns (bool) {
        return firstEventRewarded[educator_];
    }

    /**
     * @notice Returns whether a promo event has already been rewarded.
     */
    function isPromoEventRewarded(bytes32 eventId_) external view returns (bool) {
        return promoEventRewarded[eventId_];
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