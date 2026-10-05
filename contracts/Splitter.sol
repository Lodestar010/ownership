// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Splitter — divides all naming-service income three ways
/// @notice Receives tier sales, marketplace fees, auction proceeds, outsider matching
/// fees (and later B2B/package revenue, sponsor placements). Anyone may call
/// distribute() to split the current native balance by the configured percentages
/// to the three purpose-wallets: sponsor pool, family treasury, security fund.
/// Percentage changes are admin-only (timelocked). Wallet addresses are deploy-time
/// parameters; who owns them is deferred to the trust-law/entity review.
/// @dev UUPS-upgradeable. Admin (DEFAULT_ADMIN_ROLE) is the 7-day TimelockController.
/// Native token only on testnet. Compile with evmVersion "paris" or earlier.
contract Splitter is AccessControlUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    /// @dev Locks the implementation contract itself against initialization.
    constructor() {
        _disableInitializers();
    }
    uint256 public constant BPS_DENOMINATOR = 10000;

    address payable private _sponsorPool;
    address payable private _familyTreasury;
    address payable private _securityFund;

    uint256 private _sponsorBps;
    uint256 private _treasuryBps;
    uint256 private _securityBps;

    // ---- Events ----

    event WalletsUpdated(address indexed sponsorPool, address indexed familyTreasury, address indexed securityFund);
    event PercentagesUpdated(uint256 sponsorBps, uint256 treasuryBps, uint256 securityBps);
    event Distributed(
        address indexed sponsorPool,
        address indexed familyTreasury,
        address indexed securityFund,
        uint256 sponsorShare,
        uint256 treasuryShare,
        uint256 securityShare,
        uint256 leftover
    );

    // ---- Errors ----

    error ZeroAddress();
    error BadPercentages();
    error PaymentFailed();

    /// @param admin The 7-day TimelockController that administers this splitter.
    /// @param sponsorPool_ Gas sponsorship wallet (funds the paymaster deposit).
    /// @param familyTreasury_ Project revenue wallet.
    /// @param securityFund_ Audits, bounties, monitoring wallet.
    /// @param sponsorBps_ Treasury / security basis points (must sum to 10000). PLACEHOLDER on testnet.
    function initialize(
        address admin,
        address sponsorPool_,
        address familyTreasury_,
        address securityFund_,
        uint256 sponsorBps_,
        uint256 treasuryBps_,
        uint256 securityBps_
    ) public initializer {
        if (
            admin == address(0) || sponsorPool_ == address(0) || familyTreasury_ == address(0)
                || securityFund_ == address(0)
        ) revert ZeroAddress();
        if (sponsorBps_ + treasuryBps_ + securityBps_ != BPS_DENOMINATOR) revert BadPercentages();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _sponsorPool = payable(sponsorPool_);
        _familyTreasury = payable(familyTreasury_);
        _securityFund = payable(securityFund_);
        _sponsorBps = sponsorBps_;
        _treasuryBps = treasuryBps_;
        _securityBps = securityBps_;
        emit WalletsUpdated(sponsorPool_, familyTreasury_, securityFund_);
        emit PercentagesUpdated(sponsorBps_, treasuryBps_, securityBps_);
    }

    // ---- Views ----

    function wallets()
        public
        view
        returns (address sponsorPool, address familyTreasury, address securityFund)
    {
        return (_sponsorPool, _familyTreasury, _securityFund);
    }

    function percentages() public view returns (uint256 sponsorBps, uint256 treasuryBps, uint256 securityBps) {
        return (_sponsorBps, _treasuryBps, _securityBps);
    }

    // ---- Distribution (pull pattern: anyone may trigger) ----

    /// @notice Split the current balance by the configured percentages. Integer-division
    /// dust stays behind for the next call.
    function distribute() public nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) return;
        uint256 sponsorShare = (balance * _sponsorBps) / BPS_DENOMINATOR;
        uint256 treasuryShare = (balance * _treasuryBps) / BPS_DENOMINATOR;
        uint256 securityShare = (balance * _securityBps) / BPS_DENOMINATOR;
        uint256 leftover = balance - sponsorShare - treasuryShare - securityShare;
        if (sponsorShare > 0) _pay(_sponsorPool, sponsorShare);
        if (treasuryShare > 0) _pay(_familyTreasury, treasuryShare);
        if (securityShare > 0) _pay(_securityFund, securityShare);
        emit Distributed(_sponsorPool, _familyTreasury, _securityFund, sponsorShare, treasuryShare, securityShare, leftover);
    }

    receive() external payable {}

    // ---- Administration (all timelocked via DEFAULT_ADMIN_ROLE) ----

    /// @notice Update the three purpose-wallets (ownership deferred to trust-law review).
    function setWallets(address sponsorPool_, address familyTreasury_, address securityFund_)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (sponsorPool_ == address(0) || familyTreasury_ == address(0) || securityFund_ == address(0)) {
            revert ZeroAddress();
        }
        _sponsorPool = payable(sponsorPool_);
        _familyTreasury = payable(familyTreasury_);
        _securityFund = payable(securityFund_);
        emit WalletsUpdated(sponsorPool_, familyTreasury_, securityFund_);
    }

    /// @notice Update the split percentages (must sum to 10000). PLACEHOLDER ratios on testnet.
    function setPercentages(uint256 sponsorBps_, uint256 treasuryBps_, uint256 securityBps_)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (sponsorBps_ + treasuryBps_ + securityBps_ != BPS_DENOMINATOR) revert BadPercentages();
        _sponsorBps = sponsorBps_;
        _treasuryBps = treasuryBps_;
        _securityBps = securityBps_;
        emit PercentagesUpdated(sponsorBps_, treasuryBps_, securityBps_);
    }

    /// @dev Upgrades are admin-only; the admin is the 7-day TimelockController.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ---- Internals ----

    function _pay(address payable to, uint256 amount) internal {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }
}
