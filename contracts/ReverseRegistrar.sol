// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// Note: OZ v5.6's Strings pulls in Bytes.sol, which uses the Cancun-only MCOPY
// opcode and will not compile for the paris target Arc requires. We use a local
// hex helper instead.

/// @notice Minimal view of the Registry the ReverseRegistrar needs.
interface IRegistry {
    function owner(bytes32 node) external view returns (address);
    function setSubnodeOwner(bytes32 node, bytes32 labelhash, address newOwner) external returns (bytes32);
    function setResolver(bytes32 node, address newResolver) external;
}

/// @notice Minimal view of the Resolver the ReverseRegistrar needs.
interface IResolver {
    function setText(bytes32 node, string calldata key, string calldata value) external;
}

/// @title ReverseRegistrar — address -> primary name records
/// @notice Reverse names live under `*.reverse` (node = namehash("reverse")). This contract
/// owns the `reverse` root and mints one subnode per address on demand. `setName`
/// records the caller's primary name as the `name` text record on their reverse node.
/// The contract keeps ownership of reverse subnodes so record writes stay authorized
/// through the standard registry owner check — no special-casing in the Resolver.
/// `claim` hands a reverse node to its address owner as an escape hatch for direct
/// record management. Forward verification (does the name resolve back to this
/// address?) is expected at the display/resolution layer, not enforced here.
/// @dev UUPS-upgradeable. Admin (DEFAULT_ADMIN_ROLE) is the 7-day TimelockController.
/// Deploy flow: the root owner (timelock) must grant this contract the `reverse`
/// subnode via registry.setSubnodeOwner(ROOT, keccak256("reverse"), this, resolver, 0).
/// Compile with evmVersion "paris" or earlier — Arc rejects PUSH0.
contract ReverseRegistrar is AccessControlUpgradeable, UUPSUpgradeable {
    /// @dev Locks the implementation contract itself against initialization.
    constructor() {
        _disableInitializers();
    }
    bytes16 private constant HEX_DIGITS = "0123456789abcdef";

    /// @notice namehash("reverse") = keccak256(abi.encodePacked(bytes32(0), keccak256("reverse"))).
    bytes32 public constant REVERSE_ROOT_NODE = keccak256(abi.encodePacked(bytes32(0), keccak256("reverse")));
    /// @notice Text-record key carrying the primary name.
    string public constant NAME_KEY = "name";

    IRegistry private _registry;
    IResolver private _resolver;

    // ---- Events ----

    event NameSet(bytes32 indexed node, address indexed owner_, string name);
    event ReverseClaimed(bytes32 indexed node, address indexed owner_);
    event ResolverUpdated(address indexed resolver);

    // ---- Errors ----

    error ZeroAddress();
    error NotInitialised();
    error NotReverseOwner();

    /// @param admin The 7-day TimelockController that administers this registrar.
    /// @param registry_ The Registry.
    /// @param resolver_ The Resolver that stores reverse records.
    function initialize(address admin, address registry_, address resolver_) public initializer {
        if (admin == address(0) || registry_ == address(0) || resolver_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _registry = IRegistry(registry_);
        _resolver = IResolver(resolver_);
        emit ResolverUpdated(resolver_);
    }

    // ---- Views ----

    /// @notice The reverse node for `addr` (label = lowercase hex of the address, ENS convention).
    function nodeForAddress(address addr) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(REVERSE_ROOT_NODE, keccak256(bytes(_toHexString(addr)))));
    }

    function resolver() public view returns (address) {
        return address(_resolver);
    }

    // ---- Reverse records ----

    /// @notice Set (or clear, with an empty string) the caller's primary name.
    /// Mints the caller's reverse subnode on first use, pointing its resolver at
    /// the shared Resolver so the standard registry -> resolver path works.
    function setName(string calldata name) public returns (bytes32 node) {
        if (address(_registry) == address(0)) revert NotInitialised();
        if (_registry.owner(REVERSE_ROOT_NODE) != address(this)) revert NotReverseOwner();
        node = nodeForAddress(msg.sender);
        if (_registry.owner(node) == address(0)) {
            _registry.setSubnodeOwner(REVERSE_ROOT_NODE, keccak256(bytes(_toHexString(msg.sender))), address(this));
            _registry.setResolver(node, address(_resolver)); // we own the node -> authorized
        }
        _resolver.setText(node, NAME_KEY, name); // we own the node -> authorized
        emit NameSet(node, msg.sender, name);
    }

    /// @notice Take direct ownership of the caller's reverse node (escape hatch for
    /// managing records without this contract). The resolver pointer is refreshed
    /// first so records stay resolvable after the handover.
    function claim() public returns (bytes32 node) {
        node = nodeForAddress(msg.sender);
        if (_registry.owner(node) != address(this)) revert NotReverseOwner();
        _registry.setResolver(node, address(_resolver)); // before transfer: we still own it
        _registry.setSubnodeOwner(REVERSE_ROOT_NODE, keccak256(bytes(_toHexString(msg.sender))), msg.sender);
        emit ReverseClaimed(node, msg.sender);
    }

    /// @notice Take direct ownership of `owner_`'s reverse node (operator path, e.g. a
    /// wallet acting for its user). The node must currently be held by this contract.
    /// The resolver pointer is refreshed first so records stay resolvable after handover.
    function claimFor(address owner_) public returns (bytes32 node) {
        node = nodeForAddress(owner_);
        if (_registry.owner(node) != address(this)) revert NotReverseOwner();
        _registry.setResolver(node, address(_resolver)); // before transfer: we still own it
        _registry.setSubnodeOwner(REVERSE_ROOT_NODE, keccak256(bytes(_toHexString(owner_))), owner_);
        emit ReverseClaimed(node, owner_);
    }

    // ---- Administration (timelocked via DEFAULT_ADMIN_ROLE) ----

    /// @notice Point at a new Resolver for reverse records.
    function setResolver(address resolver_) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (resolver_ == address(0)) revert ZeroAddress();
        _resolver = IResolver(resolver_);
        emit ResolverUpdated(resolver_);
    }

    /// @notice Set the shared Resolver on the `reverse` root node (admin, timelocked).
    /// Required so the standard registry -> resolver path resolves reverse names;
    /// without it, `registry.resolver(reverseNode)` returns 0 for every reverse node.
    function setReverseRootResolver() public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(_registry) == address(0)) revert NotInitialised();
        if (_registry.owner(REVERSE_ROOT_NODE) != address(this)) revert NotReverseOwner();
        _registry.setResolver(REVERSE_ROOT_NODE, address(_resolver));
    }

    /// @dev Upgrades are admin-only; the admin is the 7-day TimelockController.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @dev Lowercase hex of an address with 0x prefix (no OZ Strings dependency).
    function _toHexString(address addr) internal pure returns (string memory) {
        bytes memory buffer = new bytes(42);
        buffer[0] = "0";
        buffer[1] = "x";
        uint160 value = uint160(addr);
        for (uint256 i = 0; i < 20; i++) {
            uint8 b = uint8(value >> (8 * (19 - i)));
            buffer[2 + i * 2] = HEX_DIGITS[b >> 4];
            buffer[3 + i * 2] = HEX_DIGITS[b & 0x0f];
        }
        return string(buffer);
    }
}
