// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    ERC20Burnable
} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {
    ERC20Pausable
} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

/**
 * @title HackToken
 * @dev ERC20 token with pausable transfers, role-gated minting and
 * holder-driven burning. Uses OpenZeppelin for security and standard
 * compliance.
 *
 * Burning follows the ERC20Burnable standard: a holder destroys their own
 * balance with burn(), and a third party can only burn on their behalf through
 * burnFrom(), after the holder has granted an allowance. There is no
 * administrative burn, penalties are settled by transfer in PenaltySystem,
 * and enforcement comes from profile blocking, not from confiscation.
 *
 * Administration has a single source of truth. There is no Ownable layer: this
 * contract inherits AccessControlDefaultAdminRules, under which owner() is a
 * view over defaultAdmin() as defined by ERC-5313, so ownership and
 * administrative control cannot diverge. DEFAULT_ADMIN_ROLE is held by exactly
 * one account, cannot be granted or revoked directly, and moves only through
 * beginDefaultAdminTransfer() followed, after ADMIN_TRANSFER_DELAY, by
 * acceptDefaultAdminTransfer() called by the incoming admin. The outgoing admin
 * can cancel at any point before acceptance.
 *
 * MINTER_ROLE and PAUSER_ROLE are ordinary roles and are not carried by that
 * transfer. They are granted to the initial admin at deployment as a bootstrap
 * step only: MINTER_ROLE is meant to end up held by the contracts that mint
 * (StakingContract, IncentivesPool, the presale contract) and the initial
 * admin's copy must be revoked once those exist. A handover of administration
 * is therefore not complete until the incoming admin has also reviewed who
 * holds these two roles.
 */
contract HackToken is
    ERC20,
    ERC20Burnable,
    ERC20Pausable,
    AccessControlDefaultAdminRules
{
    // --- Roles ---
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @dev Waiting period between scheduling a transfer of DEFAULT_ADMIN_ROLE
    /// and the incoming admin being able to accept it. It is the window in which
    /// a hostile transfer can be spotted and cancelled. Fixed in code rather than
    /// taken as a constructor argument so that no deployment can weaken it by
    /// mistake, it can still be changed later through changeDefaultAdminDelay(),
    /// which is itself subject to the extension's own scheduling rules.
    uint48 public constant ADMIN_TRANSFER_DELAY = 3 days;

    // --- Variables ---
    /// @notice Hard cap on the tokens this contract will ever mint.
    /// @dev This is a LIFETIME issuance cap, not a cap on circulating supply.
    /// Burning does not free headroom: destroyed tokens are gone and are never
    /// reissued.
    ///
    /// The project's tokenomics allocate the whole 1,000,000,000 across closed
    /// buckets, team, private sale, public presale, public sale, incentives,
    /// treasury and airdrops, summing to 100%. A token minted to replace a
    /// burned one would belong to no bucket, and those percentages would stop
    /// describing anything.
    ///
    /// Reaching the cap is the intended end state, not a failure: minting stops,
    /// and rewards keep being paid out of the pre-allocated incentives bucket,
    /// which recycles existing tokens through IncentivesPool rather than
    /// creating new ones.
    uint256 public immutable maxSupply;

    /// @notice Total HACK minted since deployment. Only ever increases.
    /// @dev Deliberately never decremented by burns — see {maxSupply}.
    /// Integrators after circulating supply want totalSupply(), not this.
    uint256 public mintedTokens;

    // --- Custom Errors ---
    error AmountMustBeGreaterThanZero();
    error InvalidAddress();
    error MaxSupplyExceeded();

    // --- Constructor ---
    /**
     * @dev Deploys the HackToken contract.
     * @param initialAdmin_ Account that receives DEFAULT_ADMIN_ROLE, MINTER_ROLE
     * and PAUSER_ROLE. Intended to be the project multisig, never the deploying
     * key: the deployer holds nothing once this constructor returns. A zero
     * address is rejected by AccessControlDefaultAdminRules.
     */
    constructor(
        address initialAdmin_
    )
        ERC20("Hack Chain Token", "HACK")
        AccessControlDefaultAdminRules(ADMIN_TRANSFER_DELAY, initialAdmin_)
    {
        maxSupply = 1000000000 * (10 ** decimals());

        _grantRole(MINTER_ROLE, initialAdmin_);
        _grantRole(PAUSER_ROLE, initialAdmin_);
    }

    // --- Events ---
    event TokenMinted(address indexed to, uint256 amount);

    // --- External functions ---

    /**
     * @notice Mints new tokens to a specified address.
     * @dev Gated by MINTER_ROLE. The cap is checked against mintedTokens, the
     * lifetime issuance counter, and not against totalSupply(): burning does not
     * give minting headroom back. See {maxSupply} for the reasoning.
     *
     * Minting is blocked while the contract is paused. The modifier is not
     * repeated here on purpose: _update() already enforces it through
     * ERC20Pausable, and declaring it again would duplicate that check on every
     * mint for no gain.
     */
    function mintTokens(
        address to_,
        uint256 amount_
    ) public onlyRole(MINTER_ROLE) {
        if (to_ == address(0)) revert InvalidAddress();
        if (amount_ == 0) revert AmountMustBeGreaterThanZero();
        if (mintedTokens + amount_ > maxSupply) revert MaxSupplyExceeded();

        mintedTokens += amount_;
        _mint(to_, amount_);
        emit TokenMinted(to_, amount_);
    }

    /**
     * @notice Tokens that may still be minted before the lifetime cap is reached.
     * @dev maxSupply, mintedTokens. Unaffected by burns, by design: this is
     * headroom for issuance, not the gap to a circulating-supply ceiling.
     */
    function remainingMintable() public view returns (uint256) {
        return maxSupply - mintedTokens;
    }

    /**
     * @notice Pauses all token transfers, including minting and burning.
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses token transfers.
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // --- Internal ---

    /**
     * @dev Disambiguation between ERC20 and ERC20Pausable. No logic of its own:
     * the pause check comes from ERC20Pausable's whenNotPaused, and every
     * transfer, mint and burn funnels through here.
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Pausable) {
        super._update(from, to, amount);
    }
}
