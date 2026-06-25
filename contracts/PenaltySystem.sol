// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PenaltySystem
 * @dev Handles all penalty mechanisms (7, 9, 14, 25, 26, 30).
 * Penalties are triggered by an authorized enforcer (admin/multisig)
 * after off-chain detection of infractions.
 * Penalized tokens go to IncentivesPool or Treasury depending on the case.
 */
contract PenaltySystem is AccessControl, ReentrancyGuard {

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    // ENFORCER_ROLE: assigned to admin/multisig that confirms infractions
    bytes32 public constant ENFORCER_ROLE = keccak256("ENFORCER_ROLE");

    // --- Constants ---

    // Mechanism 7: Identity fraud penalty
    uint256 public constant IDENTITY_FRAUD_PENALTY_PERCENT = 10;

    // Mechanism 9: Mass token sale penalty
    uint256 public constant MASS_SALE_PENALTY_PERCENT = 5;
    uint256 public constant MASS_SALE_THRESHOLD_PERCENT = 50;   // selling more than 50% of holdings
    uint256 public constant MASS_SALE_SUPPLY_THRESHOLD = 1;     // only applies if user holds 1%+ of supply

    // Mechanism 14: No-show interview penalty
    uint256 public constant NO_SHOW_PENALTY_PERCENT = 5;

    // Mechanism 25: Educator inactivity penalty
    uint256 public constant EDUCATOR_INACTIVITY_PENALTY_PERCENT = 5;

    // Mechanism 26: Plagiarism penalty
    uint256 public constant PLAGIARISM_PENALTY_PERCENT = 10;

    // Mechanism 30: Recruiter inactivity penalty
    uint256 public constant RECRUITER_INACTIVITY_PENALTY_PERCENT = 5;

    // --- Enums ---
    enum PenaltyType {
        IdentityFraud,      // mechanism 7
        MassSale,           // mechanism 9
        NoShowInterview,    // mechanism 14
        EducatorInactivity, // mechanism 25
        Plagiarism,         // mechanism 26
        RecruiterInactivity // mechanism 30
    }

    // --- Structs ---
    /**
     * @dev Records a penalty applied to a user.
     */
    struct PenaltyRecord {
        PenaltyType penaltyType;
        uint256 amount;
        uint256 timestamp;
        bool profileBlocked;
    }

    // --- State ---
    IERC20 public immutable hackToken;
    address public incentivesPool;
    address public treasury;

    // user => whether their profile is blocked
    mapping(address => bool) public profileBlocked;

    // user => list of penalties received
    mapping(address => PenaltyRecord[]) public penaltyHistory;

    // user => total tokens penalized
    mapping(address => uint256) public totalPenalized;

    // --- Custom Errors ---
    error InvalidAddress();
    error AmountMustBeGreaterThanZero();
    error ProfileAlreadyBlocked();
    error ProfileNotBlocked();
    error InsufficientBalance();
    error TransferFailed();
    error InvalidPenaltyType();

    // --- Events ---
    event PenaltyApplied(
        address indexed user,
        PenaltyType penaltyType,
        uint256 amount,
        bool profileBlocked
    );
    event ProfileUnblocked(address indexed user);
    event PenaltyPaid(address indexed user, uint256 amount);

    // --- Constructor ---
    /**
     * @dev Links PenaltySystem to HackToken, IncentivesPool and Treasury.
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
        _grantRole(ENFORCER_ROLE, msg.sender);
    }

    // --- Core penalty functions ---

    /**
     * @notice Apply identity fraud penalty (mechanism 7).
     * @dev Penalizes 10% of user's token balance.
     * Tokens go to IncentivesPool.
     * Profile is flagged for deletion (handled off-chain).
     * @param user_ Address of the offending user.
     */
    function applyIdentityFraudPenalty(address user_)
        external
        onlyRole(ENFORCER_ROLE)
        nonReentrant
    {
        if (user_ == address(0)) revert InvalidAddress();

        uint256 balance = hackToken.balanceOf(user_);
        uint256 penalty = balance * IDENTITY_FRAUD_PENALTY_PERCENT / 100;
        if (penalty == 0) revert AmountMustBeGreaterThanZero();

        _applyPenalty(user_, penalty, PenaltyType.IdentityFraud, false, true);
    }

    /**
     * @notice Apply mass token sale penalty (mechanism 9).
     * @dev Penalizes 5% of the sale amount.
     * Only applies if user holds 1%+ of circulating supply
     * and sells more than 50% of their holdings.
     * Tokens go to IncentivesPool.
     * @param user_ Address of the offending user.
     * @param saleAmount_ Amount of tokens sold.
     * @param circulatingSupply_ Current circulating supply (provided by enforcer).
     */
    function applyMassSalePenalty(
        address user_,
        uint256 saleAmount_,
        uint256 circulatingSupply_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (user_ == address(0)) revert InvalidAddress();
        if (saleAmount_ == 0) revert AmountMustBeGreaterThanZero();

        uint256 balance = hackToken.balanceOf(user_);

        // Check user holds 1%+ of circulating supply
        require(
            balance * 100 >= circulatingSupply_ * MASS_SALE_SUPPLY_THRESHOLD,
            "User does not hold 1% of supply"
        );

        // Check sale is more than 50% of their holdings
        require(
            saleAmount_ * 100 >= balance * MASS_SALE_THRESHOLD_PERCENT,
            "Sale does not exceed 50% of holdings"
        );

        uint256 penalty = saleAmount_ * MASS_SALE_PENALTY_PERCENT / 100;
        if (penalty == 0) revert AmountMustBeGreaterThanZero();

        _applyPenalty(user_, penalty, PenaltyType.MassSale, false, true);
    }

    /**
     * @notice Apply no-show interview penalty (mechanism 14).
     * @dev Penalizes 5% of user's token balance.
     * Tokens go to IncentivesPool.
     * Impacts user reputation (handled off-chain).
     * @param user_ Address of the user who did not show up.
     */
    function applyNoShowPenalty(address user_)
        external
        onlyRole(ENFORCER_ROLE)
        nonReentrant
    {
        if (user_ == address(0)) revert InvalidAddress();

        uint256 balance = hackToken.balanceOf(user_);
        uint256 penalty = balance * NO_SHOW_PENALTY_PERCENT / 100;
        if (penalty == 0) revert AmountMustBeGreaterThanZero();

        _applyPenalty(user_, penalty, PenaltyType.NoShowInterview, false, true);
    }

    /**
     * @notice Apply educator inactivity penalty (mechanism 25).
     * @dev Penalizes 5% of educator's token balance.
     * Profile is blocked until penalty is paid.
     * Tokens go to IncentivesPool.
     * @param educator_ Address of the inactive educator.
     */
    function applyEducatorInactivityPenalty(address educator_)
        external
        onlyRole(ENFORCER_ROLE)
        nonReentrant
    {
        if (educator_ == address(0)) revert InvalidAddress();

        uint256 balance = hackToken.balanceOf(educator_);
        uint256 penalty = balance * EDUCATOR_INACTIVITY_PENALTY_PERCENT / 100;
        if (penalty == 0) revert AmountMustBeGreaterThanZero();

        _applyPenalty(educator_, penalty, PenaltyType.EducatorInactivity, true, true);
    }

    /**
     * @notice Apply plagiarism penalty (mechanism 26).
     * @dev Penalizes 10% of educator's token balance.
     * Profile is blocked until penalty is paid.
     * If external complaint: tokens go to Treasury first, then to affected party.
     * If internal (educator vs educator): tokens go directly to affected educator.
     * @param offender_ Address of the educator who plagiarized.
     * @param affected_ Address of the affected party (educator or treasury).
     * @param isExternal_ True if complaint comes from outside the platform.
     */
    function applyPlagiarismPenalty(
        address offender_,
        address affected_,
        bool isExternal_
    ) external onlyRole(ENFORCER_ROLE) nonReentrant {
        if (offender_ == address(0)) revert InvalidAddress();
        if (affected_ == address(0)) revert InvalidAddress();

        uint256 balance = hackToken.balanceOf(offender_);
        uint256 penalty = balance * PLAGIARISM_PENALTY_PERCENT / 100;
        if (penalty == 0) revert AmountMustBeGreaterThanZero();

        // Transfer penalty from offender
        bool success = hackToken.transferFrom(offender_, address(this), penalty);
        if (!success) revert TransferFailed();

        if (isExternal_) {
            // External: goes to Treasury first, then treasury sends to affected party
            hackToken.transfer(treasury, penalty);
        } else {
            // Internal: goes directly to affected educator
            hackToken.transfer(affected_, penalty);
        }

        // Block profile
        profileBlocked[offender_] = true;

        // Record penalty
        penaltyHistory[offender_].push(PenaltyRecord({
            penaltyType: PenaltyType.Plagiarism,
            amount: penalty,
            timestamp: block.timestamp,
            profileBlocked: true
        }));

        totalPenalized[offender_] += penalty;

        emit PenaltyApplied(offender_, PenaltyType.Plagiarism, penalty, true);
    }

    /**
     * @notice Apply recruiter inactivity penalty (mechanism 30).
     * @dev Penalizes 5% of recruiter's token balance.
     * Profile is blocked until penalty is paid.
     * Tokens go to IncentivesPool.
     * @param recruiter_ Address of the inactive recruiter.
     */
    function applyRecruiterInactivityPenalty(address recruiter_)
        external
        onlyRole(ENFORCER_ROLE)
        nonReentrant
    {
        if (recruiter_ == address(0)) revert InvalidAddress();

        uint256 balance = hackToken.balanceOf(recruiter_);
        uint256 penalty = balance * RECRUITER_INACTIVITY_PENALTY_PERCENT / 100;
        if (penalty == 0) revert AmountMustBeGreaterThanZero();

        _applyPenalty(recruiter_, penalty, PenaltyType.RecruiterInactivity, true, true);
    }

    // --- Profile management ---

    /**
     * @notice Unblock a user's profile after they have paid their penalty.
     * @dev Only callable by ENFORCER_ROLE after confirming payment off-chain.
     * @param user_ Address of the user to unblock.
     */
    function unblockProfile(address user_) external onlyRole(ENFORCER_ROLE) {
        if (!profileBlocked[user_]) revert ProfileNotBlocked();
        profileBlocked[user_] = false;
        emit ProfileUnblocked(user_);
    }

    // --- Views ---

    /**
     * @notice Returns whether a user's profile is blocked.
     */
    function isProfileBlocked(address user_) external view returns (bool) {
        return profileBlocked[user_];
    }

    /**
     * @notice Returns the full penalty history of a user.
     */
    function getPenaltyHistory(address user_)
        external
        view
        returns (PenaltyRecord[] memory)
    {
        return penaltyHistory[user_];
    }

    /**
     * @notice Returns total tokens penalized for a user.
     */
    function getTotalPenalized(address user_) external view returns (uint256) {
        return totalPenalized[user_];
    }

    // --- Internal ---

    /**
     * @dev Core penalty logic reused across mechanisms.
     * Transfers penalty from user, sends to IncentivesPool,
     * optionally blocks profile, and records the penalty.
     * @param user_ User being penalized.
     * @param amount_ Penalty amount in tokens.
     * @param penaltyType_ Type of penalty applied.
     * @param blockProfile_ Whether to block the user's profile.
     * @param toPool_ Whether tokens go to IncentivesPool (true) or treasury (false).
     */
    function _applyPenalty(
        address user_,
        uint256 amount_,
        PenaltyType penaltyType_,
        bool blockProfile_,
        bool toPool_
    ) internal {
        // Transfer tokens from user to this contract
        bool success = hackToken.transferFrom(user_, address(this), amount_);
        if (!success) revert TransferFailed();

        if (toPool_) {
            // Send to IncentivesPool and notify
            hackToken.transfer(incentivesPool, amount_);
            IIncentivesPool(incentivesPool).deposit(
                amount_,
                "penalty"
            );
        } else {
            hackToken.transfer(treasury, amount_);
        }

        // Block profile if required
        if (blockProfile_) {
            profileBlocked[user_] = true;
        }

        // Record penalty
        penaltyHistory[user_].push(PenaltyRecord({
            penaltyType: penaltyType_,
            amount: amount_,
            timestamp: block.timestamp,
            profileBlocked: blockProfile_
        }));

        totalPenalized[user_] += amount_;

        emit PenaltyApplied(user_, penaltyType_, amount_, blockProfile_);
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
}

// --- Interfaces ---
interface IIncentivesPool {
    function deposit(uint256 amount_, string calldata reason_) external;
}
