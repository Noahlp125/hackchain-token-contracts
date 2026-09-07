// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ReferralSystem
 * @dev Handles the referral mechanism (mechanism 2).
 *
 * H-01 fix: validateReferral() ya no confía en el balance agregado actual
 * del referido. Ahora exige una posición de staking concreta
 * (stakeIndex_) que: (a) esté activa, (b) cumpla el monto mínimo,
 * (c) tenga duración de al menos un mes, (d) haya madurado realmente
 * (block.timestamp >= startTime + duration), y (e) haya empezado
 * DESPUÉS de que el referral fuera registrado — evitando que alguien
 * stakee primero y reclame un referido retroactivamente en el mismo
 * bloque.
 *
 * HC-SRC-002 fix: registerReferral() se bloquea por quien llama (el
 * referido). validateReferral() se bloquea por el REFERRER, no por quien
 * ejecuta la llamada, es el referrer quien cobra el incentivo, así que
 * es su estado el que importa, no el del referido que dispara la
 * transacción.
 */
contract ReferralSystem is AccessControl, ReentrancyGuard {
    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // --- Constants ---
    uint256 public constant REFERRAL_REWARD = 1_000 * 1e18;
    uint256 public constant MAX_REFERRALS_PER_MONTH = 5;
    uint256 public constant MIN_STAKE_FOR_REFERRAL = 1_000 * 1e18;
    uint256 public constant ONE_MONTH = 30 days;

    // --- Structs ---
    struct ReferralInfo {
        uint256 currentMonth;
        uint256 referralsThisMonth;
        uint256 totalReferrals;
        uint256 totalRewards;
    }

    // --- State ---
    address public incentivesPool;
    address public stakingContract;
    IRoleRegistry public roleRegistry;

    mapping(address => ReferralInfo) public referralInfo;
    mapping(address => address) public referredBy;
    mapping(address => bool) public referralValidated;

    /// @notice Timestamp en el que se registró el referral (0 si no existe).
    mapping(address => uint256) public referralRegisteredAt;

    // --- Custom Errors ---
    error InvalidAddress();
    error AlreadyReferred();
    error ReferralAlreadyValidated();
    error ReferredUserNotStaking();
    error MonthlyLimitReached();
    error CannotReferYourself();
    error NotReferred();
    error IneligibleStake();
    error StakeNotMature();
    error ReferralRegisteredTooLate();
    error ProfileBlocked();

    // --- Events ---
    event UserReferred(address indexed referrer, address indexed referred);
    event ReferralValidated(
        address indexed referrer,
        address indexed referred,
        uint256 reward
    );

    // --- Constructor ---
    constructor(
        address incentivesPool_,
        address stakingContract_,
        address roleRegistry_
    ) {
        if (incentivesPool_ == address(0)) revert InvalidAddress();
        if (stakingContract_ == address(0)) revert InvalidAddress();
        if (roleRegistry_ == address(0)) revert InvalidAddress();

        incentivesPool = incentivesPool_;
        stakingContract = stakingContract_;
        roleRegistry = IRoleRegistry(roleRegistry_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // --- Core functions ---

    /**
     * @notice Register who referred you to the platform.
     * @dev Debe llamarse ANTES de crear el stake que se usará para
     * validar el referral — validateReferral() lo exige.
     */
    function registerReferral(address referrer_) external {
        if (roleRegistry.isBlocked(msg.sender)) revert ProfileBlocked();
        if (referrer_ == address(0)) revert InvalidAddress();
        if (referrer_ == msg.sender) revert CannotReferYourself();
        if (referredBy[msg.sender] != address(0)) revert AlreadyReferred();

        referredBy[msg.sender] = referrer_;
        referralRegisteredAt[msg.sender] = block.timestamp;

        emit UserReferred(referrer_, msg.sender);
    }

    /**
     * @notice Validate and reward a referral usando una posición de
     * staking concreta y madura del referido.
     * @param stakeIndex_ Índice de la posición en userStakes[msg.sender]
     * dentro de StakingContract.
     */
    function validateReferral(uint256 stakeIndex_) external nonReentrant {
        address referred = msg.sender;
        address referrer = referredBy[referred];

        if (referrer == address(0)) revert NotReferred();
        if (referralValidated[referred]) revert ReferralAlreadyValidated();
        // Se comprueba el bloqueo del referrer, no el de quien llama: es
        // el referrer quien cobra el incentivo (HC-SRC-002).
        if (roleRegistry.isBlocked(referrer)) revert ProfileBlocked();

        (
            uint256 amount,
            uint256 startTime,
            uint256 duration,
            ,
            bool active
        ) = IStakingContract(stakingContract).userStakes(referred, stakeIndex_);

        if (!active || amount < MIN_STAKE_FOR_REFERRAL)
            revert IneligibleStake();
        if (duration < ONE_MONTH) revert IneligibleStake();
        if (referralRegisteredAt[referred] > startTime)
            revert ReferralRegisteredTooLate();
        if (block.timestamp < startTime + duration) revert StakeNotMature();

        ReferralInfo storage info = referralInfo[referrer];
        uint256 currentMonth = block.timestamp / 30 days;

        if (info.currentMonth != currentMonth) {
            info.currentMonth = currentMonth;
            info.referralsThisMonth = 0;
        }

        if (info.referralsThisMonth >= MAX_REFERRALS_PER_MONTH)
            revert MonthlyLimitReached();

        // Mark as validated before external call (CEI pattern)
        referralValidated[referred] = true;
        info.referralsThisMonth += 1;
        info.totalReferrals += 1;
        info.totalRewards += REFERRAL_REWARD;

        IIncentivesPool(incentivesPool).distribute(
            referrer,
            REFERRAL_REWARD,
            "referral_reward"
        );

        emit ReferralValidated(referrer, referred, REFERRAL_REWARD);
    }

    // --- Views ---

    function getReferralInfo(
        address user_
    ) external view returns (ReferralInfo memory) {
        return referralInfo[user_];
    }

    function getReferrer(address user_) external view returns (address) {
        return referredBy[user_];
    }

    function isValidated(address referred_) external view returns (bool) {
        return referralValidated[referred_];
    }

    function getReferralsLeft(address user_) external view returns (uint256) {
        ReferralInfo memory info = referralInfo[user_];
        uint256 currentMonth = block.timestamp / 30 days;

        if (info.currentMonth != currentMonth) return MAX_REFERRALS_PER_MONTH;
        if (info.referralsThisMonth >= MAX_REFERRALS_PER_MONTH) return 0;
        return MAX_REFERRALS_PER_MONTH - info.referralsThisMonth;
    }

    // --- Admin ---

    function setIncentivesPool(address newPool_) external onlyRole(ADMIN_ROLE) {
        if (newPool_ == address(0)) revert InvalidAddress();
        incentivesPool = newPool_;
    }

    function setStakingContract(
        address newStaking_
    ) external onlyRole(ADMIN_ROLE) {
        if (newStaking_ == address(0)) revert InvalidAddress();
        stakingContract = newStaking_;
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
    function isBlocked(address account_) external view returns (bool);
}

interface IStakingContract {
    /// @dev Coincide con el getter público auto-generado por el mapping
    /// userStakes en StakingContract.sol (struct Stake desempaquetada).
    function userStakes(
        address user_,
        uint256 index_
    )
        external
        view
        returns (
            uint256 amount,
            uint256 startTime,
            uint256 duration,
            uint256 reward,
            bool active
        );
}
