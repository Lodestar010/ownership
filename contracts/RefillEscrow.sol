// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RefillEscrow — programmed reserve wallet (sponsorship wallet #4)
/// @notice Holds reserve funds and pushes refills to the three regional sponsor
/// wallets (USA, Europe, Asia/Africa). The refill wallet IS the escrow — no
/// separate contract.
///
/// Poke model: `poke(regional)` is permissionless — anyone may call it. The
/// escrow performs ALL checks and math on-chain: it reads the regional's native
/// balance, recomputes its daily cap (lazy, at most once per UTC day), and
/// pushes a top-up to 100% of cap iff: (1) the target is a registered regional,
/// (2) its balance is at or below the trigger threshold (default 90% spent),
/// (3) it has received fewer than maxPullsPerDay refills today, (4) the escrow
/// can cover the amount.
///
/// Regional wallets are fully passive except for one logic-free blind
/// `poke(address(this))` call in their sponsorship flow, giving near-atomic
/// poke timing. The escrow never reverts on a "no refill needed" poke — it
/// exits silently so the blind poke can never break a sponsorship transaction.
///
/// Circuit breaker: a 4th refill attempt in one UTC day moves no funds and
/// emits CircuitBreakerTripped (off-chain alert). Manual timelock paths:
/// approveExtraPulls (legit spike) or pauseWallet (suspected attack).
///
/// Daily caps adapt via moving average: seeds on day 1, seed weight shrinks
/// over the seed phase-out period (default 21 days), then a 21-day MA with
/// same-weekday weighting (2x) once >=3 samples per weekday exist.
///
/// The escrow pulls from the Splitter when its own balance drops below
/// escrowRefillThreshold (same poke pattern; bounded by escrow cap).
/// Inbound (Splitter->escrow) and outbound (escrow->regionals) flows have
/// independent timelock-gated pauses, plus an emergency drain to treasury.
///
/// All tunables are storage dials (timelock-gated). All testnet numeric values
/// are TEMPORARY placeholders flagged as such; real allocations are deferred
/// until post-grant + post-audit.
/// @dev UUPS-upgradeable. Admin (DEFAULT_ADMIN_ROLE) is the 7-day TimelockController.
/// Native token only (USDC is native on Arc). Compile with evmVersion "paris" or earlier.
contract RefillEscrow is AccessControlUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    /// @dev Locks the implementation contract itself against initialization.
    constructor() {
        _disableInitializers();
    }

    // ---- Constants ----

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MA_WINDOW = 21;
    uint8 public constant REGION_USA = 0;
    uint8 public constant REGION_EUROPE = 1;
    uint8 public constant REGION_ASIA_AFRICA = 2;
    uint8 public constant REGION_COUNT = 3;

    // ---- Regional state ----

    struct Regional {
        address wallet;          // registered regional wallet (address(0) = unset)
        address pendingWallet;   // two-step rotation: proposed replacement
        uint256 seedCap;         // TEMPORARY testnet cold-start seed
        uint256 currentCap;      // live daily cap (recomputed lazily)
        uint256 startDay;        // UTC day number the region was registered
        uint256 lastCapUpdate;   // UTC day number of last cap recalculation
    }

    mapping(uint8 => Regional) private _regionals;
    mapping(address => uint8) private _regionOf;      // wallet => region index
    mapping(address => bool) private _isRegistered;

    // Usage history: daily amounts refilled per regional (proxy for daily spend).
    mapping(address => mapping(uint256 => uint256)) private _dailyRefilled;
    // Refill counts per regional per UTC day (circuit breaker).
    mapping(address => mapping(uint256 => uint256)) private _refillsToday;

    // ---- Dials (all timelock-gated; testnet values are TEMPORARY) ----

    uint256 private _triggerBps;            // default 9000 = refill at 90% spent
    uint8 private _maxPullsPerDay;          // default 3
    uint8 private _seedPhaseOutDays;        // default 21
    uint256 private _escrowCap;             // default 25,000 USDC (native)
    uint256 private _escrowRefillThreshold; // pull from Splitter below this
    address private _splitter;              // Splitter contract address
    address private _treasury;              // Treasury wallet (overflow + emergency drain)

    // ---- Pauses ----

    bool private _outboundPaused;  // escrow -> regionals
    bool private _inboundPaused;   // splitter -> escrow

    // ---- Events ----

    event RegionalProposed(uint8 indexed region, address indexed newWallet);
    event RegionalAccepted(uint8 indexed region, address indexed newWallet, address indexed oldWallet);
    event RefillExecuted(address indexed regional, uint256 amount, uint256 newCap);
    event CircuitBreakerTripped(address indexed regional, uint256 refillsToday);
    event EscrowDepleted(uint256 shortfall);
    event CapRecalculated(address indexed regional, uint256 newCap);
    event DialChanged(string indexed name, uint256 newValue);
    event AddressDialChanged(string indexed name, address indexed newValue);
    event OutboundPaused(bool paused);
    event InboundPaused(bool paused);
    event EmergencyDrain(address indexed destination, uint256 amount);
    event SplitterPullExecuted(uint256 amount);
    event ExtraPullsApproved(address indexed regional, uint8 extraPulls);

    // ---- Errors ----

    error ZeroAddress();
    error NotRegistered();
    error NotProposed();
    error BadRegion();
    error TransferFailed();
    error OverEscrowCap();
    error SplitterNotSet();

    /// @param admin The 7-day TimelockController (testnet: DJ's EOA for iteration).
    /// @param treasury_ Treasury wallet (wallet #8): overflow destination + emergency drain default.
    /// @param splitter_ Splitter contract (for escrow refill pulls; may be address(0) on testnet).
    function initialize(address admin, address treasury_, address splitter_) public initializer {
        if (admin == address(0) || treasury_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _treasury = treasury_;
        _splitter = splitter_;

        // TEMPORARY testnet dials — flagged, not mainnet values.
        // NOTE: Arc native USDC uses 18 decimals (verified live on testnet).
        _triggerBps = 9000;                 // 90% spent trigger
        _maxPullsPerDay = 3;                // 3 refills/day/regional
        _seedPhaseOutDays = 21;             // seed fully phased out by day 21
        _escrowCap = 25000 * 1e18;          // 25,000 USDC (18 decimals, native on Arc)
        _escrowRefillThreshold = 5000 * 1e18; // pull from Splitter below 5,000

        emit AddressDialChanged("treasury", treasury_);
        emit AddressDialChanged("splitter", splitter_);
    }

    // ---- Poke (permissionless) ----

    /// @notice Check a regional and push a refill if all conditions hold.
    /// Never reverts on "no refill needed" — exits silently so the blind poke
    /// embedded in regional sponsorship flows can never break a user transaction.
    /// @param regional The regional wallet address to check.
    function poke(address regional) external nonReentrant {
        // Cheap early exits first (no state changes, minimal gas).
        if (_outboundPaused) return;
        if (!_isRegistered[regional]) return;

        uint256 today = block.timestamp / 86400;
        uint8 region = _regionOf[regional];
        Regional storage r = _regionals[region];

        uint256 cap = r.currentCap;
        uint256 balance = regional.balance;

        // Cheap trigger check before any expensive work.
        if (balance * BPS_DENOMINATOR > cap * _triggerBps) return;

        // Circuit breaker: daily refill limit reached.
        uint256 refills = _refillsToday[regional][today];
        if (refills >= _maxPullsPerDay) {
            emit CircuitBreakerTripped(regional, refills);
            return;
        }

        // Lazy cap recalculation: at most once per UTC day.
        if (r.lastCapUpdate < today) {
            cap = _calculateCap(region, today);
            r.currentCap = cap;
            r.lastCapUpdate = today;
            emit CapRecalculated(regional, cap);
        }

        // Re-check trigger against the (possibly new) cap.
        if (balance * BPS_DENOMINATOR > cap * _triggerBps) return;

        uint256 refillAmount = cap - balance;
        uint256 escrowBalance = address(this).balance;
        if (escrowBalance == 0) return;
        if (refillAmount > escrowBalance) {
            emit EscrowDepleted(refillAmount - escrowBalance);
            refillAmount = escrowBalance;
        }

        // Checks-effects-interactions: record before transfer.
        _dailyRefilled[regional][today] += refillAmount;
        _refillsToday[regional][today] = refills + 1;

        (bool ok, ) = regional.call{value: refillAmount}("");
        if (!ok) revert TransferFailed();

        emit RefillExecuted(regional, refillAmount, cap);
    }

    /// @notice View: would `poke(regional)` trigger a refill right now?
    function needsRefill(address regional) external view returns (bool) {
        if (_outboundPaused || !_isRegistered[regional]) return false;
        uint8 region = _regionOf[regional];
        uint256 cap = _regionals[region].currentCap;
        if (cap == 0) return false;
        uint256 today = block.timestamp / 86400;
        if (_refillsToday[regional][today] >= _maxPullsPerDay) return false;
        return regional.balance * BPS_DENOMINATOR <= cap * _triggerBps;
    }

    // ---- Cap calculation (moving average) ----

    /// @dev Computes the daily cap for a region: seed-weighted phase then 21-day
    /// MA with 2x same-weekday weighting (once >=3 same-weekday samples exist).
    function _calculateCap(uint8 region, uint256 today) internal view returns (uint256) {
        Regional storage r = _regionals[region];
        if (today <= r.startDay) return r.seedCap;

        uint256 todayWeekday = today % 7;

        // First pass: count same-weekday samples in the trailing window.
        uint256 sameWeekdayCount = 0;
        uint256 recordedDays = 0;
        for (uint256 i = 0; i < MA_WINDOW; i++) {
            // Guard against underflow on very early days.
            if (i + 1 > today) break;
            uint256 day = today - 1 - i;
            if (day < r.startDay) break;
            recordedDays++;
            if (day % 7 == todayWeekday) sameWeekdayCount++;
        }
        bool useWeekdayWeight = sameWeekdayCount >= 3;

        // Second pass: weighted sum of recorded usage.
        uint256 weightedSum = 0;
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < recordedDays; i++) {
            uint256 day = today - 1 - i;
            uint256 usage = _dailyRefilled[r.wallet][day];
            uint256 weight = (useWeekdayWeight && day % 7 == todayWeekday) ? 2 : 1;
            weightedSum += usage * weight;
            totalWeight += weight;
        }

        uint256 daysElapsed = today - r.startDay;
        if (daysElapsed < _seedPhaseOutDays) {
            // Seed phase: unrecorded days filled with the seed value.
            uint256 unrecordedDays = MA_WINDOW - recordedDays;
            return (weightedSum + r.seedCap * unrecordedDays) / (totalWeight + unrecordedDays);
        }
        if (totalWeight == 0) return r.seedCap;
        return weightedSum / totalWeight;
    }

    // ---- Splitter funding (escrow pulls when low) ----

    /// @notice Pull funds from the Splitter when the escrow balance is below threshold.
    /// Same poke pattern: anyone may call; the escrow decides. Bounded by escrow cap.
    function pullFromSplitter() external nonReentrant {
        if (_inboundPaused) return;
        if (_splitter == address(0)) revert SplitterNotSet();
        if (address(this).balance >= _escrowRefillThreshold) return;

        uint256 headroom = _escrowCap > address(this).balance
            ? _escrowCap - address(this).balance
            : 0;
        if (headroom == 0) return;

        uint256 before = address(this).balance;
        // The Splitter's fundEscrow() sends up to the escrow's cap; only callable by this escrow.
        (bool ok, ) = _splitter.call(abi.encodeWithSignature("fundEscrow()"));
        if (!ok) return; // Splitter upgrade pending — fail silently, DJ funds manually on testnet.
        uint256 received = address(this).balance - before;
        if (received > 0) emit SplitterPullExecuted(received);
    }

    /// @notice Accept deposits. Rejects over-cap deposits to enforce the escrow ceiling.
    receive() external payable {
        if (address(this).balance > _escrowCap) revert OverEscrowCap();
    }

    // ---- Regional registration (two-step) ----

    /// @notice Propose a regional wallet (timelock). The new wallet must accept.
    function proposeRegionalWallet(uint8 region, address newWallet)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (region >= REGION_COUNT) revert BadRegion();
        if (newWallet == address(0)) revert ZeroAddress();
        _regionals[region].pendingWallet = newWallet;
        emit RegionalProposed(region, newWallet);
    }

    /// @notice Accept a proposed regional wallet role. Called by the new wallet itself.
    /// Resets the region's daily refill counter and starts a fresh cap history.
    function acceptRegionalRole(uint8 region) external {
        if (region >= REGION_COUNT) revert BadRegion();
        Regional storage r = _regionals[region];
        if (msg.sender != r.pendingWallet) revert NotProposed();

        address oldWallet = r.wallet;
        if (oldWallet != address(0)) {
            _isRegistered[oldWallet] = false;
            delete _regionOf[oldWallet];
        }
        r.wallet = msg.sender;
        r.pendingWallet = address(0);
        _isRegistered[msg.sender] = true;
        _regionOf[msg.sender] = region;

        uint256 today = block.timestamp / 86400;
        r.startDay = today;
        r.lastCapUpdate = today;
        // currentCap already holds the seed (set at registration); fresh history starts now.

        emit RegionalAccepted(region, msg.sender, oldWallet);
    }

    /// @notice Register a regional wallet with its seed cap (initial setup or re-registration).
    /// TEMPORARY testnet seeds are passed here; mainnet values come post-grant + post-audit.
    function registerRegional(uint8 region, address wallet, uint256 seedCap)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (region >= REGION_COUNT) revert BadRegion();
        if (wallet == address(0)) revert ZeroAddress();
        Regional storage r = _regionals[region];

        address oldWallet = r.wallet;
        if (oldWallet != address(0)) {
            _isRegistered[oldWallet] = false;
            delete _regionOf[oldWallet];
        }
        r.wallet = wallet;
        r.pendingWallet = address(0);
        r.seedCap = seedCap;
        r.currentCap = seedCap;
        uint256 today = block.timestamp / 86400;
        r.startDay = today;
        r.lastCapUpdate = today;
        _isRegistered[wallet] = true;
        _regionOf[wallet] = region;

        emit RegionalAccepted(region, wallet, oldWallet);
    }

    // ---- Emergency controls (all timelock-gated) ----

    /// @notice Halt refills to regionals. Regionals keep operating on existing balances.
    function setOutboundPaused(bool paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _outboundPaused = paused;
        emit OutboundPaused(paused);
    }

    /// @notice Halt pulls from the Splitter. Escrow keeps refilling from existing balance.
    function setInboundPaused(bool paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _inboundPaused = paused;
        emit InboundPaused(paused);
    }

    /// @notice Pause/unpause a single regional wallet's refills (suspected attack).
    function setWalletPaused(address regional, bool paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_isRegistered[regional]) revert NotRegistered();
        // Pausing is implemented by toggling registration: a deregistered wallet
        // fails the poke check silently. Re-register to resume.
        _isRegistered[regional] = !paused;
    }

    /// @notice Approve extra refills for a regional today (legit demand spike, post-review).
    /// @param extraPulls Number of additional refills to allow beyond the daily max.
    function approveExtraPulls(address regional, uint8 extraPulls)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!_isRegistered[regional]) revert NotRegistered();
        uint256 today = block.timestamp / 86400;
        // Lift the cap by pretending fewer refills happened today.
        uint256 used = _refillsToday[regional][today];
        _refillsToday[regional][today] = used > extraPulls ? used - extraPulls : 0;
        emit ExtraPullsApproved(regional, extraPulls);
    }

    /// @notice Move all escrow funds to a destination (default: treasury).
    /// For use only if the escrow logic itself is compromised.
    function emergencyDrain(address destination) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address to = destination == address(0) ? _treasury : destination;
        uint256 amount = address(this).balance;
        _outboundPaused = true;
        _inboundPaused = true;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit EmergencyDrain(to, amount);
        emit OutboundPaused(true);
        emit InboundPaused(true);
    }

    // ---- Dials (all timelock-gated) ----

    function setTriggerBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _triggerBps = bps;
        emit DialChanged("triggerBps", bps);
    }

    function setMaxPullsPerDay(uint8 n) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _maxPullsPerDay = n;
        emit DialChanged("maxPullsPerDay", n);
    }

    function setSeedPhaseOutDays(uint8 n) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _seedPhaseOutDays = n;
        emit DialChanged("seedPhaseOutDays", n);
    }

    function setEscrowCap(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _escrowCap = cap;
        emit DialChanged("escrowCap", cap);
    }

    function setEscrowRefillThreshold(uint256 threshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _escrowRefillThreshold = threshold;
        emit DialChanged("escrowRefillThreshold", threshold);
    }

    function setSeedCap(uint8 region, uint256 seedCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (region >= REGION_COUNT) revert BadRegion();
        _regionals[region].seedCap = seedCap;
        emit DialChanged("seedCap", seedCap);
    }

    function setSplitter(address splitter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _splitter = splitter_;
        emit AddressDialChanged("splitter", splitter_);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        _treasury = treasury_;
        emit AddressDialChanged("treasury", treasury_);
    }

    // ---- Views ----

    function getRegional(uint8 region)
        external
        view
        returns (
            address wallet,
            address pendingWallet,
            uint256 seedCap,
            uint256 currentCap,
            uint256 startDay,
            uint256 lastCapUpdate
        )
    {
        if (region >= REGION_COUNT) revert BadRegion();
        Regional storage r = _regionals[region];
        return (r.wallet, r.pendingWallet, r.seedCap, r.currentCap, r.startDay, r.lastCapUpdate);
    }

    function isRegistered(address wallet) external view returns (bool) {
        return _isRegistered[wallet];
    }

    function refillsToday(address regional) external view returns (uint256) {
        return _refillsToday[regional][block.timestamp / 86400];
    }

    function dailyRefilled(address regional, uint256 day) external view returns (uint256) {
        return _dailyRefilled[regional][day];
    }

    function dials()
        external
        view
        returns (
            uint256 triggerBps,
            uint8 maxPullsPerDay,
            uint8 seedPhaseOutDays,
            uint256 escrowCap,
            uint256 escrowRefillThreshold,
            address splitter,
            address treasury,
            bool outboundPaused,
            bool inboundPaused
        )
    {
        return (
            _triggerBps,
            _maxPullsPerDay,
            _seedPhaseOutDays,
            _escrowCap,
            _escrowRefillThreshold,
            _splitter,
            _treasury,
            _outboundPaused,
            _inboundPaused
        );
    }

    /// @dev Upgrades are admin-only; the admin is the 7-day TimelockController.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
