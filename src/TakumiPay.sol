// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TakumiWallet
/// @notice Payment contract supporting ERC20 + native token transactions and point deposits.
///         Deployed behind a UUPS proxy for upgradeability.
/// @dev Storage layout must never be reordered between upgrades. Append new slots only.
///      Storage gap __gap reserves 50 slots for future base-contract extensions.
contract TakumiWallet is Initializable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ====== Roles ======

    address public owner;
    address public pendingOwner; // two-step ownership transfer
    mapping(address => bool) private admins;
    address[] private adminList;
    mapping(address => uint256) private adminListIndex; // 1-based index for O(1) removal

    // ====== Global Pause ======

    bool public paused;

    // ====== Spending Limits ======

    mapping(address => uint256) public maxTransactionAmount; // token => max amount (0 = no limit)

    // ====== Withdrawal Timelock ======

    uint256 public withdrawalDelay;
    uint256 public constant MAX_WITHDRAWAL_DELAY = 7 days;
    uint256 private withdrawalNonce;

    // ====== Input Validation ======

    uint256 public constant MAX_STRING_LENGTH = 256;
    uint256 public constant MAX_PAGINATION_LIMIT = 500;

    struct WithdrawalRequest {
        address token;
        address to;
        uint256 amount;
        uint256 unlockTime;
        bool executed;
        bool cancelled;
    }

    mapping(bytes32 => WithdrawalRequest) public withdrawalRequests;

    // ====== Transactions ======

    uint256 public txCounter;

    struct Transaction {
        address walletAddress;
        address tokenAddress; // address(0) = native token (ETH, MATIC, etc.)
        string bookingId;
        uint256 exchangeRateId;
        string productVariantId;
        uint256 timestamp;
        string refId;
        uint256 amount;
    }

    struct TransactionParams {
        string bookingId;
        uint256 exchangeRateId;
        string productVariantId;
        address tokenAddress;
        string refId;
        uint256 amount;
    }

    mapping(uint256 => Transaction) public transactions;
    mapping(address => uint256[]) private userTransactions;
    mapping(string => uint256) private refToTx;

    // ====== Point Deposits ======

    uint256 public pointDepositCounter;

    struct PointDeposit {
        address walletAddress;
        address tokenAddress;
        uint256 amount;
        string refId;
        uint256 timestamp;
    }

    mapping(uint256 => PointDeposit) public pointDeposits;
    mapping(string => uint256) private pointRefToDeposit;
    mapping(address => uint256[]) private userPointDeposits;

    mapping(address => bool) public allowedPointTokens;
    address[] private allowedPointTokenList;
    mapping(address => uint256) private allowedPointTokenListIndex; // 1-based index for O(1) removal
    bool public pointDepositsPaused;

    // ====== Storage Gap ======
    // Reserve 50 slots for future upgrades. Decrement when adding new state variables.

    uint256[50] private __gap;

    // ====== Events ======

    event TransactionCreated(
        uint256 indexed txId,
        address indexed walletAddress,
        address indexed tokenAddress,
        string bookingId,
        uint256 exchangeRateId,
        string productVariantId,
        uint256 timestamp,
        string refId,
        uint256 amount
    );
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event Withdraw(address indexed to, address indexed token, uint256 amount);
    event NativeDeposit(address indexed from, uint256 amount);
    event ContractPausedToggled(bool paused);
    event MaxTransactionAmountUpdated(address indexed token, uint256 amount);
    event WithdrawalQueued(
        bytes32 indexed withdrawalId,
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 unlockTime
    );
    event WithdrawalExecuted(bytes32 indexed withdrawalId);
    event WithdrawalCancelled(bytes32 indexed withdrawalId);
    event WithdrawalDelayUpdated(uint256 delay);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);
    event PointDepositCreated(
        uint256 indexed depositId,
        address indexed walletAddress,
        address indexed tokenAddress,
        string refId,
        uint256 amount,
        uint256 timestamp
    );
    event PointTokenAdded(address indexed token);
    event PointTokenRemoved(address indexed token);
    event PointDepositsPausedToggled(bool paused);
    event OwnershipTransferInitiated(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferCancelled(address indexed cancelledPendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Upgraded(address indexed implementation);

    // ====== Errors ======

    error NotOwner();
    error NotAdminOrOwner();
    error ContractPaused();
    error PointDepositsPaused();
    error ZeroAddress();
    error ZeroAmount();
    error AlreadyOwner();
    error NotPendingOwner();

    // ====== Modifiers ======

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAdminOrOwner() {
        if (msg.sender != owner && !admins[msg.sender]) revert NotAdminOrOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier whenPointDepositsActive() {
        if (pointDepositsPaused) revert PointDepositsPaused();
        _;
    }

    // ====== Constructor / Initializer ======

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy. Must be called exactly once after deployment.
    /// @param initialOwner Address that will own the contract.
    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        owner = initialOwner;
    }

    // ====== UUPS Upgrade Authorization ======

    /// @dev Only the owner may authorize an implementation upgrade.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Returns the current implementation version string.
    function version() external pure virtual returns (string memory) {
        return "1.0.0";
    }

    // ====== Ownership Transfer (two-step pattern) ======
    // Prevents permanently losing the contract to a wrong address.

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        if (newOwner == owner) revert AlreadyOwner();
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previousOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, owner);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        address cancelled = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferCancelled(cancelled);
    }

    // ====== Global Pause ======

    function setPaused(bool _paused) external onlyAdminOrOwner {
        paused = _paused;
        emit ContractPausedToggled(_paused);
    }

    // ====== Spending Limits ======

    function setMaxTransactionAmount(address token, uint256 amount) external onlyOwner {
        maxTransactionAmount[token] = amount;
        emit MaxTransactionAmountUpdated(token, amount);
    }

    // ====== Create Transaction (supports ERC20 + Native) ======

    function createTransaction(
        string calldata bookingId,
        uint256 exchangeRateId,
        string calldata productVariantId,
        address tokenAddress,
        string calldata refId,
        uint256 amount
    ) external payable whenNotPaused nonReentrant {
        _validateStrings(bookingId, productVariantId, refId);
        if (tokenAddress == address(0)) {
            require(msg.value == amount, "Incorrect amount sent");
        } else {
            require(msg.value == 0, "ETH not required for ERC20");
            uint256 balanceBefore = IERC20(tokenAddress).balanceOf(address(this));
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
            require(
                IERC20(tokenAddress).balanceOf(address(this)) - balanceBefore == amount,
                "Fee-on-transfer tokens not supported"
            );
        }
        _recordTransaction(msg.sender, bookingId, exchangeRateId, productVariantId, tokenAddress, refId, amount);
    }

    // ====== Batch Transaction Creation ======

    function createTransactionBatch(TransactionParams[] calldata params) external payable whenNotPaused nonReentrant {
        uint256 len = params.length;
        require(len > 0, "Empty batch");
        require(len <= 20, "Batch too large");

        // Phase 1: Validate all params and compute expected ETH total
        uint256 totalNative = 0;
        for (uint256 i = 0; i < len; i++) {
            require(params[i].amount > 0, "Amount must be greater than 0");
            _validateStrings(params[i].bookingId, params[i].productVariantId, params[i].refId);

            // Check existing refIds before any transfers
            require(refToTx[params[i].refId] == 0, "refId must be unique");

            if (params[i].tokenAddress == address(0)) {
                totalNative += params[i].amount;
            }

            // Check spending limits upfront
            uint256 maxAmt = maxTransactionAmount[params[i].tokenAddress];
            if (maxAmt > 0) {
                require(params[i].amount <= maxAmt, "Amount exceeds spending limit");
            }
        }
        require(msg.value == totalNative, "Incorrect ETH amount for batch");

        // Phase 2: Check intra-batch duplicate refIds (O(n^2), max 20 items = max 190 iterations)
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                require(
                    keccak256(bytes(params[i].refId)) != keccak256(bytes(params[j].refId)),
                    "Duplicate refId in batch"
                );
            }
        }

        // Phase 3: Execute all ERC20 transfers
        for (uint256 i = 0; i < len; i++) {
            if (params[i].tokenAddress != address(0)) {
                uint256 balanceBefore = IERC20(params[i].tokenAddress).balanceOf(address(this));
                IERC20(params[i].tokenAddress).safeTransferFrom(msg.sender, address(this), params[i].amount);
                require(
                    IERC20(params[i].tokenAddress).balanceOf(address(this)) - balanceBefore == params[i].amount,
                    "Fee-on-transfer tokens not supported"
                );
            }
        }

        // Phase 4: Record all transactions (state updates after all external calls)
        for (uint256 i = 0; i < len; i++) {
            TransactionParams calldata p = params[i];
            _recordTransactionUnchecked(msg.sender, p.bookingId, p.exchangeRateId, p.productVariantId, p.tokenAddress, p.refId, p.amount);
        }
    }

    function _recordTransaction(
        address sender,
        string calldata bookingId,
        uint256 exchangeRateId,
        string calldata productVariantId,
        address tokenAddress,
        string calldata refId,
        uint256 amount
    ) internal {
        require(refToTx[refId] == 0, "refId must be unique");
        require(amount > 0, "Amount must be greater than 0");

        uint256 maxAmt = maxTransactionAmount[tokenAddress];
        if (maxAmt > 0) {
            require(amount <= maxAmt, "Amount exceeds spending limit");
        }

        _recordTransactionUnchecked(sender, bookingId, exchangeRateId, productVariantId, tokenAddress, refId, amount);
    }

    // Internal writer — assumes all validation already done (used by batch after pre-validation)
    function _recordTransactionUnchecked(
        address sender,
        string calldata bookingId,
        uint256 exchangeRateId,
        string calldata productVariantId,
        address tokenAddress,
        string calldata refId,
        uint256 amount
    ) internal {
        txCounter += 1;
        transactions[txCounter] = Transaction({
            walletAddress: sender,
            tokenAddress: tokenAddress,
            bookingId: bookingId,
            exchangeRateId: exchangeRateId,
            productVariantId: productVariantId,
            timestamp: block.timestamp,
            refId: refId,
            amount: amount
        });

        userTransactions[sender].push(txCounter);
        refToTx[refId] = txCounter;

        emit TransactionCreated(
            txCounter,
            sender,
            tokenAddress,
            bookingId,
            exchangeRateId,
            productVariantId,
            block.timestamp,
            refId,
            amount
        );
    }

    // ====== Withdrawals (ERC20 + Native) ======
    // Note: withdraw/withdrawAll bypass the timelock and are only permitted when
    // withdrawalDelay == 0. When a timelock is configured, use queueWithdrawal +
    // executeWithdrawal for all withdrawals.

    error TimelockActive();

    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (withdrawalDelay > 0) revert TimelockActive();
        _doWithdraw(token, to, amount);
    }

    function withdrawAll(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (withdrawalDelay > 0) revert TimelockActive();
        uint256 balance = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        require(balance > 0, "No balance");
        _doWithdraw(token, to, balance);
    }

    function _doWithdraw(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            require(address(this).balance >= amount, "Insufficient ETH balance");
            (bool ok,) = payable(to).call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Withdraw(to, token, amount);
    }

    // ====== Withdrawal Timelock ======

    function setWithdrawalDelay(uint256 delay) external onlyOwner {
        require(delay <= MAX_WITHDRAWAL_DELAY, "Delay exceeds maximum");
        withdrawalDelay = delay;
        emit WithdrawalDelayUpdated(delay);
    }

    function queueWithdrawal(address token, address to, uint256 amount) external onlyOwner returns (bytes32) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        require(withdrawalDelay > 0, "Set a withdrawal delay before queuing");

        withdrawalNonce += 1;
        bytes32 withdrawalId = keccak256(abi.encodePacked(token, to, amount, block.timestamp, withdrawalNonce));
        uint256 unlockTime = block.timestamp + withdrawalDelay;

        withdrawalRequests[withdrawalId] = WithdrawalRequest({
            token: token,
            to: to,
            amount: amount,
            unlockTime: unlockTime,
            executed: false,
            cancelled: false
        });

        emit WithdrawalQueued(withdrawalId, token, to, amount, unlockTime);
        return withdrawalId;
    }

    function executeWithdrawal(bytes32 withdrawalId) external onlyOwner nonReentrant {
        WithdrawalRequest storage req = withdrawalRequests[withdrawalId];
        require(req.unlockTime > 0, "Withdrawal not found");
        require(!req.executed, "Already executed");
        require(!req.cancelled, "Already cancelled");
        require(block.timestamp >= req.unlockTime, "Timelock not expired");

        // Effects before interactions (CEI pattern)
        req.executed = true;
        _doWithdraw(req.token, req.to, req.amount);
        emit WithdrawalExecuted(withdrawalId);
    }

    function cancelWithdrawal(bytes32 withdrawalId) external onlyOwner {
        WithdrawalRequest storage req = withdrawalRequests[withdrawalId];
        require(req.unlockTime > 0, "Withdrawal not found");
        require(!req.executed, "Already executed");
        require(!req.cancelled, "Already cancelled");
        req.cancelled = true;
        emit WithdrawalCancelled(withdrawalId);
    }

    // ====== Token Recovery ======

    function recoverToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (withdrawalDelay > 0) revert TimelockActive();
        if (token == address(0)) {
            require(address(this).balance >= amount, "Insufficient ETH balance");
            (bool ok,) = payable(to).call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit TokenRecovered(token, to, amount);
    }

    // ====== ETH Direct Deposit Handling ======

    receive() external payable nonReentrant {
        emit NativeDeposit(msg.sender, msg.value);
    }

    // ====== Admin Management ======

    function addAdmin(address admin) external onlyOwner {
        if (admin == address(0)) revert ZeroAddress();
        require(!admins[admin], "Already admin");
        admins[admin] = true;
        adminList.push(admin);
        adminListIndex[admin] = adminList.length; // 1-based index
        emit AdminAdded(admin);
    }

    function removeAdmin(address admin) external onlyOwner {
        require(admins[admin], "Not an admin");
        require(adminListIndex[admin] > 0, "Admin index inconsistency");
        admins[admin] = false;

        // Swap-and-pop to keep array compact and avoid stale entries
        uint256 idx = adminListIndex[admin] - 1; // convert to 0-based
        uint256 lastIdx = adminList.length - 1;
        if (idx != lastIdx) {
            address last = adminList[lastIdx];
            adminList[idx] = last;
            adminListIndex[last] = idx + 1; // update 1-based index
        }
        adminList.pop();
        delete adminListIndex[admin];

        emit AdminRemoved(admin);
    }

    function getAllAdmins() external view onlyOwner returns (address[] memory) {
        return adminList;
    }

    function isAdmin(address admin) external view returns (bool) {
        return admins[admin];
    }

    // ====== Transaction View Functions ======

    function getUserTransactions(uint256 offset, uint256 limit) external view returns (Transaction[] memory) {
        require(limit <= MAX_PAGINATION_LIMIT, "Limit too large");
        return _paginateTx(userTransactions[msg.sender], offset, limit);
    }

    function getTransactionsByAddress(address user, uint256 offset, uint256 limit)
        external
        view
        onlyAdminOrOwner
        returns (Transaction[] memory)
    {
        require(limit <= MAX_PAGINATION_LIMIT, "Limit too large");
        return _paginateTx(userTransactions[user], offset, limit);
    }

    function _paginateTx(uint256[] storage txIds, uint256 offset, uint256 limit)
        internal
        view
        returns (Transaction[] memory)
    {
        uint256 total = txIds.length;
        if (offset >= total) return new Transaction[](0);
        uint256 size = _min(limit, total - offset);
        Transaction[] memory result = new Transaction[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = transactions[txIds[offset + i]];
        }
        return result;
    }

    function getTransactionByRef(string calldata refId) external view onlyAdminOrOwner returns (Transaction memory) {
        uint256 txId = refToTx[refId];
        require(txId != 0, "Transaction not found");
        return transactions[txId];
    }

    function getUserTransactionCount(address user) external view onlyAdminOrOwner returns (uint256) {
        return userTransactions[user].length;
    }

    // Warning: this function iterates all transactions and should only be called off-chain.
    // Enforce a hard cap on `limit` to prevent excessive memory allocation.
    function getTransactionsInRange(uint256 start, uint256 end, uint256 offset, uint256 limit)
        external
        view
        onlyAdminOrOwner
        returns (Transaction[] memory)
    {
        require(limit <= MAX_PAGINATION_LIMIT, "Limit too large");
        require(start <= end, "Invalid range");

        // First pass: count matching transactions to size the temp array
        uint256 count = 0;
        for (uint256 i = 1; i <= txCounter; i++) {
            uint256 ts = transactions[i].timestamp;
            if (ts >= start && ts <= end) {
                count++;
            }
        }

        if (offset >= count) return new Transaction[](0);
        uint256 size = _min(limit, count - offset);
        Transaction[] memory result = new Transaction[](size);

        // Second pass: fill result with pagination
        uint256 matched = 0;
        uint256 filled = 0;
        for (uint256 i = 1; i <= txCounter && filled < size; i++) {
            Transaction memory txData = transactions[i];
            if (txData.timestamp >= start && txData.timestamp <= end) {
                if (matched >= offset) {
                    result[filled] = txData;
                    filled++;
                }
                matched++;
            }
        }

        return result;
    }

    // ====== Point Deposit Functions ======

    function depositPoints(address tokenAddress, string calldata refId, uint256 amount)
        external
        whenNotPaused
        whenPointDepositsActive
        nonReentrant
    {
        require(allowedPointTokens[tokenAddress], "Token not allowed for point deposits");
        require(pointRefToDeposit[refId] == 0, "refId already used");
        require(amount > 0, "Amount must be greater than 0");
        require(bytes(refId).length > 0 && bytes(refId).length <= MAX_STRING_LENGTH, "Invalid refId length");

        uint256 balanceBefore = IERC20(tokenAddress).balanceOf(address(this));
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        require(
            IERC20(tokenAddress).balanceOf(address(this)) - balanceBefore == amount,
            "Fee-on-transfer tokens not supported"
        );

        pointDepositCounter += 1;
        pointDeposits[pointDepositCounter] = PointDeposit({
            walletAddress: msg.sender,
            tokenAddress: tokenAddress,
            amount: amount,
            refId: refId,
            timestamp: block.timestamp
        });

        userPointDeposits[msg.sender].push(pointDepositCounter);
        pointRefToDeposit[refId] = pointDepositCounter;

        emit PointDepositCreated(pointDepositCounter, msg.sender, tokenAddress, refId, amount, block.timestamp);
    }

    // ====== Point Deposit View Functions ======

    function getPointDepositByRef(string calldata refId)
        external
        view
        onlyAdminOrOwner
        returns (PointDeposit memory)
    {
        uint256 depositId = pointRefToDeposit[refId];
        require(depositId != 0, "Point deposit not found");
        return pointDeposits[depositId];
    }

    function getPointDepositsByAddress(address user, uint256 offset, uint256 limit)
        external
        view
        onlyAdminOrOwner
        returns (PointDeposit[] memory)
    {
        require(limit <= MAX_PAGINATION_LIMIT, "Limit too large");
        return _paginateDeposit(userPointDeposits[user], offset, limit);
    }

    function getUserPointDeposits(uint256 offset, uint256 limit) external view returns (PointDeposit[] memory) {
        require(limit <= MAX_PAGINATION_LIMIT, "Limit too large");
        return _paginateDeposit(userPointDeposits[msg.sender], offset, limit);
    }

    function getUserPointDepositCount(address user) external view onlyAdminOrOwner returns (uint256) {
        return userPointDeposits[user].length;
    }

    function _paginateDeposit(uint256[] storage ids, uint256 offset, uint256 limit)
        internal
        view
        returns (PointDeposit[] memory)
    {
        uint256 total = ids.length;
        if (offset >= total) return new PointDeposit[](0);
        uint256 size = _min(limit, total - offset);
        PointDeposit[] memory result = new PointDeposit[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = pointDeposits[ids[offset + i]];
        }
        return result;
    }

    // ====== Point Token Whitelist Management ======

    function addAllowedPointToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        require(!allowedPointTokens[token], "Token already allowed");
        allowedPointTokens[token] = true;
        allowedPointTokenList.push(token);
        allowedPointTokenListIndex[token] = allowedPointTokenList.length; // 1-based index
        emit PointTokenAdded(token);
    }

    function removeAllowedPointToken(address token) external onlyOwner {
        require(allowedPointTokens[token], "Token not in whitelist");
        require(allowedPointTokenListIndex[token] > 0, "Token index inconsistency");
        allowedPointTokens[token] = false;

        // Swap-and-pop to keep array compact and avoid stale entries
        uint256 idx = allowedPointTokenListIndex[token] - 1; // convert to 0-based
        uint256 lastIdx = allowedPointTokenList.length - 1;
        if (idx != lastIdx) {
            address last = allowedPointTokenList[lastIdx];
            allowedPointTokenList[idx] = last;
            allowedPointTokenListIndex[last] = idx + 1; // update 1-based index
        }
        allowedPointTokenList.pop();
        delete allowedPointTokenListIndex[token];

        emit PointTokenRemoved(token);
    }

    function getAllowedPointTokens() external view returns (address[] memory) {
        return allowedPointTokenList;
    }

    function isAllowedPointToken(address token) external view returns (bool) {
        return allowedPointTokens[token];
    }

    // ====== Point Deposit Pause Control ======

    function setPointDepositsPaused(bool _paused) external onlyAdminOrOwner {
        pointDepositsPaused = _paused;
        emit PointDepositsPausedToggled(_paused);
    }

    // ====== Helpers ======

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _validateStrings(string calldata bookingId, string calldata productVariantId, string calldata refId)
        internal
        pure
    {
        require(bytes(bookingId).length > 0 && bytes(bookingId).length <= MAX_STRING_LENGTH, "Invalid bookingId length");
        require(
            bytes(productVariantId).length > 0 && bytes(productVariantId).length <= MAX_STRING_LENGTH,
            "Invalid productVariantId length"
        );
        require(bytes(refId).length > 0 && bytes(refId).length <= MAX_STRING_LENGTH, "Invalid refId length");
    }
}
