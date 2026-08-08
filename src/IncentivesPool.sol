// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IncentivesPool
 * @dev Central pool that holds and distributes reward tokens to all incentive contracts.
 *
 * M-01 fix: deposit() ya no incrementa la contabilidad a ciegas. Tras
 * registrar el depósito, comprueba que el balance real de HACK del
 * contrato cubre lo que la contabilidad dice tener. Si un DEPOSITOR_ROLE
 * llama a deposit() sin haber transferido los tokens antes, la llamada
 * revierte en vez de inflar poolBalance.
 */
contract IncentivesPool is AccessControl {

    // --- Roles ---
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    // --- State ---
    IERC20 public immutable hackToken;
    uint256 public poolBalance;
    uint256 public totalDistributed;
    uint256 public totalReceived;

    // --- Custom Errors ---
    error InvalidAddress();
    error AmountMustBeGreaterThanZero();
    error InsufficientPoolBalance();
    error TransferFailed();
    error AccountingMismatch();

    // --- Events ---
    event TokensDistributed(address indexed to, uint256 amount, string reason);
    event TokensDeposited(address indexed from, uint256 amount, string reason);
    event PoolFunded(address indexed from, uint256 amount);

    // --- Constructor ---
    constructor(address hackToken_) {
        if (hackToken_ == address(0)) revert InvalidAddress();
        hackToken = IERC20(hackToken_);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // --- Funding ---

    function fundPool(uint256 amount_) external {
        if (amount_ == 0) revert AmountMustBeGreaterThanZero();

        bool success = hackToken.transferFrom(msg.sender, address(this), amount_);
        if (!success) revert TransferFailed();

        poolBalance += amount_;
        emit PoolFunded(msg.sender, amount_);
    }

    // --- Distribution ---

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
     * @dev El contrato que deposita debe haber transferido los tokens a
     * este contrato ANTES de llamar a esta función. Se verifica que el
     * balance real cubra la contabilidad tras el incremento (M-01 fix).
     */
    function deposit(
        uint256 amount_,
        string calldata reason_
    ) external onlyRole(DEPOSITOR_ROLE) {
        if (amount_ == 0) revert AmountMustBeGreaterThanZero();

        poolBalance += amount_;
        totalReceived += amount_;

        if (hackToken.balanceOf(address(this)) < poolBalance) revert AccountingMismatch();

        emit TokensDeposited(msg.sender, amount_, reason_);
    }

    // --- Views ---

    function actualBalance() external view returns (uint256) {
        return hackToken.balanceOf(address(this));
    }
}
