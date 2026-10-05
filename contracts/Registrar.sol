// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// Note: OZ v5.6 removed ReentrancyGuardUpgradeable. The storage-based
// ReentrancyGuard (non-transient) is paris-safe and works behind a UUPS proxy:
// the guard slot starts at 0 in proxy storage, which != ENTERED, so the first
// call initializes it correctly.
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal view of the Registry the Registrar needs.
interface IRegistry {
    function owner(bytes32 node) external view returns (address);
    function resolver(bytes32 node) external view returns (address);
    function setSubnodeOwner(bytes32 node, bytes32 label, address newOwner) external;
    function setOwner(bytes32 node, address newOwner) external;
    function setResolver(bytes32 node, address newResolver) external;
    function isApprovedForAll(address owner_, address operator) external view returns (bool);
}

interface IAttestationRegistry {
    function hasTrack(address account, uint8 track) external view returns (bool);
}

/// @title Registrar — registration, pricing, renewals and the name lifecycle for .arc
/// @notice Tiered one-time pricing (3/4/5/6 chars priced, 7+ free, 1-2 locked), 2-year
/// terms with free renewal forever, 90-day grace, 1-year park (resolution stopped,
/// reclaimable), then re-release. The family/verified allowlist is fee-exempt once
/// members hold the orientation attestation (spec §17). Outsider registrations pay
/// a matching fee to the Splitter. Subnames are created
/// only through here so parent-bound expiry, revocability and parent pricing hold.
/// @dev UUPS-upgradeable. Admin (DEFAULT_ADMIN_ROLE) is the 7-day TimelockController.
/// This contract is a Registry *controller*: the only party that may create subnodes.
/// Compile with evmVersion "paris" or earlier — Arc rejects PUSH0.
contract Registrar is AccessControlUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    /// @dev Locks the implementation contract itself against initialization.
    constructor() {
        _disableInitializers();
    }
    /// @notice The root node (`.arc`) under which top-level names are created.
    bytes32 public constant ROOT_NODE = bytes32(0);
    /// @notice Registration term: 2 years.
    uint64 public constant TERM = 730 days;
    /// @notice After expiry, only the owner may renew for this long.
    uint64 public constant GRACE_PERIOD = 90 days;
    /// @notice After grace, a name parks (no resolution, reclaimable) for this long.
    uint64 public constant PARK_PERIOD = 365 days;
    /// @notice Term granted by a successful reclaim.
    uint64 public constant RECLAIM_TERM = 365 days;
    /// @notice Max DNS label length enforced on-chain (normalization itself is off-chain).
    uint256 public constant MAX_LABEL_LENGTH = 63;

    struct ParkRecord {
        address prevOwner;
        address prevResolver;
        uint64 parkedAt;
    }

    IRegistry private _registry;
    /// @notice Where tier prices and matching fees go (it divides them further).
    address payable private _splitter;
    /// @notice The Marketplace, authorized to report sales (term reset + hold-clock reset).
    address private _marketplace;
    /// @notice The BrandVault: names it holds are exempt from park/release (spec §8),
    /// and its sales are reported via onVaultAcquisition (term + hold-clock reset).
    address private _brandVault;
    /// @notice AttestationRegistry: the orientation attestation gates the family free path.
    IAttestationRegistry private _attestations;
    /// @notice Track id for orientation in the AttestationRegistry (spec §17).
    uint8 private constant TRACK_ORIENTATION = 0;

    /// @notice namehash -> term expiry timestamp.
    mapping(bytes32 => uint64) private _expiry;
    /// @notice namehash -> last acquisition timestamp (marketplace fee hold-clock).
    /// Set on registration and on every marketplace sale. Renewals never touch it.
    mapping(bytes32 => uint64) private _acquiredAt;
    /// @notice namehash -> park record (parkedAt == 0 means not parked).
    mapping(bytes32 => ParkRecord) private _parked;
    /// @notice namehash -> true once released back to the pool after park.
    mapping(bytes32 => bool) private _released;

    /// @notice label length (3..6) -> one-time tier price in native token. PLACEHOLDER values on testnet.
    mapping(uint256 => uint256) private _tierPrices;
    /// @notice Flat fee outsiders pay per registration, forwarded to the Splitter. PLACEHOLDER on testnet.
    uint256 private _matchingFee;

    /// @notice Family/verified allowlist: fee-exempt registrations and higher paymaster caps.
    mapping(address => bool) private _allowlisted;
    /// @notice Resolvers authorized to ping pokeActivity (activity auto-renew).
    mapping(address => bool) private _notifiers;

    /// @notice parent namehash -> true once the parent made subnames permanent (one-way).
    mapping(bytes32 => bool) private _subnamePermanent;
    /// @notice parent namehash -> price per subname in native token (free default), paid to the parent owner.
    mapping(bytes32 => uint256) private _subnamePrices;

    // ---- Events ----

    event NameRegistered(bytes32 indexed node, string label, address indexed owner, uint64 expiry);
    event NameRenewed(bytes32 indexed node, uint64 expiry);
    event NameParked(bytes32 indexed node, address indexed owner);
    event NameReclaimed(bytes32 indexed node, address indexed owner, uint64 expiry);
    event NameReleased(bytes32 indexed node);
    event ActivityPoked(bytes32 indexed node, uint64 expiry);
    event TermResetOnSale(bytes32 indexed node, address indexed buyer, uint64 expiry);
    event SubnameRegistered(bytes32 indexed subnode, bytes32 indexed parentNode, string label, address indexed owner, uint64 expiry);
    event SubnameRevoked(bytes32 indexed subnode, bytes32 indexed parentNode);
    event SubnameRenewed(bytes32 indexed subnode, uint64 expiry);
    event SubnamePermanenceSet(bytes32 indexed parentNode);
    event SubnamePriceSet(bytes32 indexed parentNode, uint256 price);
    event TierPriceUpdated(uint256 indexed length, uint256 price);
    event MatchingFeeUpdated(uint256 fee);
    event AllowlistUpdated(address indexed account, bool allowed);
    event NotifierUpdated(address indexed resolver, bool authorized);
    event MarketplaceUpdated(address indexed marketplace);
    event BrandVaultUpdated(address indexed brandVault);
    event AttestationRegistryUpdated(address indexed attestationRegistry);
    event SplitterUpdated(address indexed splitter);

    // ---- Errors ----

    error Unauthorized();
    error ZeroAddress();
    error LabelEmpty();
    error LabelTooLong();
    error NameLocked();
    error AlreadyRegistered();
    error NotRegistered();
    error AlreadyParked();
    error NotParked();
    error StillActive();
    error PastGrace();
    error ParkNotExpired();
    error ParkExpired();
    error InsufficientPayment();
    error PaymentFailed();
    error ParentNotActive();
    error SubnamePermanent();
    error SaleNotSettled();
    error ParkExempt();

    /// @param admin The 7-day TimelockController that administers this registrar.
    /// @param registry_ The Registry (this contract must be registered as a controller there).
    /// @param splitter_ The Splitter that receives tier prices and matching fees.
    function initialize(address admin, address registry_, address splitter_) public initializer {
        if (admin == address(0) || registry_ == address(0) || splitter_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _registry = IRegistry(registry_);
        _splitter = payable(splitter_);
        emit SplitterUpdated(splitter_);
    }

    // ---- Views ----

    /// @notice Term expiry timestamp for `node` (0 if never registered / released).
    function expiryOf(bytes32 node) public view returns (uint64) {
        return _expiry[node];
    }

    /// @notice Last acquisition timestamp for `node` (marketplace fee hold-clock).
    function acquiredAtOf(bytes32 node) public view returns (uint64) {
        return _acquiredAt[node];
    }

    /// @notice Whether `node` is currently parked.
    function isParked(bytes32 node) public view returns (bool) {
        return _parked[node].parkedAt != 0;
    }

    /// @notice Whether `label` is available for registration right now.
    function available(string calldata label) public view returns (bool) {
        bytes memory labelBytes = bytes(label);
        if (labelBytes.length < 3 || labelBytes.length > MAX_LABEL_LENGTH) return false;
        bytes32 node = _nodeForLabel(labelBytes);
        address currentOwner = _registry.owner(node);
        return currentOwner == address(0) || _released[node];
    }

    /// @notice Quote the cost of registering `label` as `account` (tier price + matching fee).
    /// Family-free (0, 0) requires the allowlist AND the orientation attestation.
    function quoteFor(string calldata label, address account) public view returns (uint256 tierPrice, uint256 fee) {
        uint256 len = bytes(label).length;
        if (len < 3) revert NameLocked();
        if (_isFamilyFree(account)) return (0, 0);
        tierPrice = len >= 7 ? 0 : _tierPrices[len];
        fee = _matchingFee;
    }

    /// @notice One-time tier price for names of `length` characters (3..6). PLACEHOLDER on testnet.
    function tierPriceOf(uint256 length) public view returns (uint256) {
        return _tierPrices[length];
    }

    function matchingFee() public view returns (uint256) {
        return _matchingFee;
    }

    function isAllowlisted(address account) public view returns (bool) {
        return _allowlisted[account];
    }

    /// @notice Whether `account` takes the family free path: allowlisted AND holding
    /// a live orientation attestation (spec §17). Fail-closed: if the attestation
    /// registry is not wired, nobody is free.
    function _isFamilyFree(address account) internal view returns (bool) {
        if (!_allowlisted[account]) return false;
        if (address(_attestations) == address(0)) return false;
        return _attestations.hasTrack(account, TRACK_ORIENTATION);
    }

    /// @notice Whether `account` currently qualifies for fee-exempt registration.
    function isFamilyFree(address account) public view returns (bool) {
        return _isFamilyFree(account);
    }

    function isNotifier(address resolver) public view returns (bool) {
        return _notifiers[resolver];
    }

    function marketplace() public view returns (address) {
        return _marketplace;
    }

    function splitter() public view returns (address) {
        return _splitter;
    }

    function subnamePermanent(bytes32 parentNode) public view returns (bool) {
        return _subnamePermanent[parentNode];
    }

    function subnamePrice(bytes32 parentNode) public view returns (uint256) {
        return _subnamePrices[parentNode];
    }

    // ---- Registration ----

    /// @notice Register `label`.arc for `newOwner`. 7+ chars free; 3-6 chars pay the
    /// tier price; 1-2 chars locked. Allowlisted accounts holding the orientation
    /// attestation (spec §17) are fee-exempt; allowlisted accounts without it pay
    /// as outsiders. Everyone else also pays the matching fee. Both go to the
    /// Splitter. Excess refunded.
    function register(string calldata label, address newOwner) external payable nonReentrant {
        bytes memory labelBytes = bytes(label);
        if (labelBytes.length == 0) revert LabelEmpty();
        if (labelBytes.length > MAX_LABEL_LENGTH) revert LabelTooLong();
        uint256 len = labelBytes.length;
        if (len < 3) revert NameLocked();
        if (newOwner == address(0)) revert ZeroAddress();

        bytes32 labelhash = keccak256(labelBytes);
        bytes32 node = keccak256(abi.encodePacked(ROOT_NODE, labelhash));
        address currentOwner = _registry.owner(node);
        bool released = _released[node];
        if (currentOwner != address(0) && !released) revert AlreadyRegistered();

        uint256 tierPrice;
        uint256 fee;
        if (_isFamilyFree(msg.sender)) {
            tierPrice = 0;
            fee = 0;
        } else {
            tierPrice = len >= 7 ? 0 : _tierPrices[len];
            fee = _matchingFee;
        }
        uint256 total = tierPrice + fee;
        if (msg.value < total) revert InsufficientPayment();

        _released[node] = false;
        _expiry[node] = uint64(block.timestamp) + TERM;
        _acquiredAt[node] = uint64(block.timestamp);
        _registry.setSubnodeOwner(ROOT_NODE, labelhash, newOwner);

        if (total > 0) _sendToSplitter(total);
        if (msg.value > total) _refund(msg.sender, msg.value - total);
        emit NameRegistered(node, label, newOwner, _expiry[node]);
    }

    // ---- Renewal: free forever ----

    /// @notice Renew `label`.arc for a fresh 2-year term. Free. During the 90-day
    /// grace period only the owner (or their operator) may renew. Parked names
    /// must use reclaim() instead. Renewals never reset the hold-clock.
    function renew(string calldata label) external nonReentrant {
        bytes32 node = _nodeForLabel(bytes(label));
        if (_parked[node].parkedAt != 0) revert AlreadyParked();
        address nodeOwner = _registry.owner(node);
        if (nodeOwner == address(0) || _released[node]) revert NotRegistered();
        if (msg.sender != nodeOwner && !_registry.isApprovedForAll(nodeOwner, msg.sender)) {
            revert Unauthorized();
        }
        uint64 expiry = _expiry[node];
        uint64 newExpiry;
        if (block.timestamp <= expiry) {
            newExpiry = expiry + TERM;
        } else {
            if (block.timestamp > expiry + GRACE_PERIOD) revert PastGrace();
            newExpiry = uint64(block.timestamp) + TERM;
        }
        _expiry[node] = newExpiry;
        emit NameRenewed(node, newExpiry);
    }

    // ---- Activity auto-renew (called by authorized resolvers) ----

    /// @notice Called by an authorized resolver on every record write: any
    /// owner-initiated use pushes the term to a full 2 years from now (never shorter).
    /// Parked names are skipped — they must be reclaimed.
    function pokeActivity(bytes32 node) external {
        if (!_notifiers[msg.sender]) revert Unauthorized();
        if (_parked[node].parkedAt != 0) return;
        if (_registry.owner(node) == address(0)) return;
        uint64 newExpiry = uint64(block.timestamp) + TERM;
        if (newExpiry > _expiry[node]) {
            _expiry[node] = newExpiry;
            emit ActivityPoked(node, newExpiry);
        }
    }

    // ---- Park / reclaim / release ----

    /// @notice Park an expired name: ownership is escrowed to this registrar and the
    /// resolver is cleared, so the name goes fully dormant (no transfers, no record
    /// writes, no listings). The previous owner may reclaim within a year.
    /// Vault-held brand reservations are exempt (spec §8): they never expire.
    /// Permissionless otherwise.
    function park(string calldata label) external nonReentrant {
        bytes32 node = _nodeForLabel(bytes(label));
        if (_parked[node].parkedAt != 0) revert AlreadyParked();
        address nodeOwner = _registry.owner(node);
        if (nodeOwner == address(0) || _released[node]) revert NotRegistered();
        if (nodeOwner == _brandVault) revert ParkExempt();
        if (block.timestamp <= _expiry[node] + GRACE_PERIOD) revert StillActive();
        _parked[node] =
            ParkRecord({prevOwner: nodeOwner, prevResolver: _registry.resolver(node), parkedAt: uint64(block.timestamp)});
        _registry.setOwner(node, address(this)); // escrow: registrar is a controller -> authorized
        _registry.setResolver(node, address(0)); // resolution stops
        emit NameParked(node, nodeOwner);
    }

    /// @notice Reclaim a parked name: restores ownership and the resolver, and grants
    /// a fresh 1-year term. Only the previous owner (or their operator) may reclaim.
    function reclaim(string calldata label) external nonReentrant {
        bytes32 node = _nodeForLabel(bytes(label));
        ParkRecord memory pr = _parked[node];
        if (pr.parkedAt == 0) revert NotParked();
        if (block.timestamp > pr.parkedAt + PARK_PERIOD) revert ParkExpired();
        if (msg.sender != pr.prevOwner && !_registry.isApprovedForAll(pr.prevOwner, msg.sender)) {
            revert Unauthorized();
        }
        delete _parked[node];
        uint64 newExpiry = uint64(block.timestamp) + RECLAIM_TERM;
        _expiry[node] = newExpiry;
        _registry.setOwner(node, pr.prevOwner);
        _registry.setResolver(node, pr.prevResolver);
        emit NameReclaimed(node, pr.prevOwner, newExpiry);
    }

    /// @notice Release a name whose park period elapsed: it returns to the public
    /// pool (<7 chars via the premium tier price again). Ownership stays escrowed
    /// until re-registered. Vault-held names can never reach this path (park
    /// rejects them), and the exemption is enforced here defensively too.
    /// Permissionless otherwise.
    function release(string calldata label) external nonReentrant {
        bytes32 node = _nodeForLabel(bytes(label));
        ParkRecord memory pr = _parked[node];
        if (pr.parkedAt == 0) revert NotParked();
        if (pr.prevOwner == _brandVault) revert ParkExempt();
        if (block.timestamp <= pr.parkedAt + PARK_PERIOD) revert ParkNotExpired();
        delete _parked[node];
        _expiry[node] = 0;
        _acquiredAt[node] = 0;
        _released[node] = true;
        emit NameReleased(node);
    }

    // ---- Marketplace hook ----

    /// @notice Called by the Marketplace after an atomic sale: the buyer gets a
    /// fresh 2-year term and the hold-clock restarts (fee curve starts over).
    function onMarketplaceSale(bytes32 node, address buyer) external {
        if (msg.sender != _marketplace) revert Unauthorized();
        if (buyer == address(0)) revert ZeroAddress();
        if (_registry.owner(node) != buyer) revert SaleNotSettled();
        _expiry[node] = uint64(block.timestamp) + TERM;
        _acquiredAt[node] = uint64(block.timestamp);
        emit TermResetOnSale(node, buyer, _expiry[node]);
    }

    /// @notice Called by the BrandVault after a claim or auction settlement: the
    /// buyer gets a fresh 2-year term and the hold-clock restarts — the same
    /// treatment as a marketplace sale (no decaying seed term, no fee head start).
    function onVaultAcquisition(bytes32 node, address buyer) external {
        if (msg.sender != _brandVault) revert Unauthorized();
        if (buyer == address(0)) revert ZeroAddress();
        if (_registry.owner(node) != buyer) revert SaleNotSettled();
        _expiry[node] = uint64(block.timestamp) + TERM;
        _acquiredAt[node] = uint64(block.timestamp);
        emit TermResetOnSale(node, buyer, _expiry[node]);
    }

    // ---- Subnames ----

    /// @notice Create `label` under `parentNode` for `newOwner`. The caller must own
    /// the parent (or be its operator). Subname expiry is bound: it never exceeds
    /// the parent's term. Parent-set price (free default) goes to the parent owner.
    /// Creating a subname also renews the parent's own term (owner-initiated use).
    function registerSubname(bytes32 parentNode, string calldata label, address newOwner)
        external
        payable
        nonReentrant
    {
        bytes memory labelBytes = bytes(label);
        if (labelBytes.length == 0) revert LabelEmpty();
        if (labelBytes.length > MAX_LABEL_LENGTH) revert LabelTooLong();
        if (newOwner == address(0)) revert ZeroAddress();
        address parentOwner = _registry.owner(parentNode);
        if (parentOwner == address(0) || block.timestamp > _expiry[parentNode]) revert ParentNotActive();
        if (msg.sender != parentOwner && !_registry.isApprovedForAll(parentOwner, msg.sender)) {
            revert Unauthorized();
        }
        bytes32 labelhash = keccak256(labelBytes);
        bytes32 subnode = keccak256(abi.encodePacked(parentNode, labelhash));
        // A subnode held by the parent owner is a revoked subname: re-registerable.
        address currentSubOwner = _registry.owner(subnode);
        if (currentSubOwner != address(0) && currentSubOwner != parentOwner) revert AlreadyRegistered();

        uint256 price = _subnamePrices[parentNode];
        if (msg.value < price) revert InsufficientPayment();

        // Parent activity: creating a subname renews the parent's term.
        uint64 parentExpiry = uint64(block.timestamp) + TERM;
        if (parentExpiry > _expiry[parentNode]) _expiry[parentNode] = parentExpiry;
        // Subname expiry bound to the parent's term.
        uint64 subExpiry = uint64(block.timestamp) + TERM;
        if (subExpiry > _expiry[parentNode]) subExpiry = _expiry[parentNode];
        _expiry[subnode] = subExpiry;
        _acquiredAt[subnode] = uint64(block.timestamp);

        _registry.setSubnodeOwner(parentNode, labelhash, newOwner);

        if (price > 0) _pay(parentOwner, price);
        if (msg.value > price) _refund(msg.sender, msg.value - price);
        emit SubnameRegistered(subnode, parentNode, label, newOwner, subExpiry);
    }

    /// @notice Renew a subname (owner, or the parent owner/operator). Still bound
    /// to the parent's term — it can never outlive the parent.
    function renewSubname(bytes32 parentNode, string calldata label) external nonReentrant {
        bytes32 subnode = _nodeForLabelUnder(parentNode, bytes(label));
        address subOwner = _registry.owner(subnode);
        if (subOwner == address(0)) revert NotRegistered();
        address parentOwner = _registry.owner(parentNode);
        bool isSubAuthorized = msg.sender == subOwner || _registry.isApprovedForAll(subOwner, msg.sender);
        bool isParentAuthorized =
            msg.sender == parentOwner || _registry.isApprovedForAll(parentOwner, msg.sender);
        if (!isSubAuthorized && !isParentAuthorized) revert Unauthorized();
        uint64 subExpiry = uint64(block.timestamp) + TERM;
        if (subExpiry > _expiry[parentNode]) subExpiry = _expiry[parentNode];
        _expiry[subnode] = subExpiry;
        emit SubnameRenewed(subnode, subExpiry);
    }

    /// @notice Revoke a subname back to the parent owner. Only while the parent's
    /// revocability setting is still revocable (the default).
    function revokeSubname(bytes32 parentNode, string calldata label) external nonReentrant {
        if (_subnamePermanent[parentNode]) revert SubnamePermanent();
        address parentOwner = _registry.owner(parentNode);
        if (msg.sender != parentOwner && !_registry.isApprovedForAll(parentOwner, msg.sender)) {
            revert Unauthorized();
        }
        bytes32 subnode = _nodeForLabelUnder(parentNode, bytes(label));
        if (_registry.owner(subnode) == address(0)) revert NotRegistered();
        _expiry[subnode] = 0;
        _acquiredAt[subnode] = 0;
        _registry.setSubnodeOwner(parentNode, keccak256(bytes(label)), parentOwner);
        emit SubnameRevoked(subnode, parentNode);
    }

    /// @notice Make this parent's subnames permanent. One-way: it cannot be undone.
    function makeSubnamesPermanent(bytes32 parentNode) external {
        address parentOwner = _registry.owner(parentNode);
        if (msg.sender != parentOwner && !_registry.isApprovedForAll(parentOwner, msg.sender)) {
            revert Unauthorized();
        }
        _subnamePermanent[parentNode] = true;
        emit SubnamePermanenceSet(parentNode);
    }

    /// @notice Set the price (native token) the parent charges per subname. Free by default.
    function setSubnamePrice(bytes32 parentNode, uint256 price) external {
        address parentOwner = _registry.owner(parentNode);
        if (msg.sender != parentOwner && !_registry.isApprovedForAll(parentOwner, msg.sender)) {
            revert Unauthorized();
        }
        _subnamePrices[parentNode] = price;
        emit SubnamePriceSet(parentNode, price);
    }

    // ---- Administration (all timelocked via DEFAULT_ADMIN_ROLE) ----

    /// @notice Set the one-time tier price for `length`-character names (3..6). PLACEHOLDER on testnet.
    function setTierPrice(uint256 length, uint256 price) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _tierPrices[length] = price;
        emit TierPriceUpdated(length, price);
    }

    /// @notice Set the flat outsider matching fee forwarded to the Splitter. PLACEHOLDER on testnet.
    function setMatchingFee(uint256 fee) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _matchingFee = fee;
        emit MatchingFeeUpdated(fee);
    }

    /// @notice Manage the family/verified allowlist (fee-exempt registrations).
    function setAllowlisted(address account, bool allowed) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _allowlisted[account] = allowed;
        emit AllowlistUpdated(account, allowed);
    }

    /// @notice Authorize a resolver to ping pokeActivity on record writes.
    function setNotifier(address resolver, bool authorized) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _notifiers[resolver] = authorized;
        emit NotifierUpdated(resolver, authorized);
    }

    /// @notice Set the Marketplace authorized to report sales.
    function setMarketplace(address marketplace_) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _marketplace = marketplace_;
        emit MarketplaceUpdated(marketplace_);
    }

    /// @notice Set the BrandVault whose held names are exempt from park/release
    /// (spec §8: vault-held reservations do not expire) and whose sales are
    /// reported via onVaultAcquisition.
    function setBrandVault(address brandVault_) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (brandVault_ == address(0)) revert ZeroAddress();
        _brandVault = brandVault_;
        emit BrandVaultUpdated(brandVault_);
    }

    /// @notice The BrandVault wired for the park exemption and acquisition hook.
    function brandVault() public view returns (address) {
        return _brandVault;
    }

    /// @notice Set the AttestationRegistry whose orientation attestation gates the
    /// family free path (spec §17).
    function setAttestationRegistry(address attestationRegistry_) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (attestationRegistry_ == address(0)) revert ZeroAddress();
        _attestations = IAttestationRegistry(attestationRegistry_);
        emit AttestationRegistryUpdated(attestationRegistry_);
    }

    /// @notice The AttestationRegistry gating the family free path.
    function attestationRegistry() public view returns (address) {
        return address(_attestations);
    }

    /// @notice Set the Splitter that receives tier prices and matching fees.
    function setSplitter(address splitter_) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (splitter_ == address(0)) revert ZeroAddress();
        _splitter = payable(splitter_);
        emit SplitterUpdated(splitter_);
    }

    /// @dev Upgrades are admin-only; the admin is the 7-day TimelockController.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ---- Internals ----

    /// @notice namehash for a top-level label (validates length).
    function _nodeForLabel(bytes memory labelBytes) internal pure returns (bytes32) {
        if (labelBytes.length == 0) revert LabelEmpty();
        if (labelBytes.length > MAX_LABEL_LENGTH) revert LabelTooLong();
        return keccak256(abi.encodePacked(ROOT_NODE, keccak256(labelBytes)));
    }

    /// @notice namehash for a label under `parentNode` (validates length).
    function _nodeForLabelUnder(bytes32 parentNode, bytes memory labelBytes) internal pure returns (bytes32) {
        if (labelBytes.length == 0) revert LabelEmpty();
        if (labelBytes.length > MAX_LABEL_LENGTH) revert LabelTooLong();
        return keccak256(abi.encodePacked(parentNode, keccak256(labelBytes)));
    }

    function _sendToSplitter(uint256 amount) internal {
        (bool ok, ) = _splitter.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }

    function _pay(address to, uint256 amount) internal {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }

    function _refund(address to, uint256 amount) internal {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }
}
