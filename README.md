# Hackchain HACK Token- Smart Contracts
Modular implementation of the 30 tokenomics mechanims for the $HACK token.

## Architecture
Token logic is split into 11 independent contracts for security, auditability and scalability- instead of one monolithic contract.

| Contract | Mechanisms covered |
|---|---|
| HackTokenERC20.sol | Base ERC20 token (roles: MINTER,BURNER,PAUSER) |
| IncentivesPool.sol | Central treasury for all reward distributions |
| StakingContract.sol | 1,6 |
| ReferralSystem.sol | 2 |
| MembershipSystem.sol | 3,13 |
| PenaltySystem.sol | 7,9,14,25,26,30 |
| ReputationBonuses.sol | 15,16,17 |
| EventRewards.sol | 5,10,18,19 |
| EducatorBonuses.sol | 20,21,22,24 |
| RecruiterBonuses.sol | 27,28,29 |
| TalentBonuses.sol | 4,11,23 |
| ComissionSystem.sol | 8 |

## Access Control
All reward/penalty contracts use OpenZeppelin AccessControl. Roles are granted to contracts (not external wallets) where possible to minimize trust assumptions.

## Status 
All contracts compile under Solidity 0.8.24. Deployment and role configuration pending (see deployement checklist)
