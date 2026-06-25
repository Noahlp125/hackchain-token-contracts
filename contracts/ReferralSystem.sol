// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ReferralSystem
 * @dev Handles the referral mechanism (mechanism 2).
 * Rewards users who bring new users to the platform.
 * The referred user must have at least 1000 tokens staked for 1 month.
 * Maximum 5 validated referrals per month per referrer.
 */
contract ReferralSystem is AccessControl, ReentrancyGuard {

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // --- Constants ---
    // Reward per valid referral (mechanism 2)
    uint256 public constant REFERRAL_REWARD = 1_000 * 1e18;

    // Maximum referrals per month per user
    uint256 public constant MAX_REFERRALS_PER_MONTH = 5;

    // Minimum stake required for the referred user to be valid
    uint256 public constant MIN_STAKE_FOR_REFERRAL = 1_000 * 1e18;

    // --- Structs ---
    /**
     * @dev Tracks referral activity per user per month.
     * month is stored as block.timestamp / 30 days for simplicity.
     */
    struct ReferralInfo {
        uint256 currentMonth;       // which month this counter belongs to
        uint256 referralsThisMonth; // how many valid referrals this month
        uint256 totalReferrals;     // total valid referrals all time
        uint256 totalRewards;       // total tokens earned from referrals
    }

    // --- State ---
    address public incentivesPool;
    address public stakingContract;

    // referrer address => their referral info
    mapping(address => ReferralInfo) public referralInfo;

    // referred address => referrer address (who referred them)
    mapping(address => address) public referredBy;

    // referred address => whether their referral has been validated and rewarded
    mapping(address => bool) public referralValidated;

    // --- Custom Errors ---
    error InvalidAddress();
    error AlreadyReferred();
    error ReferralAlreadyValidated();
    error ReferredUserNotStaking();
    error MonthlyLimitReached();
    error CannotReferYourself();
    error NotReferred();

    // --- Events ---
    event UserReferred(address indexed referrer, address indexed referred);
    event ReferralValidated(address indexed referrer, address indexed referred, uint256 reward);

    // --- Constructor ---
    /**
     * @dev Links ReferralSystem to IncentivesPool and StakingContract.
     * @param incentivesPool_ Address of the deployed IncentivesPool contract.
     * @param stakingContract_ Address of the deployed StakingContract.
     */
    constructor(address incentivesPool_, address stakingContract_) {
        if (incentivesPool_ == address(0)) revert InvalidAddress();
        if (stakingContract_ == address(0)) revert InvalidAddress();

        incentivesPool = incentivesPool_;
        stakingContract = stakingContract_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // --- Core functions ---

    /**
     * @notice Register who referred you to the platform.
     * @dev Called by the new user when they join.
     * The referral is not rewarded yet — only registered.
     * Reward is triggered once the referred user completes staking.
     * @param referrer_ Address of the user who referred you.
     */
    function registerReferral(address referrer_) external {
        if (referrer_ == address(0)) revert InvalidAddress();
        if (referrer_ == msg.sender) revert CannotReferYourself();
        if (referredBy[msg.sender] != address(0)) revert AlreadyReferred();

        referredBy[msg.sender] = referrer_;
        emit UserReferred(referrer_, msg.sender);
    }

    /**
     * @notice Validate and reward a referral.
     * @dev Called by the referred user after they have completed staking.
     * Checks that:
     * - The caller was referred by someone
     * - The referral has not been validated yet
     * - The caller has at least 1000 tokens staked
     * - The referrer has not exceeded 5 referrals this month
     * If all checks pass, rewards the referrer from IncentivesPool.
     */
    function validateReferral() external nonReentrant {
        address referred = msg.sender;
        address referrer = referredBy[referred];

        // Check referral exists
        if (referrer == address(0)) revert NotReferred();

        // Check not already validated
        if (referralValidated[referred]) revert ReferralAlreadyValidated();

        // Check referred user has minimum stake
        uint256 stakedAmount = IStakingContract(stakingContract).getTotalStaked(referred);
        if (stakedAmount < MIN_STAKE_FOR_REFERRAL) revert ReferredUserNotStaking();

        // Check monthly limit for referrer
        ReferralInfo storage info = referralInfo[referrer];
        uint256 currentMonth = block.timestamp / 30 days;

        // Reset counter if it's a new month
        if (info.currentMonth != currentMonth) {
            info.currentMonth = currentMonth;
            info.referralsThisMonth = 0;
        }

        if (info.referralsThisMonth >= MAX_REFERRALS_PER_MONTH) revert MonthlyLimitReached();

        // Mark as validated before external call (CEI pattern)
        referralValidated[referred] = true;
        info.referralsThisMonth += 1;
        info.totalReferrals += 1;
        info.totalRewards += REFERRAL_REWARD;

        // Request reward from IncentivesPool
        IIncentivesPool(incentivesPool).distribute(
            referrer,
            REFERRAL_REWARD,
            "referral_reward"
        );

        emit ReferralValidated(referrer, referred, REFERRAL_REWARD);
    }

    // --- Views ---

    /**
     * @notice Returns the referral info for a given user.
     */
    function getReferralInfo(address user_) external view returns (ReferralInfo memory) {
        return referralInfo[user_];
    }

    /**
     * @notice Returns who referred a given user.
     */
    function getReferrer(address user_) external view returns (address) {
        return referredBy[user_];
    }

    /**
     * @notice Returns whether a referral has been validated.
     */
    function isValidated(address referred_) external view returns (bool) {
        return referralValidated[referred_];
    }

    /**
     * @notice Returns how many referrals the user has left this month.
     */
    function getReferralsLeft(address user_) external view returns (uint256) {
        ReferralInfo memory info = referralInfo[user_];
        uint256 currentMonth = block.timestamp / 30 days;

        if (info.currentMonth != currentMonth) return MAX_REFERRALS_PER_MONTH;
        if (info.referralsThisMonth >= MAX_REFERRALS_PER_MONTH) return 0;
        return MAX_REFERRALS_PER_MONTH - info.referralsThisMonth;
    }

    // --- Admin ---

    /**
     * @notice Update the IncentivesPool address if it changes.
     */
    function setIncentivesPool(address newPool_) external onlyRole(ADMIN_ROLE) {
        if (newPool_ == address(0)) revert InvalidAddress();
        incentivesPool = newPool_;
    }

    /**
     * @notice Update the StakingContract address if it changes.
     */
    function setStakingContract(address newStaking_) external onlyRole(ADMIN_ROLE) {
        if (newStaking_ == address(0)) revert InvalidAddress();
        stakingContract = newStaking_;
    }
}

// --- Interfaces ---
interface IIncentivesPool {
    function distribute(address to_, uint256 amount_, string calldata reason_) external;
}

interface IStakingContract {
    function getTotalStaked(address user_) external view returns (uint256);
}
