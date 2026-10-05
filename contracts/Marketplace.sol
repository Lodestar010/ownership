// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal view of the Registry the Marketplace needs.
interface IRegistry {
    function owner(bytes32 node) external view returns (address);
    function setOwner(bytes32 node, address newOwner) external;
    function isApprovedForAll(address owner_, address operator) external view returns (bool);
}

/// @notice Minimal view of the Registrar the Marketplace needs.
interface IRegistrar {
    function acquiredAtOf(bytes32 node) external view returns (uint64);
    function onMarketplaceSale(bytes32 node, address buyer) external;
}

/// @title Marketplace — optional on-chain venue for .arc resales
/// @notice Seller lists at a price; buyer pays; the transfer is atomic. Every sale
/// pays the commons fee to the Splitter, scaled by the seller's hold duration along
/// the locked quadratic curve: 20% on a day-0 flip decaying smoothly to a 2% floor
/// at 2+ years (feeBps = 200 + 1800*(730-daysHeld)^2/730^2). Every resale resets the
/// name's term to a full 2 years and restarts the hold-clock. P2P transfers outside
/// this venue are unrestricted and pay no fee (they also don't reset the term).
/// Sellers approve this contract as a registry operator once, then list freely.
/// @dev UUPS-upgradeable. Admin (DEFAULT_ADMIN_ROLE) is the 7-day TimelockController.
/// Compile with evmVersion "paris" or earlier — Arc rejects PUSH0.
contract Marketplace is AccessControlUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    /// @dev Locks the implementation contract itself against initialization.
    constructor() {
        _disableInitializers();
    }
    /// @notice Fee curve: 20% cap decaying quadratically to a 2% floor over 2 years. LOCKED.
    uint256 public constant FEE_CAP_BPS = 2000;
    uint256 public constant FEE_FLOOR_BPS = 200;
    uint256 public constant FEE_HORIZON_DAYS = 730;
    uint256 public constant BPS_DENOMINATOR = 10000;

    struct Listing {
        address seller;
        uint256 price;
        bool active;
    }

    IRegistry private _registry;
    IRegistrar private _registrar;
    address payable private _splitter;

    mapping(bytes32 => Listing) private _listings;
    /// @notice All nodes with an active listing, for on-chain enumeration (spec §16).
    /// Small dataset: readable without any indexer. Swap-and-pop on removal.
    bytes32[] private _activeListings;
    /// @notice node -> index+1 in _activeListings (0 = not listed).
    mapping(bytes32 => uint256) private _listingIndex;

    // ---- Events ----

    event Listed(bytes32 indexed node, address indexed seller, uint256 price);
    event ListingCancelled(bytes32 indexed node, address indexed seller);
    event Sold(bytes32 indexed node, address indexed seller, address indexed buyer, uint256 price, uint256 fee);
    event SplitterUpdated(address indexed splitter);

    // ---- Errors ----

    error Unauthorized();
    error ZeroAddress();
    error NotRegistered();
    error BadPrice();
    error NotListed();
    error SellerNotOwner();
    error MarketplaceNotApproved();
    error UnknownAcquisition();
    error InsufficientPayment();
    error PaymentFailed();
    error EmptyLabel();

    /// @param admin The 7-day TimelockController that administers this marketplace.
    /// @param registry_ The Registry.
    /// @param registrar_ The Registrar (hold-clock + term reset).
    /// @param splitter_ The Splitter that receives the commons fee.
    function initialize(address admin, address registry_, address registrar_, address splitter_)
        public
        initializer
    {
        if (admin == address(0) || registry_ == address(0) || registrar_ == address(0) || splitter_ == address(0)) {
            revert ZeroAddress();
        }
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _registry = IRegistry(registry_);
        _registrar = IRegistrar(registrar_);
        _splitter = payable(splitter_);
        emit SplitterUpdated(splitter_);
    }

    // ---- Views ----

    /// @notice The active listing for `label`, if any.
    function listingFor(string calldata label) public view returns (address seller, uint256 price, bool active) {
        Listing memory l = _listings[_nodeForLabel(bytes(label))];
        return (l.seller, l.price, l.active);
    }

    /// @notice Commons fee in basis points for selling `node` right now, from the
    /// seller's hold duration along the locked quadratic curve.
    function feeBpsFor(bytes32 node) public view returns (uint256) {
        uint64 acquiredAt = _registrar.acquiredAtOf(node);
        if (acquiredAt == 0) revert UnknownAcquisition();
        uint256 daysHeld = (block.timestamp - acquiredAt) / 1 days;
        if (daysHeld >= FEE_HORIZON_DAYS) return FEE_FLOOR_BPS;
        uint256 remaining = FEE_HORIZON_DAYS - daysHeld;
        return FEE_FLOOR_BPS
            + ((FEE_CAP_BPS - FEE_FLOOR_BPS) * remaining * remaining)
                / (FEE_HORIZON_DAYS * FEE_HORIZON_DAYS);
    }

    function splitter() public view returns (address) {
        return _splitter;
    }

    /// @notice Number of active listings (spec §16 on-chain enumeration).
    function activeListingCount() public view returns (uint256) {
        return _activeListings.length;
    }

    /// @notice The listed node at `index` (use with activeListingCount).
    function activeListingAt(uint256 index) public view returns (bytes32) {
        return _activeListings[index];
    }

    /// @notice Paginated active listings over [offset, offset+limit), for UIs.
    function getActiveListings(uint256 offset, uint256 limit) public view returns (bytes32[] memory) {
        uint256 total = _activeListings.length;
        if (offset >= total) return new bytes32[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        bytes32[] memory out = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) out[i - offset] = _activeListings[i];
        return out;
    }

    /// @notice Whether `node` currently has an active listing.
    function isListed(bytes32 node) public view returns (bool) {
        return _listingIndex[node] != 0;
    }

    // ---- Listing ----

    /// @notice List `label` for sale at `price` (native token). The seller must have
    /// approved this marketplace as a registry operator first (one-time).
    function list(string calldata label, uint256 price) public {
        bytes32 node = _nodeForLabel(bytes(label));
        address seller = _registry.owner(node);
        if (seller == address(0)) revert NotRegistered();
        if (msg.sender != seller && !_registry.isApprovedForAll(seller, msg.sender)) revert Unauthorized();
        if (price == 0) revert BadPrice();
        if (_registrar.acquiredAtOf(node) == 0) revert UnknownAcquisition();
        if (!_registry.isApprovedForAll(seller, address(this))) revert MarketplaceNotApproved();
        _listings[node] = Listing({seller: seller, price: price, active: true});
        if (_listingIndex[node] == 0) {
            _activeListings.push(node);
            _listingIndex[node] = _activeListings.length; // index+1
        }
        emit Listed(node, seller, price);
    }

    /// @notice Cancel the active listing for `label`. The seller, their operator, or
    /// the name's current owner (covers the P2P-transfer case, where the listing
    /// would otherwise be un-cancellable) may cancel.
    function cancelListing(string calldata label) public {
        bytes32 node = _nodeForLabel(bytes(label));
        Listing memory l = _listings[node];
        if (!l.active) revert NotListed();
        bool sellerAuthorized = msg.sender == l.seller || _registry.isApprovedForAll(l.seller, msg.sender);
        if (!sellerAuthorized && msg.sender != _registry.owner(node)) revert Unauthorized();
        delete _listings[node];
        _removeListing(node);
        emit ListingCancelled(node, l.seller);
    }

    // ---- Buying: atomic sale ----

    /// @notice Buy `label` at its listed price. Atomic: payment splits (commons fee
    /// to the Splitter, remainder to the seller), ownership moves to the buyer, and
    /// the Registrar resets the name to a fresh 2-year term with a restarted hold-clock.
    function buy(string calldata label) public payable nonReentrant {
        bytes32 node = _nodeForLabel(bytes(label));
        Listing memory l = _listings[node];
        if (!l.active) revert NotListed();
        address seller = l.seller;
        uint256 price = l.price;
        if (msg.value < price) revert InsufficientPayment();
        if (_registry.owner(node) != seller) revert SellerNotOwner();

        uint256 fee = (price * feeBpsFor(node)) / BPS_DENOMINATOR;
        uint256 sellerProceeds = price - fee;
        address buyer = msg.sender;

        delete _listings[node];
        _removeListing(node);
        _registry.setOwner(node, buyer); // marketplace is the seller's approved operator
        _registrar.onMarketplaceSale(node, buyer);

        if (fee > 0) _sendToSplitter(fee);
        if (sellerProceeds > 0) _pay(payable(seller), sellerProceeds);
        if (msg.value > price) _refund(buyer, msg.value - price);
        emit Sold(node, seller, buyer, price, fee);
    }

    /// @dev Swap-and-pop removal from the active-listings enumeration. No-op when
    /// the node is not tracked (defensive; all removals go through here).
    function _removeListing(bytes32 node) private {
        uint256 idxPlusOne = _listingIndex[node];
        if (idxPlusOne == 0) return;
        uint256 idx = idxPlusOne - 1;
        uint256 lastIdx = _activeListings.length - 1;
        if (idx != lastIdx) {
            bytes32 lastNode = _activeListings[lastIdx];
            _activeListings[idx] = lastNode;
            _listingIndex[lastNode] = idx + 1;
        }
        _activeListings.pop();
        delete _listingIndex[node];
    }

    // ---- Administration (timelocked via DEFAULT_ADMIN_ROLE) ----

    /// @notice Set the Splitter that receives the commons fee.
    function setSplitter(address splitter_) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (splitter_ == address(0)) revert ZeroAddress();
        _splitter = payable(splitter_);
        emit SplitterUpdated(splitter_);
    }

    /// @dev Upgrades are admin-only; the admin is the 7-day TimelockController.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ---- Internals ----

    function _nodeForLabel(bytes memory labelBytes) internal pure returns (bytes32) {
        if (labelBytes.length == 0) revert EmptyLabel();
        return keccak256(abi.encodePacked(bytes32(0), keccak256(labelBytes)));
    }

    function _sendToSplitter(uint256 amount) internal {
        (bool ok, ) = _splitter.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }

    function _pay(address payable to, uint256 amount) internal {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }

    function _refund(address to, uint256 amount) internal {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }
}
