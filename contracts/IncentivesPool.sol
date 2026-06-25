// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IncentivesPool
 * @dev Central pool that holds and distributes reward tokens to all incentive contracts.
 * Receives tokens from the owner and from penalty/fee sinks.
 * Only authorized contracts can request token distributions.
 */
contract IncentivesPool is AccessControl {

    // --- Roles ---
    // DISTRIBUTOR_ROLE: assigned to StakingContract, ReferralSystem, etc.
    // They can request tokens from the pool to reward users.
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    // DEPOSITOR_ROLE: assigned to PenaltySystem, MembershipSystem, CommissionSystem, etc.
    // They can send tokens back to the pool (sinks).
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    // --- State ---
    // Reference to the HACK token contract
    IERC20 public immutable hackToken;

    // Total tokens available in the pool
    uint256 public poolBalance;

    // Total tokens distributed since deployment
    uint256 public totalDistributed;

    // Total tokens received from sinks since deployment
    uint256 public totalReceived;

    // --- Custom Errors ---
    error InvalidAddress();
    error AmountMustBeGreaterThanZero();
    error InsufficientPoolBalance();
    error TransferFailed();

    // --- Events ---

    /// @dev Emitted when tokens are distributed to an incentive contract.
    event TokensDistributed(address indexed to, uint256 amount, string reason);

    /// @dev Emitted when tokens are deposited into the pool (from sinks).
    event TokensDeposited(address indexed from, uint256 amount, string reason);

    /// @dev Emitted when the owner funds the pool initially or adds more tokens.
    event PoolFunded(address indexed from, uint256 amount);

    // --- Constructor ---
    /**
     * @dev Deploys IncentivesPool and links it to the HACK token.
     * The deployer receives DEFAULT_ADMIN_ROLE to manage all other roles.
     * @param hackToken_ Address of the deployed HackToken contract.
     */
    constructor(address hackToken_) {
        if (hackToken_ == address(0)) revert InvalidAddress();
        hackToken = IERC20(hackToken_);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // --- Funding ---

    /**
     * @notice Fund the pool with HACK tokens.
     * @dev The sender must have approved this contract to spend their tokens first.
     * Called by the owner after minting the incentives allocation.
     * Flow: owner mints tokens → approves IncentivesPool → calls fundPool()
     * @param amount_ Amount of HACK tokens to deposit into the pool.
     */
    function fundPool(uint256 amount_) external {
        if (amount_ == 0) revert AmountMustBeGreaterThanZero();

        bool success = hackToken.transferFrom(msg.sender, address(this), amount_);
        if (!success) revert TransferFailed();

        poolBalance += amount_;
        emit PoolFunded(msg.sender, amount_);
    }

    // --- Distribution ---

    /**
     * @notice Distribute tokens from the pool to a recipient.
     * @dev Only callable by contracts with DISTRIBUTOR_ROLE (StakingContract, etc.)
     * @param to_ Address to receive the tokens (usually the end user).
     * @param amount_ Amount of HACK tokens to distribute.
     * @param reason_ Human-readable reason for the distribution (e.g. "staking_reward").
     */
    function distribute(
        address to_,
        uint256 amount_,
        string calldata reason_
    ) external onlyRole(DISTRIBUTOR_ROLE) {
        if (to_ == address(0)) revert InvalidAddress();
        if (amount_ == 0) revert AmountMustBeGreaterThanZero();
        if (poolBalance < amount_) revert InsufficientPoolBalance();

        poolBalance -= amount_;
        totalDistributed += amount_;

        bool success = hackToken.transfer(to_, amount_);
        if (!success) revert TransferFailed();

        emit TokensDistributed(to_, amount_, reason_);
    }

    // --- Deposits from sinks ---

    /**
     * @notice Receive tokens back into the pool from penalty/fee sinks.
     * @dev Only callable by contracts with DEPOSITOR_ROLE (PenaltySystem, etc.)
     * The depositing contract must have transferred the tokens to this contract first.
     * @param amount_ Amount of HACK tokens being deposited.
     * @param reason_ Human-readable reason (e.g. "identity_penalty", "membership_fee").
     */
    function deposit(
        uint256 amount_,
        string calldata reason_
    ) external onlyRole(DEPOSITOR_ROLE) {
        if (amount_ == 0) revert AmountMustBeGreaterThanZero();

        poolBalance += amount_;
        totalReceived += amount_;

        emit TokensDeposited(msg.sender, amount_, reason_);
    }

    // --- Views ---

    /**
     * @notice Returns the current token balance held by this contract.
     * @dev Should match poolBalance. Can be used to verify accounting integrity.
     */
    function actualBalance() external view returns (uint256) {
        return hackToken.balanceOf(address(this));
    }
}
