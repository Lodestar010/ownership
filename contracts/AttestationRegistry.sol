// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title AttestationRegistry
/// @notice Soulbound registry of education-track completions for the Lodestar
/// naming service (spec §17). Completion of a track mints a non-transferable
/// attestation: there is no token, nothing to transfer, only a bitmap per
/// account that the issuer sets and revokes. Consumers gate on it:
///   - TRACK_ORIENTATION gates the Registrar's family-allowlist free path
///     ("gate the designation, never the emergency claim")
///   - TRACK_SUCCESSOR / TRACK_MANAGEMENT gate future succession and
///     management-role designations
///   - TRACK_NAME_HOLDER reserved for the name-holder track
/// Issuers are whoever runs the education program (the family office on
/// mainnet; the builder on testnet). Admin is the 7-day TimelockController.
contract AttestationRegistry is AccessControlUpgradeable, UUPSUpgradeable {
    /// @notice Can mint and revoke attestations.
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    /// @notice Education tracks. New tracks may be appended; existing ids are stable.
    uint8 public constant TRACK_ORIENTATION = 0;
    uint8 public constant TRACK_SUCCESSOR = 1;
    uint8 public constant TRACK_MANAGEMENT = 2;
    uint8 public constant TRACK_NAME_HOLDER = 3;
    /// @notice Number of defined tracks (ids 0..TRACK_COUNT-1).
    uint8 public constant TRACK_COUNT = 4;

    /// @notice account -> bitmap of completed tracks (bit i == track i).
    mapping(address => uint256) private _tracks;

    // ---- Events (spec §16: indexed for filter queries) ----

    event Attested(address indexed account, uint8 indexed track);
    event Revoked(address indexed account, uint8 indexed track);

    // ---- Errors ----

    error Unauthorized();
    error ZeroAddress();
    error BadTrack();

    /// @param admin The 7-day TimelockController that administers this registry.
    /// @param issuer The initial attestation issuer (family office / builder).
    function initialize(address admin, address issuer) public initializer {
        if (admin == address(0) || issuer == address(0)) revert ZeroAddress();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ISSUER_ROLE, issuer);
    }

    // ---- Views ----

    /// @notice Whether `account` holds a live attestation for `track`.
    function hasTrack(address account, uint8 track) public view returns (bool) {
        if (track >= TRACK_COUNT) revert BadTrack();
        return (_tracks[account] >> track) & 1 == 1;
    }

    /// @notice Raw completion bitmap for `account` (bit i == track i).
    function tracksOf(address account) public view returns (uint256) {
        return _tracks[account];
    }

    // ---- Issuance ----

    /// @notice Mint the `track` attestation for `account`. Idempotent.
    function attest(address account, uint8 track) public onlyRole(ISSUER_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (track >= TRACK_COUNT) revert BadTrack();
        uint256 bit = 1 << track;
        if (_tracks[account] & bit != 0) return; // already attested; no-op
        _tracks[account] |= bit;
        emit Attested(account, track);
    }

    /// @notice Revoke the `track` attestation from `account`. Idempotent.
    function revoke(address account, uint8 track) public onlyRole(ISSUER_ROLE) {
        if (track >= TRACK_COUNT) revert BadTrack();
        uint256 bit = 1 << track;
        if (_tracks[account] & bit == 0) return; // not attested; no-op
        _tracks[account] &= ~bit;
        emit Revoked(account, track);
    }

    /// @dev Upgrades are admin-only; the admin is the 7-day TimelockController.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
