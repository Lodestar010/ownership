// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal view of the Registry the BrandVault needs.
interface IRegistry {
    function owner(bytes32 node) external view returns (address);
    function resolver(bytes32 node) external view returns (address);
    function setOwner(bytes32 node, address newOwner) external;
    function setResolver(bytes32 node, address newResolver) external;
}

/// @notice Minimal view of the Registrar the BrandVault needs.
interface IRegistrar {
    function register(string calldata label, address newOwner) external payable;
    function tierPriceOf(uint256 length) external view returns (uint256);
    function onVaultAcquisition(bytes32 node, address buyer) external;
}

/// @notice Minimal view of the Resolver the BrandVault needs (verified-org mark).
interface IResolver {
    function setText(bytes32 node, string calldata key, string calldata value) external;
}

/// @title BrandVault — reserved brand names, ROFR claims, and scheduled auctions
/// @notice The vault *owns* reserved names (registered to itself at seed time), so the
/// Registrar naturally rejects them — no on-chain Merkle non-membership proofs needed.
/// The Merkle root is stored as the public transparency commitment for the full list.
/// Mark holders claim at the tier price after manual verification (corporate domain /
/// USPTO record -> allowlisted address). Unclaimed names go to public English auctions
/// in scheduled batches, rate-limited on-chain. All proceeds go to the Splitter.
/// The verified-org mark is a resolver text record (`org.verified`) attested while the
/// vault still owns the name — it survives transfer, so wallets can trust the mark.
/// @dev UUPS-upgradeable. Admin (DEFAULT_ADMIN_ROLE) is the 7-day TimelockController.
/// Compile with evmVersion "paris" or earlier — Arc rejects PUSH0.
contract BrandVault is AccessControlUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    /// @dev Locks the implementation contract itself against initialization.
    constructor() {
        _disableInitializers();
    }
    /// @notice Text-record key carrying the verified organization mark.
    string public constant ORG_MARK_KEY = "org.verified";
    /// @notice Rate-limit window for starting new auctions.
    uint256 public constant RATE_WINDOW = 30 days;

    struct Auction {
        uint64 startTime;
        uint64 endTime;
        address highestBidder;
        uint256 highestBid;
        bool settled;
        bool exists;
    }

    IRegistry private _registry;
    IRegistrar private _registrar;
    address payable private _splitter;
    /// @notice Resolver used when attesting the verified-org mark on a name with none set.
    address private _defaultResolver;

    /// @notice Transparency commitment for the full reserved-name list.
    bytes32 private _merkleRoot;
    /// @notice node -> address manually verified as the mark holder (may claim at tier price).
    mapping(bytes32 => address) private _claimAllowlist;
    /// @notice node -> active/finished auction.
    mapping(bytes32 => Auction) private _auctions;
    /// @notice node -> bidder -> outbid funds awaiting withdrawal.
    mapping(bytes32 => mapping(address => uint256)) private _pendingReturns;

    // Auction policy (admin-settable, timelocked; testnet defaults = locked values)
    uint64 private _auctionDuration = 3 days;
    uint256 private _minIncrementBps = 500; // 5%
    uint64 private _antiSnipeWindow = 10 minutes;
    uint256 private _maxAuctionsPerWindow = 10;
    uint64 private _windowStart;
    uint256 private _auctionsInWindow;

    // ---- Events ----

    event NameReserved(bytes32 indexed node, string label);
    event MerkleRootUpdated(bytes32 indexed root);
    event ClaimAllowlisted(bytes32 indexed node, address indexed claimer);
    event ReservedClaimed(bytes32 indexed node, address indexed claimer, uint256 price);
    event OrgAttested(bytes32 indexed node, string orgDescriptor);
    event AuctionStarted(bytes32 indexed node, uint64 endTime);
    event BidPlaced(bytes32 indexed node, address indexed bidder, uint256 amount, uint64 endTime);
    event AuctionSettled(bytes32 indexed node, address indexed winner, uint256 price);
    event AuctionCancelled(bytes32 indexed node);
    event Withdrawn(bytes32 indexed node, address indexed bidder, uint256 amount);
    event AuctionPolicyUpdated(uint64 duration, uint256 minIncrementBps, uint64 antiSnipeWindow, uint256 maxAuctionsPerWindow);
    event DefaultResolverUpdated(address indexed resolver);
    event SplitterUpdated(address indexed splitter);

    // ---- Errors ----

    error Unauthorized();
    error ZeroAddress();
    error NotVaultOwned();
    error AlreadyReserved();
    error NotAllowlistedClaimer();
    error NoActiveAuction();
    error AuctionEnded();
    error AuctionNotEnded();
    error BidTooLow();
    error InsufficientPayment();
    error PaymentFailed();
    error NothingToWithdraw();
    error AlreadySettled();
    error RateLimitExceeded();
    error AuctionAlreadyLive();
    error ClaimPending();
    error EmptyLabel();

    /// @param admin The 7-day TimelockController that administers this vault.
    /// @param registry_ The Registry.
    /// @param registrar_ The Registrar (this vault must be allowlisted there for free seeding).
    /// @param splitter_ The Splitter that receives claim payments and auction proceeds.
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
        _windowStart = uint64(block.timestamp);
        // NOTE: state-variable initializers do NOT run behind a UUPS proxy —
        // every default must be assigned here explicitly.
        _auctionDuration = 3 days;
        _minIncrementBps = 500; // 5%
        _antiSnipeWindow = 10 minutes;
        _maxAuctionsPerWindow = 10;
        emit SplitterUpdated(splitter_);
    }

    // ---- Views ----

    /// @notice Whether `node` is currently vault-held (reserved and not yet claimed/sold).
    function isReserved(bytes32 node) public view returns (bool) {
        return _registry.owner(node) == address(this);
    }

    function merkleRoot() public view returns (bytes32) {
        return _merkleRoot;
    }

    function claimerFor(bytes32 node) public view returns (address) {
        return _claimAllowlist[node];
    }

    function auctionFor(bytes32 node)
        public
        view
        returns (uint64 startTime, uint64 endTime, address highestBidder, uint256 highestBid, bool settled, bool exists)
    {
        Auction memory a = _auctions[node];
        return (a.startTime, a.endTime, a.highestBidder, a.highestBid, a.settled, a.exists);
    }

    function pendingReturn(bytes32 node, address bidder) public view returns (uint256) {
        return _pendingReturns[node][bidder];
    }

    function auctionPolicy()
        public
        view
        returns (uint64 duration, uint256 minIncrementBps, uint64 antiSnipeWindow, uint256 maxAuctionsPerWindow)
    {
        return (_auctionDuration, _minIncrementBps, _antiSnipeWindow, _maxAuctionsPerWindow);
    }

    function defaultResolver() public view returns (address) {
        return _defaultResolver;
    }

    function splitter() public view returns (address) {
        return _splitter;
    }

    // ---- Seeding: register reserved names to the vault ----

    /// @notice Register each label in `labels` to this vault (admin only). The vault
    /// must be allowlisted in the Registrar so seeding is free. 1-2 char names stay
    /// locked (registrar rule) — they join in the Phase 3+ special allocation.
    function reserveLabels(string[] calldata labels) public onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < labels.length; i++) {
            bytes32 node = _nodeForLabel(bytes(labels[i]));
            if (_registry.owner(node) != address(0)) revert AlreadyReserved();
            _registrar.register(labels[i], address(this));
            emit NameReserved(node, labels[i]);
        }
    }

    /// @notice Publish the Merkle root committing to the full reserved-name list
    /// (transparency; on-chain blocking works through vault ownership).
    function setMerkleRoot(bytes32 root) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _merkleRoot = root;
        emit MerkleRootUpdated(root);
    }

    // ---- Verified-org mark ----

    /// @notice Attest the verified organization mark on a vault-held name (admin only,
    /// after manual verification). Writes the `org.verified` text record through the
    /// name's resolver — call BEFORE the name leaves the vault; the mark survives transfer.
    function attestOrg(string calldata label, string calldata orgDescriptor)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        bytes32 node = _nodeForLabel(bytes(label));
        if (!isReserved(node)) revert NotVaultOwned();
        address resolver = _registry.resolver(node);
        if (resolver == address(0)) {
            if (_defaultResolver == address(0)) revert ZeroAddress();
            _registry.setResolver(node, _defaultResolver);
            resolver = _defaultResolver;
        }
        IResolver(resolver).setText(node, ORG_MARK_KEY, orgDescriptor);
        emit OrgAttested(node, orgDescriptor);
    }

    // ---- ROFR: mark-holder claims ----

    /// @notice Allowlist `claimer` as the verified holder for `label` (admin only,
    /// after manual verification via corporate domain / USPTO record).
    function setClaimAllowlist(string calldata label, address claimer) public onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 node = _nodeForLabel(bytes(label));
        if (!isReserved(node)) revert NotVaultOwned();
        if (claimer == address(0)) revert ZeroAddress();
        _claimAllowlist[node] = claimer;
        emit ClaimAllowlisted(node, claimer);
    }

    /// @notice The verified mark holder claims the reserved name at its tier price.
    /// Payment goes to the Splitter. (Delta rule for competing claimants is handled
    /// off-chain: first verified wins the bare name, runner-up gets a variant + package.)
    /// Reverts while a live auction exists for the name — claims and auctions are
    /// mutually exclusive. The buyer gets a fresh 2-year term via the Registrar.
    function claimReserved(string calldata label) public payable nonReentrant {
        bytes memory labelBytes = bytes(label);
        bytes32 node = _nodeForLabel(labelBytes);
        if (!isReserved(node)) revert NotVaultOwned();
        if (_claimAllowlist[node] != msg.sender) revert NotAllowlistedClaimer();
        Auction storage a = _auctions[node];
        if (a.exists && !a.settled) revert AuctionAlreadyLive();
        uint256 price = _registrar.tierPriceOf(labelBytes.length);
        if (msg.value < price) revert InsufficientPayment();

        delete _claimAllowlist[node];
        _registry.setOwner(node, msg.sender);
        _registrar.onVaultAcquisition(node, msg.sender);

        if (price > 0) _sendToSplitter(price);
        if (msg.value > price) _refund(msg.sender, msg.value - price);
        emit ReservedClaimed(node, msg.sender, price);
    }

    // ---- Auctions for unclaimed names ----

    /// @notice Start a public English auction for a vault-held name (admin only).
    /// Rate-limited on-chain: at most `_maxAuctionsPerWindow` new auctions per 30 days.
    /// Reverts if the name has a pending mark-holder claim — claims and auctions
    /// are mutually exclusive.
    function startAuction(string calldata label) public onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 node = _nodeForLabel(bytes(label));
        if (!isReserved(node)) revert NotVaultOwned();
        if (_claimAllowlist[node] != address(0)) revert ClaimPending();
        Auction storage a = _auctions[node];
        if (a.exists && !a.settled) revert AuctionAlreadyLive();

        if (block.timestamp >= _windowStart + RATE_WINDOW) {
            _windowStart = uint64(block.timestamp);
            _auctionsInWindow = 0;
        }
        if (_auctionsInWindow >= _maxAuctionsPerWindow) revert RateLimitExceeded();
        _auctionsInWindow++;

        uint64 endTime = uint64(block.timestamp) + _auctionDuration;
        _auctions[node] = Auction({
            startTime: uint64(block.timestamp),
            endTime: endTime,
            highestBidder: address(0),
            highestBid: 0,
            settled: false,
            exists: true
        });
        emit AuctionStarted(node, endTime);
    }

    /// @notice Bid on a live auction. Bids must beat the current high by the minimum
    /// increment; bids in the anti-snipe window extend the auction. Outbid funds are
    /// withdrawable (pull pattern). The full bid value locks as the new high bid —
    /// there are no partial bids, so nothing is "refunded" as excess.
    function bid(string calldata label) public payable nonReentrant {
        bytes32 node = _nodeForLabel(bytes(label));
        Auction storage a = _auctions[node];
        if (!a.exists || a.settled) revert NoActiveAuction();
        if (block.timestamp >= a.endTime) revert AuctionEnded();

        uint256 minBid = a.highestBid == 0 ? 1 : (a.highestBid * (10000 + _minIncrementBps)) / 10000;
        if (msg.value < minBid) revert BidTooLow();

        address prevBidder = a.highestBidder;
        uint256 prevBid = a.highestBid;
        a.highestBidder = msg.sender;
        a.highestBid = msg.value;
        if (a.endTime - block.timestamp < _antiSnipeWindow) {
            a.endTime = uint64(block.timestamp) + _antiSnipeWindow;
        }
        if (prevBidder != address(0)) {
            _pendingReturns[node][prevBidder] += prevBid;
        }
        emit BidPlaced(node, msg.sender, msg.value, a.endTime);
    }

    /// @notice Withdraw outbid funds for an auction (pull pattern).
    function withdraw(string calldata label) public nonReentrant {
        bytes32 node = _nodeForLabel(bytes(label));
        uint256 amount = _pendingReturns[node][msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        _pendingReturns[node][msg.sender] = 0;
        _refund(msg.sender, amount);
        emit Withdrawn(node, msg.sender, amount);
    }

    /// @notice Settle a finished auction: the name goes to the highest bidder and the
    /// proceeds go to the Splitter. With no bids, the name simply stays vault-held.
    /// The winner gets a fresh 2-year term via the Registrar.
    function settleAuction(string calldata label) public nonReentrant {
        bytes32 node = _nodeForLabel(bytes(label));
        Auction storage a = _auctions[node];
        if (!a.exists || a.settled) revert NoActiveAuction();
        if (block.timestamp < a.endTime) revert AuctionNotEnded();
        a.settled = true;
        address winner = a.highestBidder;
        uint256 price = a.highestBid;
        if (winner != address(0)) {
            _registry.setOwner(node, winner);
            _registrar.onVaultAcquisition(node, winner);
            _sendToSplitter(price);
        }
        emit AuctionSettled(node, winner, price);
    }

    /// @notice Cancel a live auction (admin only). The high bidder's funds become
    /// withdrawable; the name stays vault-held.
    function cancelAuction(string calldata label) public onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        bytes32 node = _nodeForLabel(bytes(label));
        Auction storage a = _auctions[node];
        if (!a.exists || a.settled) revert NoActiveAuction();
        a.settled = true;
        if (a.highestBidder != address(0)) {
            _pendingReturns[node][a.highestBidder] += a.highestBid;
        }
        emit AuctionCancelled(node);
    }

    // ---- Administration (all timelocked via DEFAULT_ADMIN_ROLE) ----

    /// @notice Tune the auction policy. Testnet defaults: 3-day auctions, 5% min
    /// increment, 10-minute anti-snipe, max 10 new auctions per 30 days.
    function setAuctionPolicy(
        uint64 duration,
        uint256 minIncrementBps,
        uint64 antiSnipeWindow,
        uint256 maxAuctionsPerWindow
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _auctionDuration = duration;
        _minIncrementBps = minIncrementBps;
        _antiSnipeWindow = antiSnipeWindow;
        _maxAuctionsPerWindow = maxAuctionsPerWindow;
        emit AuctionPolicyUpdated(duration, minIncrementBps, antiSnipeWindow, maxAuctionsPerWindow);
    }

    /// @notice Set the resolver used when attesting the org mark on names with none set.
    function setDefaultResolver(address resolver) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _defaultResolver = resolver;
        emit DefaultResolverUpdated(resolver);
    }

    /// @notice Set the Splitter that receives claim payments and auction proceeds.
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

    function _refund(address to, uint256 amount) internal {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }
}
