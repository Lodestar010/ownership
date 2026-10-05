// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Minimal view of the Registry the Resolver needs for authorization.
interface IRegistryAuth {
    function owner(bytes32 node) external view returns (address);
    function isApprovedForAll(address owner_, address operator) external view returns (bool);
}

/// @notice The Registrar side of the activity hook: record updates reset the
/// name's term (activity auto-renews). The Registrar only accepts pings from
/// resolvers it has explicitly authorized.
interface IActivityHook {
    function pokeActivity(bytes32 node) external;
}

/// @title Resolver — standard record storage for .arc names
/// @notice ENS-protocol-compatible record interfaces: addr (single + multichain
/// per EIP-2304), text records (ENSIP key conventions), contenthash, multicall.
/// Only the name's owner (or their approved operator) may write records.
/// Every write pings the Registrar so activity auto-renews the name's term.
/// @dev UUPS-upgradeable. Admin (DEFAULT_ADMIN_ROLE) is the 7-day TimelockController.
/// Compile with evmVersion "paris" or earlier — Arc rejects PUSH0.
contract Resolver is AccessControlUpgradeable, UUPSUpgradeable {
    /// @dev Locks the implementation contract itself against initialization.
    constructor() {
        _disableInitializers();
    }
    // ENS interface IDs (for supportsInterface)
    bytes4 private constant ADDR_RESOLVER_ID = 0x3b3b57de; // addr(bytes32)
    bytes4 private constant ADDRESS_RESOLVER_ID = 0xf1cb7e06; // addr(bytes32,uint256)
    bytes4 private constant TEXT_RESOLVER_ID = 0x59d1d43c; // text(bytes32,string)
    bytes4 private constant CONTENT_HASH_RESOLVER_ID = 0xbc1c58d1; // contenthash(bytes32)
    bytes4 private constant MULTICALLABLE_ID = 0xac9650d8; // multicall(bytes[])

    IRegistryAuth private _registry;
    IActivityHook private _registrar;

    mapping(bytes32 => address) private _addrs;
    mapping(bytes32 => mapping(uint256 => bytes)) private _multichainAddrs;
    mapping(bytes32 => mapping(string => string)) private _texts;
    mapping(bytes32 => bytes) private _contenthashes;

    // ---- Events ----

    event AddrChanged(bytes32 indexed node, address addr);
    event AddressChanged(bytes32 indexed node, uint256 coinType, bytes newAddress);
    event TextChanged(bytes32 indexed node, string indexed key, string value);
    event ContenthashChanged(bytes32 indexed node, bytes hash);
    event RegistryUpdated(address indexed registry);
    event RegistrarUpdated(address indexed registrar);

    // ---- Errors ----

    error Unauthorized();
    error ZeroAddress();

    /// @param admin The 7-day TimelockController that administers this resolver.
    /// @param registry_ The Registry contract used to check record-write authorization.
    function initialize(address admin, address registry_) public initializer {
        if (admin == address(0) || registry_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _registry = IRegistryAuth(registry_);
        emit RegistryUpdated(registry_);
    }

    // ---- Administration ----

    /// @notice Point at a new Registry (admin only, timelocked).
    function setRegistry(address registry_) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (registry_ == address(0)) revert ZeroAddress();
        _registry = IRegistryAuth(registry_);
        emit RegistryUpdated(registry_);
    }

    /// @notice Point at the Registrar that receives activity pings (admin only, timelocked).
    /// @dev The Registrar must authorize this resolver as a notifier separately.
    function setRegistrar(address registrar_) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _registrar = IActivityHook(registrar_);
        emit RegistrarUpdated(registrar_);
    }

    function registry() public view returns (address) {
        return address(_registry);
    }

    function registrar() public view returns (address) {
        return address(_registrar);
    }

    // ---- Authorization ----

    /// @notice Only the name's owner or their approved operator may write records.
    modifier onlyNameAuthorized(bytes32 node) {
        address nodeOwner = _registry.owner(node);
        if (msg.sender != nodeOwner && !_registry.isApprovedForAll(nodeOwner, msg.sender)) {
            revert Unauthorized();
        }
        _;
    }

    /// @notice Ping the Registrar so this activity resets the name's term.
    /// Skipped when no registrar is configured. A faulting registrar never blocks
    /// a record write (try/catch) — resolution data must not depend on the
    /// registrar's liveness.
    function _poke(bytes32 node) internal {
        if (address(_registrar) != address(0)) {
            try _registrar.pokeActivity(node) {} catch {}
        }
    }

    // ---- addr: primary address (coin type 60 / EVM) ----

    /// @notice Returns the primary address for `node`.
    function addr(bytes32 node) public view returns (address) {
        return _addrs[node];
    }

    /// @notice Sets the primary address for `node`.
    function setAddr(bytes32 node, address newAddr) public onlyNameAuthorized(node) {
        _addrs[node] = newAddr;
        emit AddrChanged(node, newAddr);
        _poke(node);
    }

    // ---- addr: multichain (EIP-2304, coinType => address bytes) ----

    /// @notice Returns the address for `node` on the chain identified by `coinType`.
    function addr(bytes32 node, uint256 coinType) public view returns (bytes memory) {
        return _multichainAddrs[node][coinType];
    }

    /// @notice Sets the address for `node` on the chain identified by `coinType`.
    function setAddr(bytes32 node, uint256 coinType, bytes memory newAddress) public onlyNameAuthorized(node) {
        _multichainAddrs[node][coinType] = newAddress;
        emit AddressChanged(node, coinType, newAddress);
        _poke(node);
    }

    // ---- text records (ENSIP key conventions, e.g. "org.verified", "did:*") ----

    /// @notice Returns the text record `key` for `node`.
    function text(bytes32 node, string calldata key) public view returns (string memory) {
        return _texts[node][key];
    }

    /// @notice Sets the text record `key` for `node`.
    function setText(bytes32 node, string calldata key, string calldata value)
        public
        onlyNameAuthorized(node)
    {
        _texts[node][key] = value;
        emit TextChanged(node, key, value);
        _poke(node);
    }

    // ---- contenthash ----

    /// @notice Returns the contenthash for `node` (e.g. an IPFS-hosted site or DID document).
    function contenthash(bytes32 node) public view returns (bytes memory) {
        return _contenthashes[node];
    }

    /// @notice Sets the contenthash for `node`.
    function setContenthash(bytes32 node, bytes calldata hash) public onlyNameAuthorized(node) {
        _contenthashes[node] = hash;
        emit ContenthashChanged(node, hash);
        _poke(node);
    }

    // ---- multicall: batch reads/writes in one tx ----

    /// @notice Executes a batch of calls against this resolver (wallets/dapps use this
    /// to read or write several records atomically).
    function multicall(bytes[] calldata data) public returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool ok, bytes memory ret) = address(this).delegatecall(data[i]);
            require(ok, "multicall: subcall failed");
            results[i] = ret;
        }
    }

    // ---- ERC-165 ----

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == ADDR_RESOLVER_ID || interfaceId == ADDRESS_RESOLVER_ID
            || interfaceId == TEXT_RESOLVER_ID || interfaceId == CONTENT_HASH_RESOLVER_ID
            || interfaceId == MULTICALLABLE_ID || super.supportsInterface(interfaceId);
    }

    /// @dev Upgrades are admin-only; the admin is the 7-day TimelockController.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
