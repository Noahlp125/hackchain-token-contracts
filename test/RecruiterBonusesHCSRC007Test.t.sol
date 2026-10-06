// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { RecruiterBonuses } from "../src/RecruiterBonuses.sol";
import { IncentivesPool } from "../src/IncentivesPool.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

/// @dev Regresiones de HC-SRC-007: registerHiring() y
/// claimMonthlyHiringBonus() exigen que el recruiter este registrado.
contract RecruiterBonusesHCSRC007Test is Test {
    RecruiterBonuses bonuses;
    IncentivesPool pool;
    HackToken token;
    RoleRegistry registry;

    address RECRUITER = makeAddr("recruiter");

    function setUp() public {
        token = new HackToken(address(this));
        pool = new IncentivesPool(address(token));
        registry = new RoleRegistry();
        bonuses = new RecruiterBonuses(address(pool), address(registry));
        pool.grantRole(pool.DISTRIBUTOR_ROLE(), address(bonuses));
        // Recruiter en RoleRegistry desde el inicio: estos tests aislan la
        // falta de isRegistered, no la del rol global (ver HCSRC004).
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));
        registry.registerRole(RECRUITER, RoleRegistry.BusinessRole.Recruiter);

        token.mintTokens(address(this), 100_000 ether);
        token.approve(address(pool), 100_000 ether);
        pool.fundPool(100_000 ether);

        vm.warp(1_700_000_000); // timestamp realista, evita edge case de mes 0
    }

    function test_HCSRC007_UnregisteredRecruiterCannotHaveHiringRegistered() public {
        vm.expectRevert(RecruiterBonuses.NotRegistered.selector);
        bonuses.registerHiring(RECRUITER, keccak256("talent-1"));
    }

    /// @dev Sin registro no se puede llegar a 4 contrataciones, asi que la
    /// comprobacion del claim es defensa en profundidad: debe revertir por
    /// falta de registro antes de mirar el contador.
    function test_HCSRC007_UnregisteredRecruiterCannotClaimMonthlyHiringBonus() public {
        vm.prank(RECRUITER);
        vm.expectRevert(RecruiterBonuses.NotRegistered.selector);
        bonuses.claimMonthlyHiringBonus();
    }

    function test_HCSRC007_RegisteredRecruiterCanStillClaimAfterFourHirings() public {
        bonuses.registerRecruiter(RECRUITER);
        for (uint256 i = 0; i < 4; i++) {
            bonuses.registerHiring(RECRUITER, keccak256(abi.encode("talent", i)));
        }

        vm.prank(RECRUITER);
        bonuses.claimMonthlyHiringBonus();

        assertEq(token.balanceOf(RECRUITER), bonuses.MONTHLY_HIRING_BONUS());
    }
}
