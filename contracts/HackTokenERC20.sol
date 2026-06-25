// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title HackToken
 * @dev ERC20 token with pausable transfers, role-based minting and burning,
 * and ownership transfer. Uses OpenZeppelin for security and standard compliance.
 */
contract HackToken is ERC20, Pausable, Ownable, AccessControl {

    // --- Roles ---
    // CHANGE 3: Define roles as bytes32 constants
    // keccak256 is the standard way to create a unique identifier for each role
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // --- Variables ---
    uint256 public maxSupply = 1000000000 * (10 ** decimals());
    uint256 public mintedTokens;

    // --- Custom Errors ---
    error AmountMustBeGreaterThanZero();
    error InvalidAddress();
    error MaxSupplyExceeded();
    error InsufficientBalance();

    // --- Constructor ---
    /**
     * @dev Deploys the HackToken contract.
     * CHANGE 4: The deployer receives all roles automatically.
     * Roles can later be assigned to other contracts using grantRole().
     */
    constructor() ERC20("Hack Chain Token", "HACK") Ownable(msg.sender) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); // can assign and revoke roles
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    // --- Events ---
    event TransferNewOwner(address indexed previousOwner, address indexed newOwner);
    event TokenMinted(address to, uint256 amount);
    event TokenBurned(address indexed from, uint256 amount);

    // --- External functions ---

    /**
     * @notice Mints new tokens to a specified address.
     * CHANGE 5: onlyOwner → onlyRole(MINTER_ROLE)
     * StakingContract and IncentivesPool will be able to mint rewards
     * once the owner grants them MINTER_ROLE.
     */
    function mintTokens(address to_, uint256 amount_) public onlyRole(MINTER_ROLE) {
        if (to_ == address(0)) revert InvalidAddress();
        if (amount_ == 0) revert AmountMustBeGreaterThanZero();
        if (mintedTokens + amount_ > maxSupply) revert MaxSupplyExceeded();

        mintedTokens += amount_;
        _mint(to_, amount_);
        emit TokenMinted(to_, amount_);
    }

    /**
     * @notice Burns tokens from a specified address.
     * CHANGE 6: onlyOwner → onlyRole(BURNER_ROLE)
     * PenaltySystem will be able to burn tokens from penalized users.
     * CHANGE 7: Added `from_` parameter to burn tokens from any address
     * (required for penalties — PenaltySystem burns tokens from the offending user)
     */
    function burn(address from_, uint256 amount_) public onlyRole(BURNER_ROLE) whenNotPaused {
        if (amount_ == 0) revert AmountMustBeGreaterThanZero();
        if (balanceOf(from_) < amount_) revert InsufficientBalance();
        _burn(from_, amount_);
        emit TokenBurned(from_, amount_);
    }

    /**
     * @notice Transfers ownership to a new address.
     * No changes here — still restricted to owner only.
     */
    function transferOwnershipCustom(address newOwner_) public onlyOwner {
        require(newOwner_ != address(0), "New owner cannot be zero address");
        require(newOwner_ != owner(), "New owner must be different from current owner");
        emit TransferNewOwner(owner(), newOwner_);
        transferOwnership(newOwner_);
    }

    /**
     * @notice Pauses all token transfers.
     * CHANGE 8: onlyOwner → onlyRole(PAUSER_ROLE)
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses token transfers.
     * CHANGE 8: onlyOwner → onlyRole(PAUSER_ROLE)
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // --- Internal ---

    function _update(address from, address to, uint256 amount) internal override {
        require(!paused(), "Pausable: token transfer while paused");
        super._update(from, to, amount);
    }

    /**
     * @dev Required because both Ownable and AccessControl define supportsInterface.
     * Without this override the compiler throws an ambiguity error.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

