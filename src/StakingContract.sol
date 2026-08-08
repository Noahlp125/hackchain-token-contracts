// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title StakingContract
 * @dev Handles token staking for 1 month and 1 year periods.
 * Also manages the no-commission benefit (mechanism 6).
 *
 * H-02 fix: unstake() ya no acopla la devolución del principal con el
 * cobro de la recompensa. El principal SIEMPRE se devuelve si el periodo
 * ha vencido, independientemente del estado de IncentivesPool. La
 * recompensa se acumula como deuda (pendingRewards) y se reclama aparte
 * con claimRewards(), que puede reintentarse cuando el pool tenga liquidez.
 */
contract StakingContract is AccessControl, ReentrancyGuard {

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // --- Staking periods ---
    uint256 public constant ONE_MONTH = 30 days;
    uint256 public constant ONE_YEAR = 365 days;

    // --- Staking requirements (mechanism 1) ---
    uint256 public constant MIN_STAKE_ONE_MONTH = 1_000 * 1e18;
    uint256 public constant MIN_STAKE_ONE_YEAR = 10_000 * 1e18;

    // --- Rewards (mechanism 1) ---
    uint256 public constant REWARD_ONE_MONTH = 50 * 1e18;
    uint256 public constant REWARD_ONE_YEAR = 1_000 * 1e18;

    // --- No-commission threshold (mechanism 6) ---
    uint256 public constant NO_COMMISSION_THRESHOLD = 100_000 * 1e18;

    // --- Structs ---
    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 duration;
        uint256 reward;
        bool active;
    }

    // --- State ---
    IERC20 public immutable hackToken;
    address public incentivesPool;

    mapping(address => Stake[]) public userStakes;
    mapping(address => uint256) public totalStakedByUser;
    mapping(address => bool) public noCommissionActive;

    /// @notice Recompensas acumuladas pendientes de reclamar por usuario.
    mapping(address => uint256) public pendingRewards;

    // --- Custom Errors ---
    error InvalidAddress();
    error AmountTooLow();
    error InvalidDuration();
    error StakeNotFound();
    error StakeAlreadyInactive();
    error StakingPeriodNotOver();
    error TransferFailed();
    error NoCommissionNotEligible();
    error NoCommissionAlreadyActive();
    error NoCommissionNotActive();
    error NoPendingRewards();

    // --- Events ---
    event Staked(address indexed user, uint256 amount, uint256 duration, uint256 stakeIndex);
    event PrincipalWithdrawn(address indexed user, uint256 amount, uint256 stakeIndex);
    event RewardAccrued(address indexed user, uint256 amount, uint256 stakeIndex);
    event RewardClaimed(address indexed user, uint256 amount);
    event NoCommissionActivated(address indexed user);
    event NoCommissionDeactivated(address indexed user);

    // --- Constructor ---
    constructor(address hackToken_, address incentivesPool_) {
        if (hackToken_ == address(0)) revert InvalidAddress();
        if (incentivesPool_ == address(0)) revert InvalidAddress();

        hackToken = IERC20(hackToken_);
        incentivesPool = incentivesPool_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // --- Staking ---

    function stake(uint256 amount_, uint256 duration_) external nonReentrant {
        if (duration_ != ONE_MONTH && duration_ != ONE_YEAR) revert InvalidDuration();

        if (duration_ == ONE_MONTH && amount_ < MIN_STAKE_ONE_MONTH) revert AmountTooLow();
        if (duration_ == ONE_YEAR && amount_ < MIN_STAKE_ONE_YEAR) revert AmountTooLow();

        uint256 reward = duration_ == ONE_MONTH ? REWARD_ONE_MONTH : REWARD_ONE_YEAR;

        bool success = hackToken.transferFrom(msg.sender, address(this), amount_);
        if (!success) revert TransferFailed();

        userStakes[msg.sender].push(Stake({
            amount: amount_,
            startTime: block.timestamp,
            duration: duration_,
            reward: reward,
            active: true
        }));

        totalStakedByUser[msg.sender] += amount_;

        uint256 stakeIndex = userStakes[msg.sender].length - 1;
        emit Staked(msg.sender, amount_, duration_, stakeIndex);
    }

    /**
     * @notice Retira el principal de una posición vencida. SIEMPRE
     * funciona si el periodo ha terminado, sin importar el estado de
     * IncentivesPool. La recompensa queda acumulada para reclamar aparte.
     * @param stakeIndex_ Index of the stake in the user's stakes array.
     */
    function withdrawPrincipal(uint256 stakeIndex_) external nonReentrant {
        if (stakeIndex_ >= userStakes[msg.sender].length) revert StakeNotFound();

        Stake storage userStake = userStakes[msg.sender][stakeIndex_];

        if (!userStake.active) revert StakeAlreadyInactive();

        if (block.timestamp < userStake.startTime + userStake.duration)
            revert StakingPeriodNotOver();

        // Effects antes de la interacción externa (CEI pattern)
        userStake.active = false;
        totalStakedByUser[msg.sender] -= userStake.amount;
        pendingRewards[msg.sender] += userStake.reward;

        // El principal SIEMPRE se devuelve — ya no depende de IncentivesPool
        bool success = hackToken.transfer(msg.sender, userStake.amount);
        if (!success) revert TransferFailed();

        // Si el no-commission estaba activo y ya no cualifica, desactivar
        if (noCommissionActive[msg.sender] &&
            totalStakedByUser[msg.sender] < NO_COMMISSION_THRESHOLD) {
            noCommissionActive[msg.sender] = false;
            emit NoCommissionDeactivated(msg.sender);
        }

        emit PrincipalWithdrawn(msg.sender, userStake.amount, stakeIndex_);
        emit RewardAccrued(msg.sender, userStake.reward, stakeIndex_);
    }

    /**
     * @notice Reclama las recompensas acumuladas de todas las posiciones
     * ya retiradas. Puede reintentarse si IncentivesPool no tiene liquidez
     * en el momento del intento — la deuda permanece registrada.
     */
    function claimRewards() external nonReentrant {
        uint256 amount = pendingRewards[msg.sender];
        if (amount == 0) revert NoPendingRewards();

        pendingRewards[msg.sender] = 0;

        IIncentivesPool(incentivesPool).distribute(msg.sender, amount, "staking_reward");

        emit RewardClaimed(msg.sender, amount);
    }

    // --- Mechanism 6: No-commission benefit ---

    function activateNoCommission() external {
        if (noCommissionActive[msg.sender]) revert NoCommissionAlreadyActive();
        if (!_isEligibleForNoCommission(msg.sender)) revert NoCommissionNotEligible();

        noCommissionActive[msg.sender] = true;
        emit NoCommissionActivated(msg.sender);
    }

    function deactivateNoCommission() external {
        if (!noCommissionActive[msg.sender]) revert NoCommissionNotActive();
        noCommissionActive[msg.sender] = false;
        emit NoCommissionDeactivated(msg.sender);
    }

    // --- Views ---

    function getUserStakes(address user_) external view returns (Stake[] memory) {
        return userStakes[user_];
    }

    function hasNoCommission(address user_) external view returns (bool) {
        return noCommissionActive[user_];
    }

    function getTotalStaked(address user_) external view returns (uint256) {
        return totalStakedByUser[user_];
    }

    // --- Internal ---

    function _isEligibleForNoCommission(address user_) internal view returns (bool) {
        Stake[] memory stakes = userStakes[user_];
        for (uint256 i = 0; i < stakes.length; i++) {
            if (
                stakes[i].active &&
                stakes[i].amount >= NO_COMMISSION_THRESHOLD &&
                stakes[i].duration == ONE_YEAR
            ) {
                return true;
            }
        }
        return false;
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
