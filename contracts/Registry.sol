// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Registry — the .arc name registry (ENS-style separation of ownership and records)
/// @notice Maps namehash -> owner / resolver / TTL. Ownership of records lives here;
/// record data lives in the Resolver contract. The Registrar is a *controller*: the
/// only party that may create subnodes, so registrar-level rules (pricing, expiry
/// bounds, subname revocability) cannot be bypassed by calling the registry directly.
/// @dev UUPS-upgradeable. Admin (DEFAULT_ADMIN_ROLE) is the 7-day TimelockController.
/// Compile with evmVersion "paris" or earlier — Arc rejects PUSH0.
contract Registry is AccessControlUpgradeable, UUPSUpgradeable {
    /// @dev Locks the implementation contract itself against initialization.
    constructor() {
        _disableInitializers();
    }
    /// @notice The root node (namehash of "") — represents `.arc` itself.
    bytes32 public constant ROOT_NODE = bytes32(0);

    /// @notice Delay for the two-step root ownership transfer. Never silent, never instant.
    uint256 public constant ROOT_TRANSFER_DELAY = 7 days;

    struct Record {
        address owner;
        address resolver;
        uint64 ttl;
    }

    struct RootProposal {
        address proposedOwner;
        uint64 proposedAt;
    }

    mapping(bytes32 => Record) private _records;
    /// @notice Controllers may create subnodes and manage records (the Registrar is one).
    mapping(address => bool) private _controllers;
    /// @notice owner => operator => approved (lets the Marketplace move a name for a seller).
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    RootProposal private _rootProposal;

    // ---- Events ----

    event NewOwner(bytes32 indexed node, bytes32 indexed label, address indexed owner);
    event Transfer(bytes32 indexed node, address indexed owner);
    event NewResolver(bytes32 indexed node, address indexed resolver);
    event NewTTL(bytes32 indexed node, uint64 ttl);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event ControllerUpdated(address indexed account, bool allowed);
    event RootTransferProposed(address indexed currentOwner, address indexed proposedOwner);
    event RootTransferAccepted(address indexed previousOwner, address indexed newOwner);
    event RootTransferCancelled(address indexed owner);

    // ---- Errors ----

    error Unauthorized();
    error ZeroAddress();
    error RootIsImmutable();
    error NoRootProposal();
    error NotProposedOwner();
    error TransferDelayNotMet();
    error NotRootOwner();

    /// @param admin The 7-day TimelockController that administers this registry.
    function initialize(address admin) public initializer {
        if (admin == address(0)) revert ZeroAddress();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _records[ROOT_NODE].owner = admin;
        emit Transfer(ROOT_NODE, admin);
    }

    // ---- Views ----

    /// @notice Owner of the name `node`.
    function owner(bytes32 node) public view returns (address) {
        return _records[node].owner;
    }

    /// @notice Resolver contract responsible for the records of `node`.
    function resolver(bytes32 node) public view returns (address) {
        return _records[node].resolver;
    }

    /// @notice TTL (cache duration) for the records of `node`.
    function ttl(bytes32 node) public view returns (uint64) {
        return _records[node].ttl;
    }

    /// @notice Whether `account` is a controller (may create subnodes / manage records).
    function isController(address account) public view returns (bool) {
        return _controllers[account];
    }

    /// @notice Whether `operator` may manage all names owned by `owner_`.
    function isApprovedForAll(address owner_, address operator) public view returns (bool) {
        return _operatorApprovals[owner_][operator];
    }

    /// @notice The pending root transfer proposal, if any.
    function rootTransferProposal() public view returns (address proposedOwner, uint64 proposedAt) {
        RootProposal memory p = _rootProposal;
        return (p.proposedOwner, p.proposedAt);
    }

    // ---- Operator approvals ----

    /// @notice Approve (or revoke) `operator` to manage all names owned by the caller.
    /// @dev Used by sellers to let the Marketplace transfer a name on sale.
    function setApprovalForAll(address operator, bool approved) public {
        if (operator == address(0)) revert ZeroAddress();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    // ---- Record management ----

    /// @notice Create (or reassign) the subnode `label` under `node`, setting its owner.
    /// Returns the subnode (ENS convention).
    /// @dev Callable by controllers (the Registrar mints `.arc` names through this path,
    /// so pricing/expiry/allowlist rules always apply — no back door) or by anyone
    /// authorized on the parent `node` (the ReverseRegistrar owns the `reverse` root
    /// and mints reverse subnodes through this path).
    function setSubnodeOwner(bytes32 node, bytes32 label, address newOwner) public returns (bytes32 subnode) {
        if (!_controllers[msg.sender] && !_isRecordAuthorized(node, msg.sender)) revert Unauthorized();
        if (newOwner == address(0)) revert ZeroAddress();
        subnode = keccak256(abi.encodePacked(node, label));
        _records[subnode].owner = newOwner;
        emit NewOwner(node, label, newOwner);
    }

    /// @notice Transfer ownership of `node` to `newOwner`.
    /// @dev Callable by the owner, an approved operator, or a controller
    /// (the Registrar uses this for park-escrow and reclaim). The root node
    /// itself is excluded — it moves only via the two-step timelocked path below.
    function setOwner(bytes32 node, address newOwner) public {
        if (node == ROOT_NODE) revert RootIsImmutable();
        if (!_isRecordAuthorized(node, msg.sender)) revert Unauthorized();
        if (newOwner == address(0)) revert ZeroAddress();
        _records[node].owner = newOwner;
        emit Transfer(node, newOwner);
    }

    /// @notice Set the resolver for `node`.
    function setResolver(bytes32 node, address newResolver) public {
        if (!_isRecordAuthorized(node, msg.sender)) revert Unauthorized();
        _records[node].resolver = newResolver;
        emit NewResolver(node, newResolver);
    }

    /// @notice Set the TTL for `node`.
    function setTTL(bytes32 node, uint64 newTTL) public {
        if (!_isRecordAuthorized(node, msg.sender)) revert Unauthorized();
        _records[node].ttl = newTTL;
        emit NewTTL(node, newTTL);
    }

    /// @notice Owner, approved operator, or controller may manage a record.
    function _isRecordAuthorized(bytes32 node, address account) internal view returns (bool) {
        address owner_ = _records[node].owner;
        return account == owner_ || _operatorApprovals[owner_][account] || _controllers[account];
    }

    // ---- Root ownership: two-step, timelocked, never silent ----

    /// @notice Step 1 of the root transfer: the current root owner proposes `newOwner`.
    /// The proposal is public on-chain; acceptance is possible after 7 days.
    function proposeRootTransfer(address newOwner) public {
        if (msg.sender != _records[ROOT_NODE].owner) revert NotRootOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        _rootProposal = RootProposal({proposedOwner: newOwner, proposedAt: uint64(block.timestamp)});
        emit RootTransferProposed(msg.sender, newOwner);
    }

    /// @notice Step 2: the proposed owner accepts after the 7-day delay has passed.
    function acceptRootTransfer() public {
        RootProposal memory p = _rootProposal;
        if (p.proposedOwner == address(0)) revert NoRootProposal();
        if (msg.sender != p.proposedOwner) revert NotProposedOwner();
        if (block.timestamp < p.proposedAt + ROOT_TRANSFER_DELAY) revert TransferDelayNotMet();
        address previousOwner = _records[ROOT_NODE].owner;
        _records[ROOT_NODE].owner = p.proposedOwner;
        delete _rootProposal;
        emit RootTransferAccepted(previousOwner, p.proposedOwner);
    }

    /// @notice The current root owner may cancel a pending proposal at any time.
    function cancelRootTransfer() public {
        if (msg.sender != _records[ROOT_NODE].owner) revert NotRootOwner();
        if (_rootProposal.proposedOwner == address(0)) revert NoRootProposal();
        delete _rootProposal;
        emit RootTransferCancelled(msg.sender);
    }

    // ---- Administration ----

    /// @notice Grant or revoke controller status. Controllers create subnodes and
    /// manage records (notably the Registrar). Admin only (timelocked).
    function setController(address account, bool allowed) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _controllers[account] = allowed;
        emit ControllerUpdated(account, allowed);
    }

    /// @dev Upgrades are admin-only; the admin is the 7-day TimelockController,
    /// so every upgrade is public for 7 days before it can execute.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
