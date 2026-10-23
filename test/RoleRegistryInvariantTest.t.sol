// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { RoleRegistry } from "../src/RoleRegistry.sol";

/// @dev Handler de la invariante: tres origenes con REGISTRAR_ROLE ponen y
/// quitan bloqueos sobre tres cuentas, y el admin usa la salida de
/// emergencia (revocar el rol, adminUnblock y volver a concederlo).
contract RoleRegistryBlockHandler is Test {
    RoleRegistry public registry;
    address[] public sources;
    address[] public accounts;

    constructor() {
        registry = new RoleRegistry();
        bytes32 registrar = registry.REGISTRAR_ROLE();
        for (uint256 i = 0; i < 3; i++) {
            address source = makeAddr(string.concat("source", vm.toString(i)));
            registry.grantRole(registrar, source);
            sources.push(source);
            accounts.push(makeAddr(string.concat("account", vm.toString(i))));
        }
    }

    function sourceCount() external view returns (uint256) {
        return sources.length;
    }

    function accountCount() external view returns (uint256) {
        return accounts.length;
    }

    function block_(uint256 sourceSeed_, uint256 accountSeed_) external {
        (address source, address account) = _pick(sourceSeed_, accountSeed_);
        if (registry.isBlockedBy(account, source)) return;

        vm.prank(source);
        registry.setBlocked(account);
    }

    function unblock(uint256 sourceSeed_, uint256 accountSeed_) external {
        (address source, address account) = _pick(sourceSeed_, accountSeed_);
        if (!registry.isBlockedBy(account, source)) return;

        vm.prank(source);
        registry.setUnblocked(account);
    }

    function emergencyLift(uint256 sourceSeed_, uint256 accountSeed_) external {
        (address source, address account) = _pick(sourceSeed_, accountSeed_);
        if (!registry.isBlockedBy(account, source)) return;

        bytes32 registrar = registry.REGISTRAR_ROLE();
        registry.revokeRole(registrar, source);
        registry.adminUnblock(account, source);
        registry.grantRole(registrar, source);
    }

    function _pick(uint256 sourceSeed_, uint256 accountSeed_) internal view returns (address, address) {
        return (sources[sourceSeed_ % sources.length], accounts[accountSeed_ % accounts.length]);
    }
}

/// @dev Invariantes de HC-SRC-012 sobre el bloqueo por origen de RoleRegistry.
contract RoleRegistryInvariantTest is Test {
    RoleRegistryBlockHandler handler;
    RoleRegistry registry;

    function setUp() public {
        handler = new RoleRegistryBlockHandler();
        registry = handler.registry();
        targetContract(address(handler));
    }

    /// @dev blockCount es exactamente el numero de origenes que mantienen un
    /// bloqueo sobre la cuenta.
    function invariant_BlockCountEqualsTheSourcesHoldingABlock() public view {
        for (uint256 a = 0; a < handler.accountCount(); a++) {
            address account = handler.accounts(a);
            uint256 holding;
            for (uint256 s = 0; s < handler.sourceCount(); s++) {
                if (registry.isBlockedBy(account, handler.sources(s))) holding++;
            }
            assertEq(registry.blockCount(account), holding, "blockCount must match the sources holding a block");
        }
    }

    /// @dev Una cuenta esta bloqueada si y solo si algun origen la bloquea.
    function invariant_IsBlockedMatchesBlockCount() public view {
        for (uint256 a = 0; a < handler.accountCount(); a++) {
            address account = handler.accounts(a);
            assertEq(registry.isBlocked(account), registry.blockCount(account) > 0, "isBlocked must equal blockCount > 0");
        }
    }
}
