// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { MembershipSystem } from "../src/MembershipSystem.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

contract MockIncentivesPool {
    function deposit(uint256, string calldata) external {}
}

/// @dev Regresiones de HC-SRC-001: la recompensa academica se contabiliza por
/// ciclo. Cada ciclo congela su pool y sus vistas al cerrarse, y solo se
/// reclama contra ciclos cerrados.
contract MembershipSystemHCSRC001Test is Test {
    MembershipSystem memberships;
    HackToken token;
    MockIncentivesPool pool;
    RoleRegistry registry;

    address TREASURY = makeAddr("treasury");
    address EDUCATOR_A = makeAddr("educatorA");
    address EDUCATOR_B = makeAddr("educatorB");

    uint256 EDUCATOR_SHARE;

    function setUp() public {
        token = new HackToken(address(this));
        pool = new MockIncentivesPool();
        registry = new RoleRegistry();
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));
        registry.registerRole(EDUCATOR_A, RoleRegistry.BusinessRole.Educator);
        registry.registerRole(EDUCATOR_B, RoleRegistry.BusinessRole.Educator);

        memberships = new MembershipSystem(address(token), address(pool), TREASURY, address(registry));
        EDUCATOR_SHARE = (memberships.ACADEMIC_MONTHLY_COST() * memberships.POOL_SHARE()) / 100;
    }

    /// @dev Crea un espectador, le activa una membresia mensual y registra una
    /// vista por cada educador indicado. Cada membresia aporta EDUCATOR_SHARE
    /// al ciclo abierto.
    function _viewer(string memory name_, address[] memory educators_) internal returns (address viewer) {
        viewer = makeAddr(name_);
        uint256 cost = memberships.ACADEMIC_MONTHLY_COST();
        token.mintTokens(viewer, cost);

        vm.startPrank(viewer);
        token.approve(address(memberships), cost);
        memberships.activateAcademicMembership(MembershipSystem.AcademicTier.Monthly);
        for (uint256 i = 0; i < educators_.length; i++) {
            memberships.registerContentView(educators_[i]);
        }
        vm.stopPrank();
    }

    function _one(address educator_) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = educator_;
    }

    function _none() internal pure returns (address[] memory list) {
        list = new address[](0);
    }

    function _cycle(uint256 cycleId_) internal view returns (uint256 cyclePool, uint256 totalViews, uint256 claimed) {
        (cyclePool, totalViews, claimed, , ) = memberships.cycles(cycleId_);
    }

    function test_HCSRC001_AdvanceCycleStartsWithZeroLiveViews() public {
        _viewer("viewer1", _one(EDUCATOR_A));

        memberships.advanceCycle();

        (uint256 closedPool, uint256 closedViews, ) = _cycle(0);
        (uint256 openPool, uint256 openViews, ) = _cycle(1);
        assertEq(closedViews, 1, "the closed cycle keeps its views");
        assertEq(closedPool, EDUCATOR_SHARE, "the closed cycle keeps its pool");
        assertEq(openViews, 0, "the new cycle starts with no views");
        assertEq(openPool, 0, "the new cycle starts with an empty pool");
        assertEq(memberships.educatorCycleViews(1, EDUCATOR_A), 0, "old views do not leak into the new cycle");
    }

    /// @dev El escenario del hallazgo: cuotas nuevas antes de que el educador
    /// del ciclo anterior reclame. Ya no inflan lo que cobra.
    function test_HCSRC001_ClosedCycleRewardsAreNotChangedByNewMembershipFees() public {
        _viewer("viewer1", _one(EDUCATOR_A));
        memberships.advanceCycle();

        _viewer("viewer2", _none());
        _viewer("viewer3", _one(EDUCATOR_B));

        vm.prank(EDUCATOR_A);
        memberships.claimEducatorRewards(0);

        assertEq(token.balanceOf(EDUCATOR_A), EDUCATOR_SHARE, "A gets exactly the closed cycle's pool");
        (uint256 openPool, , ) = _cycle(1);
        assertEq(openPool, 2 * EDUCATOR_SHARE, "the new fees stay in the open cycle");
    }

    function test_HCSRC001_EducatorClaimOrderDoesNotChangeCycleAllocation() public {
        _viewer("viewer1", _one(EDUCATOR_A));
        _viewer("viewer2", _one(EDUCATOR_A));
        _viewer("viewer3", _one(EDUCATOR_B));
        memberships.advanceCycle();

        // B reclama primero, y entre medias entran cuotas nuevas.
        vm.prank(EDUCATOR_B);
        memberships.claimEducatorRewards(0);
        _viewer("viewer4", _none());
        vm.prank(EDUCATOR_A);
        memberships.claimEducatorRewards(0);

        uint256 cyclePool = 3 * EDUCATOR_SHARE;
        assertEq(token.balanceOf(EDUCATOR_A), (cyclePool * 2) / 3, "A gets two thirds");
        assertEq(token.balanceOf(EDUCATOR_B), cyclePool / 3, "B gets one third");
    }

    function test_HCSRC001_CannotClaimTheOpenCycle() public {
        _viewer("viewer1", _one(EDUCATOR_A));

        vm.prank(EDUCATOR_A);
        vm.expectRevert(MembershipSystem.CycleNotClosed.selector);
        memberships.claimEducatorRewards(0);
    }

    function test_HCSRC001_CannotClaimTheSameCycleTwice() public {
        _viewer("viewer1", _one(EDUCATOR_A));
        memberships.advanceCycle();

        vm.startPrank(EDUCATOR_A);
        memberships.claimEducatorRewards(0);
        vm.expectRevert(MembershipSystem.RewardsAlreadyClaimed.selector);
        memberships.claimEducatorRewards(0);
        vm.stopPrank();
    }

    /// @dev Nadie podria reclamar el pool de un ciclo sin vistas, asi que pasa
    /// entero al siguiente al cerrarse.
    function test_HCSRC001_CycleWithoutViewsRollsItsPoolForward() public {
        _viewer("viewer1", _none());

        memberships.advanceCycle();

        (, , , , bool rolledOver) = memberships.cycles(0);
        (uint256 openPool, , ) = _cycle(1);
        assertTrue(rolledOver, "the empty cycle is rolled over");
        assertEq(openPool, EDUCATOR_SHARE, "its pool moves to the open cycle");
    }

    /// @dev La parte que nadie reclama (aqui, un educador revocado) vuelve al
    /// ciclo abierto pasado el plazo, y ese ciclo ya no se puede reclamar.
    function test_HCSRC001_UnclaimedShareRollsOverAfterTheWindow() public {
        _viewer("viewer1", _one(EDUCATOR_A));
        _viewer("viewer2", _one(EDUCATOR_B));
        memberships.advanceCycle();

        vm.prank(EDUCATOR_A);
        memberships.claimEducatorRewards(0);

        vm.warp(block.timestamp + memberships.UNCLAIMED_ROLLOVER_WINDOW());
        memberships.rollOverUnclaimed(0);

        (uint256 openPool, , ) = _cycle(1);
        assertEq(openPool, EDUCATOR_SHARE, "B's unclaimed share moves to the open cycle");

        vm.prank(EDUCATOR_B);
        vm.expectRevert(MembershipSystem.CycleRolledOver.selector);
        memberships.claimEducatorRewards(0);
    }

    function test_HCSRC001_CannotRollOverBeforeTheWindowOrAnOpenCycle() public {
        _viewer("viewer1", _one(EDUCATOR_A));

        vm.expectRevert(MembershipSystem.CycleNotClosed.selector);
        memberships.rollOverUnclaimed(0);

        memberships.advanceCycle();
        uint256 window = memberships.UNCLAIMED_ROLLOVER_WINDOW();
        vm.warp(block.timestamp + window - 1);

        vm.expectRevert(MembershipSystem.RolloverWindowStillOpen.selector);
        memberships.rollOverUnclaimed(0);
    }

    /// @dev Con cualquier reparto de vistas y cualquier orden de claims, cada
    /// educador cobra su proporcion exacta del ciclo y la suma nunca supera el
    /// pool. Las cuotas que entran entre claims no cambian nada.
    function testFuzz_HCSRC001_ClaimsAreProportionalAndOrderIndependent(
        uint8 viewsA_,
        uint8 viewsB_,
        bool aClaimsFirst_
    ) public {
        uint256 viewsA = bound(viewsA_, 1, 8);
        uint256 viewsB = bound(viewsB_, 1, 8);

        for (uint256 i = 0; i < viewsA; i++) {
            _viewer(string.concat("a", vm.toString(i)), _one(EDUCATOR_A));
        }
        for (uint256 i = 0; i < viewsB; i++) {
            _viewer(string.concat("b", vm.toString(i)), _one(EDUCATOR_B));
        }
        memberships.advanceCycle();

        address first = aClaimsFirst_ ? EDUCATOR_A : EDUCATOR_B;
        address second = aClaimsFirst_ ? EDUCATOR_B : EDUCATOR_A;
        vm.prank(first);
        memberships.claimEducatorRewards(0);
        _viewer("late", _none());
        vm.prank(second);
        memberships.claimEducatorRewards(0);

        uint256 cyclePool = (viewsA + viewsB) * EDUCATOR_SHARE;
        uint256 total = viewsA + viewsB;
        assertEq(token.balanceOf(EDUCATOR_A), (cyclePool * viewsA) / total, "A gets its exact share");
        assertEq(token.balanceOf(EDUCATOR_B), (cyclePool * viewsB) / total, "B gets its exact share");

        (, , uint256 claimed) = _cycle(0);
        assertLe(claimed, cyclePool, "claims never exceed the cycle pool");
    }

    /// @dev totalReserved sube con cada cuota para educadores, baja con cada
    /// claim y coincide con lo que el contrato tiene guardado para ellos.
    function test_HCSRC001_TotalReservedTracksFeesAndClaims() public {
        _viewer("viewer1", _one(EDUCATOR_A));
        _viewer("viewer2", _one(EDUCATOR_B));
        assertEq(memberships.totalReserved(), 2 * EDUCATOR_SHARE, "both fees reserved");

        memberships.advanceCycle();
        vm.prank(EDUCATOR_A);
        memberships.claimEducatorRewards(0);

        assertEq(memberships.totalReserved(), EDUCATOR_SHARE, "A's claim leaves B's share reserved");
        assertEq(token.balanceOf(address(memberships)), memberships.totalReserved(), "reserve matches the balance");
    }

    /// @dev Trasladar entre ciclos no cambia lo reservado, porque sigue siendo
    /// de educadores. Vale para el pase automatico y para el de lo no reclamado.
    function test_HCSRC001_RolloversDoNotChangeTotalReserved() public {
        _viewer("viewer1", _none());
        memberships.advanceCycle();
        assertEq(memberships.totalReserved(), EDUCATOR_SHARE, "the empty cycle's pool stays reserved");

        _viewer("viewer2", _one(EDUCATOR_A));
        memberships.advanceCycle();
        vm.warp(block.timestamp + memberships.UNCLAIMED_ROLLOVER_WINDOW());
        memberships.rollOverUnclaimed(1);

        assertEq(memberships.totalReserved(), 2 * EDUCATOR_SHARE, "the unclaimed rollover keeps it reserved");
    }
}
