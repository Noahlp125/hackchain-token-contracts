// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title EducatorBonuses
 * @dev Handles educator-specific bonus mechanisms (20, 21, 22, 24).
 * Mechanism 20: API integration bonus → 50,000 tokens (once ever).
 * Mechanism 21: First 10 legacy certificates tokenized via HarJoot → 10,000 tokens.
 * Mechanism 22: First 10 active Talents trained → 10,000 tokens.
 * Mechanism 24: A Talent trained by this educator gets hired → 5,000 tokens.
 * All bonuses verified off-chain by an enforcer before distribution.
 */
contract EducatorBonuses is AccessControl, ReentrancyGuard {

    // --- Roles ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    // ENFORCER_ROLE: verifies conditions off-chain and triggers rewards
    bytes32 public constant ENFORCER_ROLE = keccak256("ENFORCER_ROLE");

    // --- Constants ---

    // Mechanism 20: API integration
    uint256 public constant API_INTEGRATION_REWARD = 50_000 * 1e18;

    // Mechanism 21: Legacy certificates
    uint256 public constant LEGACY_CERTS_REWARD = 10_000 * 1e18;
    uint256 public constant LEGACY_CERTS_REQUIRED = 10;

    // Mechanism 22: First 10 talents
    uint256 public constant FIRST_TALENTS_REWARD = 10_000 * 1e18;
    uint256 public constant FIRST_TALENTS_REQUIRED = 10;

    // Mechanism 24: Talent hired
    uint256 public constant TALENT_HIRED_REWARD = 5_000 * 1e18;

    // --- State ---
    address public incentivesPool;

    // Mechanism 20: tracks if educator has received the API integration bonus
    mapping(address => bool) public apiIntegrationRewarded;

    // Mechanism 21: tracks legacy certificates tokenized per educator
    mapping(address => uint256) public legacyCertsCount;

    // Mechanism 21: tracks if educator has received the legacy certs bonus
    mapping(address => bool) public legacyCertsRewarded;

    // Mechanism 21: tracks which talents already have a legacy cert from this educator
    // educator => talent => bool
    mapping(address => mapping(address => bool)) public legacyCertIssuedTo;

    // Mechanism 22: tracks active talents per educator
    mapping(address => uint256) public activeTalentsCount;

    // Mechanism 22: tracks if educator has received the first talents bonus
    mapping(address => bool) public firstTalentsRewarded;

    // Mechanism 22: tracks which talents are active under this educator
    // educator => talent => bool
    mapping(address => mapping(address => bool)) public talentActiveUnder;

    // Mechanism 24: tracks total hiring bonuses received per educator
    mapping(address => uint256) public hiringBonusCount;

    // --- Custom Errors ---
    error InvalidAddress();
    error ApiIntegrationAlreadyRewarded();
    error LegacyCertsAlreadyRewarded();
    error LegacyCertAlreadyIssuedToTalent();
    error NotEnoughLegacyCerts();
    error FirstTalentsAlreadyRewarded();
    error TalentAlreadyActiveUnderEducator();
    error NotEnoughActiveTalents();

    // --- Events ---
    event ApiIntegrationRewarded(address indexed educator, uint256 amount);
    event LegacyCertRegistered(address indexed educator, address indexed talent, uint256 total);
    event LegacyCertsRewarded(address indexed educator, uint256 amount);
    event TalentRegisteredUnderEducator(address indexed educator, address indexed talent, uint256 total);
    event TalentBecameInactive(address indexed educator, address indexed talent);
    event FirstTalentsRewarded(address indexed educator, uint256 amount);
    event TalentHiredBonus(address indexed educator, address indexed talent, uint256 amount);

    // --- Constructor ---
    /**
     * @dev Links EducatorBonuses to IncentivesPool.
     * @param incentivesPool_ Address of the deployed IncentivesPool contract.
     */
    constructor(address incentivesPool_) {
        if (incentivesPool_ == address(0)) revert InvalidAddress();

        incentivesPool = incentivesPool_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(ENFORCER_ROLE, msg.sender);
    }

    // --- Mechanism 20: API integration ---

    /**
     * @notice Reward an educator for integrating the Hackchain API.
     * @dev Only callable by ENFORCER_ROLE after the integration has been
     * verified and approved by the Hackchain team.
     * Can only be triggered once per educator ever.
     * @param educator_ Address of the educator.
     */
    function rewardApiIntegration(address educator_)
        external
        onlyRole(ENFORCER_ROLE)
        nonReentrant
    {
        if (educator_ == address(0)) revert InvalidAddress();
        if (apiIntegrationRewarded[educator_]) revert ApiIntegrationAlreadyRewarded();

        // Mark before external call (CEI pattern)
        apiIntegrationRewarded[educator_] = true;

        IIncentivesPool(incentivesPool).distribute(
            educator_,
            API_INTEGRATION_REWARD,
            "api_integration_reward"
        );

        emit ApiIntegrationRewarded(educator_, API_INTEGRATION_REWARD);
    }

    // --- Mechanism 21: Legacy certificates ---

    /**
     * @notice Register a legacy certificate tokenized by an educator via HarJoot.
     * @dev Called by ENFORCER_ROLE each time a legacy PDF certificate is tokenized.
     * Each certificate must be for a different Talent.
     * Once 10 unique Talents have been certified, the educator can claim the bonus.
     * @param educator_ Address of the educator.
     * @param talent_ Address of the Talent receiving the legacy certificate.
     */
    function registerLegacyCert(address educator_, address talent_)
        external
        onlyRole(ENFORCER_ROLE)
    {
        if (educator_ == address(0)) revert InvalidAddress();
        if (talent_ == address(0)) revert InvalidAddress();
        if (legacyCertsRewarded[educator_]) revert LegacyCertsAlreadyRewarded();
        if (legacyCertIssuedTo[educator_][talent_]) revert LegacyCertAlreadyIssuedToTalent();

        legacyCertIssuedTo[educator_][talent_] = true;
        legacyCertsCount[educator_] += 1;

        emit LegacyCertRegistered(educator_, talent_, legacyCertsCount[educator_]);
    }

    /**
     * @notice Claim the legacy certificates bonus.
     * @dev Callable by the educator once 10 unique Talents have been certified.
     * Only claimable once ever.
     */
    function claimLegacyCertsBonus() external nonReentrant {
        if (legacyCertsRewarded[msg.sender]) revert LegacyCertsAlreadyRewarded();
        if (legacyCertsCount[msg.sender] < LEGACY_CERTS_REQUIRED)
            revert NotEnoughLegacyCerts();

        // Mark before external call (CEI pattern)
        legacyCertsRewarded[msg.sender] = true;

        IIncentivesPool(incentivesPool).distribute(
            msg.sender,
            LEGACY_CERTS_REWARD,
            "legacy_certs_reward"
        );

        emit LegacyCertsRewarded(msg.sender, LEGACY_CERTS_REWARD);
    }

    // --- Mechanism 22: First 10 active talents ---

    /**
     * @notice Register an active Talent under an educator.
     * @dev Called by ENFORCER_ROLE when a Talent obtains a certificate
     * from this educator and is active on the platform.
     * @param educator_ Address of the educator.
     * @param talent_ Address of the active Talent.
     */
    function registerActiveTalent(address educator_, address talent_)
        external
        onlyRole(ENFORCER_ROLE)
    {
        if (educator_ == address(0)) revert InvalidAddress();
        if (talent_ == address(0)) revert InvalidAddress();
        if (firstTalentsRewarded[educator_]) revert FirstTalentsAlreadyRewarded();
        if (talentActiveUnder[educator_][talent_]) revert TalentAlreadyActiveUnderEducator();

        talentActiveUnder[educator_][talent_] = true;
        activeTalentsCount[educator_] += 1;

        emit TalentRegisteredUnderEducator(educator_, talent_, activeTalentsCount[educator_]);
    }

    /**
     * @notice Mark a Talent as inactive under an educator.
     * @dev Called by ENFORCER_ROLE if a Talent becomes inactive before
     * the educator claims the bonus. Reduces the active count.
     * This prevents the educator from claiming if they no longer have 10 active Talents.
     * @param educator_ Address of the educator.
     * @param talent_ Address of the Talent who became inactive.
     */
    function markTalentInactive(address educator_, address talent_)
        external
        onlyRole(ENFORCER_ROLE)
    {
        if (educator_ == address(0)) revert InvalidAddress();
        if (talent_ == address(0)) revert InvalidAddress();
        if (!talentActiveUnder[educator_][talent_]) return;

        talentActiveUnder[educator_][talent_] = false;
        if (activeTalentsCount[educator_] > 0) {
            activeTalentsCount[educator_] -= 1;
        }

        emit TalentBecameInactive(educator_, talent_);
    }

    /**
     * @notice Claim the first 10 active Talents bonus.
     * @dev Callable by the educator once they have 10 active Talents.
     * If any Talent became inactive before claiming, the count drops
     * and the bonus is not accessible until 10 active Talents are reached again.
     * Only claimable once ever.
     */
    function claimFirstTalentsBonus() external nonReentrant {
        if (firstTalentsRewarded[msg.sender]) revert FirstTalentsAlreadyRewarded();
        if (activeTalentsCount[msg.sender] < FIRST_TALENTS_REQUIRED)
            revert NotEnoughActiveTalents();

        // Mark before external call (CEI pattern)
        firstTalentsRewarded[msg.sender] = true;

        IIncentivesPool(incentivesPool).distribute(
            msg.sender,
            FIRST_TALENTS_REWARD,
            "first_talents_reward"
        );

        emit FirstTalentsRewarded(msg.sender, FIRST_TALENTS_REWARD);
    }

    // --- Mechanism 24: Talent hired bonus ---

    /**
     * @notice Reward an educator when one of their Talents gets hired.
     * @dev Called by ENFORCER_ROLE after the platform statistically determines
     * which educator is most linked to the hired Talent.
     * Can be triggered multiple times (once per hiring event).
     * @param educator_ Address of the educator to reward.
     * @param talent_ Address of the Talent who was hired.
     */
    function rewardTalentHired(address educator_, address talent_)
        external
        onlyRole(ENFORCER_ROLE)
        nonReentrant
    {
        if (educator_ == address(0)) revert InvalidAddress();
        if (talent_ == address(0)) revert InvalidAddress();

        hiringBonusCount[educator_] += 1;

        IIncentivesPool(incentivesPool).distribute(
            educator_,
            TALENT_HIRED_REWARD,
            "talent_hired_bonus"
        );

        emit TalentHiredBonus(educator_, talent_, TALENT_HIRED_REWARD);
    }

    // --- Views ---

    /**
     * @notice Returns whether an educator has received the API integration bonus.
     */
    function hasApiIntegrationBonus(address educator_) external view returns (bool) {
        return apiIntegrationRewarded[educator_];
    }

    /**
     * @notice Returns the number of legacy certificates registered for an educator.
     */
    function getLegacyCertsCount(address educator_) external view returns (uint256) {
        return legacyCertsCount[educator_];
    }

    /**
     * @notice Returns the number of active Talents under an educator.
     */
    function getActiveTalentsCount(address educator_) external view returns (uint256) {
        return activeTalentsCount[educator_];
    }

    /**
     * @notice Returns total hiring bonuses received by an educator.
     */
    function getHiringBonusCount(address educator_) external view returns (uint256) {
        return hiringBonusCount[educator_];
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