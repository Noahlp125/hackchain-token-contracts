// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { MembershipSystem } from "../src/MembershipSystem.sol";
import { HackToken } from "../src/HackTokenERC20.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

/// @dev Handler de la invariante: espectadores que se suscriben y generan
/// vistas, educadores que reclaman, el admin que cierra ciclos y cualquiera
/// que traslada lo no reclamado, con el tiempo avanzando entre medias.
contract MembershipCycleHandler is Test {
    MembershipSystem public memberships;
    HackToken public token;
    RoleRegistry public registry;

    address[] public viewers;
    address[] public educators;

    uint256 public ghostFeesReserved;
    uint256 public ghostClaimsPaid;

    uint256 constant MAX_CYCLES = 30;

    constructor() {
        token = new HackToken(address(this));
        registry = new RoleRegistry();
        registry.grantRole(registry.REGISTRAR_ROLE(), address(this));
        memberships = new MembershipSystem(address(token), makeAddr("pool"), makeAddr("treasury"), address(registry));

        for (uint256 i = 0; i < 3; i++) {
            address educator = makeAddr(string.concat("educator", vm.toString(i)));
            registry.registerRole(educator, RoleRegistry.BusinessRole.Educator);
            educators.push(educator);
        }
        for (uint256 i = 0; i < 5; i++) {
            address viewer = makeAddr(string.concat("viewer", vm.toString(i)));
            token.mintTokens(viewer, 100 * memberships.ACADEMIC_MONTHLY_COST());
            vm.prank(viewer);
            token.approve(address(memberships), type(uint256).max);
            viewers.push(viewer);
        }
    }

    function subscribe(uint256 viewerSeed_) external {
        address viewer = viewers[viewerSeed_ % viewers.length];
        if (memberships.hasAcademicMembership(viewer)) return;

        uint256 share = (memberships.ACADEMIC_MONTHLY_COST() * memberships.POOL_SHARE()) / 100;
        vm.prank(viewer);
        memberships.activateAcademicMembership(MembershipSystem.AcademicTier.Monthly);
        ghostFeesReserved += share;
    }

    function view_(uint256 viewerSeed_, uint256 educatorSeed_) external {
        address viewer = viewers[viewerSeed_ % viewers.length];
        address educator = educators[educatorSeed_ % educators.length];
        if (!memberships.hasAcademicMembership(viewer)) return;
        if (memberships.hasCountedView(memberships.currentCycle(), viewer, educator)) return;

        vm.prank(viewer);
        memberships.registerContentView(educator);
    }

    function advance() external {
        if (memberships.currentCycle() >= MAX_CYCLES) return;
        memberships.advanceCycle();
    }

    function claim(uint256 educatorSeed_, uint256 cycleSeed_) external {
        uint256 current = memberships.currentCycle();
        if (current == 0) return;
        address educator = educators[educatorSeed_ % educators.length];
        uint256 cycleId = cycleSeed_ % current;

        uint256 amount = memberships.claimable(cycleId, educator);
        if (amount == 0) return;

        vm.prank(educator);
        memberships.claimEducatorRewards(cycleId);
        ghostClaimsPaid += amount;
    }

    function rollOver(uint256 cycleSeed_) external {
        uint256 current = memberships.currentCycle();
        if (current == 0) return;
        uint256 cycleId = cycleSeed_ % current;

        (, , , uint256 closedAt, bool rolledOver) = memberships.cycles(cycleId);
        if (rolledOver || block.timestamp < closedAt + memberships.UNCLAIMED_ROLLOVER_WINDOW()) return;

        memberships.rollOverUnclaimed(cycleId);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 hours, 40 days));
    }
}

/// @dev Invariantes de HC-SRC-001 sobre la contabilidad por ciclos.
contract MembershipSystemInvariantTest is Test {
    MembershipCycleHandler handler;
    MembershipSystem memberships;

    function setUp() public {
        handler = new MembershipCycleHandler();
        memberships = handler.memberships();
        targetContract(address(handler));
    }

    /// @dev El contrato siempre tiene al menos lo que debe a los educadores.
    function invariant_BalanceCoversTotalReserved() public view {
        assertGe(
            handler.token().balanceOf(address(memberships)),
            memberships.totalReserved(),
            "balance must cover what is owed to educators"
        );
    }

    /// @dev Lo pendiente de cada ciclo cerrado sin trasladar, mas el pool del
    /// ciclo abierto, suma exactamente totalReserved.
    function invariant_CyclesAddUpToTotalReserved() public view {
        uint256 current = memberships.currentCycle();
        uint256 outstanding;
        for (uint256 c = 0; c < current; c++) {
            (uint256 pool, , uint256 claimed, , bool rolledOver) = memberships.cycles(c);
            if (!rolledOver) outstanding += pool - claimed;
        }
        (uint256 openPool, , , , ) = memberships.cycles(current);

        assertEq(outstanding + openPool, memberships.totalReserved(), "cycles must add up to totalReserved");
    }

    /// @dev totalReserved es lo cobrado en cuotas menos lo pagado en claims.
    function invariant_TotalReservedIsFeesMinusClaims() public view {
        assertEq(
            memberships.totalReserved(),
            handler.ghostFeesReserved() - handler.ghostClaimsPaid(),
            "totalReserved must equal fees minus claims"
        );
    }
}
