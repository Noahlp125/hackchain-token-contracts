// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title RoleRegistry
 * @dev Registro on-chain de identidad de rol de negocio (Educador, Talento,
 * Reclutador). Resuelve la falta de verificación señalada en la revisión:
 * "No se tiene registrado quien es talento, educador o reclutador, por lo
 * que no se pueden hacer las comprovaciones adecuadas".
 *
 * Este registro es la fuente de verdad única que deben consultar
 * MembershipSystem, EducatorBonuses, RecruiterBonuses, TalentBonuses y
 * cualquier módulo futuro (Mecanismo 12) antes de conceder beneficios o
 * registrar actividad ligada a un rol.
 *
 * Un mismo address puede tener varios roles a la vez si el negocio lo
 * permite (p.ej. alguien que es Talento y también Educador).
 */
contract RoleRegistry is AccessControl {
    // --- Roles de gestión ---

    /// @notice Rol asignado a las cuentas/backends autorizados a registrar
    /// o revocar roles de negocio tras verificación off-chain (KYC, etc.).
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    // --- Roles de negocio (enum para extender fácilmente en el futuro) ---

    enum BusinessRole {
        Educator,
        Talent,
        Recruiter
    }

    // --- State ---

    /// @notice user => role => está registrado actualmente.
    mapping(address => mapping(BusinessRole => bool)) public hasBusinessRole;

    /// @notice user => role => timestamp de registro (0 si nunca se registró).
    mapping(address => mapping(BusinessRole => uint256)) public registeredAt;

    // --- Custom Errors ---

    error InvalidAddress();
    error AlreadyRegistered();
    error NotRegistered();

    // --- Events ---

    event RoleRegistered(address indexed account, BusinessRole indexed role, uint256 timestamp);
    event RoleRevoked(address indexed account, BusinessRole indexed role);

    // --- Constructor ---

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // --- Core ---

    /**
     * @notice Registra un address bajo un rol de negocio tras verificación off-chain.
     * @dev Solo invocable por cuentas con REGISTRAR_ROLE. Revierte si el
     * address ya tiene ese rol activo, para evitar resetear registeredAt
     * accidentalmente.
     * @param account_ Dirección a registrar.
     * @param role_ Rol de negocio a conceder.
     */
    function registerRole(address account_, BusinessRole role_)
        external
        onlyRole(REGISTRAR_ROLE)
    {
        if (account_ == address(0)) revert InvalidAddress();
        if (hasBusinessRole[account_][role_]) revert AlreadyRegistered();

        hasBusinessRole[account_][role_] = true;
        registeredAt[account_][role_] = block.timestamp;

        emit RoleRegistered(account_, role_, block.timestamp);
    }

    /**
     * @notice Revoca un rol de negocio previamente registrado.
     * @dev No borra registeredAt (queda como histórico), solo desactiva
     * hasBusinessRole. Solo invocable por REGISTRAR_ROLE.
     * @param account_ Dirección a revocar.
     * @param role_ Rol de negocio a revocar.
     */
    function revokeRole(address account_, BusinessRole role_)
        external
        onlyRole(REGISTRAR_ROLE)
    {
        if (!hasBusinessRole[account_][role_]) revert NotRegistered();

        hasBusinessRole[account_][role_] = false;

        emit RoleRevoked(account_, role_);
    }

    // --- Views ---

    /**
     * @notice Comprueba si un address está registrado como Educador.
     */
    function isEducator(address account_) external view returns (bool) {
        return hasBusinessRole[account_][BusinessRole.Educator];
    }

    /**
     * @notice Comprueba si un address está registrado como Talento.
     */
    function isTalent(address account_) external view returns (bool) {
        return hasBusinessRole[account_][BusinessRole.Talent];
    }

    /**
     * @notice Comprueba si un address está registrado como Reclutador.
     */
    function isRecruiter(address account_) external view returns (bool) {
        return hasBusinessRole[account_][BusinessRole.Recruiter];
    }
}
