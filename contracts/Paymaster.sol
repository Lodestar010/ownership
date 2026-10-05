// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
// Note: we do NOT use OZ's MessageHashUtils — it imports Strings -> Bytes, which uses
// the Cancun-only MCOPY opcode and will not compile for the paris target Arc requires.
// The "\x19Ethereum Signed Message:\n32" prefix is inlined below instead.

/// @notice Minimal ERC-4337 v0.7 EntryPoint interface (deposit + stake accounting).
interface IEntryPoint {
    function depositTo(address account) external payable;
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external;
    function balanceOf(address account) external view returns (uint256);
    function addStake(uint32 unstakeDelaySec) external payable;
    function unlockStake() external;
    function withdrawStake(address payable withdrawAddress) external;
}

/// @notice ERC-4337 v0.7 packed user operation (fields we read).
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}

enum PostOpMode {
    opSucceeded,
    opReverted,
    postOpReverted
}

/// @title ArcPaymaster — verifying paymaster sponsoring .arc onboarding operations
/// @notice Sponsors gas for registrations, renewals, record updates, and
/// parent-authorized subnames on Arc Testnet. A trusted off-chain verifying signer
/// (testnet: a small service Douglas runs; mainnet: hardened signer infra) pre-validates
/// each operation and signs the canonical v0.7 operation digest (which excludes
/// paymasterAndData and the account signature, so signing is never circular)
/// together with (validUntil, validAfter, opType).
/// On-chain, this contract fails closed: it only sponsors calls whose (target,
/// selector) pair is allowlisted for the declared op type, parsed from the account's
/// single `execute(address,uint256,bytes)` call (SimpleAccount convention).
///
/// Sybil resistance is two-tier: public per-day caps per op type, and a family/verified
/// allowlist with a higher multiplier. Deposit health degrades automatically:
///   deposit >= lowThreshold      -> normal caps
///   criticalThreshold <= deposit < lowThreshold -> tightened (public caps halved)
///   deposit < criticalThreshold  -> free tier paused (user-paid txs always work)
/// The paymaster can only sponsor gas — it cannot take names, touch user funds, or
/// block user-paid transactions.
/// @dev UUPS-upgradeable. Admin (DEFAULT_ADMIN_ROLE) is the 7-day TimelockController;
/// GUARDIAN_ROLE (Douglas / family multisig) tightens or pauses instantly.
/// Compile with evmVersion "paris" or earlier — Arc rejects PUSH0.
contract ArcPaymaster is AccessControlUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    /// @dev Locks the implementation contract itself against initialization.
    constructor() {
        _disableInitializers();
    }
    using ECDSA for bytes32;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Sponsorable operation types. 0 = not allowlisted.
    uint8 public constant OP_NONE = 0;
    uint8 public constant OP_REGISTER = 1;
    uint8 public constant OP_RENEW = 2;
    uint8 public constant OP_RECORD = 3;
    uint8 public constant OP_SUBNAME = 4;

    /// @notice SimpleAccount.execute(address,uint256,bytes) selector (v0.6/v0.7 convention).
    bytes4 public constant EXECUTE_SELECTOR = 0xb61d27f6;
    /// @notice paymasterAndData prefix length: paymaster(20) + verificationGas(16) + postOpGas(16).
    uint256 public constant PAYMASTER_DATA_OFFSET = 52;

    IEntryPoint private _entryPoint;
    /// @notice Off-chain verifying signer (EOA, personal_sign / toEthSignedMessageHash).
    address private _verifyingSigner;
    /// @notice Vault that is the ONLY permitted withdrawal destination.
    address payable private _vault;

    /// @notice target -> selector -> allowed op type (0 = not allowed).
    mapping(address => mapping(bytes4 => uint8)) private _targetAllowlist;
    /// @notice Base (public) daily caps per op type.
    mapping(uint8 => uint256) private _dailyCaps;
    /// @notice Family/verified allowlist: higher caps.
    mapping(address => bool) private _sybilAllowlist;
    /// @notice Multiplier applied to base caps for allowlisted senders.
    uint256 private _allowlistMultiplier = 4;
    /// @notice sender -> opType -> dayNumber -> sponsored count.
    mapping(address => mapping(uint8 => mapping(uint256 => uint256))) private _usage;

    uint256 private _lowThreshold;
    uint256 private _criticalThreshold;
    bool private _paused;

    // ---- Events ----

    event UserOpSponsored(address indexed sender, uint8 indexed opType, address indexed target, bytes4 selector);
    event PostOpObserved(PostOpMode indexed mode, uint256 actualGasCost);
    event TargetAllowlistUpdated(address indexed target, bytes4 indexed selector, uint8 opType);
    event DailyCapUpdated(uint8 indexed opType, uint256 newCap);
    event CapsTightened(uint8 indexed opType, uint256 oldCap, uint256 newCap);
    event SybilAllowlistUpdated(address indexed account, bool allowed);
    event AllowlistMultiplierUpdated(uint256 multiplier);
    event ThresholdsUpdated(uint256 lowThreshold, uint256 criticalThreshold);
    event VerifyingSignerUpdated(address indexed signer);
    event VaultUpdated(address indexed vault);
    event DepositAdded(uint256 amount);
    event WithdrawnToVault(uint256 amount);
    event Staked(uint256 amount, uint32 unstakeDelaySec);
    event StakeUnlocked();
    event StakeWithdrawn(address indexed to);
    event Paused();
    event Unpaused();

    // ---- Errors ----

    error ZeroAddress();
    error OnlyEntryPoint();
    error Paused_();
    error DepositCritical();
    error BadSignature();
    error BadPaymasterData();
    error Expired();
    error NotYetValid();
    error BadOpType();
    error TargetNotAllowlisted();
    error UnsupportedAccountCall();
    error DailyCapExceeded();
    error InsufficientDeposit();
    error CapNotTightened();
    error PaymentFailed();

    /// @param admin The 7-day TimelockController.
    /// @param guardian Emergency actor (Douglas -> family multisig): instant tighten/pause.
    /// @param entryPoint_ Canonical EntryPoint v0.7 on Arc.
    /// @param verifyingSigner_ Off-chain verifying signer address.
    /// @param vault_ ONLY permitted withdrawal destination.
    /// @param lowThreshold_ Deposit below this -> tightened caps (native-token wei; PLACEHOLDER).
    /// @param criticalThreshold_ Deposit below this -> free tier paused (PLACEHOLDER).
    function initialize(
        address admin,
        address guardian,
        address entryPoint_,
        address verifyingSigner_,
        address vault_,
        uint256 lowThreshold_,
        uint256 criticalThreshold_
    ) public initializer {
        if (
            admin == address(0) || guardian == address(0) || entryPoint_ == address(0)
                || verifyingSigner_ == address(0) || vault_ == address(0)
        ) revert ZeroAddress();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
        _entryPoint = IEntryPoint(entryPoint_);
        _verifyingSigner = verifyingSigner_;
        _vault = payable(vault_);
        _lowThreshold = lowThreshold_;
        _criticalThreshold = criticalThreshold_;
        // Locked public caps: 5 registrations / 50 renewals / 50 record updates / 20 subnames per day.
        _dailyCaps[OP_REGISTER] = 5;
        _dailyCaps[OP_RENEW] = 50;
        _dailyCaps[OP_RECORD] = 50;
        _dailyCaps[OP_SUBNAME] = 20;
        // State-variable initializers do NOT run behind a UUPS proxy — assign explicitly.
        _allowlistMultiplier = 4;
        emit VerifyingSignerUpdated(verifyingSigner_);
        emit VaultUpdated(vault_);
        emit ThresholdsUpdated(lowThreshold_, criticalThreshold_);
    }

    // ---- Views ----

    function entryPoint() public view returns (address) {
        return address(_entryPoint);
    }

    function verifyingSigner() public view returns (address) {
        return _verifyingSigner;
    }

    function vault() public view returns (address) {
        return _vault;
    }

    function depositBalance() public view returns (uint256) {
        return _entryPoint.balanceOf(address(this));
    }

    function thresholds() public view returns (uint256 lowThreshold, uint256 criticalThreshold) {
        return (_lowThreshold, _criticalThreshold);
    }

    function paused() public view returns (bool) {
        return _paused;
    }

    function dailyCapOf(uint8 opType) public view returns (uint256) {
        return _dailyCaps[opType];
    }

    function allowlistMultiplier() public view returns (uint256) {
        return _allowlistMultiplier;
    }

    function isSybilAllowlisted(address account) public view returns (bool) {
        return _sybilAllowlist[account];
    }

    function allowedOpType(address target, bytes4 selector) public view returns (uint8) {
        return _targetAllowlist[target][selector];
    }

    /// @notice Remaining free ops for `sender`/`opType` today under the current deposit health.
    function remainingQuota(address sender, uint8 opType) public view returns (uint256) {
        uint256 cap = _effectiveCap(sender, opType);
        uint256 used = _usage[sender][opType][block.timestamp / 1 days];
        return used >= cap ? 0 : cap - used;
    }

    // ---- ERC-4337 v0.7 paymaster entry points ----

    /// @notice Validate a userOp for sponsorship. Fails closed on every check.
    /// @dev The `userOpHash` supplied by the EntryPoint is intentionally ignored:
    /// it commits to paymasterAndData (which carries this paymaster's signature),
    /// so signing over it would be circular. We verify the signature over the
    /// canonical v0.7 digest instead (see _verifySponsorship).
    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256 maxCost)
        external
        returns (bytes memory context, uint256 validationData)
    {
        if (msg.sender != address(_entryPoint)) revert OnlyEntryPoint();
        if (_paused) revert Paused_();

        uint256 currentDeposit = _entryPoint.balanceOf(address(this));
        if (currentDeposit < _criticalThreshold) revert DepositCritical();
        if (currentDeposit < maxCost) revert InsufficientDeposit();

        (uint48 validUntil, uint48 validAfter, uint8 opType) = _verifySponsorship(userOp);

        // Parse the account's single execute() call and check the (target, selector) allowlist.
        (address target, bytes4 selector) = _parseExecute(userOp.callData);
        uint8 allowed = _targetAllowlist[target][selector];
        if (allowed == OP_NONE || allowed != opType) revert TargetNotAllowlisted();

        _consumeQuota(userOp.sender, opType);

        emit UserOpSponsored(userOp.sender, opType, target, selector);
        validationData = (uint256(validAfter) << 208) | (uint256(validUntil) << 160);
        return ("", validationData);
    }

    /// @notice Post-execution hook: observes the actual gas cost for sponsor accounting.
    function postOp(PostOpMode mode, bytes calldata, uint256 actualGasCost, uint256) external {
        if (msg.sender != address(_entryPoint)) revert OnlyEntryPoint();
        emit PostOpObserved(mode, actualGasCost);
    }

    // ---- Deposit management ----

    /// @notice Top up the EntryPoint deposit (anyone may fund the sponsor pool).
    function deposit() public payable nonReentrant {
        _entryPoint.depositTo{value: msg.value}(address(this));
        emit DepositAdded(msg.value);
    }

    /// @notice Sweep any native balance held directly into the EntryPoint deposit.
    function sweepToDeposit() public nonReentrant {
        uint256 amount = address(this).balance;
        if (amount > 0) {
            _entryPoint.depositTo{value: amount}(address(this));
            emit DepositAdded(amount);
        }
    }

    /// @notice Withdraw deposit to the vault ONLY (admin/timelocked).
    function withdrawToVault(uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        _entryPoint.withdrawTo(_vault, amount);
        emit WithdrawnToVault(amount);
    }

    /// @notice Stake native tokens with the EntryPoint (guardian-gated). Staking is
    /// required under ERC-7562: this paymaster writes its own storage (quota
    /// accounting) during validation, which conforming bundlers only accept from
    /// staked entities. Without stake, sponsored ops are rejected at simulation.
    function stake(uint32 unstakeDelaySec) public payable onlyRole(GUARDIAN_ROLE) nonReentrant {
        _entryPoint.addStake{value: msg.value}(unstakeDelaySec);
        emit Staked(msg.value, unstakeDelaySec);
    }

    /// @notice Begin the stake unlock countdown (guardian-gated).
    function unlockStake() public onlyRole(GUARDIAN_ROLE) {
        _entryPoint.unlockStake();
        emit StakeUnlocked();
    }

    /// @notice Withdraw unlocked stake to `to` (guardian-gated).
    function withdrawStake(address payable to) public onlyRole(GUARDIAN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _entryPoint.withdrawStake(to);
        emit StakeWithdrawn(to);
    }

    receive() external payable {}

    // ---- Guardian: instant tighten / pause (emergency powers) ----

    function pause() public onlyRole(GUARDIAN_ROLE) {
        _paused = true;
        emit Paused();
    }

    function unpause() public onlyRole(GUARDIAN_ROLE) {
        _paused = false;
        emit Unpaused();
    }

    /// @notice Instantly tighten a cap (new cap must be strictly lower). Loosening is admin/timelocked.
    function tightenCap(uint8 opType, uint256 newCap) public onlyRole(GUARDIAN_ROLE) {
        if (opType == OP_NONE || opType > OP_SUBNAME) revert BadOpType();
        uint256 oldCap = _dailyCaps[opType];
        if (newCap >= oldCap) revert CapNotTightened();
        _dailyCaps[opType] = newCap;
        emit CapsTightened(opType, oldCap, newCap);
    }

    /// @notice Emergency verifying-signer rotation (compromise response).
    function rotateSigner(address newSigner) public onlyRole(GUARDIAN_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();
        _verifyingSigner = newSigner;
        emit VerifyingSignerUpdated(newSigner);
    }

    // ---- Admin (timelocked): loosening, policy, upgrades ----

    /// @notice Set base daily caps (loosening included — timelocked).
    function setDailyCaps(uint256 registerCap, uint256 renewCap, uint256 recordCap, uint256 subnameCap)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _dailyCaps[OP_REGISTER] = registerCap;
        _dailyCaps[OP_RENEW] = renewCap;
        _dailyCaps[OP_RECORD] = recordCap;
        _dailyCaps[OP_SUBNAME] = subnameCap;
        emit DailyCapUpdated(OP_REGISTER, registerCap);
        emit DailyCapUpdated(OP_RENEW, renewCap);
        emit DailyCapUpdated(OP_RECORD, recordCap);
        emit DailyCapUpdated(OP_SUBNAME, subnameCap);
    }

    /// @notice Allowlist a (target, selector) pair for an op type (0 removes it).
    function setTargetAllowed(address target, bytes4 selector, uint8 opType) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (opType > OP_SUBNAME) revert BadOpType();
        _targetAllowlist[target][selector] = opType;
        emit TargetAllowlistUpdated(target, selector, opType);
    }

    /// @notice Manage the family/verified Sybil allowlist (higher caps).
    function setSybilAllowlisted(address account, bool allowed) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _sybilAllowlist[account] = allowed;
        emit SybilAllowlistUpdated(account, allowed);
    }

    /// @notice Set the cap multiplier for allowlisted senders.
    function setAllowlistMultiplier(uint256 multiplier) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _allowlistMultiplier = multiplier;
        emit AllowlistMultiplierUpdated(multiplier);
    }

    /// @notice Set the deposit degradation thresholds (loosening-adjacent — timelocked).
    function setThresholds(uint256 lowThreshold_, uint256 criticalThreshold_)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _lowThreshold = lowThreshold_;
        _criticalThreshold = criticalThreshold_;
        emit ThresholdsUpdated(lowThreshold_, criticalThreshold_);
    }

    /// @notice Set the vault (ONLY permitted withdrawal destination — timelocked).
    function setVault(address vault_) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vault_ == address(0)) revert ZeroAddress();
        _vault = payable(vault_);
        emit VaultUpdated(vault_);
    }

    /// @dev Upgrades are admin-only; the admin is the 7-day TimelockController.
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ---- Internals ----

    /// @dev Effective daily cap for a sender: allowlisted senders get the multiplier;
    /// public caps halve when the deposit is in the tightened band.
    function _effectiveCap(address sender, uint8 opType) internal view returns (uint256) {
        uint256 cap = _dailyCaps[opType];
        if (_sybilAllowlist[sender]) return cap * _allowlistMultiplier;
        if (_entryPoint.balanceOf(address(this)) < _lowThreshold) return cap / 2;
        return cap;
    }

    /// @dev Decode paymasterData, enforce the time window, and verify the off-chain
    /// signer's signature over the canonical v0.7 operation digest. The digest
    /// commits to every userOp field EXCEPT paymasterAndData (which carries this
    /// paymaster's signature) and the account signature — mirroring the reference
    /// VerifyingPaymaster / Circle's SponsorPaymaster — so signing is never
    /// circular: the signer can always compute the digest before signing.
    /// Returns (validUntil, validAfter, opType).
    /// paymasterData layout: abi.encode(uint48 validUntil, uint48 validAfter, uint8 opType, bytes signature)
    function _verifySponsorship(PackedUserOperation calldata userOp)
        internal
        view
        returns (uint48 validUntil, uint48 validAfter, uint8 opType)
    {
        bytes calldata paymasterAndData = userOp.paymasterAndData;
        if (paymasterAndData.length < PAYMASTER_DATA_OFFSET) revert BadPaymasterData();
        bytes calldata pmData = paymasterAndData[PAYMASTER_DATA_OFFSET:];
        bytes memory signature;
        (validUntil, validAfter, opType, signature) = abi.decode(pmData, (uint48, uint48, uint8, bytes));
        if (opType == OP_NONE || opType > OP_SUBNAME) revert BadOpType();
        if (validUntil < block.timestamp) revert Expired();
        if (validAfter > block.timestamp) revert NotYetValid();

        // Canonical digest: pack everything up to (but excluding) paymasterAndData,
        // then bind the gas limits, chain, this paymaster, the time window and op type.
        bytes32 digest = _sponsorshipDigest(userOp, validUntil, validAfter, opType);
        // Equivalent of MessageHashUtils.toEthSignedMessageHash(digest): EIP-191 personal_sign
        // prefix, so the verifying signer can be a plain EOA.
        bytes32 ethSignedDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        if (ECDSA.recover(ethSignedDigest, signature) != _verifyingSigner) revert BadSignature();
    }

    /// @dev Canonical v0.7 sponsorship digest. Commits to the sender, nonce, hashed
    /// initCode/callData, gas limits and fees, the paymaster gas limits from
    /// paymasterAndData, the chain, this paymaster, the time window and the op type.
    /// paymasterAndData itself (which carries the signature) and the account
    /// signature are excluded, so signing is never circular.
    /// paymasterAndData layout: paymaster(20) | verificationGas(16) | postOpGas(16) | data
    function _sponsorshipDigest(
        PackedUserOperation calldata userOp,
        uint48 validUntil,
        uint48 validAfter,
        uint8 opType
    ) internal view returns (bytes32) {
        bytes32 opPart = keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees
            )
        );
        bytes calldata paymasterAndData = userOp.paymasterAndData;
        uint128 verificationGasLimit = uint128(bytes16(paymasterAndData[20:36]));
        uint128 postOpGasLimit = uint128(bytes16(paymasterAndData[36:52]));
        return keccak256(
            abi.encode(
                opPart,
                verificationGasLimit,
                postOpGasLimit,
                block.chainid,
                address(this),
                validUntil,
                validAfter,
                opType
            )
        );
    }

    /// @dev Enforce the per-day quota for a sender + op type (reverts when exhausted).
    function _consumeQuota(address sender, uint8 opType) internal {
        uint256 day = block.timestamp / 1 days;
        uint256 cap = _effectiveCap(sender, opType);
        if (_usage[sender][opType][day] >= cap) revert DailyCapExceeded();
        _usage[sender][opType][day]++;
    }

    /// @dev Parse a SimpleAccount single `execute(address,uint256,bytes)` call into (target, selector).
    function _parseExecute(bytes calldata callData) internal pure returns (address target, bytes4 selector) {
        if (callData.length < 4 || bytes4(callData[0:4]) != EXECUTE_SELECTOR) revert UnsupportedAccountCall();
        bytes memory func;
        (target, , func) = abi.decode(callData[4:], (address, uint256, bytes));
        if (func.length < 4) revert UnsupportedAccountCall();
        selector = bytes4(func);
    }
}
